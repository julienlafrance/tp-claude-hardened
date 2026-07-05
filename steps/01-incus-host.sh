#!/usr/bin/env bash
# =============================================================================
# steps/01-incus-host.sh — Provisionne l'HOTE JETABLE Incus (anneau 1).
# -----------------------------------------------------------------------------
# Delegue le gros du travail a scripts/incus-host.sh (create).
#
# OPTIONNEL : si SKIP_INCUS=1 (ou flag --skip-incus), ce step est un NO-OP
#   reussi. Cas d'usage :
#     - on execute deja le TP DANS l'hote Incus (Docker imbrique local) ;
#     - Incus n'est pas installe / pas souhaite sur le poste.
#
# Idempotent : 'create' relance proprement si l'instance existe.
# =============================================================================

set -euo pipefail

TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")}"
# shellcheck source=../lib/log.sh
source "$TP_ROOT/lib/log.sh"

# Support du flag --skip-incus en plus de la variable SKIP_INCUS.
for arg in "$@"; do
  case "$arg" in
    --skip-incus) SKIP_INCUS=1 ;;
  esac
done

if [[ "${SKIP_INCUS:-0}" == "1" ]]; then
  warn "SKIP_INCUS=1 : l'anneau 1 (hote Incus jetable) est IGNORE."
  info "Le durcissement Docker (anneau 2 — la partie NOTEE) s'execute alors directement sur l'hote courant."
  ok "Step 01 no-op (Incus saute) : OK."
  exit 0
fi

if ! command -v incus >/dev/null 2>&1; then
  warn "incus introuvable : impossible de provisionner l'anneau 1."
  warn "Pour continuer sur l'hote courant, relancer avec SKIP_INCUS=1."
  die "Incus requis pour le step 01 (ou positionner SKIP_INCUS=1)."
fi

info "Provisionnement de l'hote jetable Incus (anneau 1)..."
# On delegue a la bibliotheque de provisionnement (create est idempotent).
bash "$TP_ROOT/scripts/incus-host.sh" create

ok "Step 01 : hote Incus jetable pret (Docker imbrique operationnel)."
