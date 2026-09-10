#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary="$root/.build/debug/DFUUtility"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/dfu-handoff-smoke.XXXXXX")
failure_pid=""
trap 'if [ -n "$failure_pid" ]; then kill "$failure_pid" 2>/dev/null || true; wait "$failure_pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT HUP INT TERM

case "$root" in
  /Applications|/Applications/*) echo "Refusing to run from /Applications" >&2; exit 1 ;;
esac

swift build >/dev/null
[ -x "$binary" ] || { echo "Debug DFUUtility executable was not built" >&2; exit 1; }

run_success() {
  log="$tmp/success.log"
  "$binary" --handoff-termination-smoke-success >"$log" 2>&1 &
  pid=$!
  deadline=$((SECONDS + 8))
  while kill -0 "$pid" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    echo "Successful handoff smoke process did not exit (pid $pid)" >&2
    cat "$log" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  wait "$pid" 2>/dev/null || true
  grep -Fq 'synthetic installer spawn succeeded' "$log"
  grep -Fq 'termination request on main thread=true' "$log"
  grep -Fq 'applicationShouldTerminate reply=terminateNow' "$log"
  grep -Fq 'applicationWillTerminate' "$log"
}

run_failure() {
  log="$tmp/failure.log"
  "$binary" --handoff-termination-smoke-failure >"$log" 2>&1 &
  failure_pid=$!
  sleep 1
  if ! kill -0 "$failure_pid" 2>/dev/null; then
    echo "Spawn-failure smoke process exited unexpectedly" >&2
    cat "$log" >&2
    return 1
  fi
  grep -Fq 'synthetic installer spawn failed; app remains running' "$log"
  if grep -Fq 'termination request' "$log" || grep -Fq 'applicationWillTerminate' "$log"; then
    echo "Spawn-failure smoke unexpectedly requested termination" >&2
    cat "$log" >&2
    return 1
  fi
  kill "$failure_pid" 2>/dev/null || true
  wait "$failure_pid" 2>/dev/null || true
  failure_pid=""
}

run_success
run_failure
echo "Handoff termination smoke passed"
