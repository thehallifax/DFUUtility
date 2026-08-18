#!/bin/sh
set -eu
app=${1:-/Applications/DFUUtility.app}
executable="$app/Contents/MacOS/DFUUtility"
[ -x "$executable" ] || { echo "DFUUtility app not found: $app" >&2; exit 1; }
"$executable" --unregister-helper
echo "The DFUUtility privileged helper was unregistered. No application, cache, log, or unrelated file was removed."
