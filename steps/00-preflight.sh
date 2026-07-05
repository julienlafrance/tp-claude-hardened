#!/usr/bin/env bash
# =============================================================================
# steps/00-preflight.sh — Verification des prerequis AVANT toute action.
# -----------------------------------------------------------------------------
# Tache unitaire : echoue (code != 0) si l'environnement n'est pas pret.
#   - docker present + demon joignable ;
#   - incus present (OPTIONNEL : seulement averti, sauf si l'anneau 1 est requis) ;
#   - LITELLM_VIRTUAL_KEY + LITELLM_ENDPOINT presents et endpoint LiteLLM (le backend)
#     joignable (l'agent Claude Code utilise ce backend externe pour tourner) ;
#   - fichiers requis presents (Dockerfiles, profil seccomp, config figee) ;
#   - resolution realpath des chemins sensibles (symlinks resolus AVANT usage).
#
# Idempotent : ne modifie rien, ne fait que verifier.
# =============================================================================

set -euo pipefail

# Racine du projet : fournie par run.sh, sinon recalculee depuis ce fichier.
TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")}"
# shellcheck source=../lib/log.sh
source "$TP_ROOT/lib/log.sh"

info "Preflight: verification de l'environnement (racine: $TP_ROOT)"

# Compteur d'erreurs : on accumule pour tout reporter d'un coup.
ERRORS=0
soft_fail() { err "$*"; ERRORS=$((ERRORS+1)); }

# -----------------------------------------------------------------------------
# 1) Docker — IMPOSE par le TP. Binaire + demon joignable.
# -----------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  ok "docker present: $(docker --version 2>/dev/null || echo '?')"
  if docker info >/dev/null 2>&1; then
    ok "demon Docker joignable."
  else
    soft_fail "Le demon Docker n'est PAS joignable (docker info a echoue). Demarrer le service, ou executer ce TP DANS l'hote Incus."
  fi
else
  soft_fail "Binaire 'docker' introuvable (Docker est IMPOSE par le TP)."
fi

# -----------------------------------------------------------------------------
# 2) Incus — OPTIONNEL pour l'anneau 1. On AVERTIT seulement.
#    Si SKIP_INCUS=1, on ne se soucie pas du tout d'Incus.
# -----------------------------------------------------------------------------
if [[ "${SKIP_INCUS:-0}" == "1" ]]; then
  info "SKIP_INCUS=1 -> l'hote Incus (anneau 1) sera ignore (step 01 no-op)."
else
  if command -v incus >/dev/null 2>&1; then
    ok "incus present: $(incus --version 2>/dev/null || echo '?')"
  else
    warn "Binaire 'incus' absent : l'anneau 1 (hote jetable) sera ignorable. Positionner SKIP_INCUS=1 pour rester sur l'hote courant."
  fi
fi

# -----------------------------------------------------------------------------
# 3) Backend LLM EXTERNE (LiteLLM externe backend-host:3101 -> Ollama).
#    L'agent Claude Code s'authentifie avec la cle LiteLLM SCOPEE
#    (LITELLM_VIRTUAL_KEY -> ANTHROPIC_AUTH_TOKEN), PAS avec une cle Anthropic.
#    On verifie : la cle scopee est definie, l'endpoint est defini, et l'endpoint
#    repond. On AVERTIT plutot que d'echouer dur : la prepa de l'infra (build,
#    reseaux) peut se faire sans backend ; le check fonctionnel des steps 04/06
#    le re-signalera.
# -----------------------------------------------------------------------------
if [[ -n "${LITELLM_VIRTUAL_KEY:-}" ]]; then
  ok "LITELLM_VIRTUAL_KEY presente (cle LiteLLM scopee, longueur: ${#LITELLM_VIRTUAL_KEY})."
else
  warn "LITELLM_VIRTUAL_KEY absente : sans elle, l'agent ne peut pas s'authentifier aupres du backend LiteLLM (steps 04/06 echoueront). La renseigner dans .env avant 'attacks'."
fi

LITELLM_ENDPOINT="${LITELLM_ENDPOINT:-http://backend-host:3101}"
if [[ -n "${LITELLM_ENDPOINT}" ]]; then
  ok "LITELLM_ENDPOINT defini: $LITELLM_ENDPOINT"
  # Joignabilite du backend externe (le backend). Endpoint de sante LiteLLM.
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS -m 5 "${LITELLM_ENDPOINT%/}/health/liveliness" >/dev/null 2>&1; then
      ok "Backend LiteLLM joignable (${LITELLM_ENDPOINT%/}/health/liveliness)."
    else
      warn "Backend LiteLLM INJOIGNABLE a ${LITELLM_ENDPOINT%/}/health/liveliness (le backend backend-host:3101). Verifier que le backend est demarre/route ; le check fonctionnel des steps 04/06 echouera tant que le backend ne repond pas."
    fi
  else
    warn "curl absent : impossible de tester la joignabilite du backend LiteLLM (${LITELLM_ENDPOINT})."
  fi
else
  warn "LITELLM_ENDPOINT absent : definir l'endpoint du backend LiteLLM (defaut http://backend-host:3101)."
fi

# -----------------------------------------------------------------------------
# 4) Fichiers requis. On distingue :
#    - REQUIS DURS (provenant des autres groupes) : on echoue s'ils manquent.
#    - On resout chaque chemin via realpath (symlinks resolus AVANT validation).
#
#    NB : ces fichiers sont produits par les groupes agent/ config/.
#    Le runner les CONSOMME ; il ne les cree pas.
# -----------------------------------------------------------------------------
require_file() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    # realpath : resout les symlinks AVANT toute validation (exigence TP).
    local rp; rp="$(realpath "$path" 2>/dev/null || echo "$path")"
    ok "$label present: $rp"
  else
    soft_fail "$label MANQUANT: $path"
  fi
}
require_dir() {
  local label="$1" path="$2"
  if [[ -d "$path" ]]; then
    local rp; rp="$(realpath "$path" 2>/dev/null || echo "$path")"
    ok "$label present: $rp/"
  else
    soft_fail "$label (repertoire) MANQUANT: $path"
  fi
}

info "Verification des fichiers attendus (produits par les autres groupes)..."

# Image agent (SEULE image du TP) + profil seccomp. Pas de proxy ni d'exfil :
# provenance = ré-auth LiteLLM, egress = reseau tp_internal --internal (cf. docs/10).
require_file "Dockerfile agent"  "$TP_ROOT/agent/Dockerfile"
require_file "Profil seccomp"    "$TP_ROOT/agent/seccomp-claude.json"

# Config figee de l'agent (groupe config). Noms autoritaires (cf. PLAN.md sec.8).
require_file "Config project-settings.json" "$TP_ROOT/config/project-settings.json"
require_file "Config project-CLAUDE.md"     "$TP_ROOT/config/project-CLAUDE.md"
require_file "Config project-mcp.json"      "$TP_ROOT/config/project-mcp.json"
require_dir  "Config project-skills"        "$TP_ROOT/config/project-skills"
require_file "Config user-settings.json"    "$TP_ROOT/config/user-settings.json"
require_dir  "Config user-skills"           "$TP_ROOT/config/user-skills"
# Secret factice (consomme par le profil NU via compose ; les steps 04/06 le
# regenerent au RUN, mais on s'assure que la SOURCE de reference existe pour
# eviter que Docker ne cree un repertoire fantome a la place du fichier).
require_file "Secret factice config"        "$TP_ROOT/config/fake_token.txt"

# Scripts du runner lui-meme (coherence interne).
require_dir  "Repertoire steps" "$TP_ROOT/steps"
require_dir  "Repertoire lib"   "$TP_ROOT/lib"

# Repertoire de preuves : on s'assure qu'il existe (cree par log.sh, mais on
# le rend explicite ici).
mkdir -p "$TP_ROOT/evidence"
ok "Repertoire de preuves pret: $TP_ROOT/evidence/"

# -----------------------------------------------------------------------------
# Verdict.
# -----------------------------------------------------------------------------
if [[ "$ERRORS" -gt 0 ]]; then
  die "Preflight: $ERRORS probleme(s) bloquant(s). Corriger avant de continuer."
fi
ok "Preflight: tous les prerequis sont satisfaits."
