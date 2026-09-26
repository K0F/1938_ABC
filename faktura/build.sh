#!/bin/sh
# build.sh — render every invoice .md next to it as PDF (A4, pango/cairo via docs/md2pdf.py)
# Usage:  sh faktura/build.sh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$DIR/.." && pwd)"

for md in "$DIR"/*.md; do
    [ -f "$md" ] || continue
    python3 "$REPO/docs/md2pdf.py" --pdf -o "${md%.md}.pdf" "$md"
done
