#!/bin/sh
set -eu

repository="thehallifax/DFUUtility"
api_url="https://api.github.com/repos/$repository/releases/latest"
destination="/Applications/DFUUtility.app"
test_mode=${DFUUTILITY_INSTALL_RELEASE_TEST_MODE:-0}
work_root=$(mktemp -d "${TMPDIR:-/tmp}/dfuutility-release-install.XXXXXX")

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  rm -rf "$work_root"
  exit "$status"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'Unable to install DFUUtility: %s\n' "$1" >&2
  exit 1
}

[ "$(uname -s)" = Darwin ] || fail "this installer supports macOS only."

if [ "$test_mode" = 1 ]; then
  test_root=${DFUUTILITY_INSTALL_RELEASE_TEST_ROOT:?Test mode requires DFUUTILITY_INSTALL_RELEASE_TEST_ROOT.}
  destination=${DFUUTILITY_INSTALL_RELEASE_DESTINATION:?Test mode requires DFUUTILITY_INSTALL_RELEASE_DESTINATION.}
  [ -d "$test_root" ] || fail "the test root does not exist."
  test_root=$(CDPATH= cd -- "$test_root" && pwd -P)
  destination_name=$(basename "$destination")
  destination_parent=$(dirname "$destination")
  [ -d "$destination_parent" ] || fail "the test destination folder does not exist."
  destination_parent=$(CDPATH= cd -- "$destination_parent" && pwd -P)
  destination="$destination_parent/$destination_name"
  case "$test_root" in /|/Applications|/Applications/*) fail "the test root must not use /Applications or the filesystem root." ;; esac
  case "$destination" in "$test_root"/*) ;; *) fail "the test destination must remain beneath its physical fixture root." ;; esac
elif [ -n "${DFUUTILITY_INSTALL_RELEASE_TEST_ROOT:-}${DFUUTILITY_INSTALL_RELEASE_DESTINATION:-}${DFUUTILITY_INSTALL_RELEASE_METADATA_FILE:-}${DFUUTILITY_INSTALL_RELEASE_ASSET_FILE:-}${DFUUTILITY_INSTALL_RELEASE_TEST_RUNNING:-}${DFUUTILITY_INSTALL_RELEASE_TEST_FAILURE:-}" ]; then
  fail "test overrides require explicit test mode."
fi

if [ "$test_mode" = 1 ]; then
  [ "${DFUUTILITY_INSTALL_RELEASE_TEST_RUNNING:-0}" != 1 ] || fail "DFUUtility is currently running. Quit DFUUtility and try again."
elif /usr/bin/pgrep -x DFUUtility >/dev/null 2>&1; then
  fail "DFUUtility is currently running. Quit DFUUtility and try again."
fi

metadata_json="$work_root/release.json"
metadata_plist="$work_root/release.plist"
archive="$work_root/DFUUtility.zip"
archive_entries="$work_root/archive-entries.txt"
extract_root="$work_root/extracted"

if [ "$test_mode" = 1 ]; then
  metadata_fixture=${DFUUTILITY_INSTALL_RELEASE_METADATA_FILE:?Test mode requires release metadata.}
  [ -f "$metadata_fixture" ] || fail "the release metadata fixture is missing."
  cp "$metadata_fixture" "$metadata_json"
else
  printf 'Resolving latest stable release... '
  /usr/bin/curl --proto '=https' --tlsv1.2 --fail --silent --show-error \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    --output "$metadata_json" "$api_url" || fail "GitHub release metadata could not be downloaded."
  echo "OK"
fi

/usr/bin/plutil -convert xml1 -o "$metadata_plist" "$metadata_json" >/dev/null 2>&1 || fail "GitHub returned malformed release metadata."
plist_read() { /usr/libexec/PlistBuddy -c "Print :$1" "$metadata_plist" 2>/dev/null; }

tag=$(plist_read tag_name) || fail "the release does not contain a version tag."
draft=$(plist_read draft) || fail "the release draft state is missing."
prerelease=$(plist_read prerelease) || fail "the release prerelease state is missing."
[ "$draft" = false ] || fail "draft releases cannot be installed."
[ "$prerelease" = false ] || fail "prerelease releases cannot be installed."
printf '%s\n' "$tag" | /usr/bin/grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || fail "the release version tag is invalid."
version=${tag#v}
asset_name="DFUUtility-$version.zip"

asset_count=0
asset_url=""
asset_size=""
asset_digest=""
index=0
while name=$(plist_read "assets:$index:name"); do
  if [ "$name" = "$asset_name" ]; then
    asset_count=$((asset_count + 1))
    asset_url=$(plist_read "assets:$index:browser_download_url") || fail "the release asset URL is missing."
    asset_size=$(plist_read "assets:$index:size") || fail "the release asset size is missing."
    asset_digest=$(plist_read "assets:$index:digest") || fail "the release asset SHA-256 is missing."
  fi
  index=$((index + 1))
done
[ "$asset_count" -eq 1 ] || fail "the release must contain exactly one $asset_name asset."
[ "$asset_url" = "https://github.com/$repository/releases/download/$tag/$asset_name" ] || fail "the release asset URL is not the expected HTTPS GitHub URL."
case "$asset_size" in ''|*[!0-9]*) fail "the release asset size is invalid." ;; esac
[ "$asset_size" -gt 0 ] || fail "the release asset size is invalid."
case "$asset_digest" in sha256:*) ;; *) fail "the release asset SHA-256 is invalid." ;; esac
expected_sha=${asset_digest#sha256:}
[ "${#expected_sha}" -eq 64 ] || fail "the release asset SHA-256 is invalid."
case "$expected_sha" in *[!0-9a-fA-F]*) fail "the release asset SHA-256 is invalid." ;; esac

printf 'Downloading DFUUtility %s... ' "$version"
if [ "$test_mode" = 1 ]; then
  asset_fixture=${DFUUTILITY_INSTALL_RELEASE_ASSET_FILE:?Test mode requires a release asset.}
  [ -f "$asset_fixture" ] || fail "the release asset fixture is missing."
  cp "$asset_fixture" "$archive"
else
  effective_url_file="$work_root/effective-url"
  /usr/bin/curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error \
    --location --max-redirs 5 --output "$archive" --write-out '%{url_effective}' \
    "$asset_url" > "$effective_url_file" || fail "the release asset could not be downloaded."
  effective_url=$(cat "$effective_url_file")
  case "$effective_url" in
    https://github.com/*|https://release-assets.githubusercontent.com/*|https://objects.githubusercontent.com/*) ;;
    *) fail "the release download ended at an untrusted location." ;;
  esac
fi
echo "OK"

actual_size=$(/usr/bin/stat -f '%z' "$archive")
[ "$actual_size" = "$asset_size" ] || fail "the downloaded asset size does not match the release metadata."
actual_sha=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
[ "$(printf '%s' "$actual_sha" | tr 'A-F' 'a-f')" = "$(printf '%s' "$expected_sha" | tr 'A-F' 'a-f')" ] || fail "the downloaded asset failed SHA-256 verification."

/usr/bin/unzip -Z1 "$archive" > "$archive_entries" 2>/dev/null || fail "the release asset is not a readable ZIP archive."
[ -s "$archive_entries" ] || fail "the release archive is empty."
while IFS= read -r entry; do
  case "$entry" in
    /*|*\\*) fail "the release archive contains an unsafe path." ;;
  esac
  case "/$entry/" in
    */../*|*/./*) fail "the release archive contains path traversal." ;;
  esac
  case "$entry" in
    DFUUtility.app|DFUUtility.app/*|__MACOSX|__MACOSX/|__MACOSX/DFUUtility.app|__MACOSX/DFUUtility.app/*) ;;
    *) fail "the release archive contains an unexpected top-level item." ;;
  esac
done < "$archive_entries"
/usr/bin/grep -Fqx 'DFUUtility.app/Contents/Info.plist' "$archive_entries" || fail "the expected application bundle is missing from the archive."
/usr/bin/zipinfo -l "$archive" | /usr/bin/grep -Eq '^l' && fail "symbolic links are not accepted in the release archive."

mkdir -p "$extract_root"
/usr/bin/unzip -qq "$archive" -d "$extract_root" || fail "the release archive could not be expanded."
app="$extract_root/DFUUtility.app"
[ -d "$app" ] || fail "the archive did not contain DFUUtility.app."
[ "$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print | wc -l | tr -d ' ')" = 1 ] || fail "the archive must contain exactly one application bundle."

verify_bundle() {
  candidate=$1
  info="$candidate/Contents/Info.plist"
  [ -f "$info" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info" 2>/dev/null)" = org.dfuutility.app ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info" 2>/dev/null)" = "$version" ] || return 1
  [ "$(/usr/libexec/PlistBuddy -c 'Print :DFUUtilityInstallationKind' "$info" 2>/dev/null)" = distribution ] || return 1
  for executable in \
    Contents/MacOS/DFUUtility \
    Contents/Library/LaunchServices/DFUPrivilegedHelper \
    Contents/Resources/DFUBinaryInstaller \
    Contents/Resources/macvdmtool; do
    [ -x "$candidate/$executable" ] || return 1
  done
  for resource in \
    Contents/Resources/DFUUtility-LICENSE.txt \
    Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt \
    Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt \
    Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM-NOTICE.md; do
    [ -s "$candidate/$resource" ] || return 1
  done
  /usr/bin/codesign --verify --deep --strict "$candidate" >/dev/null 2>&1 || return 1
}

verify_bundle "$app" || fail "the downloaded application failed bundle or signature verification."

destination_parent=$(dirname "$destination")
[ -d "$destination_parent" ] || fail "the destination folder does not exist."
if [ ! -w "$destination_parent" ]; then
  fail "DFUUtility was verified, but $destination_parent is not writable. Download the ZIP from GitHub Releases and move DFUUtility.app into Applications manually."
fi
if [ -e "$destination" ]; then
  [ -d "$destination" ] || fail "the existing destination is not an application bundle."
  existing_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)
  [ "$existing_identifier" = org.dfuutility.app ] || fail "the existing /Applications/DFUUtility.app has an unexpected bundle identifier."
fi

transaction_id=$(/usr/bin/uuidgen)
stage="$destination_parent/.DFUUtility-install-$transaction_id.app"
backup="$destination_parent/.DFUUtility-backup-$transaction_id.app"
failed="$destination_parent/.DFUUtility-failed-$transaction_id.app"
case "$stage$backup$failed" in *'UUID().uuidString'*) fail "unable to create unique transaction paths." ;; esac

/usr/bin/ditto "$app" "$stage" || fail "the verified application could not be staged beside the destination."
verify_bundle "$stage" || { rm -rf "$stage"; fail "the staged application failed verification."; }

had_previous=0
if [ -e "$destination" ]; then
  mv "$destination" "$backup" || { rm -rf "$stage"; fail "the existing application could not be preserved for rollback."; }
  had_previous=1
fi

replacement_failed=0
if [ "$test_mode" = 1 ] && [ "${DFUUTILITY_INSTALL_RELEASE_TEST_FAILURE:-}" = replacement ]; then
  replacement_failed=1
elif ! mv "$stage" "$destination"; then
  replacement_failed=1
fi

if [ "$replacement_failed" -eq 1 ]; then
  if [ "$had_previous" -eq 1 ] && mv "$backup" "$destination"; then
    rm -rf "$stage"
    fail "replacement failed; the previous application was restored."
  fi
  fail "replacement failed and automatic rollback could not be completed. Preserved backup: $backup"
fi

if ! verify_bundle "$destination"; then
  mv "$destination" "$failed" 2>/dev/null || true
  if [ "$had_previous" -eq 1 ] && mv "$backup" "$destination"; then
    fail "post-install verification failed; the previous application was restored."
  fi
  fail "post-install verification failed and automatic rollback could not be completed. Preserved backup: $backup"
fi

retired=""
if [ "$had_previous" -eq 1 ]; then
  if [ "$test_mode" = 1 ]; then
    trash_root=${DFUUTILITY_INSTALL_RELEASE_TRASH:?Test mode requires DFUUTILITY_INSTALL_RELEASE_TRASH.}
  else
    trash_root="$HOME/.Trash"
  fi
  mkdir -p "$trash_root"
  retired="$trash_root/DFUUtility-$transaction_id.app"
  if ! mv "$backup" "$retired"; then
    retired="$backup"
    printf 'Warning: the previous application remains at %s\n' "$backup" >&2
  fi
fi

printf '\nInstalled DFUUtility %s\n' "$version"
printf '  %s\n' "$destination"
[ -z "$retired" ] || printf 'Previous application preserved at:\n  %s\n' "$retired"
printf '\nFuture releases are available through DFUUtility → Check for Updates…\n'
