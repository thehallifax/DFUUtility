#!/bin/sh
set -eu

usage() {
  echo "Usage: scripts/install-local.sh [--test] [--verbose]" >&2
  echo "  --test  Run the repository test suite before packaging and installation." >&2
  echo "  --verbose  Show complete command output for troubleshooting." >&2
  exit "${1:-64}"
}
run_tests=0
verbose=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --test) run_tests=1; shift ;;
    --verbose) verbose=1; shift ;;
    --help|-h) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/Config/Version.env"
source_app="$root/.build/app/DFUUtility.app"
destination="/Applications/DFUUtility.app"
stage="$root/.build/local-install/DFUUtility.app"
log_dir=$(mktemp -d "${TMPDIR:-/tmp}/dfuutility-install.XXXXXX")
backup_record="$log_dir/backup-path"
trap 'rm -rf "$log_dir"' EXIT HUP INT TERM

run_step() {
  label=$1
  name=$2
  shift 2
  log="$log_dir/$name.log"
  if [ "$verbose" -eq 1 ]; then printf '%s...\n' "$label"; else printf '%s... ' "$label"; fi
  if "$@" >"$log" 2>&1; then
    if [ "$verbose" -eq 1 ] && [ -s "$log" ]; then cat "$log"; fi
    if [ "$verbose" -eq 1 ]; then printf '%s... OK\n' "$label"; else echo "OK"; fi
    return 0
  fi
  if [ "$verbose" -eq 1 ]; then printf '%s... FAILED\n' "$label"; else echo "FAILED"; fi
  echo
  echo "--- $name output ---"
  cat "$log"
  echo "--- end $name output ---"
  return 1
}

check_requirements() {
  command -v swift >/dev/null || { echo "swift was not found. Install current Apple Command Line Tools or Xcode."; return 1; }
  command -v codesign >/dev/null || { echo "codesign was not found. Install Apple Command Line Tools."; return 1; }
  command -v xcrun >/dev/null || { echo "xcrun was not found. Install Apple Command Line Tools."; return 1; }
  command -v xcode-select >/dev/null || { echo "xcode-select was not found. Install Apple Command Line Tools."; return 1; }
  xcode-select -p
  xcrun --find swift
  xcrun --find codesign
  if [ "$run_tests" -eq 1 ] && ! swift -e 'import Testing' >/dev/null 2>&1; then
    echo "Full test mode requires a newer Swift/Xcode toolchain that includes the Swift Testing package."
    echo "The application itself can still be installed without --test."
    return 1
  fi
}

run_tests_step() { swift test; }
build_release() { swift build -c release; }
package_app() { scripts/package-app.sh release; }
verify_app() { scripts/verify-app.sh "$source_app"; }
install_app() {
  rm -rf "$root/.build/local-install"
  mkdir -p "$root/.build/local-install"
  ditto "$source_app" "$stage"
  if [ -e "$destination" ]; then
    stamp=$(date +%Y%m%d-%H%M%S)
    backup="$HOME/.Trash/DFUUtility-$stamp.app"
    mv "$destination" "$backup"
    printf '%s\n' "$backup" > "$backup_record"
  fi
  if ! mv "$stage" "$destination"; then
    if [ -s "$backup_record" ] && [ ! -e "$destination" ]; then
      backup=$(cat "$backup_record")
      if mv "$backup" "$destination"; then : > "$backup_record"; else echo "The previous application could not be restored automatically from: $backup" >&2; fi
    fi
    echo "Could not write to /Applications. Install the verified app manually from: $source_app" >&2
    return 1
  fi
  rmdir "$root/.build/local-install"
}

cd "$root"
echo "DFUUtility Community Installer"
echo
run_step "Checking requirements" requirements check_requirements
run_step "Building DFUUtility $MARKETING_VERSION" build build_release
if [ "$run_tests" -eq 1 ]; then run_step "Running tests" tests run_tests_step; fi
run_step "Packaging app" package package_app
run_step "Verifying app" verify verify_app
run_step "Installing app" install install_app

support_dir="$HOME/Library/Application Support/DFUUtility"
mkdir -p "$support_dir"
printf '%s\n' "$root" > "$support_dir/update-source"
chmod 600 "$support_dir/update-source"

if [ -s "$backup_record" ]; then
  echo
  echo "Previous app moved to Trash:"
  sed 's/^/  /' "$backup_record"
fi
echo
echo "Installed:"
echo "  $destination"
echo
echo "Done."
echo
echo "Mac DFU entry may request administrator authorization."
echo "iPhone/iPad DFU uses guided physical-button instructions."
echo "Open Applications → DFUUtility."
quoted_root=$(printf '%s' "$root" | sed "s/'/'\\\\''/g")
echo
echo "To update DFUUtility later:"
echo
printf "  cd '%s'\n" "$quoted_root"
echo "  scripts/update.sh"
