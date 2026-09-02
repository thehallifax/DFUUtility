#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
suite=$(mktemp -d "${TMPDIR:-/tmp}/dfuutility-update-tests.XXXXXX")
trap 'rm -rf "$suite"' EXIT HUP INT TERM
failures=0

fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }
expect_status() { [ "$status" -eq "$1" ] || fail "$case_name: expected status $1, got $status"; }
expect_file() { [ -f "$1" ] || fail "$case_name: expected file $1"; }
expect_no_file() { [ ! -e "$1" ] || fail "$case_name: unexpected file $1"; }
expect_output() { grep -Fq "$1" "$output" || fail "$case_name: missing output: $1"; }
expect_head() { actual=$(git -C "$checkout" rev-parse HEAD); [ "$actual" = "$1" ] || fail "$case_name: HEAD changed unexpectedly"; }

new_fixture() {
  case_name=$1
  case_root="$suite/$case_name"
  remote="$case_root/remote.git"
  seed="$case_root/seed"
  checkout="$case_root/checkout with spaces"
  install_log="$case_root/installer.log"
  output="$case_root/output.log"
  mkdir -p "$case_root"
  git init -q --bare "$remote"
  git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
  git init -q -b main "$seed"
  git -C "$seed" config user.name "DFUUtility Test"
  git -C "$seed" config user.email "test@example.invalid"
  mkdir -p "$seed/Config" "$seed/scripts"
  printf '%s\n' 'MARKETING_VERSION=0.6.1' > "$seed/Config/Version.env"
  cp "$root/scripts/update.sh" "$seed/scripts/update.sh"
  printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" > "$DFUUTILITY_TEST_INSTALL_LOG"' 'exit "${DFUUTILITY_TEST_INSTALL_STATUS:-0}"' > "$seed/scripts/install-local.sh"
  chmod +x "$seed/scripts/update.sh" "$seed/scripts/install-local.sh"
  git -C "$seed" add .
  git -C "$seed" commit -q -m initial
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" push -q -u origin main
  git clone -q "$remote" "$checkout"
  git -C "$checkout" config user.name "DFUUtility Test"
  git -C "$checkout" config user.email "test@example.invalid"
  initial_head=$(git -C "$checkout" rev-parse HEAD)
}

advance_remote() {
  version=$1
  marker=$2
  printf '%s\n' "MARKETING_VERSION=$version" > "$seed/Config/Version.env"
  printf '%s\n' "$marker" > "$seed/$marker.txt"
  git -C "$seed" add .
  git -C "$seed" commit -q -m "$marker"
  git -C "$seed" push -q origin main
  remote_head=$(git -C "$seed" rev-parse HEAD)
}

run_update() {
  status=0
  DFUUTILITY_TEST_INSTALL_LOG="$install_log" "${checkout}/scripts/update.sh" "$@" >"$output" 2>&1 || status=$?
}

new_fixture clean-fast-forward
advance_remote 0.7.0 update
run_update --verbose --test
expect_status 0; expect_head "$remote_head"; expect_file "$install_log"; [ "$(cat "$install_log")" = "--test --verbose" ] || fail "$case_name: combined flags were not passed through"; expect_output "DFUUtility 0.6.1 → 0.7.0"

new_fixture already-current
run_update
expect_status 0; expect_head "$initial_head"; expect_no_file "$install_log"; expect_output "already up to date"

new_fixture dirty-tracked
printf '%s\n' dirty >> "$checkout/Config/Version.env"
advance_remote 0.7.0 update
run_update
[ "$status" -ne 0 ] || fail "$case_name: dirty checkout succeeded"; expect_head "$initial_head"; expect_no_file "$install_log"; expect_output "contains local changes"

new_fixture dirty-untracked
printf '%s\n' dirty > "$checkout/untracked.txt"
advance_remote 0.7.0 update
run_update
[ "$status" -ne 0 ] || fail "$case_name: untracked checkout succeeded"; expect_head "$initial_head"; expect_no_file "$install_log"

new_fixture detached-head
git -C "$checkout" checkout -q --detach
run_update
[ "$status" -ne 0 ] || fail "$case_name: detached HEAD succeeded"; expect_head "$initial_head"; expect_no_file "$install_log"; expect_output "detached HEAD"

new_fixture wrong-branch
git -C "$checkout" checkout -q -b feature
run_update
[ "$status" -ne 0 ] || fail "$case_name: feature branch succeeded"; expect_head "$initial_head"; expect_no_file "$install_log"; expect_output "currently on: feature"

new_fixture diverged
advance_remote 0.7.0 remote-change
printf '%s\n' local > "$checkout/local.txt"
git -C "$checkout" add local.txt
git -C "$checkout" commit -q -m local-change
local_head=$(git -C "$checkout" rev-parse HEAD)
run_update
[ "$status" -ne 0 ] || fail "$case_name: diverged branch succeeded"; expect_head "$local_head"; expect_no_file "$install_log"; expect_output "diverged"

new_fixture fetch-failure
mv "$remote" "$case_root/unavailable.git"
run_update
[ "$status" -ne 0 ] || fail "$case_name: fetch failure succeeded"; expect_head "$initial_head"; expect_no_file "$install_log"; expect_output "Could not contact"

new_fixture installer-failure
advance_remote 0.7.0 update
status=0
DFUUTILITY_TEST_INSTALL_LOG="$install_log" DFUUTILITY_TEST_INSTALL_STATUS=23 "$checkout/scripts/update.sh" >"$output" 2>&1 || status=$?
expect_status 23; expect_head "$remote_head"; expect_file "$install_log"; expect_output "source was updated, but installation failed"

new_fixture check-only
advance_remote 0.7.0 update
run_update --check
expect_status 0; expect_head "$initial_head"; expect_no_file "$install_log"; expect_output "Update available: 0.7.0"

new_fixture test-flag
advance_remote 0.7.0 update
run_update --test
expect_status 0; [ "$(cat "$install_log")" = "--test" ] || fail "$case_name: --test was not passed through"

new_fixture verbose-flag
advance_remote 0.7.0 update
run_update --verbose
expect_status 0; [ "$(cat "$install_log")" = "--verbose" ] || fail "$case_name: --verbose was not passed through"

new_fixture same-version
advance_remote 0.6.1 source-only
run_update
expect_status 0; expect_head "$remote_head"; expect_file "$install_log"; expect_output "Version remains 0.6.1"

new_fixture wrong-origin
git -C "$checkout" remote set-url origin https://example.invalid/not-dfuutility.git
run_update
[ "$status" -ne 0 ] || fail "$case_name: unexpected origin succeeded"; expect_head "$initial_head"; expect_no_file "$install_log"; expect_output "does not point to the expected repository"

if [ "$failures" -ne 0 ]; then
  echo "$failures updater test(s) failed." >&2
  exit 1
fi
echo "Updater shell tests passed."
