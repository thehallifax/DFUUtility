#!/bin/sh
set -eu

usage() { echo "Usage: scripts/package-app.sh [debug|release] [--identity \"Developer ID Application: Name (TEAMID)\"]" >&2; exit "${1:-64}"; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=release
identity=""
if [ "$#" -gt 0 ] && { [ "$1" = debug ] || [ "$1" = release ]; }; then configuration=$1; shift; fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --identity) [ "$#" -ge 2 ] || usage; identity=$2; shift 2 ;;
    --help|-h) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

cd "$root"
scripts/generate-build-metadata.sh
. Config/Version.env
git_commit=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
app="$root/.build/app/DFUUtility.app"
distribution="$root/.build/distribution/DFUUtility-$MARKETING_VERSION.zip"

if [ -n "$identity" ]; then
  security find-identity -v -p codesigning | grep -F -- "$identity" >/dev/null || { echo "Requested signing identity was not found: $identity" >&2; exit 1; }
  signing_mode=production
  signer=$identity
else
  signing_mode=development-ad-hoc
  signer=-
fi
echo "Packaging mode: $signing_mode"

swift build -c "$configuration" --product DFUUtility
swift build -c "$configuration" --product macvdmtool
swift build -c "$configuration" --product DFUPrivilegedHelper

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdPartyLicenses" "$app/Contents/Library/LaunchServices" "$app/Contents/Library/LaunchDaemons"
install -m 755 ".build/$configuration/DFUUtility" "$app/Contents/MacOS/DFUUtility"
install -m 755 ".build/$configuration/macvdmtool" "$app/Contents/Resources/macvdmtool"
install -m 755 ".build/$configuration/DFUPrivilegedHelper" "$app/Contents/Library/LaunchServices/DFUPrivilegedHelper"
install -m 644 Packaging/org.dfuutility.privileged-helper.plist "$app/Contents/Library/LaunchDaemons/org.dfuutility.privileged-helper.plist"
install -m 644 Vendor/macvdmtool/LICENSE "$app/Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt"
install -m 644 Vendor/macvdmtool/UPSTREAM_REVISION "$app/Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt"

plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string DFUUtility "$app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string org.dfuutility.app "$app/Contents/Info.plist"
plutil -insert CFBundleName -string DFUUtility "$app/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string DFUUtility "$app/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string "$MARKETING_VERSION" "$app/Contents/Info.plist"
plutil -insert CFBundleVersion -string "$BUILD_NUMBER" "$app/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 14.0 "$app/Contents/Info.plist"
plutil -insert DFUUtilityGitCommit -string "$git_commit" "$app/Contents/Info.plist"
plutil -insert DFUUtilityBuildDate -string "$build_date" "$app/Contents/Info.plist"
plutil -insert DFUUtilityHelperProtocolVersion -integer "$HELPER_PROTOCOL_VERSION" "$app/Contents/Info.plist"
plutil -insert DFUUtilityMacVDMToolRevision -string "$MACVDMTOOL_REVISION" "$app/Contents/Info.plist"

if [ "$signing_mode" = production ]; then
  common="--force --timestamp --options runtime --sign"
  codesign $common "$signer" --identifier org.dfuutility.macvdmtool "$app/Contents/Resources/macvdmtool"
  codesign $common "$signer" --entitlements Signing/DFUPrivilegedHelper.entitlements --identifier org.dfuutility.privileged-helper "$app/Contents/Library/LaunchServices/DFUPrivilegedHelper"
  codesign $common "$signer" --entitlements Signing/DFUUtility.entitlements --identifier org.dfuutility.app "$app"
else
  codesign --force --sign - --identifier org.dfuutility.macvdmtool "$app/Contents/Resources/macvdmtool"
  codesign --force --sign - --entitlements Signing/DFUPrivilegedHelper.entitlements --identifier org.dfuutility.privileged-helper "$app/Contents/Library/LaunchServices/DFUPrivilegedHelper"
  codesign --force --sign - --entitlements Signing/DFUUtility.entitlements --identifier org.dfuutility.app "$app"
fi

scripts/verify-app.sh "$app"
mkdir -p "$(dirname "$distribution")"; rm -f "$distribution"
ditto -c -k --keepParent --sequesterRsrc "$app" "$distribution"
echo "App: $app"
echo "Distribution ZIP: $distribution"
