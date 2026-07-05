#!/usr/bin/env bash
# =============================================================================
# scripts/recreate-daily.sh — Recreation PERIODIQUE du conteneur durci.
# -----------------------------------------------------------------------------
# A LANCER DANS L'INSTANCE INCUS (tp-claude-host), PAS depuis corrin. N'utilise
# que `docker` + `bash` (le demon Docker vit DANS l'instance). AUCUNE commande
# cote hote : la planification (cron/systemd) s'installe elle aussi DANS l'instance.
#
# JUSTIFICATION — ANTI-PERSISTANCE (threat model, categorie « persistance »).
#   Meme si un attaquant obtenait un foothold DANS le conteneur durci (malgre le
#   durcissement), la recreation lui fait TOUT perdre :
#     - la racine (--read-only + overlay) est ephemere -> aucun binaire depose ne
#       survit ;
#     - les tmpfs (/tmp, /run, /home/agent/.claude = etat runtime de l'agent :
#       sessions, cache) sont RECREES vides -> aucune persistance d'etat ;
#     - la config est re-montee :ro depuis une copie FRAICHE re-figee (step 03) ;
#     - le process (et tout implant en memoire) est tue.
#   AUCUN minting de cle : la virtual key scopee reste STATIQUE (decision de
#   conception : l'enonce demande un scoping runtime + pas de secret dans le
#   conteneur, PAS une rotation ; cf. docs/10). Ce script ne touche a aucun secret.
#
# BRIDGE SSH INCHANGE : le durci est recree avec une IP FIXE (172.31.7.2, cf.
#   step 06). Le proxy device Incus qui compose la chaine SSH corrin -> incus ->
#   docker:2222 pointe sur cette IP stable -> il reste valide SANS re-pose. La
#   recreation n'a donc jamais besoin de l'hote.
#
# PREUVE INTEGREE : avant destruction on plante un marqueur dans l'etat runtime
#   (tmpfs /home/agent/.claude) ; apres recreation on verifie qu'il a DISPARU.
#   -> demonstration directe et journalisee de l'effacement de persistance.
#
# PLANIFICATION (24 h), DANS L'INSTANCE :
#   cron :   0 4 * * *  /root/tp/scripts/recreate-daily.sh >> /root/tp/evidence/recreate.log 2>&1
#   systemd: cp /root/tp/scripts/systemd/tp-recreate.{service,timer} /etc/systemd/system/ &&
#            systemctl enable --now tp-recreate.timer   (cf. scripts/systemd/).
#
# Idempotent. Variables : NAME (conteneur durci), TP_ROOT (racine du TP).
# =============================================================================
set -euo pipefail

TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")}"
NAME="${NAME:-claude-hardened}"
PROBE="/home/agent/.claude/PERSIST_PROBE"        # marqueur en zone runtime (tmpfs)
LOG="$TP_ROOT/evidence/recreate.log"
mkdir -p "$TP_ROOT/evidence"

command -v docker >/dev/null 2>&1 || { echo "docker introuvable — ce script tourne DANS l'instance Incus."; exit 1; }

ts()  { date '+%Y-%m-%dT%H:%M:%S%z'; }
log() { local m="$(ts) [recreate] $*"; printf '%s\n' "$m"; printf '%s\n' "$m" >>"$LOG" 2>/dev/null || true; }

log "=== Recreation anti-persistance de '$NAME' (dans l'instance Incus) ==="

# --- 0) PREUVE (avant) : planter un marqueur dans l'etat runtime (tmpfs) -------
MARK="foothold-$(ts)"
if docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  if docker exec "$NAME" sh -c "printf '%s\n' '$MARK' > '$PROBE'" >/dev/null 2>&1; then
    log "marqueur de persistance plante dans $PROBE (etat runtime tmpfs) = $MARK"
  else
    log "impossible de planter le marqueur (zone runtime non ecrivable ?) — on poursuit."
  fi
else
  log "durci non demarre : recreation A FROID (pas de marqueur a planter)."
fi

# --- 1) DESTRUCTION : le foothold eventuel + tout l'etat ephemere disparaissent -
docker rm -f "$NAME" >/dev/null 2>&1 || true
log "conteneur $NAME detruit (racine ephemere + tmpfs + process elimines)."

# --- 2) CONFIG FRAICHE (double-verrou, step 03) puis RELANCE (step 06) ---------
#     Le step 06 recree le durci a l'IP FIXE 172.31.7.2 -> bridge SSH inchange.
if bash "$TP_ROOT/steps/03-config-perms.sh" durci >/dev/null 2>&1; then
  log "config durci regeneree et re-figee (copie fraiche root:root 0444/0555 ; NU intacte)."
else
  log "AVERTISSEMENT : step 03 (config-perms) a signale une erreur — on tente la relance."
fi
if bash "$TP_ROOT/steps/06-run-durci.sh" >/dev/null 2>&1; then
  log "durci recree (non-root, --read-only, config :ro fraiche, tmpfs neufs, IP fixe 172.31.7.2)."
else
  log "ECHEC : step 06 (run-durci) n'a pas relance le conteneur."; exit 1
fi

# --- 3) PREUVE (apres) : le marqueur doit avoir DISPARU -----------------------
if docker exec "$NAME" sh -c "test -e '$PROBE'" >/dev/null 2>&1; then
  log "!! ECHEC anti-persistance : $PROBE TOUJOURS PRESENT apres recreation."
  exit 2
else
  log "OK anti-persistance : $PROBE ABSENT apres recreation (etat runtime efface)."
fi

log "=== Recreation terminee avec succes (aucune action cote hote corrin). ==="
