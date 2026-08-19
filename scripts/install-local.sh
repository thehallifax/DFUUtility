#!/bin/sh
set -eu

usage() { echo "Usage: scripts/install-local.sh [--skip-tests]" >&2; exit "${1:-64}"; }
skip_tests=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skip-tests) skip_tests=1; shift ;;
    --help|-h) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_app="$root/.build/app/DFUUtility.app"
destination="/Applications/DFUUtility.app"
stage="$root/.build/local-install/DFUUtility.app"

cd "$root"
if [ "$skip_tests" -eq 0 ]; then swift test; fi
scripts/package-app.sh release
scripts/verify-app.sh "$source_app"

rm -rf "$root/.build/local-install"
mkdir -p "$root/.build/local-install"
ditto "$source_app" "$stage"

if [ -e "$destination" ]; then
  stamp=$(date +%Y%m%d-%H%M%S)
  backup="$HOME/.Trash/DFUUtility-$stamp.app"
  mv "$destination" "$backup"
  echo "Previous app moved to: $backup"
fi
if ! mv "$stage" "$destination"; then
  echo "Could not write to /Applications. Install the verified app manually from: $source_app" >&2
  exit 1
fi
rmdir "$root/.build/local-install"

echo "Installed Community build: $destination"
echo "Open Applications → DFUUtility. Administrator authorization is requested only when you click Enter DFU."
echo "No background helper was registered."
