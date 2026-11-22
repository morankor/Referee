#!/bin/bash
# Usage: scripts/snapshots.sh [--out <dir>] [--scene <name>]... [--dark] [--size WxH]     (default output: build/snapshots)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="build/snapshots"; ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT="${2:?--out needs a directory}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
scripts/build.sh --product Referee
mkdir -p "$OUT"
"$(swift build --show-bin-path)/Referee" --ui-snapshot "$OUT" ${ARGS[@]+"${ARGS[@]}"}
ls -1 "$OUT"/*.png
