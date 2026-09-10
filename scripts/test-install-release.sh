#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
installer="$repo/scripts/install-release.sh"
suite=$(mktemp -d "${TMPDIR:-/tmp}/dfuutility-install-release-tests.XXXXXX")
trap 'rm -rf "$suite"' EXIT HUP INT TERM
case "$suite" in /Applications|/Applications/*) echo 'Refusing to test in /Applications.' >&2; exit 1 ;; esac

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

make_app() {
  app=$1 version=$2 identifier=$3 provenance=$4 missing=${5:-none} marker=${6:-new}
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchServices" "$app/Contents/Resources/ThirdPartyLicenses"
  /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$identifier" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleVersion -string 1 "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string DFUUtility "$app/Contents/Info.plist"
  /usr/bin/plutil -insert DFUUtilityInstallationKind -string "$provenance" "$app/Contents/Info.plist"
  for path in Contents/MacOS/DFUUtility Contents/Library/LaunchServices/DFUPrivilegedHelper Contents/Resources/DFUBinaryInstaller Contents/Resources/macvdmtool; do
    [ "$missing" = "$path" ] || { printf '#!/bin/sh\nexit 0\n' > "$app/$path"; chmod 755 "$app/$path"; }
  done
  for path in Contents/Resources/DFUUtility-LICENSE.txt Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM-NOTICE.md; do
    [ "$missing" = "$path" ] || printf 'fixture attribution\n' > "$app/$path"
  done
  printf '%s\n' "$marker" > "$app/Contents/Resources/fixture-marker"
  for code in "$app/Contents/Resources/macvdmtool" "$app/Contents/Resources/DFUBinaryInstaller" "$app/Contents/Library/LaunchServices/DFUPrivilegedHelper"; do
    [ -e "$code" ] && /usr/bin/codesign --force --sign - "$code" >/dev/null 2>&1
  done
  /usr/bin/codesign --force --deep --sign - --identifier "$identifier" "$app" >/dev/null 2>&1
}

prepare_case() {
  name=$1
  case_root="$suite/$name"
  fixture="$case_root/fixture"
  destination_root="$case_root/destination"
  destination="$destination_root/DFUUtility.app"
  trash="$case_root/trash"
  metadata="$case_root/release.json"
  archive="$case_root/DFUUtility-0.11.0.zip"
  output="$case_root/output"
  mkdir -p "$fixture" "$destination_root" "$trash"
}

write_release() {
  draft=${1:-false} prerelease=${2:-false} asset_name=${3:-DFUUtility-0.11.0.zip}
  size=$(/usr/bin/stat -f '%z' "$archive")
  digest=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
  printf '{"tag_name":"v0.11.0","draft":%s,"prerelease":%s,"assets":[{"name":"%s","browser_download_url":"https://github.com/thehallifax/DFUUtility/releases/download/v0.11.0/%s","size":%s,"digest":"sha256:%s"}]}\n' "$draft" "$prerelease" "$asset_name" "$asset_name" "$size" "$digest" > "$metadata"
}

package_fixture() {
  app=$1
  rm -f "$archive"
  /usr/bin/ditto -c -k --keepParent --sequesterRsrc "$app" "$archive"
  write_release
}

run_installer() {
  status=0
  DFUUTILITY_INSTALL_RELEASE_TEST_MODE=1 \
  DFUUTILITY_INSTALL_RELEASE_TEST_ROOT="$case_root" \
  DFUUTILITY_INSTALL_RELEASE_DESTINATION="$destination" \
  DFUUTILITY_INSTALL_RELEASE_METADATA_FILE="$metadata" \
  DFUUTILITY_INSTALL_RELEASE_ASSET_FILE="$archive" \
  DFUUTILITY_INSTALL_RELEASE_TRASH="$trash" \
  "$installer" > "$output" 2>&1 || status=$?
}

expect_failure() { [ "$status" -ne 0 ] || fail "$1 unexpectedly succeeded"; }

printf '1/12 valid distribution release installs\n'
prepare_case valid
make_app "$fixture/DFUUtility.app" 0.11.0 org.dfuutility.app distribution
package_fixture "$fixture/DFUUtility.app"
run_installer
[ "$status" -eq 0 ] || { cat "$output" >&2; fail 'valid release failed'; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :DFUUtilityInstallationKind' "$destination/Contents/Info.plist")" = distribution ] || fail 'installed provenance changed'

printf '2/12 source provenance is rejected\n'
prepare_case source-provenance
make_app "$fixture/DFUUtility.app" 0.11.0 org.dfuutility.app source
package_fixture "$fixture/DFUUtility.app"
run_installer; expect_failure 'source bundle'; [ ! -e "$destination" ] || fail 'source bundle modified destination'

printf '3/12 wrong bundle identifier is rejected\n'
prepare_case wrong-identifier
make_app "$fixture/DFUUtility.app" 0.11.0 com.example.other distribution
package_fixture "$fixture/DFUUtility.app"
run_installer; expect_failure 'wrong identifier'

printf '4/12 version mismatch is rejected\n'
prepare_case version-mismatch
make_app "$fixture/DFUUtility.app" 0.10.10 org.dfuutility.app distribution
package_fixture "$fixture/DFUUtility.app"
run_installer; expect_failure 'version mismatch'

printf '5/12 missing required component is rejected\n'
prepare_case missing-component
make_app "$fixture/DFUUtility.app" 0.11.0 org.dfuutility.app distribution Contents/Resources/macvdmtool
package_fixture "$fixture/DFUUtility.app"
run_installer; expect_failure 'missing component'

printf '6/12 running application is rejected\n'
prepare_case running
make_app "$fixture/DFUUtility.app" 0.11.0 org.dfuutility.app distribution
package_fixture "$fixture/DFUUtility.app"
status=0
DFUUTILITY_INSTALL_RELEASE_TEST_MODE=1 DFUUTILITY_INSTALL_RELEASE_TEST_ROOT="$case_root" DFUUTILITY_INSTALL_RELEASE_DESTINATION="$destination" DFUUTILITY_INSTALL_RELEASE_TEST_RUNNING=1 "$installer" > "$output" 2>&1 || status=$?
expect_failure 'running application'; /usr/bin/grep -Fq 'Quit DFUUtility and try again' "$output" || fail 'running guidance missing'

printf '7/12 existing destination is preserved then replaced\n'
prepare_case existing
make_app "$destination" 0.10.10 org.dfuutility.app distribution none old
make_app "$fixture/DFUUtility.app" 0.11.0 org.dfuutility.app distribution none new
package_fixture "$fixture/DFUUtility.app"
run_installer
[ "$status" -eq 0 ] || { cat "$output" >&2; fail 'existing destination replacement failed'; }
[ "$(cat "$destination/Contents/Resources/fixture-marker")" = new ] || fail 'new application was not installed'
retired=$(find "$trash" -mindepth 1 -maxdepth 1 -name 'DFUUtility-*.app' -print -quit)
[ -n "$retired" ] && [ "$(cat "$retired/Contents/Resources/fixture-marker")" = old ] || fail 'previous application was not preserved'

printf '8/12 replacement failure rolls back\n'
prepare_case rollback
make_app "$destination" 0.10.10 org.dfuutility.app distribution none old
make_app "$fixture/DFUUtility.app" 0.11.0 org.dfuutility.app distribution none new
package_fixture "$fixture/DFUUtility.app"
status=0
DFUUTILITY_INSTALL_RELEASE_TEST_MODE=1 DFUUTILITY_INSTALL_RELEASE_TEST_ROOT="$case_root" DFUUTILITY_INSTALL_RELEASE_DESTINATION="$destination" DFUUTILITY_INSTALL_RELEASE_METADATA_FILE="$metadata" DFUUTILITY_INSTALL_RELEASE_ASSET_FILE="$archive" DFUUTILITY_INSTALL_RELEASE_TRASH="$trash" DFUUTILITY_INSTALL_RELEASE_TEST_FAILURE=replacement "$installer" > "$output" 2>&1 || status=$?
expect_failure 'forced replacement failure'
[ "$(cat "$destination/Contents/Resources/fixture-marker")" = old ] || fail 'rollback did not restore old application'

printf '9/12 missing release asset is rejected\n'
prepare_case missing-asset
make_app "$fixture/DFUUtility.app" 0.11.0 org.dfuutility.app distribution
package_fixture "$fixture/DFUUtility.app"
write_release false false Other.zip
run_installer; expect_failure 'missing asset'

printf '10/12 drafts and prereleases are rejected\n'
prepare_case draft
make_app "$fixture/DFUUtility.app" 0.11.0 org.dfuutility.app distribution
package_fixture "$fixture/DFUUtility.app"
write_release true false
run_installer; expect_failure 'draft release'
write_release false true
run_installer; expect_failure 'prerelease release'

printf '11/12 malformed release archive is rejected\n'
prepare_case malformed-archive
printf 'not a zip archive\n' > "$archive"
write_release
run_installer; expect_failure 'malformed archive'; [ ! -e "$destination" ] || fail 'malformed archive modified destination'

printf '12/12 checksum mismatch is rejected\n'
prepare_case checksum-mismatch
make_app "$fixture/DFUUtility.app" 0.11.0 org.dfuutility.app distribution
package_fixture "$fixture/DFUUtility.app"
/usr/bin/plutil -convert xml1 -o "$case_root/release.plist" "$metadata"
/usr/libexec/PlistBuddy -c "Set :assets:0:digest sha256:$(printf '0%.0s' $(jot 64))" "$case_root/release.plist"
/usr/bin/plutil -convert json -o "$metadata" "$case_root/release.plist"
run_installer; expect_failure 'checksum mismatch'; [ ! -e "$destination" ] || fail 'checksum mismatch modified destination'

[ ! -e /Applications/DFUUtility.install-release-test ] || fail 'unexpected /Applications test marker'
! /usr/bin/grep -Eq 'install-local|update-source|update\.sh' "$installer" || fail 'release installer references the source updater'
printf 'Release installer harness passed without network or /Applications access.\n'
