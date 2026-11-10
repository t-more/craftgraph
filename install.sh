#!/bin/sh
# Installs the addon from this repository into the game.
#   ./install.sh            copy CraftGraph into the game's AddOns folder
#   ./install.sh --check    only say what would change
# In game afterwards: /cg reload  (a full restart only if a file was added
# or CraftGraph.toc changed).
# Another game folder:  WOW_ADDONS=/path/to/Interface/AddOns ./install.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
# The game folder: WOW_ADDONS if given, else a World of Warcraft Forever
# installed through Steam (Proton), wherever Steam keeps it.
addons=${WOW_ADDONS:-}
if [ -z "$addons" ]; then
  for candidate in "$HOME"/.local/share/Steam/steamapps/compatdata/*/pfx/drive_c/"Program Files (x86)"/"World of Warcraft"/_forever_/Interface/AddOns \
                   "$HOME"/.steam/steam/steamapps/compatdata/*/pfx/drive_c/"Program Files (x86)"/"World of Warcraft"/_forever_/Interface/AddOns; do
    if [ -d "$candidate" ]; then addons=$candidate; break; fi
  done
fi
[ -n "$addons" ] || { echo "Could not find the game. Set WOW_ADDONS=/path/to/_forever_/Interface/AddOns" >&2; exit 1; }
[ -d "$addons" ] || { echo "No AddOns folder at: $addons" >&2; exit 1; }
dry=""
[ "${1:-}" = "--check" ] && dry="--dry-run"
# tools/ is for development only. Four files in Data/ are written by the
# optional tool outside the game (prices, newest version, shared prices,
# the helper's answers); the empty ones kept here must not replace them,
# and are only put there when the game has none.
rsync -a --delete --itemize-changes $dry \
  --exclude 'tools/' --exclude '__pycache__/' \
  --exclude 'Data/Online.lua' --exclude 'Data/Latest.lua' --exclude 'Data/Shared.lua' --exclude 'Data/Helper.lua' \
  "$here/CraftGraph/" "$addons/CraftGraph/"
if [ -z "$dry" ]; then
  [ -f "$addons/CraftGraph/Data/Online.lua" ] || cp "$here/CraftGraph/sync/Online.stub.lua" "$addons/CraftGraph/Data/Online.lua"
  for name in Latest Shared Helper; do
    [ -f "$addons/CraftGraph/Data/$name.lua" ] || cp "$here/CraftGraph/Data/$name.lua" "$addons/CraftGraph/Data/$name.lua"
  done
fi
[ -n "$dry" ] && echo "(nothing was changed)" || echo "Installed into $addons/CraftGraph"
# A short command for the optional setup page and tool, when Python 3 is
# there: craftgraph-setup and craftgraph-sync, run from the game's copy so
# they find the game's saved data.
if [ -z "$dry" ] && command -v python3 >/dev/null 2>&1 && [ -d "$HOME/.local/bin" ]; then
  for name in setup sync; do
    printf '#!/bin/sh\nexec python3 "%s/CraftGraph/sync/craftgraph_%s.py" "$@"\n' "$addons" "$name" > "$HOME/.local/bin/craftgraph-$name"
    chmod +x "$HOME/.local/bin/craftgraph-$name"
  done
  echo "Python 3 found: 'craftgraph-setup' opens the setup page, 'craftgraph-sync' is the tool."
fi
