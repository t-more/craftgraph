#!/bin/sh
# Runs the offline checks (needs lua5.1). They prove the addon's own logic,
# not that the game accepts each call.
set -eu
cd "$(dirname "$0")/CraftGraph"
lua5.1 tools/test.lua | grep -v '^ *\[chat\]' | tail -n 4
