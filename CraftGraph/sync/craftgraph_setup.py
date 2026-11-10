#!/usr/bin/env python3
"""A setup page, in your browser, for CraftGraph's optional online features.

    python3 craftgraph_setup.py

It starts a small web page that only this computer can reach, opens it in
your browser, and lets you: read what you take on, enter your Blizzard API
key, fetch prices, set the hourly run, delete Blizzard's data after thirty
days, keep every scan, and share prices. Everything it does, the commands of
craftgraph_sync.py do as well; this is the same thing with buttons.

Needs only Python 3, nothing else. Close the page or press Ctrl+C to stop.

Safety: the page is served on 127.0.0.1 only, on a random port, and every
request must carry a random code made for this one run, so no other page or
program can use it. The API key is written to the private config file and is
never sent back to the page.
"""
import http.server
import json
import os
import secrets
import shutil
import sys
import threading
import time
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import craftgraph_sync as tool          # noqa: E402

TOKEN = secrets.token_urlsafe(18)
IDLE_SECONDS = 45 * 60
busy = threading.Lock()
last_used = [time.time()]


def run_command(fn, file=None):
    """Runs one of the tool's commands and returns (ok, what it printed).
    The game is then told what is set up now."""
    ok, text = tool.capture(fn, file)
    try:
        tool.write_helper()
    except Exception:
        pass
    return ok, text


def state():
    cfg = tool.load_config()
    info = {
        "accepted": bool(cfg.get("accepted_terms")),
        "has_key": bool(cfg.get("client_id") and cfg.get("client_secret")),
        "region": cfg.get("region", "eu"),
        "ruleset": cfg.get("ruleset", 1),
        "house": cfg.get("house_name") or "",
        "config_file": str(tool.CONFIG_FILE),
        "terms_url": tool.API_TERMS_URL,
        "keep_days": tool.BLIZZARD_KEEP_DAYS,
        "oldest_days": None,
        "snapshots": 0,
        "own_points": 0,
        "version": tool.addon_version(),
        "timer": os.name != "nt" and shutil.which("systemctl") is not None,
        "github": shutil.which("gh") is not None or bool(os.environ.get("GITHUB_TOKEN")),
        "saved_data": tool.saved_variables_file() is not None,
        "watch_installed": (tool.UNIT_DIR / "craftgraph-archive.path").exists(),
    }
    if tool.DB_FILE.exists():
        db = tool.open_db()
        oldest = tool.oldest_blizzard_data(db)
        if oldest:
            info["oldest_days"] = round((time.time() - oldest) / 86400, 1)
        info["snapshots"] = db.execute("SELECT COUNT(*) FROM snapshot").fetchone()[0]
        info["own_points"] = db.execute("SELECT COUNT(*) FROM scan").fetchone()[0]
        db.close()
    return info


def save_key(body):
    if not body.get("accepted"):
        return False, "Tick the box first: the key is yours and so are Blizzard's terms."
    client_id = str(body.get("client_id", "")).strip()
    secret = str(body.get("client_secret", "")).strip()
    if not client_id or not secret:
        return False, "Both the Client ID and the Client Secret are needed."
    region = str(body.get("region", "eu")).strip().lower()
    if region not in ("eu", "us", "kr", "tw"):
        return False, "The region is one of eu, us, kr, tw."
    try:
        ruleset = int(body.get("ruleset", 1))
    except (TypeError, ValueError):
        return False, "The ruleset is a number."
    cfg = tool.load_config()
    cfg.update(client_id=client_id, client_secret=secret, region=region, ruleset=ruleset,
               accepted_terms=int(time.time()))
    cfg.pop("house", None)
    ok, text = run_command(lambda args: tool.save_config(cfg))
    if not ok:
        return False, text
    return True, "Saved to %s, readable only by you. It is kept there and nowhere else." % tool.CONFIG_FILE


def forget_key(body):
    cfg = tool.load_config()
    for name in ("client_id", "client_secret", "accepted_terms", "house", "house_name", "house_realm"):
        cfg.pop(name, None)
    ok, text = run_command(lambda args: tool.save_config(cfg))
    if not ok:
        return False, text
    return True, "The key is removed from this computer. To end it at Blizzard too, delete the client on their site."


ACTIONS = {
    "save_key": save_key,
    "forget_key": forget_key,
    "run": lambda body: run_command(tool.cmd_run),
    "purge": lambda body: run_command(tool.cmd_purge),
    "archive": lambda body: run_command(tool.cmd_archive),
    "check_update": lambda body: run_command(tool.cmd_check_update),
    "status": lambda body: run_command(tool.cmd_status),
    "data_pull": lambda body: run_command(tool.cmd_data_pull),
    "data_sync": lambda body: run_command(tool.cmd_data_sync),
    "install_timer": lambda body: run_command(tool.cmd_install_timer),
    "remove_timer": lambda body: run_command(tool.cmd_remove_timer),
    "install_watch": lambda body: run_command(tool.cmd_install_watch),
    "remove_watch": lambda body: run_command(tool.cmd_remove_watch),
}

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>CraftGraph: online features</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { background:#14110d; color:#e8e0cf; font:16px/1.5 system-ui, sans-serif; margin:0; }
  main { max-width:760px; margin:0 auto; padding:24px 20px 80px; }
  h1 { color:#ffd100; font-size:26px; margin:0 0 4px; }
  h2 { color:#ffd100; font-size:19px; margin:0 0 8px; }
  section { background:#1e1913; border:1px solid #5c4a2a; border-radius:8px; padding:16px 18px; margin:16px 0; }
  section.locked { opacity:.45; pointer-events:none; }
  p { margin:6px 0; } small, .dim { color:#a89878; }
  a { color:#73bfff; }
  ul { margin:6px 0 6px 20px; padding:0; } li { margin:3px 0; }
  label { display:block; margin:8px 0 2px; }
  input[type=text], input[type=password], select { width:100%; box-sizing:border-box; padding:8px; border-radius:5px;
    border:1px solid #6b5a36; background:#0c0a08; color:#fff; font:inherit; }
  .row { display:flex; gap:12px; } .row > div { flex:1; }
  button { background:#6e1611; color:#ffd100; border:1px solid #c8a45a; border-radius:5px; padding:8px 14px;
    font:inherit; cursor:pointer; margin:8px 8px 0 0; }
  button:hover { background:#8d1f17; } button:disabled { opacity:.5; cursor:default; }
  button.plain { background:#2c2622; color:#e8e0cf; border-color:#5a5248; }
  pre { background:#0c0a08; border:1px solid #3a3020; border-radius:5px; padding:10px; white-space:pre-wrap;
    margin:10px 0 0; min-height:1.4em; color:#d8ccb0; font:13px/1.45 ui-monospace, monospace; }
  .ok { color:#66e666; } .warn { color:#ff8c33; }
  .tick { display:flex; gap:10px; align-items:flex-start; margin:10px 0 0; }
  .tick input { margin-top:5px; transform:scale(1.3); }
  table.form { border-collapse:collapse; margin:8px 0; width:100%; }
  table.form td { border-top:1px solid #3a3020; padding:7px 8px 7px 0; vertical-align:top; }
  table.form td:first-child { white-space:nowrap; color:#ffd100; width:1%; padding-right:14px; }
  code { background:#0c0a08; border:1px solid #3a3020; border-radius:4px; padding:1px 5px; color:#d8ccb0; }
  code.copy { cursor:pointer; } code.copy:hover { border-color:#c8a45a; } code.copied { border-color:#66e666; }
</style></head><body><main>
<h1>CraftGraph: online features</h1>
<p class="dim">Optional. The addon works without any of this. This page runs on your computer only.</p>

<section id="s-legal">
  <h2>1. Your responsibility</h2>
  <p>CraftGraph is a prototype made by a few friends, given as it is, with no warranty. How you use it is your own
     decision and your own responsibility. It is not affiliated with or endorsed by Blizzard.</p>
  <p>The hourly prices need an API key that <b>you</b> make at Blizzard under <b>your</b> account. Making it means you
     accept <a id="terms" target="_blank" rel="noopener">Blizzard's Developer API Terms of Use</a> yourself. In short
     (the terms themselves are what counts):</p>
  <ul>
    <li><b>The key is yours alone.</b> Keep it secret, never share it. You answer for its use.</li>
    <li><b>Thirty days.</b> Data from the service may be kept 30 days at most. You are reminded; deleting is up to you.</li>
    <li><b>Not passed on.</b> The data may not be redistributed, sold or licensed. Exports and shared prices hold only
        your own in-game scans.</li>
    <li><b>Blizzard decides.</b> They may end your access at any time. Breaking the terms can cost you the key and may
        have consequences for your account.</li>
  </ul>
  <label class="tick"><input type="checkbox" id="accept">
    <span>I have read Blizzard's terms, I accept them myself, and I use this at my own responsibility.</span></label>
</section>

<section id="s-key" class="locked">
  <h2>2. Your API key</h2>
  <p>Make a free one at <a href="https://develop.battle.net/access/clients" target="_blank" rel="noopener">develop.battle.net</a>:
     sign in, <i>Create Client</i>, any name, no redirect URL. Copy its two codes here.</p>
  <p><b>What to fill in on Blizzard's "Create Client" form</b> (click a grey text to copy it):</p>
  <table class="form">
    <tr><td>Client Name</td><td>Any name nobody else has used, such as <code class="copy">craftgraph-yourname-personal</code>.
      Do not put "Blizzard" or "WoW" in it.</td></tr>
    <tr><td>Redirect URLs</td><td>Leave empty. If the form insists: <code class="copy">http://localhost</code></td></tr>
    <tr><td>Service URL</td><td>Leave empty. If the form insists: <code class="copy">http://localhost</code>
      (the tool runs only on your own computer).</td></tr>
    <tr><td>Intended Use</td><td><code class="copy">Personal, non-commercial use. A script on my own computer reads the auction house data of my own realm from the Game Data API about once an hour, using the client credentials flow, to show prices in a personal crafting addon. The data stays on my computer, is not passed on, and is deleted within 30 days.</code>
      <br><small>Write what is true for you; this is what the tool does.</small></td></tr>
  </table>
  <p>Blizzard then shows the client's <b>Client ID</b> and <b>Client Secret</b>. Those two go here:</p>
  <p id="keystate" class="dim"></p>
  <label for="cid">Client ID</label><input type="text" id="cid" autocomplete="off" spellcheck="false">
  <label for="sec">Client Secret</label><input type="password" id="sec" autocomplete="off" spellcheck="false">
  <div class="row">
    <div><label for="region">Region</label><select id="region">
      <option value="eu">Europe</option><option value="us">Americas</option><option value="kr">Korea</option><option value="tw">Taiwan</option></select></div>
    <div><label for="ruleset">Realm type</label><select id="ruleset">
      <option value="1">PvP</option><option value="2">Normal</option><option value="3">Roleplay</option><option value="15">Roleplay PvP</option></select></div>
  </div>
  <button data-act="save_key">Save the key on this computer</button>
  <button class="plain" data-act="forget_key">Remove the key</button>
  <p><small>It is written to <span id="cfgfile"></span>, readable only by you. It is never put in the addon folder, an
     export, or anything shared or uploaded, and this page never shows it again.</small></p>
  <pre id="o-key"></pre>
</section>

<section id="s-game">
  <h2>In-game buttons</h2>
  <p>The game cannot start a program itself. With this on, a button in the game (Data, Blizzard prices) leaves a
     request when the game reloads, and this helper does it: fetch prices, delete old data, keep scans, and so on.
     Only those fixed actions can be asked for, and your key never goes to the game.</p>
  <p id="gamestate" class="dim"></p>
  <span id="watchbtns"><button data-act="install_watch">Let the game's buttons work, always</button>
  <button class="plain" data-act="remove_watch">Stop that</button></span>
  <pre id="o-game"></pre>
</section>

<section id="s-run" class="locked">
  <h2>3. Fetch the prices</h2>
  <p>Do a full scan in the game first and log out or type <code>/reload</code>, so your auction house can be found.
     Then fetch. The game shows the prices at your next login or <code>/reload</code>.</p>
  <button data-act="run">Fetch now</button>
  <span id="timer"><button class="plain" data-act="install_timer">Fetch every hour by itself</button>
  <button class="plain" data-act="remove_timer">Stop the hourly fetch</button></span>
  <p id="notimer" class="dim" hidden>To fetch every hour on Windows, add a task in Task Scheduler that runs
     <code>python craftgraph_sync.py run</code>.</p>
  <pre id="o-run"></pre>
</section>

<section id="s-keep" class="locked">
  <h2>4. Thirty days</h2>
  <p id="oldest"></p>
  <button data-act="purge">Delete Blizzard data older than 30 days</button>
  <p><small>Your own in-game scans are yours and are not touched. In the game, the Data page has the matching button.</small></p>
  <pre id="o-purge"></pre>
</section>

<section id="s-extra">
  <h2>5. Other things (no key needed)</h2>
  <p>Keep every in-game scan in a database on this computer, look for a newer version, and fetch or share prices
     in the shared repository on GitHub.</p>
  <button class="plain" data-act="archive">Keep every scan</button>
  <button class="plain" data-act="check_update">Look for a newer version</button>
  <button class="plain" data-act="data_pull">Fetch what others share</button>
  <button class="plain" data-act="data_sync" id="b-sync">Share mine and fetch</button>
  <button class="plain" data-act="status">Show status</button>
  <p id="ghnote" class="dim" hidden>Sharing yours needs the GitHub CLI logged in (<code>gh auth login</code>) and the
     repository owner's go-ahead. It makes your character's name, your GitHub name and your prices public.</p>
  <pre id="o-extra"></pre>
</section>
<p class="dim">CraftGraph <span id="ver"></span>. Close this tab when you are done; the page stops by itself after a while.</p>
</main>
<script>
const TOKEN = "__TOKEN__";
const where = { save_key:"o-key", forget_key:"o-key", run:"o-run", install_timer:"o-run", remove_timer:"o-run",
  install_watch:"o-game", remove_watch:"o-game", purge:"o-purge", archive:"o-extra", check_update:"o-extra", data_pull:"o-extra", data_sync:"o-extra", status:"o-extra" };
async function call(action, body) {
  const r = await fetch("/api/" + action, { method:"POST", headers:{ "Content-Type":"application/json",
    "X-CraftGraph-Token":TOKEN }, body: JSON.stringify(body || {}) });
  return r.json();
}
function $(id) { return document.getElementById(id); }
async function refresh() {
  const s = await call("state");
  $("terms").href = s.terms_url; $("cfgfile").textContent = s.config_file; $("ver").textContent = s.version;
  if (s.accepted) $("accept").checked = true;
  const open = $("accept").checked;
  $("s-key").classList.toggle("locked", !open);
  $("s-run").classList.toggle("locked", !(open && s.has_key));
  $("s-keep").classList.toggle("locked", !(open && s.has_key));
  $("keystate").innerHTML = s.has_key ? '<span class="ok">A key is saved on this computer.</span> Enter a new one to replace it.'
    : "No key is saved yet.";
  $("region").value = s.region; $("ruleset").value = String(s.ruleset);
  $("timer").hidden = !s.timer; $("notimer").hidden = s.timer;
  $("ghnote").hidden = false;
  $("watchbtns").hidden = !s.timer;
  $("gamestate").innerHTML = s.watch_installed ? '<span class="ok">On: the game\'s buttons work whenever you play.</span>'
    : '<span class="ok">While this page is open, the game\'s buttons work.</span>' + (s.timer ? " Press the button to keep it so after you close it."
      : " To keep it so on Windows, leave this page open while you play, or run <code>python craftgraph_sync.py watch</code>.");
  let t = "Blizzard's terms allow their data to be kept " + s.keep_days + " days. ";
  if (s.oldest_days === null) t += "None is held yet.";
  else if (s.oldest_days > s.keep_days) t = '<span class="warn">You hold Blizzard data that is ' + Math.floor(s.oldest_days)
    + " days old.</span> " + t + "Delete the older part now.";
  else t += "The oldest you hold is " + (s.oldest_days < 1 ? "under a day" : Math.floor(s.oldest_days) + " days") + " old.";
  $("oldest").innerHTML = t;
  if (!s.saved_data) $("o-run").textContent = "The addon has no saved data yet. Play once with CraftGraph loaded, then log out or /reload.";
}
document.querySelectorAll("code.copy").forEach(c => c.addEventListener("click", async () => {
  try { await navigator.clipboard.writeText(c.textContent); } catch (e) {
    const r = document.createRange(); r.selectNodeContents(c); const sel = getSelection(); sel.removeAllRanges(); sel.addRange(r); }
  c.classList.add("copied"); setTimeout(() => c.classList.remove("copied"), 900);
}));
$("accept").addEventListener("change", refresh);
document.querySelectorAll("button[data-act]").forEach(b => b.addEventListener("click", async () => {
  const act = b.dataset.act, out = $(where[act]);
  let body = {};
  if (act === "save_key") body = { accepted:$("accept").checked, client_id:$("cid").value, client_secret:$("sec").value,
    region:$("region").value, ruleset:$("ruleset").value };
  b.disabled = true; out.textContent = "Working ...";
  try {
    const r = await call(act, body);
    out.textContent = r.text || (r.ok ? "Done." : "That did not work.");
    out.className = r.ok ? "" : "warn";
    if (act === "save_key" && r.ok) { $("cid").value = ""; $("sec").value = ""; }
  } catch (e) { out.textContent = "The setup page is no longer running. Start it again."; }
  b.disabled = false; refresh();
}));
refresh();
</script></body></html>
"""


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "CraftGraphSetup"

    def log_message(self, *args):               # keep the terminal quiet
        pass

    def _local(self):
        host = (self.headers.get("Host") or "").split(":")[0]
        return host in ("127.0.0.1", "localhost")

    def _send(self, code, body, kind="application/json"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", kind + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        last_used[0] = time.time()
        path, _, query = self.path.partition("?")
        if not self._local() or path != "/" or ("k=" + TOKEN) not in query.split("&"):
            self._send(403, "Not allowed. Open the address the program printed.", "text/plain")
            return
        self._send(200, PAGE.replace("__TOKEN__", TOKEN), "text/html")

    def do_POST(self):
        last_used[0] = time.time()
        if not self._local() or self.headers.get("X-CraftGraph-Token") != TOKEN:
            self._send(403, json.dumps({"ok": False, "text": "Not allowed."}))
            return
        action = self.path[len("/api/"):] if self.path.startswith("/api/") else ""
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except ValueError:
            body = {}
        if action == "state":
            self._send(200, json.dumps(state()))
            return
        fn = ACTIONS.get(action)
        if not fn:
            self._send(404, json.dumps({"ok": False, "text": "No such action."}))
            return
        if not busy.acquire(blocking=False):
            self._send(200, json.dumps({"ok": False, "text": "Still busy with the last thing. Try again in a moment."}))
            return
        try:
            ok, text = fn(body)
        finally:
            busy.release()
        self._send(200, json.dumps({"ok": ok, "text": text}))


def watch_game():
    """While the page is open, does what the game's buttons ask for."""
    seen = [False]
    try:
        tool.handle_requests(verbose=False)
    except Exception:
        pass
    while tool.watching[0]:
        try:
            if busy.acquire(blocking=False):
                try:
                    tool.watch_once(seen)
                finally:
                    busy.release()
        except Exception:
            pass
        time.sleep(2)


def serve(open_browser=True, watch=False):
    """Starts the page. Returns (server, address)."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    address = "http://127.0.0.1:%d/?k=%s" % (server.server_address[1], TOKEN)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    if watch:
        tool.watching[0] = True
        threading.Thread(target=watch_game, daemon=True).start()
    if open_browser:
        try:
            webbrowser.open(address)
        except Exception:
            pass
    return server, address


def main():
    server, address = serve(watch=True)
    print("CraftGraph setup is open in your browser. If it did not open, go to:")
    print("  " + address)
    print("Press Ctrl+C here, or just close this window, when you are done.", flush=True)
    try:
        while time.time() - last_used[0] < IDLE_SECONDS:
            time.sleep(1)
        print("Stopped after being idle.")
    except KeyboardInterrupt:
        print("\nStopped.")
    tool.watching[0] = False
    try:
        tool.write_helper()
    except Exception:
        pass
    server.shutdown()


if __name__ == "__main__":
    main()
