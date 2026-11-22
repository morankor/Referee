#!/bin/bash
# The ONLY supported way to run tests. Usage: scripts/test.sh [extra `swift test` arguments, e.g. --filter PaperTextTests]
# - adds the Swift Testing search paths when the active developer directory is the Command Line Tools (no Xcode)
# - fails if zero tests ran, so a mistyped --filter or a mis-built runner can never look green
set -uo pipefail
cd "$(dirname "$0")/.."
FLAGS=()
DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
  FW="$DEV_DIR/Library/Developer/Frameworks"
  FLAGS=(-Xswiftc -F -Xswiftc "$FW"
         -Xswiftc -plugin-path -Xswiftc "$DEV_DIR/usr/lib/swift/host/plugins/testing"
         -Xlinker -F -Xlinker "$FW"
         -Xlinker -rpath -Xlinker "$FW"
         -Xlinker -rpath -Xlinker "$DEV_DIR/Library/Developer/usr/lib")
fi
LOG="$(mktemp -t referee-test)"
trap 'rm -f "$LOG"' EXIT
swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
RAN="$(grep -Eo 'Test run with [0-9]+ tests?' "$LOG" | tail -1 | grep -Eo '[0-9]+' || true)"
if [[ "$STATUS" -ne 0 ]]; then echo "test.sh: FAILED (swift test exit $STATUS)" >&2; exit "$STATUS"; fi
if [[ -z "$RAN" || "$RAN" -lt 1 ]]; then echo "test.sh: FAILED (zero tests ran; check the --filter and the Swift Testing flags)" >&2; exit 3; fi
echo "test.sh: OK ($RAN tests)"
