#!/bin/bash
# Regenerates docs/brand from the vectors: the icon (scripts/make-icon.sh), the concept previews, the SVGs, the sheet
# of the built icon's sizes and the README hero. Usage: scripts/brand/render.sh
# Uses only swift and iconutil, like scripts/make-icon.sh. The files it writes are committed; run it after changing
# a number of docs/brand/brand.md, then look at the images.
set -euo pipefail
cd "$(dirname "$0")/../.."
scripts/make-icon.sh
mkdir -p docs/brand/concepts
swift scripts/brand/concepts.swift docs/brand/concepts
swift scripts/brand/docs.swift build/AppIcon.iconset docs/brand
cp build/AppIcon-1024.png docs/brand/icon-1024.png
echo "Rendered docs/brand"
