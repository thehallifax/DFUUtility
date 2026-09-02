#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
swift build --product DFUUtility

for scenario in multiple-devices normal-mac mac-dfu iphone-guided-dfu ipad-guided-dfu firmware-chooser download-progress restore-progress manage-downloads completed-restore; do
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

echo "Generated 10 deterministic screenshots in docs/images."
