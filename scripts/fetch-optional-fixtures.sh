#!/bin/bash
# Downloads three public arXiv papers into Fixtures/private/ (git-ignored) for the tests that need real PDFs
# (plan.md section 3.6). Network: arxiv.org only, one request every three seconds as arXiv asks; a paper already
# present is kept. Journal-system PDFs of your own go in Fixtures/private/journal/, which this script never touches.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=Fixtures/private
mkdir -p "$DEST"
# 1706.03762: numeric citations with hyperref links (15 pages, 40 references).
# 1409.0473 and 1803.09015: author–year citations with links, a machine-learning and an econometrics paper.
PAPERS=(1706.03762 1409.0473 1803.09015)
FIRST=1
for ID in "${PAPERS[@]}"; do
  OUT="$DEST/arxiv-$ID.pdf"
  if [[ -s "$OUT" ]] && [[ "$(head -c 5 "$OUT")" == "%PDF-" ]]; then
    echo "kept $OUT"
    continue
  fi
  [[ $FIRST -eq 1 ]] || sleep 3
  FIRST=0
  PART="$DEST/.arxiv-$ID.partial"
  if ! curl -fsSL --max-time 120 --proto '=https' --proto-redir '=https' -A "referee-fixtures/0.1" -o "$PART" "https://arxiv.org/pdf/$ID"; then
    rm -f "$PART"
    echo "fetch-optional-fixtures.sh: could not download arXiv $ID" >&2
    exit 1
  fi
  if [[ "$(head -c 5 "$PART")" != "%PDF-" ]]; then
    rm -f "$PART"
    echo "fetch-optional-fixtures.sh: arXiv $ID did not return a PDF" >&2
    exit 1
  fi
  mv "$PART" "$OUT"
  echo "fetched $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
done
