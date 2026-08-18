#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${1:-release}

cd "$repository_root"
swift build -c "$configuration" --product macvdmtool
printf '%s\n' "$repository_root/.build/$configuration/macvdmtool"
