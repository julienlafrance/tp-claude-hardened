#!/usr/bin/env bash
# =============================================================================
# scripts/incus-host.sh — Provisionnement de l'HOTE JETABLE (anneau 1).
# -----------------------------------------------------------------------------
# Cree un CONTENEUR Incus LXC jetable nomme "tp-claude-host" a partir de
# l'image "images:debian/12", configure pour Docker IMBRIQUE
# (security.nesting=true), y installe Docker, et prend un snapshot 'clean'.
#
# Architecture a 2 anneaux (cf. PLAN.md sec.1) :
#   - Anneau 1 = CE conteneur LXC jetable (noyau PARTAGE avec l'hote -> plus
#     LEGER mais MOINS SUR). C'est ce qui est IMPLEMENTE.
#   - Ideal DOCUMENTE = une VM Incus (KVM) -> noyau DEDIE -> vraie isolation
#     noyau (plus lourd, plus sur). Voir la variante en commentaire ci-dessous.
#
# >>> VARIANTE VM (recommandee en prod, NON utilisee ici car plus lourde) :
#       incus launch images:debian/12 tp-claude-host --vm \
#         -c limits.cpu=4 -c limits.memory=8GiB
#     Une VM embarque son PROPRE noyau via KVM : meme une evasion du conteneur
#     Docker (anneau 2) ne donne PAS le noyau de l'hote reel. C'est l'isolation
#     a recommander dans le rapport PDF. On reste en LXC ici pour iterer vite,
#     et parce que la PARTIE NOTEE est le durcissement Docker (anneau 2).
#
# Sous-commandes : create | restore | destroy | status | exec
#   create   : cree l'instance (idempotent), installe Docker, snapshot 'clean'.
#   restore  : restaure le snapshot 'clean' (remet l'hote a l'etat initial).
#   destroy  : detruit l'instance (incus delete --force) -> aucune trace.
#   status   : affiche l'etat de l'instance.
#   exec ... : execute une commande dans l'instance (helper de debug).
#
# Idempotent : 'create' relance proprement si l'instance existe deja.
# =============================================================================

set -euo pipefail

# Racine + log partage.
TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")}"
# shellcheck source=../lib/log.sh
source "$TP_ROOT/lib/log.sh"

# --- Constantes autoritaires (cf. conventions JSON / PLAN.md). ---------------
INCUS_INSTANCE="${INCUS_INSTANCE:-tp-claude-host}"
INCUS_IMAGE="${INCUS_IMAGE:-images:debian/12}"
INCUS_SNAPSHOT="${INCUS_SNAPSHOT:-clean}"

# -----------------------------------------------------------------------------
# _need_incus — verifie qu'incus est dispo (sinon die explicite).
# -----------------------------------------------------------------------------
_need_incus() {
  command -v incus >/dev/null 2>&1 || die "incus introuvable : impossible de provisionner l'anneau 1. (Astuce: SKIP_INCUS=1 pour rester sur l'hote courant.)"
}

# -----------------------------------------------------------------------------
# _instance_exists — vrai si l'instance existe deja.
# -----------------------------------------------------------------------------
_instance_exists() {
  incus info "$INCUS_INSTANCE" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# _instance_running — vrai si l'instance est demarree.
# -----------------------------------------------------------------------------
_instance_running() {
  incus list "$INCUS_INSTANCE" --format csv -c s 2>/dev/null | grep -qi RUNNING
}

# -----------------------------------------------------------------------------
# _wait_network — attend que l'instance ait un acces reseau (DNS/HTTP) avant
#   d'installer des paquets. Boucle bornee (pas de sleep "nu" en avant-plan
#   interdit : ici on est dans un step lance par run.sh, sleep est legitime).
# -----------------------------------------------------------------------------
_wait_network() {
  local i
  info "Attente de la connectivite reseau dans $INCUS_INSTANCE..."
  for i in $(seq 1 30); do
    if incus exec "$INCUS_INSTANCE" -- getent hosts deb.debian.org >/dev/null 2>&1; then
      ok "Connectivite reseau OK dans l'instance."
      return 0
    fi
    sleep 2
  done
  warn "Connectivite reseau non confirmee apres 60s (on tente quand meme l'install)."
  return 0
}

# -----------------------------------------------------------------------------
# create — cree l'instance LXC jetable, la configure pour Docker imbrique,
#          installe Docker, et prend le snapshot 'clean'. Idempotent.
# -----------------------------------------------------------------------------
create() {
  _need_incus

  if _instance_exists; then
    info "Instance '$INCUS_INSTANCE' deja presente : on s'assure qu'elle tourne."
    if ! _instance_running; then
      incus start "$INCUS_INSTANCE"
    fi
  else
    info "Creation de l'instance LXC jetable '$INCUS_INSTANCE' depuis $INCUS_IMAGE..."
    # security.nesting=true : autorise Docker IMBRIQUE dans le conteneur LXC.
    # security.syscalls.intercept.mknod / setxattr : utiles pour que Docker
    #   imbrique cree des device nodes / pose des xattrs (overlayfs) sans avoir
    #   besoin de --privileged. C'est l'interception "propre" d'Incus.
    incus launch "$INCUS_IMAGE" "$INCUS_INSTANCE" \
      -c security.nesting=true \
      -c security.syscalls.intercept.mknod=true \
      -c security.syscalls.intercept.setxattr=true
    ok "Instance '$INCUS_INSTANCE' creee et demarree."
  fi

  _wait_network

  # --- Installation de Docker DANS l'instance (idempotent). -----------------
  # On verifie d'abord si docker est deja la (relance idempotente).
  if incus exec "$INCUS_INSTANCE" -- sh -c 'command -v docker >/dev/null 2>&1'; then
    ok "Docker deja installe dans '$INCUS_INSTANCE'."
  else
    info "Installation de Docker dans '$INCUS_INSTANCE' (depot officiel Debian)..."
    # Script d'installation pousse dans l'instance puis execute.
    # On utilise le paquet 'docker.io' de Debian 12 : suffisant pour le TP et
    # plus simple/robuste que le depot upstream (pas de cle externe a gerer).
    incus exec "$INCUS_INSTANCE" -- sh -eu -c '
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq docker.io ca-certificates >/dev/null
      systemctl enable --now docker >/dev/null 2>&1 || service docker start || true
    '
    ok "Docker installe dans '$INCUS_INSTANCE'."
  fi

  # --- Verification : le demon Docker repond DANS l'instance. ---------------
  if incus exec "$INCUS_INSTANCE" -- docker info >/dev/null 2>&1; then
    ok "Demon Docker operationnel dans '$INCUS_INSTANCE' (Docker imbrique OK)."
  else
    die "Docker imbrique NON operationnel dans '$INCUS_INSTANCE' (docker info a echoue)."
  fi

  # --- Snapshot 'clean' : etat initial restaurable. -------------------------
  if incus info "$INCUS_INSTANCE" 2>/dev/null | grep -q "^  $INCUS_SNAPSHOT "; then
    info "Snapshot '$INCUS_SNAPSHOT' deja present (conserve)."
  else
    info "Creation du snapshot '$INCUS_SNAPSHOT'..."
    incus snapshot "$INCUS_INSTANCE" "$INCUS_SNAPSHOT"
    ok "Snapshot '$INCUS_SNAPSHOT' cree (restauration possible via 'restore')."
  fi

  ok "Hote Incus jetable pret : $INCUS_INSTANCE"
}

# -----------------------------------------------------------------------------
# restore — restaure le snapshot 'clean' (remet l'hote a son etat post-create).
# -----------------------------------------------------------------------------
restore() {
  _need_incus
  _instance_exists || die "Instance '$INCUS_INSTANCE' absente : rien a restaurer."
  info "Restauration du snapshot '$INCUS_SNAPSHOT' de '$INCUS_INSTANCE'..."
  incus restore "$INCUS_INSTANCE" "$INCUS_SNAPSHOT"
  ok "Instance restauree a l'etat '$INCUS_SNAPSHOT'."
}

# -----------------------------------------------------------------------------
# destroy — detruit l'instance jetable (--force). Idempotent (no-op si absente).
# -----------------------------------------------------------------------------
destroy() {
  _need_incus
  if _instance_exists; then
    info "Suppression de l'instance jetable '$INCUS_INSTANCE' (--force)..."
    incus delete --force "$INCUS_INSTANCE"
    ok "Instance '$INCUS_INSTANCE' supprimee : aucune trace sur l'hote reel."
  else
    info "Instance '$INCUS_INSTANCE' absente : rien a supprimer (no-op)."
  fi
}

# -----------------------------------------------------------------------------
# status — affiche l'etat de l'instance.
# -----------------------------------------------------------------------------
status() {
  _need_incus
  if _instance_exists; then
    incus list "$INCUS_INSTANCE"
  else
    info "Instance '$INCUS_INSTANCE' absente."
  fi
}

# -----------------------------------------------------------------------------
# exec ... — execute une commande arbitraire dans l'instance (debug).
# -----------------------------------------------------------------------------
do_exec() {
  _need_incus
  _instance_exists || die "Instance '$INCUS_INSTANCE' absente."
  incus exec "$INCUS_INSTANCE" -- "$@"
}

# -----------------------------------------------------------------------------
# Dispatch.
# -----------------------------------------------------------------------------
case "${1:-}" in
  create)  create ;;
  restore) restore ;;
  destroy) destroy ;;
  status)  status ;;
  exec)    shift; do_exec "$@" ;;
  *)
    cat >&2 <<EOF
Usage: scripts/incus-host.sh <create|restore|destroy|status|exec ...>
  create   Cree l'hote LXC jetable '$INCUS_INSTANCE' + Docker + snapshot 'clean'.
  restore  Restaure le snapshot '$INCUS_SNAPSHOT'.
  destroy  Detruit l'instance (--force).
  status   Affiche l'etat.
  exec ... Execute une commande dans l'instance.
EOF
    exit 2
    ;;
esac
