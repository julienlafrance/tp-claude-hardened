#!/usr/bin/env bash
# =============================================================================
# steps/02-build.sh — Construit l'image Docker de l'agent.
# -----------------------------------------------------------------------------
#   - claude-hardened:latest   (agent/Dockerfile)   -> l'agent Claude Code
#
# UNE SEULE image est necessaire au bac a sable. Le partitionnement, l'isolation
# reseau et la coupure d'egress sont obtenus par le RUNTIME (steps 03/06 :
# --read-only, binds :ro, --internal, cgroups), pas par des images d'infra.
# En particulier, AUCUN proxy MITM dedie n'est deploye : la ré-authentification
# amont (provenance) est portee par la gateway LiteLLM sur ixia et la coupure
# d'egress par le reseau `tp_internal --internal` (cf. docs/10-litellm-vs-mitmproxy.md).
# Le code proxy/addon.py reste dans le depot A TITRE DOCUMENTAIRE (illustration
# du swap jeton↔virtual key), mais n'est ni construit ni execute.
#
# REGLE DE SECURITE : aucun secret ne doit entrer dans les LAYERS d'image
#   (les secrets factices sont injectes au RUN, jamais au build). On ne passe
#   donc AUCUN --build-arg secret ici.
#
# Idempotent : Docker reutilise son cache ; on peut forcer via FORCE_BUILD=1.
# =============================================================================

set -euo pipefail

TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")}"
# shellcheck source=../lib/log.sh
source "$TP_ROOT/lib/log.sh"

need_cmd docker "Docker est IMPOSE par le TP."

# Option : reconstruire sans cache.
BUILD_OPTS=()
if [[ "${FORCE_BUILD:-0}" == "1" ]]; then
  warn "FORCE_BUILD=1 : reconstruction sans cache (--no-cache --pull)."
  BUILD_OPTS+=(--no-cache --pull)
fi

# -----------------------------------------------------------------------------
# build_image <tag> <contexte> <dockerfile>
#   Construit une image et verifie sa presence ensuite.
# -----------------------------------------------------------------------------
build_image() {
  local tag="$1" ctx="$2" dockerfile="$3"

  [[ -f "$dockerfile" ]] || die "Dockerfile introuvable: $dockerfile (groupe responsable non termine ?)"

  info "Build de l'image '$tag' (contexte: $ctx)..."
  # On dirige la sortie verbeuse vers le journal central tout en la montrant.
  if docker build "${BUILD_OPTS[@]}" -t "$tag" -f "$dockerfile" "$ctx" 2>&1 | tee -a "$TP_RUN_LOG"; then
    : # Le pipe a reussi globalement ; on revalide via inspect ci-dessous.
  fi

  # Verification robuste de la presence de l'image (independante du pipe/tee).
  if docker image inspect "$tag" >/dev/null 2>&1; then
    ok "Image construite et presente: $tag"
  else
    die "Echec du build de l'image: $tag"
  fi
}

# -----------------------------------------------------------------------------
# Construction de l'image de l'agent. Le contexte de build est agent/ ; le
# Dockerfile y est attendu (cf. PLAN.md sec.8).
# -----------------------------------------------------------------------------
build_image "claude-hardened:latest" "$TP_ROOT/agent"  "$TP_ROOT/agent/Dockerfile"
# NB : PAS de cible d'exfil "maison" ni de proxy d'infra. Une cible d'exfil
# represente un serveur TIERS controle par l'attaquant : par definition HORS de
# notre perimetre. La defense se PROUVE par le BLOCAGE (clé étrangère -> 401
# LiteLLM ; `api.anthropic.com` direct -> injoignable via `--internal`), pas par
# un serveur qui recoit. -> 1 image : l'agent.

# -----------------------------------------------------------------------------
# Recapitulatif de l'image presente (preuve pour le rapport).
# -----------------------------------------------------------------------------
info "Image du TP presente :"
docker images --format '  {{.Repository}}:{{.Tag}}  ({{.Size}})' \
  claude-hardened 2>/dev/null | tee -a "$TP_RUN_LOG" || true

ok "Step 02 : l'image de l'agent est construite."
