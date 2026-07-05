#!/usr/bin/env bash
# =============================================================================
# run.sh — ORCHESTRATEUR MAITRE du TP « Durcissement d'un agent Claude Code en
#          conteneur Docker » (piece centrale du groupe "runner").
# -----------------------------------------------------------------------------
# Role :
#   Enchaine, en FAIL-FAST, les etapes unitaires steps/00..09 qui montent
#   l'architecture a 2 anneaux (hote Incus jetable + Docker durci), lancent les
#   profils NU et DURCI, rejouent les 6 attaques (+ bonus) et agregent les
#   preuves dans evidence/.
#
# Principes (cf. PLAN.md) :
#   - set -euo pipefail : la moindre erreur stoppe la chaine immediatement.
#   - run_step "<nom>" steps/NN-xxx.sh : LOG le debut, execute, et N'AVANCE QUE
#     SI le code retour == 0 (sinon log echec + exit 1).
#   - Idempotent au possible : chaque step peut etre rejoue sans casser.
#
# Sous-commandes :
#   ./run.sh all        -> 00 -> 08 en fail-fast (chaine complete sans teardown)
#   ./run.sh up         -> 00 -> 04 (prerequis, hote, build, perms, lancement NU)
#                          ... en pratique "up" = preparer + lancer les profils :
#                          00,01,02,03,04(run-nu),06(run-durci)
#   ./run.sh attacks    -> 05 (attaques NU) + 07 (attaques DURCI) + 08 (table)
#   ./run.sh down       -> 09-teardown (arret conteneurs/reseaux ; Incus optionnel)
#   ./run.sh <step>     -> execute un step isole, ex: ./run.sh 03-config-perms
#   ./run.sh list       -> liste les steps disponibles
#
# Options globales (variables d'environnement, documentees) :
#   SKIP_INCUS=1        -> ne provisionne pas l'hote Incus (anneau 1).
#                          Utile si on travaille deja DANS l'hote, ou sans Incus.
#                          Equivalent : flag --skip-incus passe a 01.
#   KEEP_INCUS=1        -> au teardown (09), NE detruit PAS l'instance Incus.
#
# Le flag d'invocation NON-INTERACTIF de l'agent Claude Code est documente dans
# steps/04-run-nu.sh et steps/06-run-durci.sh (claude -p / --print).
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Localisation du script (realpath -> symlinks resolus avant tout usage).
# TP_ROOT est exporte pour que tous les steps partagent la meme racine.
# -----------------------------------------------------------------------------
__SELF="$(realpath "${BASH_SOURCE[0]}")"
TP_ROOT="$(dirname "$__SELF")"
export TP_ROOT

# Bibliotheque de log partagee (definit info/ok/warn/err/section/die/run.log).
# shellcheck source=lib/log.sh
source "$TP_ROOT/lib/log.sh"

# Repertoire des steps.
STEPS_DIR="$TP_ROOT/steps"

# -----------------------------------------------------------------------------
# run_step "<nom lisible>" <chemin/relatif/step.sh> [args...]
#   - Logge le debut de l'etape (section + INFO).
#   - Execute le step dans un sous-shell (bash), en lui transmettant TP_ROOT et
#     l'environnement courant.
#   - N'AVANCE QUE SI le code retour est 0 ; sinon log ERR + exit 1 (fail-fast).
#   - Mesure et logge la duree pour le rapport.
# -----------------------------------------------------------------------------
run_step() {
  local name="$1"; shift
  local script="$1"; shift || true
  local abs="$STEPS_DIR/$script"

  section "STEP: $name  ($script)"

  if [[ ! -f "$abs" ]]; then
    die "Step introuvable: $abs"
  fi

  local start end dur rc
  start="$(date +%s)"

  # Execution : on lance via 'bash' (les steps ont leur propre set -euo pipefail).
  # On NE met PAS le step dans un 'if' qui masquerait l'echec : on capture le
  # code retour explicitement pour decider de poursuivre ou non.
  set +e
  bash "$abs" "$@"
  rc=$?
  set -e

  end="$(date +%s)"
  dur=$(( end - start ))

  if [[ "$rc" -ne 0 ]]; then
    err "STEP ECHOUE: '$name' (code=$rc, duree=${dur}s) -> arret fail-fast."
    exit 1
  fi
  ok "STEP OK: '$name' (duree=${dur}s)"
}

# -----------------------------------------------------------------------------
# Definition ORDONNEE de la chaine complete (00..09).
# Chaque entree : "<nom lisible>|<fichier step>".
# 09-teardown N'EST PAS dans la chaine 'all' (on ne detruit pas apres une demo).
# -----------------------------------------------------------------------------
CHAIN=(
  "Preflight (prerequis)|00-preflight.sh"
  "Hote Incus jetable (anneau 1)|01-incus-host.sh"
  "Build des 3 images Docker|02-build.sh"
  "Permissions config (root:root 0444/0555)|03-config-perms.sh"
  "Lancement profil NU + check fonctionnel|04-run-nu.sh"
  "Attaques contre NU (attendu: REUSSI)|05-attacks-nu.sh"
  "Lancement profil DURCI + check fonctionnel|06-run-durci.sh"
  "Attaques contre DURCI (attendu: BLOQUE)|07-attacks-durci.sh"
  "Table de resultats (evidence/results.md)|08-results-table.sh"
)

# -----------------------------------------------------------------------------
# do_all — execute toute la chaine 00..08 en fail-fast.
# -----------------------------------------------------------------------------
do_all() {
  local entry name file
  for entry in "${CHAIN[@]}"; do
    name="${entry%%|*}"
    file="${entry##*|}"
    run_step "$name" "$file"
  done
  recap_ok "Chaine complete 00..08 terminee."
}

# -----------------------------------------------------------------------------
# do_up — prepare l'infra et lance les DEUX profils, sans rejouer les attaques.
#   Pratique pour inspecter/demonstration manuelle avant 'attacks'.
# -----------------------------------------------------------------------------
do_up() {
  run_step "Preflight (prerequis)"                         "00-preflight.sh"
  run_step "Hote Incus jetable (anneau 1)"                 "01-incus-host.sh"
  run_step "Build des 3 images Docker"                     "02-build.sh"
  run_step "Permissions config (root:root 0444/0555)"      "03-config-perms.sh"
  run_step "Lancement profil NU + check fonctionnel"       "04-run-nu.sh"
  run_step "Lancement profil DURCI + check fonctionnel"    "06-run-durci.sh"
  recap_ok "Infra prete : profils NU et DURCI lances."
}

# -----------------------------------------------------------------------------
# do_attacks — rejoue les attaques sur les deux profils puis agrege la table.
#   Suppose que 'up' a deja ete execute (conteneurs presents).
# -----------------------------------------------------------------------------
do_attacks() {
  run_step "Attaques contre NU (attendu: REUSSI)"          "05-attacks-nu.sh"
  run_step "Attaques contre DURCI (attendu: BLOQUE)"       "07-attacks-durci.sh"
  run_step "Table de resultats (evidence/results.md)"      "08-results-table.sh"
  recap_ok "Attaques rejouees. Voir evidence/results.md."
}

# -----------------------------------------------------------------------------
# do_down — teardown (arret/suppression conteneurs+reseaux ; Incus optionnel).
# -----------------------------------------------------------------------------
do_down() {
  run_step "Teardown (nettoyage)"                          "09-teardown.sh"
  recap_ok "Teardown termine."
}

# -----------------------------------------------------------------------------
# do_one <token> — execute un step isole. Accepte :
#   - le nom complet : 00-preflight.sh
#   - sans extension : 00-preflight
#   - le prefixe num : 00
# -----------------------------------------------------------------------------
do_one() {
  local token="$1"; shift || true
  local file=""
  # Resolution tolerante.
  if [[ -f "$STEPS_DIR/$token" ]]; then
    file="$token"
  elif [[ -f "$STEPS_DIR/$token.sh" ]]; then
    file="$token.sh"
  else
    # Recherche par prefixe numerique (ex: "03" -> 03-config-perms.sh).
    local match
    match="$(find "$STEPS_DIR" -maxdepth 1 -type f -name "${token}*.sh" -printf '%f\n' 2>/dev/null | sort | head -n1)"
    [[ -n "$match" ]] && file="$match"
  fi
  [[ -z "$file" ]] && die "Step inconnu: '$token' (voir ./run.sh list)"
  run_step "Step isole: $file" "$file" "$@"
}

# -----------------------------------------------------------------------------
# do_list — liste les steps disponibles.
# -----------------------------------------------------------------------------
do_list() {
  section "Steps disponibles"
  find "$STEPS_DIR" -maxdepth 1 -type f -name '*.sh' -printf '  %f\n' 2>/dev/null | sort
}

# -----------------------------------------------------------------------------
# recap_ok — recapitulatif final lisible (et trace dans run.log).
# -----------------------------------------------------------------------------
recap_ok() {
  section "RECAP"
  ok "$*"
  info "Journal central : $TP_RUN_LOG"
  info "Table resultats : $TP_EVIDENCE_DIR/results.md (apres 08)"
}

# -----------------------------------------------------------------------------
# usage — aide d'utilisation.
# -----------------------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
Usage: ./run.sh <commande>

Commandes principales :
  all         Enchaine 00 -> 08 en fail-fast (chaine complete, sans teardown).
  up          Prepare l'infra et lance NU + DURCI (00,01,02,03,04,06).
  attacks     Rejoue les attaques NU + DURCI puis agrege la table (05,07,08).
  down        Teardown (09) : arret conteneurs/reseaux ; Incus optionnel.
  list        Liste les steps disponibles.
  <step>      Execute un step isole : ex. "03", "03-config-perms" ou le .sh complet.

Variables d'environnement utiles :
  SKIP_INCUS=1   Ne provisionne pas l'hote Incus (anneau 1).
  KEEP_INCUS=1   Au teardown, conserve l'instance Incus.
  NO_COLOR=1     Desactive la couleur.

Exemples :
  SKIP_INCUS=1 ./run.sh all
  ./run.sh up && ./run.sh attacks
  ./run.sh 02-build
EOF
}

# -----------------------------------------------------------------------------
# Dispatch principal.
# -----------------------------------------------------------------------------
main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    all)      do_all ;;
    up)       do_up ;;
    attacks)  do_attacks ;;
    down|clean) do_down ;;
    list)     do_list ;;
    ""|-h|--help|help) usage ;;
    *)        do_one "$cmd" "$@" ;;
  esac
}

main "$@"
