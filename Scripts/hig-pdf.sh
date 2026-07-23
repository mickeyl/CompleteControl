#!/bin/sh
# Render Docs/HIG.md as a print-ready A4 PDF (identity fonts, per-chapter
# page breaks, embedded gallery). Requires pandoc and Google Chrome.
#
# Usage: Scripts/hig-pdf.sh [output.pdf]   (default: /tmp/CompleteControl-HIG.pdf)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
OUT=${1:-/tmp/CompleteControl-HIG.pdf}
FONTS="$ROOT/Sources/KontrolSurfaceKit2/Resources/Fonts"
CHROME=${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/print.css" <<EOF
@font-face { font-family: 'IBM Plex Sans Condensed'; src: url('file://$FONTS/IBMPlexSansCondensed-Regular.otf'); font-weight: 400; }
@font-face { font-family: 'IBM Plex Sans Condensed'; src: url('file://$FONTS/IBMPlexSansCondensed-Medium.otf'); font-weight: 500 700; }
@font-face { font-family: 'JetBrains Mono'; src: url('file://$FONTS/JetBrainsMono-Regular.ttf'); font-weight: 400; }
@font-face { font-family: 'JetBrains Mono'; src: url('file://$FONTS/JetBrainsMono-Bold.ttf'); font-weight: 700; }
@page { size: A4; margin: 18mm 16mm; }
html { font-size: 10.5pt; }
body { font-family: 'IBM Plex Sans Condensed', sans-serif; line-height: 1.45; color: #111; max-width: none; }
h1 { font-size: 21pt; font-weight: 500; letter-spacing: -0.01em; margin: 0 0 6pt; }
h2 { font-size: 14pt; font-weight: 500; margin: 18pt 0 6pt; page-break-after: avoid; break-after: avoid; }
h2:not(:first-of-type) { page-break-before: always; }
h3 { font-size: 11.5pt; font-weight: 500; margin: 12pt 0 4pt; page-break-after: avoid; }
p, li { orphans: 3; widows: 3; }
code, pre { font-family: 'JetBrains Mono', monospace; font-size: 8pt; }
pre { background: #f4f4f4; border: 0.5pt solid #ccc; padding: 6pt 8pt; page-break-inside: avoid; white-space: pre-wrap; }
code { background: #f4f4f4; padding: 0 2pt; }
table { border-collapse: collapse; width: 100%; font-size: 8.5pt; page-break-inside: avoid; margin: 6pt 0; }
th, td { border: 0.5pt solid #999; padding: 3pt 5pt; text-align: left; vertical-align: top; }
th { background: #eee; font-weight: 500; }
img { max-width: 100%; border: 0.5pt solid #444; display: block; margin: 4pt 0; page-break-inside: avoid; }
hr { border: none; border-top: 0.5pt solid #999; margin: 10pt 0; }
EOF

cd "$ROOT/Docs"
pandoc HIG.md --standalone --embed-resources \
    --metadata pagetitle="CompleteControl — Hardware UI HIG" \
    --css="$WORK/print.css" -f gfm -t html5 -o "$WORK/hig.html"

"$CHROME" --headless --disable-gpu --no-pdf-header-footer \
    --print-to-pdf="$OUT" "file://$WORK/hig.html" 2>/dev/null

echo "$OUT"
