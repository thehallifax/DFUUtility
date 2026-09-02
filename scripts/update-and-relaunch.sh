#!/bin/sh
set -u

if [ "$#" -ne 4 ]; then
  echo "Usage: update-and-relaunch.sh SOURCE_ROOT OLD_PID APP_PATH RESULT_FILE" >&2
  exit 64
fi
source_root=$1
old_pid=$2
app_path=$3
result_file=$4
log_dir="$HOME/Library/Logs/DFUUtility"
log="$log_dir/update.log"
mkdir -p "$log_dir" "$(dirname "$result_file")"
exec >>"$log" 2>&1
printf '\n[%s] In-app update started\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

while kill -0 "$old_pid" 2>/dev/null; do sleep 1; done
old_version=$(sed -n 's/^MARKETING_VERSION=//p' "$source_root/Config/Version.env" | head -1)
old_commit=$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)
printf 'Current source: version=%s commit=%s\n' "$old_version" "$old_commit"

if "$source_root/scripts/update.sh" --verbose; then
  new_version=$(sed -n 's/^MARKETING_VERSION=//p' "$source_root/Config/Version.env" | head -1)
  new_commit=$(git -C "$source_root" rev-parse HEAD 2>/dev/null || true)
  {
    printf 'status=success\n'
    printf 'old_version=%s\nnew_version=%s\nold_commit=%s\nnew_commit=%s\n' "$old_version" "$new_version" "$old_commit" "$new_commit"
  } > "$result_file"
  chmod 600 "$result_file"
  printf '[%s] Update installed; relaunching %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$app_path"
  if ! open "$app_path"; then printf '[%s] Relaunch failed; application remains installed.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; fi
  exit 0
fi

{
  printf 'status=failed\n'
  printf 'old_version=%s\nold_commit=%s\n' "$old_version" "$old_commit"
} > "$result_file"
chmod 600 "$result_file"
printf '[%s] Update failed; existing installed application was preserved.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
open "$app_path" || printf '[%s] Could not reopen the existing application.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit 1
