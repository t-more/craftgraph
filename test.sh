#!/bin/sh
# Runs the offline checks (needs lua5.1). They prove the addon's own logic,
# not that the game accepts each call.
set -eu
cd "$(dirname "$0")/CraftGraph"
lua5.1 tools/test.lua | grep -v '^ *\[chat\]' | tail -n 1
# A brand-new install with no data: every view and command must open.
lua5.1 tools/qa_empty.lua | tail -n 1
