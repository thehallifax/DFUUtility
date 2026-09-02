#!/bin/sh
set -eu

usage() {
  echo "Usage: scripts/update.sh [--check] [--test] [--verbose]" >&2
  echo "  --check    Check for newer source without changing or installing anything." >&2
  echo "  --test     Run the repository tests during installation." >&2
  echo "  --verbose  Show complete installer command output." >&2
  exit "${1:-64}"
}

check_only=0
run_tests=0
verbose=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check_only=1; shift ;;
    --test) run_tests=1; shift ;;
    --verbose) verbose=1; shift ;;
    --help|-h) usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

source_version_from_file() {
  sed -n 's/^MARKETING_VERSION=//p' "$1" | head -n 1
}

fail_no_changes() {
  echo
  printf '%b\n' "$1" >&2
  echo >&2
  echo "No source files or installed application were changed." >&2
  exit 1
}

echo "DFUUtility Updater"
echo
printf 'Checking repository... '
if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "FAILED"
  fail_no_changes "DFUUtility can't update because this folder is not a Git worktree."
fi
top=$(CDPATH= cd -- "$(git -C "$root" rev-parse --show-toplevel)" && pwd -P)
if [ "$top" != "$root" ]; then
  echo "FAILED"
  fail_no_changes "DFUUtility can't update because scripts/update.sh is not at the root of this Git worktree."
fi
if ! origin_url=$(git -C "$root" remote get-url origin 2>/dev/null); then
  echo "FAILED"
  fail_no_changes "DFUUtility can't update because this checkout has no origin remote."
fi
case "$origin_url" in
  https://github.com/thehallifax/DFUUtility|https://github.com/thehallifax/DFUUtility.git|git@github.com:thehallifax/DFUUtility|git@github.com:thehallifax/DFUUtility.git|ssh://git@github.com/thehallifax/DFUUtility|ssh://git@github.com/thehallifax/DFUUtility.git|file://*|/*|./*|../*) ;;
  *)
    echo "FAILED"
    fail_no_changes "DFUUtility can't update because origin does not point to the expected repository:\n  $origin_url"
    ;;
esac
if ! branch=$(git -C "$root" symbolic-ref --quiet --short HEAD); then
  echo "FAILED"
  fail_no_changes "DFUUtility automatic updates require the main branch. This checkout has a detached HEAD."
fi
if [ "$branch" != "main" ]; then
  echo "FAILED"
  fail_no_changes "DFUUtility automatic updates are available from the main branch.\nThis checkout is currently on: $branch"
fi
if [ -n "$(git -C "$root" status --porcelain --untracked-files=all)" ]; then
  echo "FAILED"
  fail_no_changes "DFUUtility can't update because this source folder contains local changes.\n\nRun:\n  git status"
fi
if [ ! -f "$root/Config/Version.env" ]; then
  echo "FAILED"
  fail_no_changes "DFUUtility can't find Config/Version.env."
fi
current_version=$(source_version_from_file "$root/Config/Version.env")
if [ -z "$current_version" ]; then
  echo "FAILED"
  fail_no_changes "DFUUtility can't read MARKETING_VERSION from Config/Version.env."
fi
echo "OK"

printf 'Checking for updates... '
if ! git -C "$root" fetch --quiet origin main; then
  echo "FAILED"
  fail_no_changes "Could not contact the DFUUtility Git repository."
fi
remote_ref=refs/remotes/origin/main
if ! git -C "$root" rev-parse --verify --quiet "$remote_ref" >/dev/null; then
  echo "FAILED"
  fail_no_changes "The origin remote does not provide the supported main branch."
fi
current_commit=$(git -C "$root" rev-parse HEAD)
latest_commit=$(git -C "$root" rev-parse "$remote_ref")
if ! latest_metadata=$(git -C "$root" show "$remote_ref:Config/Version.env" 2>/dev/null); then
  echo "FAILED"
  fail_no_changes "DFUUtility can't read Config/Version.env from origin/main."
fi
latest_version=$(printf '%s\n' "$latest_metadata" | sed -n 's/^MARKETING_VERSION=//p' | head -n 1)
if [ -z "$latest_version" ]; then
  echo "FAILED"
  fail_no_changes "DFUUtility can't read MARKETING_VERSION from origin/main."
fi
echo "OK"
echo
echo "Current source: $current_version"

if [ "$current_commit" = "$latest_commit" ]; then
  echo
  echo "DFUUtility is already up to date."
  exit 0
fi

if ! git -C "$root" merge-base --is-ancestor "$current_commit" "$latest_commit"; then
  if git -C "$root" merge-base --is-ancestor "$latest_commit" "$current_commit"; then
    reason="This main branch contains local commits that are not on origin/main."
  else
    reason="This main branch has diverged from origin/main."
  fi
  fail_no_changes "$reason\nManage this Git checkout manually before using the updater."
fi

if [ "$check_only" -eq 1 ]; then
  echo "Update available: $latest_version"
  exit 0
fi

echo "Latest source: $latest_version"
echo
printf 'Updating source... '
if git -C "$root" merge --ff-only --quiet "$remote_ref"; then
  echo "OK"
else
  echo "FAILED"
  fail_no_changes "The source could not be fast-forwarded safely."
fi

echo "Installing DFUUtility $latest_version..."
echo
installer="$root/scripts/install-local.sh"
if [ ! -x "$installer" ]; then
  echo "The source was updated, but scripts/install-local.sh is missing or not executable." >&2
  echo "The existing installed application was not replaced by the updater." >&2
  exit 1
fi
if [ "$run_tests" -eq 1 ] && [ "$verbose" -eq 1 ]; then
  install_status=0; "$installer" --test --verbose || install_status=$?
elif [ "$run_tests" -eq 1 ]; then
  install_status=0; "$installer" --test || install_status=$?
elif [ "$verbose" -eq 1 ]; then
  install_status=0; "$installer" --verbose || install_status=$?
else
  install_status=0; "$installer" || install_status=$?
fi
if [ "$install_status" -ne 0 ]; then
  echo >&2
  echo "DFUUtility source was updated, but installation failed." >&2
  echo "The existing application may still be installed. Review the installer output above." >&2
  exit "$install_status"
fi

echo
if [ "$current_version" = "$latest_version" ]; then
  echo "Updated DFUUtility source."
  echo "Version remains $latest_version."
else
  echo "Updated:"
  echo "  DFUUtility $current_version → $latest_version"
fi
