#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
suite=$(mktemp -d "${TMPDIR:-/tmp}/dfuutility-sidebar-layout.XXXXXX")
bundle_id="org.dfuutility.sidebar-layout-test.$$"
app="$suite/DFUUtility.app"
log="$suite/diagnostics.log"
output="$suite/output.log"
child_pid=""
keep_suite=0

cleanup() {
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  /usr/bin/defaults delete "$bundle_id" 2>/dev/null || true
  if [ "$keep_suite" -eq 0 ]; then
    rm -rf -- "$suite"
  else
    echo "Preserved sidebar layout test root: $suite" >&2
  fi
}
trap cleanup EXIT HUP INT TERM

case "$root" in
  /Applications|/Applications/*) echo "Refusing to run from /Applications" >&2; exit 1 ;;
esac

cd "$root"
scripts/package-app.sh debug >"$suite/package.log" 2>&1
ditto "$root/.build/app/DFUUtility.app" "$app"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier org.dfuutility.app "$app" >/dev/null

split_key='NSSplitView Subview Frames SwiftUI.ModifiedContent<DFUUtilityApp.ContentView, SwiftUI._FlexFrameLayout>-1-AppWindow-1, SidebarNavigationSplitView'
window_key='NSWindow Frame SwiftUI.ModifiedContent<DFUUtilityApp.ContentView, SwiftUI._FlexFrameLayout>-1-AppWindow-1'
/usr/bin/defaults write "$bundle_id" "$split_key" -array \
  '0.000000, 0.000000, 268.000000, 860.000000, NO, NO' \
  '271.000000, 0.000000, 969.000000, 860.000000, NO, NO'
/usr/bin/defaults write "$bundle_id" "$window_key" '200 100 1240 860 0 0 1800 1130 '

DFUUTILITY_SIDEBAR_DIAGNOSTICS=1 "$app/Contents/MacOS/DFUUtility" --demo --sidebar-layout-resize-smoke >"$output" 2>"$log" &
child_pid=$!
deadline=$((SECONDS + 8))
while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$child_pid" 2>/dev/null; do
  if /usr/bin/grep -Fq 'SidebarResizeSmoke phase=large-again' "$log" 2>/dev/null; then break; fi
  sleep 0.1
done

if ! /usr/bin/grep -Fq 'requested=Optional(280.0)' "$log"; then
  keep_suite=1
  echo "Sidebar guard did not promote the restored sub-ideal width." >&2
  cat "$log" >&2
  exit 1
fi
/usr/bin/grep -Fq 'autosave=Optional("SwiftUI.ModifiedContent<DFUUtilityApp.ContentView, SwiftUI._FlexFrameLayout>-1-AppWindow-1, SidebarNavigationSplitView")' "$log"
/usr/bin/grep -Fq 'repairAfter' "$log"
/usr/bin/grep -Fq 'sidebarFrame=(0.0, 0.0, 280.0' "$log"

for phase in launch-large normal minimum manual large-again; do
  line=$(/usr/bin/grep -F "SidebarResizeSmoke phase=$phase " "$log" | tail -1 || true)
  [ -n "$line" ] || { keep_suite=1; echo "Missing resize marker for $phase." >&2; cat "$log" >&2; exit 1; }
  width=$(printf '%s\n' "$line" | sed -n 's/.*sidebar=\([0-9.]*\).*/\1/p')
  [ -n "$width" ] || { keep_suite=1; echo "Missing sidebar width for $phase: $line" >&2; exit 1; }
  awk -v width="$width" 'BEGIN { exit !(width >= 260 && width <= 340) }' || {
    keep_suite=1
    echo "Sidebar width out of supported range for $phase: $line" >&2
    cat "$log" >&2
    exit 1
  }
done

manual_line=$(/usr/bin/grep -F 'SidebarResizeSmoke phase=manual ' "$log" | tail -1)
manual_width=$(printf '%s\n' "$manual_line" | sed -n 's/.*sidebar=\([0-9.]*\).*/\1/p')
awk -v width="$manual_width" 'BEGIN { exit !(width >= 300) }' || {
  keep_suite=1
  echo "Native manual divider position was not retained: ${manual_width:-missing}" >&2
  cat "$log" >&2
  exit 1
}

/usr/bin/grep -Fq 'SidebarResizeSmoke phase=large-again' "$log"

/usr/bin/grep -F 'SidebarResizeSmoke phase=' "$log"

kill "$child_pid" 2>/dev/null || true
wait "$child_pid" 2>/dev/null || true
child_pid=""
echo "Sidebar layout process test passed (large launch/normal/minimum/large-again resize and valid manual divider retained)."
