#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
. "$root/scripts/screenshot-scenarios.sh"
swift build --product DFUUtility

screenshot_count=0
for scenario in $screenshot_scenarios; do
  screenshot_count=$((screenshot_count + 1))
  destination="$root/docs/images/$scenario.png"
  rm -f "$destination"
  .build/debug/DFUUtility --demo --screenshot "$scenario" --capture-screenshot "$destination"
  attempts=0
  while [ ! -s "$destination" ]; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 100 ]; then
      echo "Timed out capturing $scenario" >&2
      exit 1
    fi
    sleep 0.1
  done
done

echo "Generated $screenshot_count deterministic screenshots in docs/images."
