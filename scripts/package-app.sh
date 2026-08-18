#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-release}
output_root="$repository_root/.build/app"
app="$output_root/DFUUtility.app"

cd "$repository_root"
swift build -c "$configuration" --product DFUUtility
swift build -c "$configuration" --product macvdmtool
swift build -c "$configuration" --product DFUPrivilegedHelper

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/ThirdPartyLicenses" "$app/Contents/Library/LaunchServices" "$app/Contents/Library/LaunchDaemons"
install -m 755 ".build/$configuration/DFUUtility" "$app/Contents/MacOS/DFUUtility"
install -m 755 ".build/$configuration/macvdmtool" "$app/Contents/Resources/macvdmtool"
install -m 755 ".build/$configuration/DFUPrivilegedHelper" "$app/Contents/Library/LaunchServices/DFUPrivilegedHelper"
install -m 644 "Packaging/org.dfuutility.privileged-helper.plist" "$app/Contents/Library/LaunchDaemons/org.dfuutility.privileged-helper.plist"
install -m 644 "Vendor/macvdmtool/LICENSE" "$app/Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt"
install -m 644 "Vendor/macvdmtool/UPSTREAM_REVISION" "$app/Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt"

plutil -create xml1 "$app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string DFUUtility "$app/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string org.dfuutility.app "$app/Contents/Info.plist"
plutil -insert CFBundleName -string DFUUtility "$app/Contents/Info.plist"
plutil -insert CFBundleDisplayName -string DFUUtility "$app/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 0.3.0 "$app/Contents/Info.plist"
plutil -insert CFBundleVersion -string 1 "$app/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 14.0 "$app/Contents/Info.plist"

codesign --force --identifier org.dfuutility.macvdmtool --sign - "$app/Contents/Resources/macvdmtool"
codesign --force --identifier org.dfuutility.privileged-helper --sign - "$app/Contents/Library/LaunchServices/DFUPrivilegedHelper"
codesign --force --identifier org.dfuutility.app --sign - "$app"
printf '%s\n' "$app"
