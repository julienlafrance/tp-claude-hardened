#!/usr/bin/env bash
# =============================================================================
# steps/09-teardown.sh — Nettoyage complet de l'environnement du TP.
# -----------------------------------------------------------------------------
# Supprime, dans l'ordre :
#   1. les conteneurs claude-nu, claude-hardened (+ egress-proxy, exfil-server
#      HERITES : plus deployes dans le design actuel, nettoyes par securite si un
#      ancien run les a laisses) ;
#   2. les reseaux Docker tp_internal (+ tp_egress : egress libre du profil NU
#      et/ou heritage) ;
#   3. (optionnel) l'instance Incus jetable tp-claude-host (anneau 1) ;
#   4. les artefacts ephemeres locaux (secret nu ; .session-token herite).
#
# L'instance Incus est detruite par defaut (==> "aucune trace sur l'hote reel").
# Pour la CONSERVER (iterer plus vite), positionner KEEP_INCUS=1.
#
# Les COPIES de config par profil (tp/.runtime/) sont JETABLES et regenerees a
# chaque run (steps 03/04/06) : on les supprime par defaut. Pour les CONSERVER
# (inspecter ce que l'attaque NU a reecrit), positionner KEEP_RUNTIME=1.
#
# On NE supprime PAS les preuves persistantes (evidence/run.log, results.md,
# *.tsv) : elles servent au rapport PDF.
#
# Idempotent : no-op silencieux sur ce qui est deja absent.
# =============================================================================

set -euo pipefail

TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")}"
# shellcheck source=../lib/log.sh
source "$TP_ROOT/lib/log.sh"

info "Teardown : nettoyage de l'environnement du TP."

# -----------------------------------------------------------------------------
# 1) Conteneurs.
# -----------------------------------------------------------------------------
CONTAINERS=(claude-nu claude-hardened egress-proxy exfil-server)
if command -v docker >/dev/null 2>&1; then
  for c in "${CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
      docker rm -f "$c" >/dev/null 2>&1 && ok "Conteneur supprime: $c" || warn "Suppression conteneur $c partielle."
    else
      info "Conteneur deja absent: $c"
    fi
  done

  # ---------------------------------------------------------------------------
  # 2) Reseaux.
  # ---------------------------------------------------------------------------
  for n in tp_internal tp_egress; do
    if docker network inspect "$n" >/dev/null 2>&1; then
      docker network rm "$n" >/dev/null 2>&1 && ok "Reseau supprime: $n" || warn "Reseau $n encore utilise ?"
    else
      info "Reseau deja absent: $n"
    fi
  done
else
  warn "docker absent : etape conteneurs/reseaux ignoree."
fi

# -----------------------------------------------------------------------------
# 3) Instance Incus jetable (anneau 1).
# -----------------------------------------------------------------------------
if [[ "${KEEP_INCUS:-0}" == "1" ]]; then
  info "KEEP_INCUS=1 : l'instance Incus tp-claude-host est CONSERVEE."
elif [[ "${SKIP_INCUS:-0}" == "1" ]]; then
  info "SKIP_INCUS=1 : aucun hote Incus a detruire."
elif command -v incus >/dev/null 2>&1; then
  info "Destruction de l'instance Incus jetable (anneau 1)..."
  bash "$TP_ROOT/scripts/incus-host.sh" destroy || warn "Destruction Incus partielle (deja absente ?)."
else
  info "incus absent : aucun hote a detruire."
fi

# -----------------------------------------------------------------------------
# 4) Artefacts ephemeres locaux (secrets/jetons de demo) — pas les preuves.
# -----------------------------------------------------------------------------
rm -rf "$TP_ROOT/evidence/.secret-nu" 2>/dev/null || true
rm -f  "$TP_ROOT/evidence/.session-token" 2>/dev/null || true
# Fichiers de health-check laisses par les agents dans le workspace.
rm -f  "$TP_ROOT/workspace/_healthcheck_nu.txt" "$TP_ROOT/workspace/_healthcheck_durci.txt" 2>/dev/null || true

# Copies de config jetables par profil (tp/.runtime/). La copie durci-config a
# pu etre figee (dirs 0555 / files 0444) et/ou appartenir a root:root par le
# step 03 : __rm_runtime_dir (lib/log.sh) gere le chmod u+w puis le rm, avec
# fallback sudo si necessaire.
# Pour CONSERVER les copies (inspecter ce que l'attaque NU a reecrit) : KEEP_RUNTIME=1.
if [[ "${KEEP_RUNTIME:-0}" == "1" ]]; then
  info "KEEP_RUNTIME=1 : les copies de config tp/.runtime/ sont CONSERVEES."
elif [[ -d "$RUNTIME_DIR" ]]; then
  __rm_runtime_dir "$RUNTIME_DIR"
  if [[ -d "$RUNTIME_DIR" ]]; then
    warn "Suppression $RUNTIME_DIR partielle (privileges ? fichiers root:root sans sudo)."
  else
    ok "Copies de config jetables supprimees: $RUNTIME_DIR"
  fi
else
  info "Aucune copie de config jetable a supprimer ($RUNTIME_DIR absent)."
fi

info "Artefacts ephemeres nettoyes (preuves persistantes conservees)."

ok "Step 09 : teardown termine."
