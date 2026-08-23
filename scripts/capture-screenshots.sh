#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
swift build --product DFUUtility

for scenario in normal-mac mac-dfu iphone-guided-dfu ipad-guided-dfu firmware-chooser download-progress restore-progress manage-downloads completed-restore; do
  .build/debug/DFUUtility --demo --screenshot "$scenario" --capture-screenshot "$root/docs/images/$scenario.png"
done

echo "Generated 9 deterministic screenshots in docs/images."
