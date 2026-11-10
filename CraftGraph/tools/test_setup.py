#!/usr/bin/env python3
"""Checks the setup page (sync/craftgraph_setup.py) against a throwaway
config folder: who may reach it, where the key goes, and that it never comes
back. Run by test.sh when Python 3 is there."""
import json
import os
import stat
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

tmp = tempfile.mkdtemp(prefix="cg-setup-test-")
os.environ["XDG_CONFIG_HOME"] = tmp + "/config"
os.environ["XDG_DATA_HOME"] = tmp + "/data"
os.environ["APPDATA"] = tmp
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "sync"))
import craftgraph_setup as page          # noqa: E402

passed = failed = 0


def check(ok, what):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAILED: " + what)


server, address = page.serve(open_browser=False)
base = address.split("/?")[0]


def post(action, body=None, token=page.TOKEN, host=None):
    request = urllib.request.Request(base + "/api/" + action, data=json.dumps(body or {}).encode(),
                                     headers={"X-CraftGraph-Token": token, "Content-Type": "application/json"})
    if host:
        request.add_header("Host", host)
    try:
        return json.loads(urllib.request.urlopen(request).read())
    except urllib.error.HTTPError as error:
        return error.code


def get(url):
    try:
        return urllib.request.urlopen(url).read().decode()
    except urllib.error.HTTPError as error:
        return error.code


check(server.server_address[0] == "127.0.0.1", "the page is served to this computer only")
html = get(address)
check(isinstance(html, str) and "Your responsibility" in html and page.tool.API_TERMS_URL not in html,
      "the page opens with its code and leads with the responsibility")
check(get(base + "/") == 403, "without the code the page is refused")
check(post("state", token="guess") == 403, "an action without the code is refused")
check(post("state", host="evil.example") == 403, "a request under another host name is refused")
s = post("state")
check(s["has_key"] is False and s["accepted"] is False and s["terms_url"] == page.tool.API_TERMS_URL,
      "at first there is no key, nothing accepted, and the terms are linked")
r = post("save_key", {"client_id": "abc", "client_secret": "SECRETXYZ"})
check(r["ok"] is False and not page.tool.CONFIG_FILE.exists(), "no key is saved before the terms are accepted")
r = post("save_key", {"accepted": True, "client_id": "", "client_secret": "x"})
check(r["ok"] is False, "both codes are needed")
r = post("save_key", {"accepted": True, "client_id": " abc ", "client_secret": "SECRETXYZ", "region": "EU", "ruleset": "2"})
cfg = json.loads(page.tool.CONFIG_FILE.read_text())
check(r["ok"] and cfg["client_id"] == "abc" and cfg["client_secret"] == "SECRETXYZ" and cfg["region"] == "eu"
      and cfg["ruleset"] == 2 and cfg["accepted_terms"] > 0, "the key is saved, with when the terms were accepted")
if os.name != "nt":
    check(stat.S_IMODE(os.stat(page.tool.CONFIG_FILE).st_mode) == 0o600, "the key file is readable by its owner only")
addon = Path(__file__).resolve().parent.parent
check(addon not in page.tool.CONFIG_FILE.resolve().parents, "the key file is outside the addon folder")
s = post("state")
check(s["has_key"] and s["accepted"] and "SECRETXYZ" not in json.dumps(s) and "abc" not in json.dumps(s.get("house", "")),
      "the page learns that a key is saved, never the key")
check("SECRETXYZ" not in get(address), "the key is not in the page either")
r = post("purge")
check(r["ok"] and "nothing to delete" in r["text"], "the delete button runs the purge command: " + str(r))
r = post("status")
check(r["ok"] and "Config:" in r["text"], "status shows what the command prints")
check(post("nonsense") == 404, "an unknown action is refused")
r = post("forget_key")
cfg = json.loads(page.tool.CONFIG_FILE.read_text())
check(r["ok"] and "client_secret" not in cfg and "client_id" not in cfg and post("state")["has_key"] is False,
      "removing the key removes it from the file")
server.shutdown()
print("%d checks, %d failed" % (passed, failed))
sys.exit(1 if failed else 0)
