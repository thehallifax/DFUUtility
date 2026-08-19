#!/bin/sh
set -eu
[ "$#" -eq 0 ] || { echo "Usage: scripts/uninstall-local.sh" >&2; exit 64; }
app="/Applications/DFUUtility.app"
if [ ! -e "$app" ]; then echo "DFUUtility is not installed in /Applications."; exit 0; fi
stamp=$(date +%Y%m%d-%H%M%S)
destination="$HOME/.Trash/DFUUtility-$stamp.app"
mv "$app" "$destination"
echo "DFUUtility was moved to Trash: $destination"
echo "Caches and logs were retained. No helper or unrelated service was changed."
