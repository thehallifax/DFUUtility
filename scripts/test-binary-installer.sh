#!/bin/sh
set -eu

root=$(mktemp -d "${TMPDIR:-/tmp}/dfu-binary-installer.XXXXXX")
keep=0
cleanup() {
    status=$?
    # The rollback-failure fixture intentionally makes one directory read-only.
    chmod -R 700 "$root" 2>/dev/null || true
    if [ "$status" -ne 0 ] || [ "$keep" -eq 1 ]; then
        printf 'Binary installer harness retained fixture root: %s\n' "$root" >&2
    else
        rm -rf "$root"
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

reset_fixture() {
    chmod -R 700 "$root" 2>/dev/null || true
    rm -rf "$destinationParent" "$support"
    mkdir -p "$destinationParent" "$staging"
}

case "$root" in
    /Applications|/Applications/*) echo 'Refusing to use /Applications.' >&2; exit 1 ;;
esac

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
scripts/package-app.sh release >/dev/null 2>&1
installer="$repo/.build/app/DFUUtility.app/Contents/Resources/DFUBinaryInstaller"
[ -x "$installer" ] || { echo "Missing executable: $installer" >&2; exit 1; }

support="$root/support"
destinationParent="$root/destination"
staging="$support/Updates/payload"
destination="$destinationParent/DFUUtility.app"
backup="$destinationParent/.DFUUtility.backup"
descriptor="$support/binary-update-transaction.json"
result="$support/binary-update-result.txt"
launcher="$root/no-op-launcher.sh"
launchMarker="$root/launcher-marker"

assert_under_root() {
    case "$1" in
        "$root"/*) ;;
        *) echo "Path escaped temporary root: $1" >&2; exit 1 ;;
    esac
}
for path in "$support" "$destination" "$staging" "$backup" "$descriptor" "$result"; do assert_under_root "$path"; done
[ "$destination" != "/Applications/DFUUtility.app" ] || { echo 'Real application path is forbidden.' >&2; exit 1; }

mkdir -p "$support" "$destinationParent" "$staging"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" > "%s"\n' "$launchMarker" > "$launcher"
chmod 755 "$launcher"

make_bundle() {
    app=$1; version=$2; build=$3; marker=$4
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Library/LaunchServices" "$app/Contents/Resources"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict>' '<key>CFBundleIdentifier</key><string>org.dfuutility.app</string>' "<key>CFBundleShortVersionString</key><string>$version</string>" "<key>CFBundleVersion</key><string>$build</string>" '<key>CFBundleExecutable</key><string>DFUUtility</string>' '</dict></plist>' > "$app/Contents/Info.plist"
    for file in Contents/MacOS/DFUUtility Contents/Library/LaunchServices/DFUPrivilegedHelper Contents/Resources/macvdmtool Contents/Resources/DFUUtility-LICENSE.txt; do printf 'fixture\n' > "$app/$file"; done
    printf '%s\n' "$marker" > "$app/Contents/Resources/fixture-marker"
    chmod 755 "$app/Contents/MacOS/DFUUtility" "$app/Contents/Resources/macvdmtool"
    codesign --force --deep --sign - --identifier org.dfuutility.app "$app" >/dev/null
}

write_transaction() {
    artifact=$1; expectedVersion=$2; expectedBuild=$3; txDestination=$4; txBackup=$5; txResult=$6
    id=$(uuidgen)
    now=$(date +%s)
    printf '{"id":"%s","expectedVersion":{"major":0,"minor":10,"patch":0},"expectedBuild":"%s","artifactURL":"file://%s","destinationURL":"file://%s","backupURL":"file://%s","resultURL":"file://%s","phase":"preflight","createdAt":%s}\n' "$id" "$expectedBuild" "$artifact" "$txDestination" "$txBackup" "$txResult" "$now" > "$descriptor"
    chmod 600 "$descriptor"
    [ "$(stat -f '%Lp' "$descriptor")" = 600 ] || { echo 'Transaction permissions are not 0600.' >&2; exit 1; }
}

run_helper() {
    failure=${1:-}
    if [ -n "$failure" ]; then
        DFUUTILITY_INSTALLER_TEST_FAILURE="$failure" \
        DFUUTILITY_INSTALLER_TEST_MODE=1 \
        DFUUTILITY_INSTALLER_SUPPORT_ROOT="$support" \
        DFUUTILITY_INSTALLER_LAUNCHER="$launcher" \
        "$installer" --test-mode "$descriptor"
    else
        DFUUTILITY_INSTALLER_TEST_MODE=1 \
        DFUUTILITY_INSTALLER_SUPPORT_ROOT="$support" \
        DFUUTILITY_INSTALLER_LAUNCHER="$launcher" \
        "$installer" --test-mode "$descriptor"
    fi
}

assert_result() {
    expected=$1
    grep -Fqx "status=$expected" "$result" || { echo "Unexpected result:" >&2; cat "$result" >&2; exit 1; }
    [ "$(stat -f '%Lp' "$result")" = 600 ] || { echo 'Result permissions are not 0600.' >&2; exit 1; }
}

echo '1/5 successful replacement'
reset_fixture
make_bundle "$destination" 0.9.0 1 old
make_bundle "$staging/DFUUtility.app" 0.10.0 2 new
write_transaction "$staging/DFUUtility.app" 0.10.0 2 "$destination" "$backup" "$result"
run_helper
assert_result success
[ "$(plutil -extract CFBundleShortVersionString raw -o - "$destination/Contents/Info.plist")" = 0.10.0 ]
[ "$(plutil -extract CFBundleVersion raw -o - "$destination/Contents/Info.plist")" = 2 ]
[ "$(cat "$destination/Contents/Resources/fixture-marker")" = new ]
[ ! -e "$backup" ] || { echo 'Backup survived successful verification.' >&2; exit 1; }
[ -s "$launchMarker" ] && [ "$(cat "$launchMarker")" = "$destination" ] || { echo 'No-op relaunch was not invoked correctly.' >&2; exit 1; }

echo '2/5 verification failure rolls back'
reset_fixture
make_bundle "$destination" 0.9.0 1 old
make_bundle "$staging/DFUUtility.app" 0.10.0 2 new
write_transaction "$staging/DFUUtility.app" 0.10.0 2 "$destination" "$backup" "$result"
if run_helper verification; then echo 'Verification failure unexpectedly succeeded.' >&2; exit 1; fi
assert_result failure
[ "$(cat "$destination/Contents/Resources/fixture-marker")" = old ] || { echo 'Rollback did not restore old application.' >&2; exit 1; }
[ ! -e "$backup" ] || { echo 'Backup remained after successful rollback.' >&2; exit 1; }
grep -Fq 'verification' "$result" || { echo 'Failure result omitted verification detail.' >&2; exit 1; }

echo '3/5 rollback failure preserves recovery evidence'
reset_fixture
make_bundle "$destination" 0.9.0 1 old
make_bundle "$staging/DFUUtility.app" 0.10.0 2 new
write_transaction "$staging/DFUUtility.app" 0.10.0 2 "$destination" "$backup" "$result"
if run_helper rollback; then echo 'Rollback failure unexpectedly succeeded.' >&2; exit 1; fi
assert_result failure
grep -Fq 'rollback' "$result" || { echo 'Failure result omitted rollback detail.' >&2; exit 1; }
[ -d "$backup" ] || { echo 'Rollback backup was not preserved.' >&2; exit 1; }
[ "$(cat "$backup/Contents/Resources/fixture-marker")" = old ] || { echo 'Preserved backup is not the old application.' >&2; exit 1; }

echo '4/5 invalid transactions are rejected before replacement'
reset_fixture
mkdir -p "$root/outside"
make_bundle "$destination" 0.9.0 1 old
make_bundle "$staging/DFUUtility.app" 0.10.0 2 new
write_transaction "$root/outside/DFUUtility.app" 0.10.0 2 "$destination" "$backup" "$result"
if run_helper; then echo 'Outside-staging artifact unexpectedly accepted.' >&2; exit 1; fi
[ "$(cat "$destination/Contents/Resources/fixture-marker")" = old ] || { echo 'Invalid transaction modified destination.' >&2; exit 1; }
make_bundle "$root/outside/Other.app" 0.10.0 2 other
plutil -replace CFBundleIdentifier -string com.example.other "$root/outside/Other.app/Contents/Info.plist"
write_transaction "$staging/DFUUtility.app" 0.10.0 2 "$root/outside/Other.app" "$backup" "$result"
if run_helper; then echo 'Wrong destination bundle unexpectedly accepted.' >&2; exit 1; fi
[ "$(cat "$destination/Contents/Resources/fixture-marker")" = old ] || { echo 'Wrong destination changed real fixture.' >&2; exit 1; }
printf '{not-json}\n' > "$descriptor"
if run_helper; then echo 'Malformed transaction unexpectedly accepted.' >&2; exit 1; fi
[ "$(cat "$destination/Contents/Resources/fixture-marker")" = old ] || { echo 'Malformed transaction modified destination.' >&2; exit 1; }

echo '5/5 relaunch isolation and safety assertions'
[ "$destination" != "/Applications/DFUUtility.app" ] || { echo 'Harness refuses to use a real application path.' >&2; exit 1; }
[ ! -e "$root/.git" ] || { echo 'Unexpected source-control mutation in fixture root.' >&2; exit 1; }
[ ! -e "$root/real-install-marker" ] || { echo 'Unexpected real-install marker.' >&2; exit 1; }
printf 'Binary installer harness passed under %s\n' "$root"
