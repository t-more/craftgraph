#!/usr/bin/env python3
"""CraftGraph sync: brings Blizzard's hourly auction house data into the addon.

The game cannot reach the internet, so this small program does it from
outside: it downloads the auction house you play on from Blizzard's own web
API, keeps an hourly history on your disk, works out what probably sold
between two hours, and writes a data file the addon reads at the next login
or /reload. Nothing is uploaded anywhere.

One-time setup (needs a free Battle.net API client, see the README):
    python3 craftgraph_sync.py setup

Then, as often as you like (the data changes once an hour):
    python3 craftgraph_sync.py run

Other commands:
    houses          list the auction houses and how well each matches your scans
    status          what has been collected so far
    install-timer   run it every hour in the background (Linux, systemd)
    remove-timer    stop that

Only the Python standard library is used.
"""

import argparse
import base64
import glob
import gzip
import hashlib
import json
import math
import os
import re
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

USER_AGENT = "craftgraph-sync"
MAX_LEVELS = 28
KEEP_HOURLY_DAYS = 14
SOLD_TIME_LEFT = {"LONG", "VERY_LONG"}   # gone with this much time left: sold, not expired
MAX_SOLD_GAP = 3 * 3600


# ----------------------------------------------------------------------------
# Where things live
# ----------------------------------------------------------------------------
def base_dirs():
    if os.name == "nt":
        root = Path(os.environ.get("APPDATA", Path.home())) / "CraftGraph"
        return root, root
    config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "craftgraph"
    data = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / "craftgraph"
    return config, data


CONFIG_DIR, DATA_DIR = base_dirs()
CONFIG_FILE = CONFIG_DIR / "sync.json"
DB_FILE = DATA_DIR / "market.sqlite"
ADDON_DIR = Path(__file__).resolve().parent.parent


def load_config():
    if CONFIG_FILE.exists():
        return json.loads(CONFIG_FILE.read_text())
    return {}


def save_config(cfg):
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))
    try:
        os.chmod(CONFIG_FILE, 0o600)      # it holds the API secret
    except OSError:
        pass


def saved_variables_file():
    """The addon's saved data, newest account first. The addon folder is
    <game>/Interface/AddOns/CraftGraph, so the account data is three up."""
    game = ADDON_DIR.parent.parent.parent
    found = glob.glob(str(game / "WTF" / "Account" / "*" / "SavedVariables" / "CraftGraph.lua"))
    found.sort(key=os.path.getmtime, reverse=True)
    return Path(found[0]) if found else None


# ----------------------------------------------------------------------------
# Reading the addon's saved data (a Lua table written by the game)
# ----------------------------------------------------------------------------
class LuaTable:
    NUMBER = re.compile(r"-?(?:0x[0-9a-fA-F]+|\d+\.?\d*(?:[eE][-+]?\d+)?|\.\d+)")
    NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

    def __init__(self, text):
        self.s, self.i = text, 0

    def skip(self):
        s, n = self.s, len(self.s)
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                end = s.find("\n", self.i)
                self.i = n if end < 0 else end
            else:
                break

    def value(self):
        self.skip()
        s = self.s
        c = s[self.i]
        if c == "{":
            return self.table()
        if c == '"':
            return self.string()
        for word, val in (("true", True), ("false", False), ("nil", None)):
            if s.startswith(word, self.i):
                self.i += len(word)
                return val
        m = self.NUMBER.match(s, self.i)
        if m:
            self.i = m.end()
            text = m.group()
            if text.lower().startswith(("0x", "-0x")):
                return int(text, 16)
            num = float(text)
            return int(num) if num.is_integer() and abs(num) < 1e15 else num
        m = self.NAME.match(s, self.i)       # inf, nan and the like
        if m:
            self.i = m.end()
            return None
        raise ValueError("cannot read saved data at position %d" % self.i)

    def string(self):
        s = self.s
        self.i += 1
        out = []
        while s[self.i] != '"':
            c = s[self.i]
            if c == "\\":
                self.i += 1
                c = s[self.i]
                if c.isdigit():
                    m = re.match(r"\d{1,3}", s[self.i:])
                    out.append(chr(int(m.group())))
                    self.i += len(m.group()) - 1
                else:
                    out.append({"n": "\n", "t": "\t", "r": "\r"}.get(c, c))
            else:
                out.append(c)
            self.i += 1
        self.i += 1
        # The game writes strings as UTF-8 bytes.
        try:
            return "".join(out).encode("latin-1").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            return "".join(out)

    def table(self):
        s = self.s
        self.i += 1
        out, index = {}, 1
        while True:
            self.skip()
            if s[self.i] == "}":
                self.i += 1
                return out
            if s[self.i] == "[":
                self.i += 1
                key = self.value()
                self.skip()
                self.i += 1              # ]
                self.skip()
                self.i += 1              # =
                out[key] = self.value()
            else:
                m = self.NAME.match(s, self.i)
                rest = s[m.end():m.end() + 3].lstrip() if m else ""
                if m and rest.startswith("=") and not rest.startswith("=="):
                    self.i = s.index("=", m.end()) + 1
                    out[m.group()] = self.value()
                else:
                    out[index] = self.value()
                    index += 1
            self.skip()
            if s[self.i] in ",;":
                self.i += 1


def read_saved(path):
    text = Path(path).read_text(encoding="latin-1")
    start = text.find("CraftGraphDB")
    if start < 0:
        return {}
    reader = LuaTable(text)
    reader.i = text.index("=", start) + 1
    return reader.value() or {}


def our_scan(saved):
    """Cheapest prices from the player's most recent in-game scans:
    realm key, {item: (cheapest price, time)}."""
    best_key, best = None, {}
    for key, realm in (saved.get("realms") or {}).items():
        prices = {}
        for item, rec in (realm.get("items") or {}).items():
            ladder = rec.get("l") if isinstance(rec, dict) else None
            if isinstance(ladder, dict) and ladder.get(1) and rec.get("lt") and not rec.get("ls"):
                prices[int(item)] = (ladder[1], rec["lt"])
        newest = max((t for _, t in prices.values()), default=0)
        if newest > max((t for _, t in best.values()), default=0):
            best_key, best = key, prices
    return best_key, best


# ----------------------------------------------------------------------------
# Blizzard's API
# ----------------------------------------------------------------------------
class Api:
    def __init__(self, cfg, fixture=None):
        self.cfg, self.fixture, self.token = cfg, fixture, None
        self.region = cfg.get("region", "eu")
        self.ruleset = int(cfg.get("ruleset", 1))

    def _get(self, url, headers):
        req = urllib.request.Request(url, headers=dict(headers, **{
            "User-Agent": USER_AGENT, "Accept-Encoding": "gzip"}))
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                body = gzip.decompress(body)
            return json.loads(body), resp.headers

    def login(self):
        if self.fixture:
            return
        if not self.cfg.get("client_id") or not self.cfg.get("client_secret"):
            sys.exit("No API key yet. Run:  python3 craftgraph_sync.py setup")
        auth = base64.b64encode(("%s:%s" % (self.cfg["client_id"], self.cfg["client_secret"])).encode()).decode()
        req = urllib.request.Request(
            "https://oauth.battle.net/token", data=b"grant_type=client_credentials",
            headers={"Authorization": "Basic " + auth, "User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                self.token = json.loads(resp.read())["access_token"]
        except urllib.error.HTTPError as err:
            sys.exit("Blizzard refused the API key (%s). Check the client ID and secret with 'setup'." % err.code)

    def get(self, path):
        """Returns (json, time the data was produced) or (None, None) when the
        route does not exist."""
        if self.fixture:
            name = path.strip("/").replace("/", "_") + ".json"
            file = Path(self.fixture) / name
            if not file.exists():
                return None, None
            return json.loads(file.read_text()), int(file.stat().st_mtime)
        url = "https://%s.api.blizzard.com%s?%s" % (self.region, path, urllib.parse.urlencode({
            "namespace": "dynamic-forever-" + self.region, "locale": "en_GB"}))
        try:
            data, headers = self._get(url, {"Authorization": "Bearer " + self.token})
        except urllib.error.HTTPError as err:
            if err.code == 404:
                return None, None
            raise
        stamp = None
        if headers.get("Last-Modified"):
            try:
                import email.utils
                stamp = int(email.utils.parsedate_to_datetime(headers["Last-Modified"]).timestamp())
            except (TypeError, ValueError):
                stamp = None
        return data, stamp or int(time.time())

    def houses(self):
        # The trailing slash matters on this route.
        data, _ = self.get("/data/wow/ruleset/%d/auctions/" % self.ruleset)
        if not data:
            sys.exit("Blizzard's API did not list any auction houses for ruleset %d." % self.ruleset)
        return [(int(h["id"]), str(h.get("name") or h["id"])) for h in data.get("auctions", [])]

    def listings(self, house):
        """Every listing of one house as (auction id, item, unit price,
        quantity, time left), plus the time of the snapshot."""
        base = "/data/wow/ruleset/%d/auctions/%d" % (self.ruleset, house)
        detail, stamp = self.get(base)
        if detail is None:
            return [], None
        out = []

        def add(rows, unit_key):
            for a in rows or []:
                item = a.get("item")
                item = item.get("id") if isinstance(item, dict) else item
                qty = int(a.get("quantity") or 1)
                if unit_key == "unit_price":
                    unit = a.get("unit_price")
                else:
                    unit = a.get("buyout")
                    unit = unit / qty if unit else None      # buyout is for the whole stack
                if item and unit and unit > 0 and qty > 0:
                    out.append((int(a.get("id") or 0), int(item), float(unit), qty, str(a.get("time_left") or "")))

        auctions = detail.get("auctions")
        if isinstance(auctions, list):
            add(auctions, "buyout")
        commodities = detail.get("commodities")
        if isinstance(commodities, list):
            add(commodities, "unit_price")
        else:
            data, stamp2 = self.get(base + "/commodities")
            if data:
                add(data.get("auctions"), "unit_price")
                stamp = max(stamp or 0, stamp2 or 0)
        return out, stamp


# ----------------------------------------------------------------------------
# Price ladders (the same shape the addon uses)
# ----------------------------------------------------------------------------
def compress(pairs):
    """pairs: [(unit price, quantity)]. Returns ([price, qty, ...], total, tolerance)."""
    levels = {}
    for price, qty in pairs:
        price = int(price + 0.5)
        levels[price] = levels.get(price, 0) + qty
    flat = sorted(levels.items())
    total = sum(q for _, q in flat)
    if len(flat) <= MAX_LEVELS:
        return [x for pq in flat for x in pq], total, None
    tol = 0.02
    while True:
        out, start, qty, cost = [], None, 0, 0
        for price, n in flat:
            if start is not None and price > start * (1 + tol):
                out.append((int(cost / qty + 0.5), qty))
                start, qty, cost = None, 0, 0
            if start is None:
                start = price
            qty += n
            cost += price * n
        if qty:
            out.append((int(cost / qty + 0.5), qty))
        if len(out) <= MAX_LEVELS or tol > 4:
            return [x for pq in out for x in pq], total, tol
        tol *= 2


def robust_price(flat, total):
    """Average of the cheapest tenth: steadier than the single cheapest listing."""
    want = max(1, min(50, math.ceil(total * 0.1)))
    cost = got = 0
    for i in range(0, len(flat), 2):
        take = min(flat[i + 1], want - got)
        cost += take * flat[i]
        got += take
        if got >= want:
            break
    return int(cost / got + 0.5) if got else 0


# ----------------------------------------------------------------------------
# Local history
# ----------------------------------------------------------------------------
def open_db():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(str(DB_FILE))
    db.executescript("""
        CREATE TABLE IF NOT EXISTS snapshot (house INT, t INT, auctions INT, PRIMARY KEY (house, t));
        CREATE TABLE IF NOT EXISTS price (house INT, t INT, item INT, minp INT, robust INT, qty INT,
            PRIMARY KEY (house, t, item)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS latest (house INT, item INT, t INT, ladder TEXT, qty INT, blur REAL,
            PRIMARY KEY (house, item)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS live (house INT, aid INT, item INT, unit REAL, qty INT, tl TEXT,
            PRIMARY KEY (house, aid)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS sold (house INT, t INT, item INT, qty INT, value REAL,
            PRIMARY KEY (house, t, item)) WITHOUT ROWID;
        -- The player's own in-game scans, kept in full for good. The addon
        -- thins its saved history as it ages; nothing is thinned here.
        CREATE TABLE IF NOT EXISTS scan (realm TEXT, item INT, t INT, minp INT, robust INT, qty INT,
            PRIMARY KEY (realm, item, t)) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS scan_time ON scan (realm, t);
        -- The full price ladder of each item as last scanned: JSON [price, qty, ...].
        CREATE TABLE IF NOT EXISTS scan_ladder (realm TEXT, item INT, t INT, ladder TEXT, qty INT,
            PRIMARY KEY (realm, item, t)) WITHOUT ROWID;
        -- Every saved file that has been imported, so none is read twice.
        CREATE TABLE IF NOT EXISTS imported (sha TEXT PRIMARY KEY, path TEXT, mtime INT, size INT,
            t INT, points INT, added INT, raw TEXT);
        -- Files already looked at, by name, time and size: these are not opened again.
        CREATE TABLE IF NOT EXISTS seen_file (path TEXT PRIMARY KEY, mtime INT, size INT);
    """)
    return db


def store_snapshot(db, house, stamp, rows):
    """Adds one hourly snapshot. Returns False when it is already stored."""
    last = db.execute("SELECT MAX(t) FROM snapshot WHERE house=?", (house,)).fetchone()[0]
    if last and stamp - last < 20 * 60:
        return False

    # What disappeared since the last snapshot with plenty of time left is
    # taken as sold; a unit-sale listing that shrank sold the difference.
    if last and stamp - last <= MAX_SOLD_GAP:
        now_live = {aid: qty for aid, _, _, qty, _ in rows if aid}
        sold = {}
        for aid, item, unit, qty, tl in db.execute(
                "SELECT aid, item, unit, qty, tl FROM live WHERE house=?", (house,)):
            gone = 0
            if aid not in now_live:
                if tl in SOLD_TIME_LEFT:
                    gone = qty
            elif now_live[aid] < qty:
                gone = qty - now_live[aid]
            if gone:
                q, v = sold.get(item, (0, 0.0))
                sold[item] = (q + gone, v + gone * unit)
        db.executemany("INSERT OR REPLACE INTO sold VALUES (?,?,?,?,?)",
                       [(house, stamp, item, q, v) for item, (q, v) in sold.items()])

    db.execute("DELETE FROM live WHERE house=?", (house,))
    db.executemany("INSERT OR REPLACE INTO live VALUES (?,?,?,?,?,?)",
                   [(house, aid, item, unit, qty, tl) for aid, item, unit, qty, tl in rows if aid])

    by_item = {}
    for _, item, unit, qty, _ in rows:
        by_item.setdefault(item, []).append((unit, qty))
    for item, pairs in by_item.items():
        flat, total, blur = compress(pairs)
        db.execute("INSERT OR REPLACE INTO price VALUES (?,?,?,?,?,?)",
                   (house, stamp, item, flat[0], robust_price(flat, total), total))
        db.execute("INSERT OR REPLACE INTO latest VALUES (?,?,?,?,?,?)",
                   (house, item, stamp, json.dumps(flat), total, blur))
    db.execute("INSERT OR REPLACE INTO snapshot VALUES (?,?,?)", (house, stamp, len(rows)))

    # Older than two weeks: keep one snapshot a day.
    cutoff = stamp - KEEP_HOURLY_DAYS * 86400
    db.execute("""DELETE FROM price WHERE house=? AND t<? AND t NOT IN
                  (SELECT MIN(t) FROM snapshot WHERE house=? AND t<? GROUP BY t/86400)""",
               (house, cutoff, house, cutoff))
    db.execute("DELETE FROM sold WHERE house=? AND t<?", (house, stamp - 60 * 86400))
    db.commit()
    return True


# ----------------------------------------------------------------------------
# Which house is ours
# ----------------------------------------------------------------------------
def match_score(rows, ours, now):
    """How many of our recently scanned cheapest prices this house agrees with."""
    cheapest = {}
    for _, item, unit, _, _ in rows:
        if item not in cheapest or unit < cheapest[item]:
            cheapest[item] = unit
    common = hits = 0
    for item, (price, when) in ours.items():
        if now - when <= 12 * 3600 and item in cheapest:
            common += 1
            if abs(cheapest[item] / price - 1) <= 0.02:
                hits += 1
    return hits, common


def pick_house(api, cfg, saved, verbose=False):
    realm, ours = our_scan(saved)
    if cfg.get("house") and cfg.get("house_realm") == realm and not verbose:
        return int(cfg["house"]), cfg.get("house_name", ""), realm
    if not ours:
        sys.exit("No in-game scan found. Do a full scan with CraftGraph in the game, log out or /reload, "
                 "and run this again: the scan tells me which auction house is yours.")
    now = int(time.time())
    newest = max(t for _, t in ours.values())
    if now - newest > 12 * 3600 and not api.fixture:
        sys.exit("Your last in-game scan is %.0f hours old. Do a fresh full scan, /reload, and run this "
                 "again within a few hours, so the prices can be matched to the right auction house."
                 % ((now - newest) / 3600))
    houses = api.houses()
    faction = None
    for word in ("Alliance", "Horde"):
        if realm and word in realm:
            faction = word
    named = [h for h in houses if faction and faction.lower() in h[1].lower()]
    candidates = named or houses
    scored = []
    for house, name in candidates:
        rows, _ = api.listings(house)
        hits, common = match_score(rows, ours, now if not api.fixture else newest)
        scored.append((hits / common if common else 0.0, hits, common, house, name))
        if verbose:
            print("  house %3d  %-28s %5d listings, %4d of %4d of your prices match"
                  % (house, name[:28], len(rows), hits, common))
    scored.sort(reverse=True)
    best = scored[0]
    second = scored[1][0] if len(scored) > 1 else 0.0
    if best[2] < 30 or best[0] < 0.4 or best[0] < second * 1.3:
        sys.exit("Could not tell which auction house is yours (best match %d of %d prices). "
                 "Do a fresh full scan in the game, /reload, and try again soon after."
                 % (best[1], best[2]))
    cfg["house"], cfg["house_name"], cfg["house_realm"] = best[3], best[4], realm
    save_config(cfg)
    return best[3], best[4], realm


# ----------------------------------------------------------------------------
# Writing the addon's data file
# ----------------------------------------------------------------------------
def tracked_items(saved):
    """Items the addon knows: everything in its recipe data, plus what the
    player has scanned."""
    items = set()
    recipes = ADDON_DIR / "Data" / "Recipes.lua"
    if recipes.exists():
        in_items = False
        for line in recipes.read_text(encoding="utf-8").splitlines():
            if line.startswith("ns.Data.items"):
                in_items = True
            elif in_items:
                m = re.match(r"\[(\d+)\]=", line)
                if m:
                    items.add(int(m.group(1)))
    for realm in (saved.get("realms") or {}).values():
        for item in (realm.get("items") or {}):
            items.add(int(item))
    return items


def lua_list(values):
    return "{" + ",".join(("%d" % v) if float(v).is_integer() else ("%.4g" % v) for v in values) + "}"


def write_online(db, house, name, realm, items):
    now = db.execute("SELECT MAX(t) FROM snapshot WHERE house=?", (house,)).fetchone()[0]
    if not now:
        return 0
    count = db.execute("SELECT COUNT(*) FROM snapshot WHERE house=?", (house,)).fetchone()[0]
    first = db.execute("SELECT MIN(t) FROM snapshot WHERE house=?", (house,)).fetchone()[0]

    # Sales a day, over the stretch of the last week that snapshots cover.
    week = now - 7 * 86400
    stamps = [t for (t,) in db.execute("SELECT t FROM snapshot WHERE house=? AND t>=? ORDER BY t", (house, week))]
    covered = sum(b - a for a, b in zip(stamps, stamps[1:]) if b - a <= MAX_SOLD_GAP) / 86400
    sold = {}
    if covered >= 0.2:
        for item, qty in db.execute(
                "SELECT item, SUM(qty) FROM sold WHERE house=? AND t>=? GROUP BY item", (house, week)):
            sold[item] = qty / covered

    lines = []
    written = 0
    latest = {item: (t, ladder, qty, blur) for item, t, ladder, qty, blur in db.execute(
        "SELECT item, t, ladder, qty, blur FROM latest WHERE house=?", (house,))}
    history = {}
    for item, t, robust, qty in db.execute(
            "SELECT item, t, robust, qty FROM price WHERE house=? ORDER BY t", (house,)):
        if item in items:
            history.setdefault(item, []).append((t, robust, qty))

    for item in sorted(items):
        points = history.get(item)
        if not points:
            continue
        parts = []
        t, ladder, qty, blur = latest[item]
        if t == now:
            parts.append("t=%d,n=%d,l=%s" % (t, qty, lua_list(json.loads(ladder))))
            if blur:
                parts.append("z=%.4g" % blur)
        else:
            parts.append("t=%d,n=0,l={}" % now)          # nothing listed in the latest snapshot
        if covered >= 0.2:
            parts.append("v=%.4g" % sold.get(item, 0))

        # History for the price model: hourly for two days, then one a day.
        kept, last_day = [], None
        for t, robust, qty in points:
            if now - t <= 48 * 3600:
                kept.append((t, robust, qty))
            else:
                day = t // 86400
                if day != last_day:
                    kept.append((t, robust, qty))
                    last_day = day
        parts.append("h=" + lua_list([x for p in kept[-140:] for x in p]))

        # Hour of day and day of week, in this computer's local time (the
        # same clock the game shows).
        mean = sum(math.log(max(r, 1)) for _, r, _ in points) / len(points)
        for key, fmt in (("hd", lambda tm: tm.tm_hour), ("wd", lambda tm: (tm.tm_wday + 1) % 7)):
            tally = {}
            for t, robust, qty in points:
                slot = fmt(time.localtime(t))
                n, rel, total = tally.get(slot, (0, 0.0, 0))
                tally[slot] = (n + 1, rel + math.log(max(robust, 1)) - mean, total + qty)
            parts.append(key + "={" + ",".join(
                "[%d]={%d,%.4g,%d}" % (slot, n, rel, total) for slot, (n, rel, total) in sorted(tally.items())) + "}")
        lines.append("[%d]={%s}," % (item, ",".join(parts)))
        written += 1

    out = ADDON_DIR / "Data" / "Online.lua"
    text = [
        "-- Written by sync/craftgraph_sync.py from Blizzard's auction house API. Do not edit.",
        "local _, ns = ...",
        "ns.Online = {",
        "  house = %d, name = %s, realm = %s," % (house, json.dumps(name), json.dumps(realm or "")),
        "  updated = %d, first = %d, snapshots = %d, soldDays = %.3g," % (now, first, count, covered),
        "  items = {",
    ]
    text.extend(lines)
    text.append("  },")
    text.append("}")
    tmp = out.with_suffix(".tmp")
    tmp.write_text("\n".join(text) + "\n", encoding="utf-8")
    os.replace(tmp, out)
    return written


# ----------------------------------------------------------------------------
# Commands
# ----------------------------------------------------------------------------
def cmd_setup(args):
    cfg = load_config()
    print("This needs a free Battle.net API client:")
    print("  1. Open https://develop.battle.net/access/clients and sign in.")
    print("  2. Create a client (any name; no redirect URL needed).")
    print("  3. Copy its Client ID and Client Secret here.")
    client_id = input("Client ID: ").strip()
    secret = input("Client Secret: ").strip()
    region = input("Region [%s]: " % cfg.get("region", "eu")).strip().lower() or cfg.get("region", "eu")
    print("Rulesets: 1 PvP, 2 Normal, 3 Roleplay, 15 Roleplay PvP")
    ruleset = input("Ruleset [%s]: " % cfg.get("ruleset", 1)).strip() or cfg.get("ruleset", 1)
    cfg.update(client_id=client_id, client_secret=secret, region=region, ruleset=int(ruleset))
    cfg.pop("house", None)
    save_config(cfg)
    print("Saved to %s (readable only by you)." % CONFIG_FILE)
    print("Now do a full scan in the game, /reload, and run:  python3 %s run" % Path(__file__).name)


def load_saved():
    path = saved_variables_file()
    if not path:
        sys.exit("The addon has no saved data yet. Play once with CraftGraph loaded, then log out or /reload.")
    return read_saved(path)


def cmd_run(args):
    cfg = load_config()
    if not args.fixture:
        say_if_newer(note_latest())
    api = Api(cfg, args.fixture)
    api.login()
    saved = load_saved()
    house, name, realm = pick_house(api, cfg, saved)
    rows, stamp = api.listings(house)
    if not rows:
        sys.exit("The auction house (%d) came back empty. Try again later." % house)
    db = open_db()
    import_all(db, verbose=False)       # keep the player's own scans too
    fresh = store_snapshot(db, house, stamp, rows)
    written = write_online(db, house, name, realm, tracked_items(saved))
    count = db.execute("SELECT COUNT(*) FROM snapshot WHERE house=?", (house,)).fetchone()[0]
    print("%s: %d listings %s; %d snapshots kept; prices for %d items written for the addon."
          % (name or house, len(rows), "stored" if fresh else "already stored", count, written))
    print("They load at your next login or /reload.")


def cmd_houses(args):
    cfg = load_config()
    api = Api(cfg, args.fixture)
    api.login()
    house, name, realm = pick_house(api, cfg, load_saved(), verbose=True)
    print("Yours is house %d (%s), matched to \"%s\"." % (house, name, realm))


def lua_array(table):
    """A Lua array read as {1: a, 2: b, ...} (or a list) as a Python list."""
    if isinstance(table, list):
        return table
    if not isinstance(table, dict):
        return []
    out, i = [], 1
    while i in table:
        out.append(table[i])
        i += 1
    return out


def unpack_history(packed):
    """The addon's packed older history ("dt,price,robust,qty;...", time as
    seconds since the point before) as the same flat list as its table."""
    flat, t = [], 0
    if not isinstance(packed, str):
        return flat
    for point in packed.split(";"):
        parts = point.split(",")
        if len(parts) == 4:
            t += int(parts[0])
            flat += [t, int(parts[1]), int(parts[2]), int(parts[3])]
    return flat


def archive_saved(db, saved):
    """Copies the price points the addon has saved into the scan table.
    Only points newer than the newest one already stored for an item are
    written, so the work stays small however long the history grows.
    Returns (rows added, points seen)."""
    added = seen = 0
    newest = {}
    for realm, item, t in db.execute("SELECT realm, item, MAX(t) FROM scan GROUP BY realm, item"):
        newest[(realm, item)] = t
    points, ladders = [], []
    for realm, data in (saved.get("realms") or {}).items():
        for item, rec in (data.get("items") or {}).items():
            if not isinstance(rec, dict):
                continue
            item = int(item)
            h = unpack_history(rec.get("hp")) + lua_array(rec.get("h"))
            seen += len(h) // 4
            last = newest.get((realm, item), 0)
            # History is in time order: walk back from the end to the first new point.
            i = len(h) - 4
            while i >= 0 and h[i] > last:
                points.append((realm, item, int(h[i]), int(h[i + 1]), int(h[i + 2]), int(h[i + 3])))
                i -= 4
            ladder = lua_array(rec.get("l"))
            if ladder and rec.get("lt") and not rec.get("ls"):
                ladders.append((realm, item, int(rec["lt"]), json.dumps(ladder), int(rec.get("ln") or 0)))
    before = db.total_changes
    db.executemany("INSERT OR IGNORE INTO scan VALUES (?,?,?,?,?,?)", points)
    db.executemany("INSERT OR IGNORE INTO scan_ladder VALUES (?,?,?,?,?)", ladders)
    added = db.total_changes - before
    return added, seen


RAW_DIR = DATA_DIR / "raw"
RAW_KEEP_ALL_DAYS = 7      # every raw copy for a week, then one a day


def prune_raw(db):
    """Keeps the raw copies from growing without end: all of the last week,
    then the last copy of each day. The database keeps every price point."""
    now = time.time()
    by_day = {}
    for sha, t, raw in db.execute("SELECT sha, t, raw FROM imported WHERE raw IS NOT NULL ORDER BY t"):
        if now - t > RAW_KEEP_ALL_DAYS * 86400:
            by_day.setdefault(time.strftime("%Y-%m-%d", time.localtime(t)), []).append((sha, raw))
    for copies in by_day.values():
        for sha, raw in copies[:-1]:
            try:
                Path(raw).unlink()
            except OSError:
                pass
            db.execute("UPDATE imported SET raw=NULL WHERE sha=?", (sha,))


def import_file(db, path, keep_raw=True):
    """Imports one saved file (plain or .gz) unless it has been imported
    before. A file whose name, time and size are known is not even opened.
    Returns (rows added, points seen), or None when there was nothing new."""
    path = Path(path)
    stat = path.stat()
    known = db.execute("SELECT 1 FROM seen_file WHERE path=? AND mtime=? AND size=?",
                       (str(path), int(stat.st_mtime), stat.st_size)).fetchone()
    if known:
        return None
    db.execute("INSERT OR REPLACE INTO seen_file VALUES (?,?,?)", (str(path), int(stat.st_mtime), stat.st_size))
    data = path.read_bytes()
    if path.suffix == ".gz":
        data = gzip.decompress(data)
    sha = hashlib.sha1(data).hexdigest()
    if db.execute("SELECT 1 FROM imported WHERE sha=?", (sha,)).fetchone():
        # The same content under another name or date: nothing to do.
        db.commit()
        return None
    text = data.decode("latin-1")
    start = text.find("CraftGraphDB")
    saved = {}
    if start >= 0:
        reader = LuaTable(text)
        reader.i = text.index("=", start) + 1
        saved = reader.value() or {}
    added, seen = archive_saved(db, saved)
    raw = None
    if keep_raw and RAW_DIR not in path.parents:
        RAW_DIR.mkdir(parents=True, exist_ok=True)
        raw = RAW_DIR / ("CraftGraph-%s.lua.gz" % time.strftime("%Y%m%d-%H%M%S", time.localtime(stat.st_mtime)))
        with gzip.open(str(raw), "wb", compresslevel=6) as out:
            out.write(data)
    elif RAW_DIR in path.parents:
        raw = path
    db.execute("INSERT OR REPLACE INTO imported VALUES (?,?,?,?,?,?,?,?)",
               (sha, str(path), int(stat.st_mtime), stat.st_size, int(stat.st_mtime), seen, added,
                str(raw) if raw else None))
    db.commit()
    return added, seen


def import_all(db, verbose=True):
    """Imports the game's saved file and any raw copy in the raw folder
    that is not in the database yet (one dropped in by hand, say)."""
    total = files = 0
    sources = []
    live = saved_variables_file()
    if live:
        sources.append(live)
    if RAW_DIR.exists():
        sources += sorted(p for p in RAW_DIR.iterdir() if p.name.endswith((".lua", ".lua.gz")))
    for source in sources:
        try:
            result = import_file(db, source)
        except Exception as error:                      # a half-written or damaged file
            if verbose:
                print("Skipped %s: %s" % (source, error))
            continue
        if result:
            files += 1
            total += result[0]
            if verbose:
                print("Imported %s: %d new rows from %d price points." % (source.name, result[0], result[1]))
    prune_raw(db)
    db.commit()
    return files, total


def cmd_archive(args):
    """Needs no Blizzard account: it only reads the addon's saved file."""
    db = open_db()
    say_if_newer(note_latest())
    files, _ = import_all(db)
    if not files:
        print("Nothing new: every saved file is already in the database.")
    n, items, first, last = db.execute("SELECT COUNT(*), COUNT(DISTINCT item), MIN(t), MAX(t) FROM scan").fetchone()
    if n:
        print("The archive holds %d price points for %d items, from %s to %s." % (
            n, items, time.strftime("%d %b %H:%M", time.localtime(first)),
            time.strftime("%d %b %H:%M", time.localtime(last))))
    copies = db.execute("SELECT COUNT(*) FROM imported WHERE raw IS NOT NULL").fetchone()[0]
    print("Database: %s (%.1f MB). Raw copies: %d in %s" % (DB_FILE, DB_FILE.stat().st_size / 1e6, copies, RAW_DIR))


def cmd_install_watch(args):
    """Imports by itself: when this computer starts a session, and every
    time the game writes its saved file (logout, /reload, exit)."""
    if os.name == "nt":
        sys.exit("On Windows use Task Scheduler to run:  python craftgraph_sync.py archive  at logon.")
    live = saved_variables_file()
    if not live:
        sys.exit("The addon has no saved data yet. Play once with CraftGraph loaded, then log out or /reload.")
    UNIT_DIR.mkdir(parents=True, exist_ok=True)
    (UNIT_DIR / "craftgraph-archive.service").write_text(
        "[Unit]\nDescription=Import CraftGraph scans into its database\n\n[Service]\nType=oneshot\n"
        "ExecStart=%s %s archive\n\n[Install]\nWantedBy=default.target\n"
        % (sys.executable, json.dumps(str(Path(__file__).resolve()))))
    (UNIT_DIR / "craftgraph-archive.path").write_text(
        "[Unit]\nDescription=Watch the CraftGraph saved file\n\n[Path]\nPathChanged=%s\n"
        "Unit=craftgraph-archive.service\n\n[Install]\nWantedBy=default.target\n" % live)
    os.system("systemctl --user daemon-reload && systemctl --user enable craftgraph-archive.service "
              "&& systemctl --user enable --now craftgraph-archive.path")
    print("Installed. Scans are imported when you log in to this computer and whenever the game saves.")


def cmd_remove_watch(args):
    os.system("systemctl --user disable --now craftgraph-archive.path; "
              "systemctl --user disable craftgraph-archive.service")
    for name in ("craftgraph-archive.service", "craftgraph-archive.path"):
        file = UNIT_DIR / name
        if file.exists():
            file.unlink()
    os.system("systemctl --user daemon-reload")
    print("Removed.")


# ----------------------------------------------------------------------------
# Sharing prices as files (.cg.json)
# ----------------------------------------------------------------------------
SHARE_FORMAT = "craftgraph-prices"


def build_export(saved):
    """The prices of the player's own scans from the last day, as the share
    format: (document, realm). The realm with the most fresh prices wins."""
    best_realm, items = None, {}
    now = int(time.time())
    for realm, data in (saved.get("realms") or {}).items():
        found = {}
        for item, rec in (data.get("items") or {}).items():
            ladder = lua_array(rec.get("l")) if isinstance(rec, dict) else []
            if ladder and rec.get("lt") and not rec.get("ls") and now - rec["lt"] < 86400:
                found[str(int(item))] = {"t": int(rec["lt"]), "n": int(rec.get("ln") or 0),
                                         "l": [int(round(x)) for x in ladder[:16]]}
        if len(found) > len(items):
            best_realm, items = realm, found
    if not items:
        return None, None
    # The character: the one this realm's saved data knows best.
    name, most = "someone", -1
    for key, char in (saved.get("chars") or {}).items():
        known = len(char.get("known") or {}) if isinstance(char, dict) else 0
        if known > most:
            name, most = str(key).split(" - ")[0], known
    made = max(entry["t"] for entry in items.values())
    return {"format": SHARE_FORMAT, "version": 1, "realm": best_realm, "from": name, "made": made, "items": items}, best_realm


def cmd_share_export(args):
    """Writes the prices of your scans from the last day to a .cg.json file
    that another player can import. The same JSON the game's Export makes."""
    document, realm = build_export(load_saved())
    if not document:
        sys.exit("No scan of your own in the last day to export. Do a full scan, then log out or /reload.")
    target = Path(args.file) if args.file else Path.cwd() / ("CraftGraph-%s.cg.json" % time.strftime("%Y%m%d-%H%M"))
    target.write_text(json.dumps(document, separators=(",", ":")))
    print("Exported %d prices for \"%s\" to %s" % (len(document["items"]), realm, target))


def cmd_share_import(args):
    """Puts a .cg.json file where the game reads it at the next login."""
    if not args.file:
        sys.exit("Which file?  craftgraph_sync.py share-import <file.cg.json>")
    text = Path(args.file).read_text(encoding="utf-8")
    try:
        data = json.loads(text)
    except ValueError as error:
        sys.exit("%s is not valid JSON: %s" % (args.file, error))
    if data.get("format") != SHARE_FORMAT or not isinstance(data.get("items"), dict):
        sys.exit("%s is JSON, but not CraftGraph prices." % args.file)
    level = 0
    while ("]" + "=" * level + "]") in text:
        level += 1
    (ADDON_DIR / "Data" / "Shared.lua").write_text(
        "-- Put here by sync/craftgraph_sync.py share-import. Read by the addon at login.\n"
        "local _, ns = ...\n"
        "ns.SharedFile = [%s[%s]%s]\n" % ("=" * level, text, "=" * level), encoding="utf-8")
    print("Ready: %d prices for \"%s\" from %s." % (len(data["items"]), data.get("realm"), data.get("from")))
    print("Log in (or /reload) and the game says in chat how many it took in.")


# ----------------------------------------------------------------------------
# The shared data repository on GitHub (optional)
#
# Players who want to can put the prices of their latest scans in one public
# repository, each in a file of their own named after their GitHub account
# and tagged with their character's name. Everyone can read it without an
# account; writing needs a GitHub account that the repository's owner has
# let in. The addon then lists each player as a data source of their own.
# ----------------------------------------------------------------------------
DATA_REPOSITORY = "t-more/craftgraph-data"


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", str(text).lower()).strip("-") or "realm"


def github_token():
    for name in ("CRAFTGRAPH_GITHUB_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"):
        if os.environ.get(name):
            return os.environ[name]
    try:
        import subprocess
        out = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=10)
        return out.stdout.strip() or None
    except Exception:
        return None


def github(path, token=None, method="GET", body=None):
    headers = {"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request("https://api.github.com" + path, data=data, headers=headers, method=method)
    return json.loads(urllib.request.urlopen(request, timeout=30).read() or b"null")


def cmd_data_publish(args):
    """Puts your latest prices in the shared repository under your GitHub
    account. Your character's name and your GitHub name become public."""
    document, realm = build_export(load_saved())
    if not document:
        sys.exit("No scan of your own in the last day to share. Do a full scan, then log out or /reload.")
    token = github_token()
    if not token:
        sys.exit("To share you need a GitHub account on this computer: install the GitHub CLI and run "
                 "'gh auth login', or set GITHUB_TOKEN. Reading what others share needs none.")
    try:
        login = github("/user", token)["login"]
    except urllib.error.HTTPError as error:
        sys.exit("GitHub did not accept the login (%s)." % error.code)
    document["github"] = login
    path = "/repos/%s/contents/data/%s/%s.cg.json" % (DATA_REPOSITORY, slug(realm), login)
    sha = None
    try:
        sha = github(path, token)["sha"]
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
    text = json.dumps(document, separators=(",", ":"))
    body = {"message": "Prices from %s (%s), %d items" % (document["from"], login, len(document["items"])),
            "content": base64.b64encode(text.encode()).decode()}
    if sha:
        body["sha"] = sha
    try:
        github(path, token, "PUT", body)
    except urllib.error.HTTPError as error:
        if error.code in (403, 404):
            sys.exit("You are not let in to the shared repository yet. Ask its owner to add your GitHub "
                     "account (%s) at https://github.com/%s" % (login, DATA_REPOSITORY))
        raise
    print("Shared %d prices for \"%s\" as %s (GitHub: %s)." % (len(document["items"]), realm, document["from"], login))
    return login


def cmd_data_pull(args, own=None):
    """Fetches what other players have shared for your auction house and
    puts it where the game reads it at login. Needs no account."""
    saved = load_saved()
    _, realm = build_export(saved)
    if not realm:
        realms = list((saved.get("realms") or {}).keys())
        realm = realms[0] if realms else None
    if not realm:
        sys.exit("The addon has no saved data yet, so the auction house is not known.")
    token = github_token()
    if own is None and token:
        try:
            own = github("/user", token)["login"]
        except Exception:
            own = None
    try:
        listing = github("/repos/%s/contents/data/%s" % (DATA_REPOSITORY, slug(realm)), token)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            listing = []
        else:
            raise
    texts, lines, others = [], [], 0
    for entry in listing:
        name = entry.get("name", "")
        if not name.endswith(".cg.json"):
            continue
        request = urllib.request.Request(entry["download_url"], headers={"User-Agent": USER_AGENT})
        text = urllib.request.urlopen(request, timeout=60).read().decode("utf-8")
        try:
            data = json.loads(text)
        except ValueError:
            continue
        if data.get("format") != SHARE_FORMAT or data.get("realm") != realm:
            continue
        # The file name is the account that wrote it; that is who it is from.
        data["github"] = name[:-len(".cg.json")]
        texts.append(json.dumps(data, separators=(",", ":")))
        # Your own file goes along too: the game does not import it, but
        # shows that you are there.
        mine = own and data["github"].lower() == own.lower()
        if not mine:
            others += 1
        lines.append("  %s (GitHub: %s): %d prices, scanned %s%s" % (
            data.get("from"), data["github"], len(data.get("items") or {}),
            time.strftime("%d %b %H:%M", time.localtime(data.get("made", 0))),
            " (you: shown in game, not imported)" if mine else ""))
    chunks = []
    for text in texts:
        level = 0
        while ("]" + "=" * level + "]") in text:
            level += 1
        chunks.append("  [%s[%s]%s]," % ("=" * level, text, "=" * level))
    (ADDON_DIR / "Data" / "Shared.lua").write_text(
        "-- Put here by sync/craftgraph_sync.py data-pull: what other players shared.\n"
        "local _, ns = ...\n"
        "ns.SharedFile = {\n%s\n}\n" % "\n".join(chunks), encoding="utf-8")
    if lines:
        print("Fetched prices from %d other players for \"%s\":" % (others, realm))
        print("\n".join(lines))
        print("Log in (or /reload): the game lists each of them under Data sources.")
    else:
        print("Nobody else has shared prices for \"%s\" yet." % realm)


def cmd_data_sync(args):
    """Shares yours and fetches the others': the two together."""
    own = None
    if github_token():
        own = cmd_data_publish(args)
    else:
        print("No GitHub account on this computer: only fetching what others share.")
    cmd_data_pull(args, own)


# ----------------------------------------------------------------------------
# Is there a newer version of the addon?
# ----------------------------------------------------------------------------
REPOSITORY = "t-more/craftgraph"
RELEASES_URL = "https://github.com/%s/releases/latest" % REPOSITORY
CHECK_EVERY = 20 * 3600


def version_tuple(text):
    return tuple(int(n) for n in re.findall(r"\d+", str(text)))


def addon_version():
    for line in (ADDON_DIR / "CraftGraph.toc").read_text(encoding="utf-8").splitlines():
        if line.startswith("## Version:"):
            return line.split(":", 1)[1].strip()
    return "0"


def note_latest(force=False):
    """Asks GitHub for the newest release (no account needed) and writes it
    to Data/Latest.lua for the addon. At most once in twenty hours unless
    forced. Returns (version, url) or None if it could not be found out."""
    stamp = DATA_DIR / "latest.json"
    try:
        if not force and stamp.exists():
            seen = json.loads(stamp.read_text())
            if time.time() - seen.get("checked", 0) < CHECK_EVERY:
                return seen.get("version"), seen.get("url")
        request = urllib.request.Request(
            "https://api.github.com/repos/%s/releases/latest" % REPOSITORY,
            headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"})
        release = json.loads(urllib.request.urlopen(request, timeout=10).read())
        version = str(release.get("tag_name", "")).lstrip("vV")
        url = release.get("html_url") or RELEASES_URL
        if not version_tuple(version):
            return None
        now = int(time.time())
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        stamp.write_text(json.dumps({"version": version, "url": url, "checked": now}))
        (ADDON_DIR / "Data" / "Latest.lua").write_text(
            "-- Written by sync/craftgraph_sync.py: the newest release when last looked up.\n"
            "local _, ns = ...\n"
            "ns.Latest = { version = %s, url = %s, checked = %d }\n" % (json.dumps(version), json.dumps(url), now),
            encoding="utf-8")
        return version, url
    except Exception:
        return None


def say_if_newer(latest):
    if latest and version_tuple(latest[0]) > version_tuple(addon_version()):
        print("A newer CraftGraph is out: %s (you have %s). %s" % (latest[0], addon_version(), latest[1]))
        return True
    return False


def cmd_check_update(args):
    latest = note_latest(force=True)
    if not latest:
        print("Could not reach GitHub to look for a newer version. See %s" % RELEASES_URL)
    elif not say_if_newer(latest):
        print("You have the newest version (%s)." % addon_version())
    if latest:
        print("The game shows this at your next login or /reload.")


def cmd_status(args):
    cfg = load_config()
    print("Config: %s%s" % (CONFIG_FILE, "" if CONFIG_FILE.exists() else " (not set up yet)"))
    if cfg.get("house"):
        print("Auction house: %s (%s) for \"%s\"" % (cfg["house"], cfg.get("house_name"), cfg.get("house_realm")))
    if DB_FILE.exists():
        db = open_db()
        for house, n, first, last in db.execute(
                "SELECT house, COUNT(*), MIN(t), MAX(t) FROM snapshot GROUP BY house"):
            print("History: house %d, %d snapshots from %s to %s" % (
                house, n, time.strftime("%d %b %H:%M", time.localtime(first)),
                time.strftime("%d %b %H:%M", time.localtime(last))))
        n, items, first, last = db.execute(
            "SELECT COUNT(*), COUNT(DISTINCT item), MIN(t), MAX(t) FROM scan").fetchone()
        if n:
            print("Your own scans: %d price points for %d items from %s to %s" % (
                n, items, time.strftime("%d %b %H:%M", time.localtime(first)),
                time.strftime("%d %b %H:%M", time.localtime(last))))
        print("Stored in %s (%.1f MB)" % (DB_FILE, DB_FILE.stat().st_size / 1e6))
    else:
        print("No history yet.")


UNIT_DIR = Path.home() / ".config" / "systemd" / "user"


def cmd_install_timer(args):
    if os.name == "nt":
        sys.exit("On Windows use Task Scheduler to run:  python craftgraph_sync.py run  every hour.")
    UNIT_DIR.mkdir(parents=True, exist_ok=True)
    (UNIT_DIR / "craftgraph-sync.service").write_text(
        "[Unit]\nDescription=CraftGraph auction house sync\n\n[Service]\nType=oneshot\n"
        "ExecStart=%s %s run\n" % (sys.executable, json.dumps(str(Path(__file__).resolve()))))
    (UNIT_DIR / "craftgraph-sync.timer").write_text(
        "[Unit]\nDescription=Hourly CraftGraph auction house sync\n\n[Timer]\nOnCalendar=*:07\n"
        "Persistent=true\n\n[Install]\nWantedBy=timers.target\n")
    os.system("systemctl --user daemon-reload && systemctl --user enable --now craftgraph-sync.timer")
    print("Installed. It runs at seven minutes past every hour while you are logged in to this computer.")


def cmd_remove_timer(args):
    os.system("systemctl --user disable --now craftgraph-sync.timer")
    for name in ("craftgraph-sync.service", "craftgraph-sync.timer"):
        file = UNIT_DIR / name
        if file.exists():
            file.unlink()
    os.system("systemctl --user daemon-reload")
    print("Removed.")


def main():
    parser = argparse.ArgumentParser(description="Bring Blizzard's hourly auction data into CraftGraph.")
    parser.add_argument("command", nargs="?", default="run",
                        choices=["setup", "run", "archive", "houses", "status", "install-timer", "remove-timer",
                                 "install-watch", "remove-watch", "check-update",
                                 "share-export", "share-import",
                                 "data-publish", "data-pull", "data-sync"])
    parser.add_argument("file", nargs="?", help="for share-export and share-import: the .cg.json file")
    parser.add_argument("--fixture", help=argparse.SUPPRESS)      # read saved API answers (for tests)
    args = parser.parse_args()
    {"setup": cmd_setup, "run": cmd_run, "archive": cmd_archive, "houses": cmd_houses, "status": cmd_status,
     "install-timer": cmd_install_timer, "remove-timer": cmd_remove_timer,
     "install-watch": cmd_install_watch, "remove-watch": cmd_remove_watch,
     "check-update": cmd_check_update, "share-export": cmd_share_export,
     "share-import": cmd_share_import, "data-publish": cmd_data_publish,
     "data-pull": cmd_data_pull, "data-sync": cmd_data_sync}[args.command](args)


if __name__ == "__main__":
    main()
