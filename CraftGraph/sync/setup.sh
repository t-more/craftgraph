#!/bin/sh
# Opens CraftGraph's setup page for the optional online features.
# Needs Python 3. The addon itself works without it.
here=$(cd "$(dirname "$0")" && pwd)
for py in python3 python; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then
    exec "$py" "$here/craftgraph_setup.py"
  fi
done
echo "Python 3 was not found. The addon works without it; the online features need it."
echo "Install Python 3 with your system's package manager, then run this again."
exit 1
