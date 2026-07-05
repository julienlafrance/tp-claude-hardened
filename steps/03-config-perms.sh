#!/usr/bin/env bash
# =============================================================================
# steps/03-config-perms.sh — Prepare les COPIES de config PAR PROFIL sous
#                            tp/.runtime/ et applique le 2e VERROU (root:root
#                            0444 fichiers / 0555 repertoires) sur la copie
#                            DURCI, AVANT tout montage :ro.
# -----------------------------------------------------------------------------
# POURQUOI DES COPIES ? (correction de bug d'idempotence)
#   La SOURCE tp/config/ est le MODELE partage. Si on la montait en :rw cote NU,
#   l'attaque NU (step 05) reecrirait ces fichiers et CORROMPRAIT la source, que
#   le profil durci (step 06) monte ensuite en :ro -> 'run.sh all' n'etait PAS
#   idempotent. On travaille donc sur des copies jetables (cf. lib/log.sh) :
#     - tp/.runtime/nu-config/    : droits NORMAUX  (l'agent NU peut ECRIRE ->
#                                   les attaques 1-4 reussissent, sur la COPIE).
#     - tp/.runtime/durci-config/ : droits VERROUILLES (ci-dessous) puis :ro.
#   La source tp/config/ reste INTACTE.
#
# Defense en profondeur au niveau FICHIER (cf. PLAN.md sec.4), profil DURCI :
#   - Verrou 1 (kernel)  : montage Docker :ro (applique au step 06/07).
#   - Verrou 2 (FS hote) : ICI -> proprietaire root:root + droits 0444/0555 sur
#     la COPIE durci-config. Meme avant tout montage, et meme si un :ro etait
#     oublie, l'utilisateur 'agent' (UID 10001) NON-root du conteneur ne POSSEDE
#     pas ces fichiers et ne peut donc pas les reecrire.
#   POURQUOI :ro EST STRICTEMENT PLUS FORT : le verrou kernel :ro est applique
#     par le noyau au montage ; il bloque TOUTE ecriture (meme par root dans le
#     conteneur), independamment du proprietaire/droits du fichier hote. Le 2e
#     verrou (proprietaire root) n'est qu'une defense en profondeur "ceinture +
#     bretelles" pour le cas ou le :ro serait oublie.
#
# Cibles (CONV.ro_targets, cote COPIE durci-config) :
#   - project-settings.json, project-CLAUDE.md, project-mcp.json
#   - project-skills/ (recursif), user-settings.json, user-skills/ (recursif)
#
# NB sur les droits : 0444 = lecture seule pour tous ; 0555 pour les
#   repertoires (lecture + traversee). C'est suffisant : le conteneur les monte
#   en :ro et n'a besoin que de LIRE.
#
# Privileges : chown root necessite root. On utilise sudo si on n'est pas root.
#   Si NI root NI sudo : on LOG un WARN clair (seul le verrou kernel :ro sera
#   effectif, ce qui est ATTENDU et SUFFISANT) et on NE FAIT PAS echouer le step.
# Idempotent : (re)cree des copies fraiches et reapplique les memes droits.
# =============================================================================

set -euo pipefail

TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")}"
# shellcheck source=../lib/log.sh
source "$TP_ROOT/lib/log.sh"

CONFIG_DIR="$TP_ROOT/config"
[[ -d "$CONFIG_DIR" ]] || die "Repertoire config introuvable: $CONFIG_DIR (groupe config non termine ?)"

# Profil(s) a (re)generer : "both" (defaut, flux run.sh), ou "durci" seul.
# La recreation anti-persistance (scripts/recreate-daily.sh) appelle "durci" pour
# NE PAS regenerer la copie nu-config PENDANT que le conteneur NU tourne : sinon
# on supprimerait/recreerait les inodes que les binds de NU pointent, cassant ses
# montages (l'attaque 3 sur NU deviendrait faussement BLOQUEE).
PROFILE_ARG="${1:-both}"

# -----------------------------------------------------------------------------
# 1) COPIE NU — droits NORMAUX (laisse les attaques reussir sur la COPIE, pas
#    sur la source). On (re)cree une copie fraiche pour un etat reproductible.
#    SAUTEE si on ne (re)genere que le profil durci (NU deja lance).
# -----------------------------------------------------------------------------
if [[ "$PROFILE_ARG" != "durci" ]]; then
  info "Preparation de la copie NU jetable (droits normaux) sous .runtime/nu-config..."
  NU_CONFIG="$(make_runtime_config nu)"
  ok "Copie NU prete : $NU_CONFIG (droits normaux, modifiable par l'agent NU)."
else
  info "Profil 'durci' seul : copie NU laissee intacte (conteneur NU possiblement actif)."
fi

# -----------------------------------------------------------------------------
# 2) COPIE DURCI — copie fraiche PUIS 2e verrou (root:root 0444/0555).
# -----------------------------------------------------------------------------
info "Preparation de la copie DURCI jetable sous .runtime/durci-config..."
DURCI_CONFIG="$(make_runtime_config durci)"

# -----------------------------------------------------------------------------
# Selecteur de privilege pour le chown root:root :
#   - deja root            -> SUDO="" (operation directe) ;
#   - sudo NON-INTERACTIF dispo (sudo -n true reussit) -> SUDO="sudo" ;
#   - sinon (pas de root, pas de sudo utilisable sans mot de passe) -> on
#     DESACTIVE le chown root (CAN_CHOWN_ROOT=0) et on LOG un WARN clair.
# Le chmod 0444/0555, lui, ne necessite PAS root (le proprietaire de la COPIE
# fraiche est l'utilisateur courant) : on l'applique TOUJOURS sans sudo.
# -----------------------------------------------------------------------------
SUDO=""
CAN_CHOWN_ROOT=1
if [[ "$(id -u)" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    SUDO="sudo"
    info "Execution non-root : chown root:root via sudo (non-interactif disponible)."
  else
    CAN_CHOWN_ROOT=0
    warn "Ni root ni sudo non-interactif : le 2e verrou (proprietaire root:root) NE sera PAS applique."
    warn "Comportement ATTENDU et non bloquant : seul le verrou kernel :ro (step 06/07)"
    warn "protegera la config durci — et :ro est STRICTEMENT PLUS FORT (applique par le"
    warn "noyau au montage, bloque toute ecriture meme par root dans le conteneur)."
    warn "Les droits 0444/0555 restent appliques (utiles si le conteneur tournait root)."
  fi
fi

# -----------------------------------------------------------------------------
# Listes des CIBLES a verrouiller, resolues SUR LA COPIE durci-config.
# -----------------------------------------------------------------------------
FILE_TARGETS=(
  "$DURCI_CONFIG/project-settings.json"
  "$DURCI_CONFIG/project-CLAUDE.md"
  "$DURCI_CONFIG/project-mcp.json"
  "$DURCI_CONFIG/user-settings.json"
)
DIR_TARGETS=(
  "$DURCI_CONFIG/project-skills"
  "$DURCI_CONFIG/user-skills"
)

MISSING=0

# -----------------------------------------------------------------------------
# lock_file <chemin> — fige un fichier en root:root 0444.
# -----------------------------------------------------------------------------
lock_file() {
  local f="$1"
  if [[ ! -e "$f" ]]; then
    err "Cible MANQUANTE: $f"
    MISSING=$((MISSING+1))
    return 0
  fi
  local rp; rp="$(realpath "$f")"
  # chmod ne necessite PAS root (proprietaire de la copie) -> sans sudo.
  chmod 0444 "$rp" 2>/dev/null || warn "chmod 0444 impossible sur $rp."
  # chown root:root necessite root/sudo -> seulement si disponible.
  if [[ "$CAN_CHOWN_ROOT" -eq 1 ]]; then
    $SUDO chown root:root "$rp" 2>/dev/null || warn "chown root:root impossible sur $rp (privileges ?)"
    ok "Fige 0444 root:root : $rp"
  else
    ok "Fige 0444 (proprietaire courant ; chown root saute) : $rp"
  fi
}

# -----------------------------------------------------------------------------
# lock_dir <chemin> — fige un repertoire ET son contenu :
#   repertoires en 0555, fichiers en 0444, tout en root:root (recursif).
# -----------------------------------------------------------------------------
lock_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    err "Cible repertoire MANQUANTE: $d"
    MISSING=$((MISSING+1))
    return 0
  fi
  local rp; rp="$(realpath "$d")"
  # Repertoires : 0555 (lecture + traversee). Fichiers : 0444 (lecture seule).
  # chmod ne necessite PAS root (proprietaire de la copie) -> sans sudo.
  find "$rp" -type d -exec chmod 0555 {} + 2>/dev/null || warn "chmod 0555 (dirs) impossible sur $rp."
  find "$rp" -type f -exec chmod 0444 {} + 2>/dev/null || warn "chmod 0444 (files) impossible sur $rp."
  # chown root:root necessite root/sudo -> seulement si disponible.
  if [[ "$CAN_CHOWN_ROOT" -eq 1 ]]; then
    $SUDO chown -R root:root "$rp" 2>/dev/null || warn "chown -R root:root impossible sur $rp (privileges ?)"
    ok "Fige recursif (dirs 0555 / files 0444) root:root : $rp/"
  else
    ok "Fige recursif (dirs 0555 / files 0444 ; chown root saute) : $rp/"
  fi
}

info "Application du 2e verrou (proprietaire root + droits lecture seule) sur la copie DURCI..."

for f in "${FILE_TARGETS[@]}"; do lock_file "$f"; done
for d in "${DIR_TARGETS[@]}"; do lock_dir  "$d"; done

# -----------------------------------------------------------------------------
# Verification finale (preuve pour le rapport) : on liste les droits effectifs
# de la copie DURCI verrouillee.
# -----------------------------------------------------------------------------
info "Droits effectifs des cibles de config DURCI :"
{
  for f in "${FILE_TARGETS[@]}"; do [[ -e "$f" ]] && ls -ld "$f"; done
  for d in "${DIR_TARGETS[@]}"; do [[ -d "$d" ]] && ls -ld "$d"; done
} 2>/dev/null | tee -a "$TP_RUN_LOG" || true

if [[ "$MISSING" -gt 0 ]]; then
  die "Step 03 : $MISSING cible(s) de config manquante(s) dans la copie DURCI (groupe config a terminer)."
fi

ok "Step 03 : copies de config pretes (nu-config rw, durci-config figee) — source tp/config/ intacte."
