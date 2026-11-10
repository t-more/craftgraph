#!/bin/sh
# Installs the addon from this repository into the game.
#   ./install.sh            copy CraftGraph into the game's AddOns folder
#   ./install.sh --check    only say what would change
# In game afterwards: /cg reload  (a full restart only if a file was added
# or CraftGraph.toc changed).
# Another game folder:  WOW_ADDONS=/path/to/Interface/AddOns ./install.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
addons=${WOW_ADDONS:-"$HOME/.local/share/Steam/steamapps/compatdata/3574889647/pfx/drive_c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"}
[ -d "$addons" ] || { echo "No AddOns folder at: $addons" >&2; exit 1; }
dry=""
[ "${1:-}" = "--check" ] && dry="--dry-run"
# tools/ is for development only. Data/Online.lua in the game is written by
# the sync tool and must not be replaced by the empty one kept here; it is
# only put there when the game has none.
rsync -a --delete --itemize-changes $dry \
  --exclude 'tools/' --exclude '__pycache__/' --exclude 'Data/Online.lua' \
  "$here/CraftGraph/" "$addons/CraftGraph/"
if [ -z "$dry" ] && [ ! -f "$addons/CraftGraph/Data/Online.lua" ]; then
  cp "$here/CraftGraph/sync/Online.stub.lua" "$addons/CraftGraph/Data/Online.lua"
fi
[ -n "$dry" ] && echo "(nothing was changed)" || echo "Installed into $addons/CraftGraph"
