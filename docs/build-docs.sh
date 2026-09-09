#!/bin/sh
# build-docs.sh — render .dot schematics and markdown into PDF
# Usage:  sh docs/build-docs.sh          (from repo root)
#         sh build-docs.sh               (from docs/)
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
DOT="$DIR/dot"

echo "=== dot -> pdf ==="
mkdir -p "$DOT"

for prefix in sch hw; do
    pdfs=""
    for f in "$DOT"/${prefix}_*.dot; do
        [ -f "$f" ] || continue
        out="${f%.dot}.pdf"
        dot -Tpdf -o "$out" "$f"
        echo "  $(basename "$f") -> $(basename "$out")"
        pdfs="$pdfs $out"
    done
    if [ -n "$pdfs" ]; then
        label=$(echo "$prefix" | tr '[:lower:]' '[:upper:]')
        tmp="$DIR/${label}_dot_tmp.pdf"
        pdfunite $pdfs "$tmp"
        echo "  dot diagrams -> ${label}_dot_tmp.pdf"
    fi
done

echo ""
echo "=== md -> pdf ==="
REPO="$(cd "$DIR/.." && pwd)"
for md in "$DIR"/SCH.md "$REPO/HW.md" "$DIR"/BUILD.md; do
    [ -f "$md" ] || continue
    base="$(basename "$md" .md)"
    python3 "$DIR/md2pdf.py" --pdf -o "$DIR/$base.pdf" "$md"
done

echo ""
echo "=== merge dot + md ==="
python3 - "$DIR" <<'PYEOF'
import sys, os
import pikepdf

d = sys.argv[1]
for prefix in ("SCH", "HW"):
    tmp = os.path.join(d, f"{prefix}_dot_tmp.pdf")
    md_pdf = os.path.join(d, f"{prefix}.pdf")
    out = os.path.join(d, f"{prefix}.pdf")
    if os.path.exists(tmp) and os.path.exists(md_pdf):
        merged = pikepdf.Pdf.new()
        # dot diagrams first
        src1 = pikepdf.open(tmp)
        merged.pages.extend(src1.pages)
        # then text content
        src2 = pikepdf.open(md_pdf)
        merged.pages.extend(src2.pages)
        merged.save(out)
        os.remove(tmp)
        sz = os.path.getsize(out)
        print(f"  {prefix}.pdf ({sz//1024}K) -- dot diagrams + text")
    elif os.path.exists(tmp):
        os.rename(tmp, out)
PYEOF

echo ""
echo "done."
