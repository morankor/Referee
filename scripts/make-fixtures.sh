#!/bin/bash
# Regenerates Fixtures/pdf and Fixtures/raw from Fixtures/tex. Needs MacTeX (pdflatex) and sips. Usage: scripts/make-fixtures.sh [--pdf-only]
set -euo pipefail
cd "$(dirname "$0")/.."
TEX=Fixtures/tex; PDF=Fixtures/pdf; RAW=Fixtures/raw
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PDF" "$RAW"
STRIP_JOURNAL='/\\usepackage{draftwatermark}/d; /\\SetWatermarkText/d; /\\SetWatermarkScale/d; /\\linenumbers/d'
cp "$TEX/ay_nolinks.tex" "$TEX/s1_preamble.tex" "$TEX/num_twocol_links.tex" "$TEX/ay_long.tex" "$WORK/"
sed -e "$STRIP_JOURNAL" -e '/\\usepackage{lineno}/d' -e 's/\\usepackage{natbib}/\\usepackage[round]{natbib}/' "$TEX/ay_nolinks.tex" > "$WORK/ay_round_nolinks.tex"
sed -e "$STRIP_JOURNAL" -e '/\\usepackage{lineno}/d' -e 's/\\usepackage{natbib}/\\usepackage{natbib}\\usepackage[colorlinks=true,citecolor=blue]{hyperref}/' "$TEX/ay_nolinks.tex" > "$WORK/ay_links.tex"
sed -e "$STRIP_JOURNAL" -e 's/\\usepackage{lineno}/\\input{s1_preamble}/' -e 's/\\usepackage{natbib}/\\usepackage[round]{natbib}/' "$TEX/ay_nolinks.tex" > "$WORK/s1_ruler.tex"
sed -e 's/\[10pt,twocolumn\]/[11pt]/' -e 's/A Two-Column Numeric Fixture With Links/A Single-Column Numeric Fixture With Links/' "$TEX/num_twocol_links.tex" > "$WORK/num_links.tex"
for name in ay_nolinks ay_round_nolinks ay_links s1_ruler num_links num_twocol_links ay_long; do
  ( cd "$WORK" && for pass in 1 2 3; do pdflatex -interaction=nonstopmode -halt-on-error "$name.tex" >/dev/null; done )
  cp "$WORK/$name.pdf" "$PDF/$name.pdf"
  echo "built $PDF/$name.pdf"
done
sips -s format png "$PDF/ay_round_nolinks.pdf" --out "$WORK/scan.png" >/dev/null
sips -s format pdf "$WORK/scan.png" --out "$PDF/scanned.pdf" >/dev/null
echo "built $PDF/scanned.pdf"
[[ "${1:-}" == "--pdf-only" ]] && exit 0
scripts/build.sh --product referee-cli
CLI="$(swift build --show-bin-path)/referee-cli"
for f in "$PDF"/*.pdf; do
  "$CLI" dump-raw "$f" > "$RAW/$(basename "$f" .pdf).raw.json"
  echo "dumped $RAW/$(basename "$f" .pdf).raw.json"
done
