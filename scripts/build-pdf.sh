#!/usr/bin/env bash
# =============================================================================
# build-pdf.sh — Convertit le rapport assemble (docs/RAPPORT.md) en PDF.
#
# Livrable du TP = un PDF detaille. Ce script transforme docs/RAPPORT.md en
# out/RAPPORT.pdf au moyen de pandoc. Il est commente abondamment (exigence du
# rapport) et prevoit un FALLBACK explicite si pandoc (ou un moteur LaTeX)
# n'est pas disponible.
#
# Usage :
#   ./scripts/build-pdf.sh            # genere out/RAPPORT.pdf
#   ./scripts/build-pdf.sh chemin.pdf # genere un PDF a l'emplacement donne
#
# Prerequis (ideal) :
#   - pandoc                (conversion Markdown -> PDF)
#   - un moteur PDF : xelatex / pdflatex / weasyprint / wkhtmltopdf
# =============================================================================

# Fail-fast : toute erreur stoppe le script, variable non definie = erreur,
# et une erreur au milieu d'un pipe propage le code d'echec.
set -euo pipefail

# --- Resolution robuste des chemins (independante du repertoire d'appel) -----
# On resout le repertoire reel du script (realpath) AVANT de construire les
# chemins, conformement a la regle « resoudre les symlinks avant de valider ».
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"          # .../tp
DOCS_DIR="$PROJECT_DIR/docs"
OUT_DIR="$PROJECT_DIR/out"
RAPPORT_MD="$DOCS_DIR/RAPPORT.md"

# Destination du PDF : 1er argument, sinon out/RAPPORT.pdf par defaut.
PDF_OUT="${1:-$OUT_DIR/RAPPORT.pdf}"

# --- Verifications de base ----------------------------------------------------
if [[ ! -f "$RAPPORT_MD" ]]; then
  echo "[build-pdf] ERREUR : rapport introuvable : $RAPPORT_MD" >&2
  echo "[build-pdf] Verifier que docs/RAPPORT.md existe (groupe docs)." >&2
  exit 1
fi

# Le dossier de sortie out/ est cree au besoin (artefacts du TP).
mkdir -p "$(dirname "$PDF_OUT")"

# =============================================================================
# Tentative principale : pandoc
# =============================================================================
if command -v pandoc >/dev/null 2>&1; then
  echo "[build-pdf] pandoc detecte : conversion de RAPPORT.md -> $PDF_OUT"

  # On choisit un moteur PDF disponible. xelatex gere mieux l'UTF-8 (accents
  # francais, schemas ASCII), on le prefere, puis pdflatex, puis des moteurs
  # HTML->PDF (weasyprint / wkhtmltopdf) ne necessitant pas LaTeX.
  PDF_ENGINE=""
  for engine in xelatex lualatex pdflatex weasyprint wkhtmltopdf; do
    if command -v "$engine" >/dev/null 2>&1; then
      PDF_ENGINE="$engine"
      break
    fi
  done

  if [[ -n "$PDF_ENGINE" ]]; then
    echo "[build-pdf] Moteur PDF utilise : $PDF_ENGINE"
    # Options pandoc :
    #   --from gfm                : Markdown GitHub (tables, ```fences```).
    #   --toc --toc-depth=2       : table des matieres automatique.
    #   --number-sections         : numerote les sections.
    #   -V geometry:margin=2cm    : marges raisonnables pour le rendu.
    #   -V mainfont (xelatex)     : police gerant l'UTF-8 si dispo.
    PANDOC_ARGS=(
      "$RAPPORT_MD"
      --from gfm
      --pdf-engine="$PDF_ENGINE"
      --toc --toc-depth=2
      --number-sections
      -V geometry:margin=2cm
      -V title="Durcissement d'un agent Claude Code en Docker"
      -V author="TP cybersecurite"
      -o "$PDF_OUT"
    )
    # mainfont n'a de sens qu'avec xelatex/lualatex.
    if [[ "$PDF_ENGINE" == "xelatex" || "$PDF_ENGINE" == "lualatex" ]]; then
      PANDOC_ARGS+=(-V mainfont="DejaVu Sans")
    fi

    if pandoc "${PANDOC_ARGS[@]}"; then
      echo "[build-pdf] OK : PDF genere -> $PDF_OUT"
      exit 0
    else
      echo "[build-pdf] AVERTISSEMENT : pandoc a echoue avec $PDF_ENGINE." >&2
      echo "[build-pdf] Passage au fallback HTML ci-dessous." >&2
    fi
  else
    echo "[build-pdf] AVERTISSEMENT : pandoc present mais AUCUN moteur PDF " >&2
    echo "            (xelatex/pdflatex/weasyprint/wkhtmltopdf) trouve." >&2
    echo "[build-pdf] Generation d'un HTML autonome a la place (fallback)." >&2
  fi

  # --- Fallback intermediaire : pandoc -> HTML autonome ----------------------
  # Si pandoc existe mais qu'aucun moteur PDF n'est dispo, on produit au moins
  # un HTML autonome (imprimable en PDF depuis un navigateur : Ctrl+P).
  HTML_OUT="${PDF_OUT%.pdf}.html"
  if pandoc "$RAPPORT_MD" --from gfm --standalone --toc --toc-depth=2 \
            --metadata title="Durcissement d'un agent Claude Code en Docker" \
            -o "$HTML_OUT"; then
    echo "[build-pdf] HTML autonome genere -> $HTML_OUT"
    echo "[build-pdf] -> Ouvrir dans un navigateur puis Imprimer en PDF (Ctrl+P)."
    exit 0
  fi
fi

# =============================================================================
# Fallback final : pandoc absent
# =============================================================================
echo "[build-pdf] pandoc introuvable." >&2
echo "" >&2
echo "[build-pdf] Pour generer le PDF, installer pandoc + un moteur PDF :" >&2
echo "    Debian/Ubuntu : sudo apt-get install -y pandoc texlive-xetex" >&2
echo "    (alternative legere : sudo apt-get install -y pandoc weasyprint)" >&2
echo "" >&2
echo "[build-pdf] En attendant, le rapport complet reste lisible en Markdown :" >&2
echo "    $RAPPORT_MD" >&2
echo "[build-pdf] (on peut aussi le coller dans n'importe quel convertisseur Markdown->PDF.)" >&2

# Code de sortie != 0 pour signaler clairement qu'aucun PDF n'a ete produit
# (utile dans une chaine fail-fast / CI).
exit 2
