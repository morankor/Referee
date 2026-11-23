#!/bin/bash
# The real local-model end to end of plan.md section 10.4: a review and a question through Ollama on 127.0.0.1, at no cost.
# Usage: scripts/e2e-ollama.sh [model] [pdf] [--expect-parts]
#   model           an installed Ollama model (default gemma4:e4b; "phi4" finds "phi4:latest")
#   pdf             the manuscript (default Fixtures/pdf/ay_round_nolinks.pdf)
#   --expect-parts  fail unless the plan reads the paper in parts and the run sends every planned request
# Requires exit 0, status=completed and comments>=1 in the SUMMARY line, and a non-empty answer to the question.
# A local model's content is not judged. Exit codes: 0 pass; 1 the pipeline failed; 2 usage; 3 Ollama does not answer.
set -uo pipefail
cd "$(dirname "$0")/.."
MODEL="gemma4:e4b"
PDF="Fixtures/pdf/ay_round_nolinks.pdf"
EXPECT_PARTS=0
COUNT=0
for argument in "$@"; do
  case "$argument" in
    --expect-parts) EXPECT_PARTS=1 ;;
    -*) echo "e2e-ollama.sh: unknown option $argument" >&2; exit 2 ;;
    *) COUNT=$((COUNT + 1))
       if [[ $COUNT -eq 1 ]]; then MODEL="$argument"; elif [[ $COUNT -eq 2 ]]; then PDF="$argument"
       else echo "usage: scripts/e2e-ollama.sh [model] [pdf] [--expect-parts]" >&2; exit 2; fi ;;
  esac
done
fail() { echo "e2e-ollama.sh: FAILED ($1)" >&2; exit 1; }

curl -fsS --max-time 5 http://127.0.0.1:11434/api/version >/dev/null 2>&1 || {
  echo "e2e-ollama.sh: Ollama does not answer on http://127.0.0.1:11434" >&2; exit 3; }
[[ -f "$PDF" ]] || { echo "e2e-ollama.sh: no such file: $PDF" >&2; exit 2; }
scripts/build.sh --product referee-cli >/dev/null || fail "build"
CLI="$(swift build --show-bin-path)/referee-cli"
LOG="$(mktemp -t referee-e2e)"
trap 'rm -f "$LOG"' EXIT

PLAN="$("$CLI" plan "$PDF" --provider ollama --model "$MODEL")"
PLAN_STATUS=$?
echo "$PLAN"
[[ $PLAN_STATUS -eq 0 ]] || fail "plan exited $PLAN_STATUS"
PLANNED="$(grep -Eo 'requests=[0-9]+' <<< "$PLAN" | head -1 | cut -d= -f2)"
if [[ $EXPECT_PARTS -eq 1 && "${PLANNED:-1}" -le 1 ]]; then
  fail "the plan reads $(basename "$PDF") in one pass; --expect-parts needs a longer paper or a model with a smaller window"
fi

START=$(date +%s)
"$CLI" review "$PDF" --provider ollama --model "$MODEL" | tee "$LOG"
STATUS=${PIPESTATUS[0]}
SUMMARY="$(grep '^SUMMARY ' "$LOG" | tail -1)"
[[ $STATUS -eq 0 ]] || fail "review exited $STATUS"
[[ "$SUMMARY" == *"status=completed"* ]] || fail "no SUMMARY line with status=completed"
field() { grep -Eo "(^| )$1=[0-9]+" <<< "$SUMMARY" | head -1 | cut -d= -f2; }
COMMENTS="$(field comments)"
ANCHORED="$(field anchored)"
REQUESTS="$(field requests)"
REPORTED="$(grep -Eo '(^| )model=[^ ]+' <<< "$SUMMARY" | head -1 | cut -d= -f2)"     # the model Ollama's stream named
[[ "${COMMENTS:-0}" -ge 1 ]] || fail "the review produced no comment"
if [[ $EXPECT_PARTS -eq 1 && "${REQUESTS:-0}" -lt "$PLANNED" ]]; then fail "the review sent $REQUESTS of the $PLANNED planned requests"; fi
echo "e2e-ollama.sh: anchored=$ANCHORED of comments=$COMMENTS, requests=$REQUESTS"

ANSWER="$("$CLI" ask "$PDF" --provider ollama --model "$MODEL" --question "Is the claim in the abstract supported?" \
  --quote "The effect is statistically significant but economically small.")"
ASK_STATUS=$?
echo "$ANSWER"
[[ $ASK_STATUS -eq 0 ]] || fail "ask exited $ASK_STATUS"
[[ -n "${ANSWER//[[:space:]]/}" ]] || fail "the answer is empty"
echo "e2e-ollama.sh: OK ($MODEL on $(basename "$PDF"): $COMMENTS comments, $ANCHORED anchored, $REQUESTS requests, $(( $(date +%s) - START )) s, reported model ${REPORTED:--})"
