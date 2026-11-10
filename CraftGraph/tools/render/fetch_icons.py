#!/usr/bin/env python3
"""Fetches the item icons the pictures need, so that renders show the real
icons instead of coloured tiles. Optional; needs Python 3 with Pillow.

    python3 tools/render/fetch_icons.py <file listing wanted icons, one per line>

A wanted icon is a file id (as the addon's data gives it) or an icon name.
Names come from wago.tools' file list for the game build; the pictures from
Wowhead's icon server. Results are kept in tools/render/icons/ as base64
PNGs, which the renderer embeds. That folder is not committed: the icons
are Blizzard's art.
"""
import base64, io, json, sys, time, urllib.request
from pathlib import Path
from PIL import Image

HERE = Path(__file__).resolve().parent
ICONS = HERE / "icons"
BUILD = "1.60.1.70862"
AGENT = {"User-Agent": "Mozilla/5.0"}


def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers=AGENT), timeout=60).read()


def names():
    cache = ICONS / "list.json"
    if not cache.exists():
        cache.write_bytes(get("https://wago.tools/api/files?search=interface/icons/&version=" + BUILD))
    return json.loads(cache.read_text())


def main():
    ICONS.mkdir(exist_ok=True)
    wanted = [line.strip() for line in open(sys.argv[1]) if line.strip()]
    listing = names()
    done = failed = 0
    for key in wanted:
        target = ICONS / (key + ".b64")
        if target.exists():
            continue
        name = key
        if key.isdigit():
            path = listing.get(key)
            if not path:
                failed += 1
                continue
            name = path.rsplit("/", 1)[-1].rsplit(".", 1)[0]
        try:
            raw = get("https://wow.zamimg.com/images/wow/icons/large/%s.jpg" % name.lower())
            image = Image.open(io.BytesIO(raw)).convert("RGB").resize((48, 48), Image.LANCZOS)
            out = io.BytesIO()
            image.save(out, "PNG", optimize=True)
            target.write_text(base64.b64encode(out.getvalue()).decode())
            done += 1
            time.sleep(0.05)
        except Exception as error:
            failed += 1
            print("no icon for %s (%s): %s" % (key, name, error))
    print("%d icons fetched, %d not found, %d wanted" % (done, failed, len(wanted)))


if __name__ == "__main__":
    main()
