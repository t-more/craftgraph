#!/bin/sh
# Builds the zip to share: dist/CraftGraph-<version>.zip, without the
# development tools and with an empty online-data file.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
version=$(sed -n 's/^## Version: *//p' "$here/CraftGraph/CraftGraph.toc" | tr -d '\r')
mkdir -p "$here/dist"
out="$here/dist/CraftGraph-$version.zip"
rm -f "$out"
cd "$here"
zip -qr "$out" CraftGraph -x 'CraftGraph/tools/*' -x '*/__pycache__/*'
# The Windows installer sits beside the CraftGraph folder in the zip.
(cd "$here/windows" && zip -q "$out" "Install CraftGraph.cmd" install.ps1)
echo "$out"
