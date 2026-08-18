#!/bin/sh
set -eu
usage() { echo "Usage: scripts/notarize-app.sh /path/to/DFUUtility.app --keychain-profile PROFILE" >&2; exit 64; }
[ "$#" -eq 3 ] && [ "$2" = --keychain-profile ] || usage
app=$1; profile=$3
[ -d "$app" ] || { echo "App not found: $app" >&2; exit 1; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$root/scripts/verify-app.sh" "$app"
team=$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)
[ -n "$team" ] && [ "$team" != "not set" ] || { echo "Notarization requires a Developer ID-signed app" >&2; exit 1; }
temporary=$(mktemp -d "${TMPDIR:-/tmp}/DFUUtility-notary.XXXXXX"); trap 'rm -rf "$temporary"' EXIT
archive="$temporary/DFUUtility.zip"
ditto -c -k --keepParent --sequesterRsrc "$app" "$archive"
xcrun notarytool submit "$archive" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
output="$root/.build/distribution/DFUUtility-$version-notarized.zip"
rm -f "$output"; ditto -c -k --keepParent --sequesterRsrc "$app" "$output"
echo "Notarized distribution: $output"
