#!/usr/bin/env bash
# =============================================================================
# scripts/ssh-bridge.sh — pose le BRIDGE SSH (proxy device Incus) cote HOTE.
# -----------------------------------------------------------------------------
# A LANCER SUR L'HOTE, PAS dans l'instance : `incus config device` est
# une commande cote hote. Cree/maj un proxy device Incus qui forwarde :
#     le poste hote:<SSH_HOST_PORT>  ->  <ip-du-conteneur-durci>:2222  (dropbear)
#
# Pourquoi ce mecanisme (et pas docker -p / socat) :
#   - l'agent durci est sur le reseau Docker tp_internal (--internal) -> aucune
#     publication 'docker -p' possible ;
#   - un relais socat conteneurise plante (SIGILL) dans ce nesting Docker-in-Incus.
#   Le proxy device Incus, lui, ecoute sur l'hote et compose les DEUX sauts
#   (le poste hote -> instance, puis instance -> conteneur) de maniere fiable.
#
# Le durci a desormais une IP FIXE (172.31.7.2, cf. step 06) : ce bridge est donc
# a poser UNE SEULE FOIS. Il reste valide apres chaque recreation du conteneur
# (l'IP ne change plus) -> la recreation anti-persistance (scripts/recreate-daily.sh)
# n'a PAS besoin de le re-poser et tourne entierement dans l'instance.
# Variables : INSTANCE, NAME, SSH_HOST_PORT (defauts ci-dessous).
# =============================================================================
set -euo pipefail

INSTANCE="${INSTANCE:-tp-claude-host}"
NAME="${NAME:-claude-hardened}"
SSH_HOST_PORT="${SSH_HOST_PORT:-2200}"   # 2222 est pris par Forgejo sur le poste hote
DEV="sshin"

command -v incus >/dev/null 2>&1 || { echo "incus introuvable (lancer sur l'hote)"; exit 1; }

CIP="$(incus exec "$INSTANCE" -- docker inspect \
        -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME" 2>/dev/null)"
[[ -n "$CIP" ]] || { echo "IP du conteneur '$NAME' introuvable — lancer d'abord le step06."; exit 1; }

# (Re)pose le device proprement.
incus config device remove "$INSTANCE" "$DEV" >/dev/null 2>&1 || true
incus config device add "$INSTANCE" "$DEV" proxy \
  listen="tcp:0.0.0.0:${SSH_HOST_PORT}" connect="tcp:${CIP}:2222" bind=host

echo "Bridge SSH OK : le poste hote:${SSH_HOST_PORT} -> ${CIP}:2222 (dropbear de ${NAME})"
echo "Depuis n'importe quel poste : ssh -p ${SSH_HOST_PORT} agent@<ip-hote>  (cle id_rsa -> forced-command claude)"
