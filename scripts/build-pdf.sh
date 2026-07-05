#!/usr/bin/env bash
# =============================================================================
# build-pdf.sh — rend le rapport en PDF (pandoc -> LaTeX/lualatex).
#   Source  : docs/RAPPORT-V0.md  (corps)  +  docs/annexes.md  (annexes A/B/C)
#   Charte  : scripts/pdf/preamble.tex  (titre indigo, encadrés lavande, pieds
#             de page, tables booktabs, code coloré — inspiré du rapport de réf.)
#   Schémas : scripts/pdf/fig/fig{1,2,3}.tex  (TikZ natif — pas de navigateur)
#   Sortie  : out/RAPPORT.pdf
#
# Prérequis (Debian/Ubuntu) :
#   sudo apt-get install -y pandoc texlive-luatex texlive-latex-extra \
#                           texlive-fonts-recommended fonts-dejavu
#   (lualatex + luaotfload ; au 1er run : luaotfload-tool --update)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
PDFSRC="$SCRIPT_DIR/pdf"
BUILD="$ROOT/out/build"
OUT="${1:-$ROOT/out/RAPPORT.pdf}"

for t in pandoc lualatex python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "[build-pdf] ERREUR : '$t' manquant." >&2; exit 1; }
done
mkdir -p "$BUILD"

echo "[build-pdf] 1/3 préprocessing (titre+charte, mermaid->TikZ, annexes)"
python3 "$PDFSRC/preprocess.py" \
  "$ROOT/docs/RAPPORT-V0.md" "$BUILD/RAPPORT.md" "$PDFSRC/fig" "$ROOT/docs/annexes.md"

echo "[build-pdf] 2/3 pandoc markdown -> latex"
pandoc "$BUILD/RAPPORT.md" \
  -f markdown+raw_tex+tex_math_dollars+pipe_tables --standalone \
  --include-in-header="$PDFSRC/preamble.tex" --highlight-style=tango \
  -V documentclass=article -V papersize=a4 -V geometry:margin=2.1cm \
  -V fontsize=10pt -V lang=fr \
  -V colorlinks=true -V linkcolor=accent -V urlcolor=accent2 -V toccolor=accent \
  -o "$BUILD/RAPPORT.tex"

echo "[build-pdf] 3/3 lualatex x3 (TOC + pieds de page)"
( cd "$BUILD" && for i in 1 2 3; do
    lualatex -interaction=nonstopmode -halt-on-error RAPPORT.tex >"lualatex-$i.log" 2>&1 \
      || { echo "[build-pdf] lualatex passe $i a échoué :"; grep -nE '^!|Error' "lualatex-$i.log" | head; exit 1; }
  done )

cp "$BUILD/RAPPORT.pdf" "$OUT"
echo "[build-pdf] OK -> $OUT"
