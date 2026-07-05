#!/usr/bin/env bash
# =============================================================================
# lib/log.sh — Bibliotheque de journalisation partagee du TP
# -----------------------------------------------------------------------------
# Fournit des helpers de log colorises et horodates, utilises par run.sh et par
# tous les scripts steps/NN-*.sh.
#
# Tous les messages sont :
#   1. affiches sur la console (stderr) avec couleur si terminal interactif ;
#   2. recopies (sans codes couleur) dans le journal central evidence/run.log
#      pour servir de PREUVE dans le rapport PDF.
#
# Ce fichier est destine a etre source ("source lib/log.sh"), pas execute.
# =============================================================================

# --- Garde anti-double-inclusion : ce fichier peut etre source plusieurs fois
#     (par run.sh puis par un step). On evite de re-declarer/re-couleur.
if [[ -n "${__TP_LOG_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
__TP_LOG_SH_LOADED=1

# -----------------------------------------------------------------------------
# Resolution des chemins : on calcule la racine du projet (tp/) a partir de
# l'emplacement reel de CE fichier, via realpath (les symlinks sont resolus
# AVANT toute utilisation — exigence de securite du TP).
# -----------------------------------------------------------------------------
# BASH_SOURCE[0] = chemin de lib/log.sh lui-meme.
__TP_LOG_SELF="$(realpath "${BASH_SOURCE[0]}")"
# La racine du projet est le parent du repertoire lib/.
TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$__TP_LOG_SELF")")}"
export TP_ROOT

# Repertoire et fichier de preuves (journal central). Cree a la volee.
TP_EVIDENCE_DIR="${TP_EVIDENCE_DIR:-$TP_ROOT/evidence}"
TP_RUN_LOG="${TP_RUN_LOG:-$TP_EVIDENCE_DIR/run.log}"
export TP_EVIDENCE_DIR TP_RUN_LOG
mkdir -p "$TP_EVIDENCE_DIR" 2>/dev/null || true

# -----------------------------------------------------------------------------
# Secrets de backend (LiteLLM) — charges depuis .secret/litellm.env s'il existe.
# Contient la VIRTUAL KEY scopee (+ endpoint/modele optionnels). Ce fichier est
# GITIGNORE : il ne part JAMAIS dans le depot public. On le charge ICI pour que
# TOUT step (via run.sh OU lance directement, ex. par recreate-daily.sh) en
# herite via l'environnement. Modele fourni : .secret/litellm.env.example.
# -----------------------------------------------------------------------------
__TP_SECRET_ENV="${TP_SECRET_ENV:-$TP_ROOT/.secret/litellm.env}"
if [[ -f "$__TP_SECRET_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$__TP_SECRET_ENV" 2>/dev/null || true
  set +a
fi

# -----------------------------------------------------------------------------
# Couleurs ANSI — activees UNIQUEMENT si stderr est un terminal interactif et
# que la variable NO_COLOR n'est pas positionnee (convention freedesktop).
# -----------------------------------------------------------------------------
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  __C_RESET=$'\033[0m'
  __C_DIM=$'\033[2m'
  __C_BLUE=$'\033[34m'
  __C_GREEN=$'\033[32m'
  __C_YELLOW=$'\033[33m'
  __C_RED=$'\033[31m'
  __C_BOLD=$'\033[1m'
else
  __C_RESET=''; __C_DIM=''; __C_BLUE=''; __C_GREEN=''
  __C_YELLOW=''; __C_RED=''; __C_BOLD=''
fi

# -----------------------------------------------------------------------------
# __tp_ts — horodatage ISO-8601 local, reutilise par tous les logs.
# -----------------------------------------------------------------------------
__tp_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# -----------------------------------------------------------------------------
# __tp_emit <niveau> <couleur> <message...>
#   Coeur de la journalisation. Ecrit a la fois :
#     - sur la console (stderr) avec couleur ;
#     - dans evidence/run.log SANS couleur (texte brut exploitable).
#   stderr est choisi pour ne PAS polluer la sortie standard (stdout reste
#   disponible pour des donnees "machine" eventuelles d'un step).
# -----------------------------------------------------------------------------
__tp_emit() {
  local level="$1"; local color="$2"; shift 2
  local ts; ts="$(__tp_ts)"
  local msg="$*"
  # Console (coloree, sur stderr)
  printf '%s%s [%s]%s %s\n' "$color" "$ts" "$level" "$__C_RESET" "$msg" >&2
  # Journal central (brut). On ignore une eventuelle erreur d'ecriture pour ne
  # pas faire echouer un step a cause de la seule journalisation.
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >>"$TP_RUN_LOG" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Helpers publics : info / ok / warn / err
#   - info : information de progression ;
#   - ok   : succes d'une operation ;
#   - warn : avertissement non bloquant ;
#   - err  : erreur (n'arrete PAS le script lui-meme — c'est l'appelant qui
#            decide via son code retour / set -e).
# -----------------------------------------------------------------------------
info() { __tp_emit "INFO" "$__C_BLUE"   "$@"; }
ok()   { __tp_emit "OK"   "$__C_GREEN"  "$@"; }
warn() { __tp_emit "WARN" "$__C_YELLOW" "$@"; }
err()  { __tp_emit "ERR"  "$__C_RED"    "$@"; }

# -----------------------------------------------------------------------------
# section <titre> — affiche un separateur visuel pour delimiter une etape.
# -----------------------------------------------------------------------------
section() {
  local title="$*"
  local line='----------------------------------------------------------------------'
  printf '%s%s%s\n' "$__C_DIM" "$line" "$__C_RESET" >&2
  printf '%s%s== %s%s\n' "$__C_BOLD" "$__C_BLUE" "$title" "$__C_RESET" >&2
  printf '%s%s%s\n' "$__C_DIM" "$line" "$__C_RESET" >&2
  {
    printf '%s\n' "$line"
    printf '== %s\n' "$title"
    printf '%s\n' "$line"
  } >>"$TP_RUN_LOG" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# die <message> — log une erreur fatale puis sort en code 1.
#   Utilise par les steps pour un echec net et explicite.
# -----------------------------------------------------------------------------
die() {
  err "$@"
  exit 1
}

# -----------------------------------------------------------------------------
# need_cmd <binaire> [message] — verifie qu'une commande existe, sinon die().
#   Helper de preflight reutilisable.
# -----------------------------------------------------------------------------
need_cmd() {
  local bin="$1"; shift || true
  if ! command -v "$bin" >/dev/null 2>&1; then
    die "Binaire requis introuvable: '$bin'. ${*:-}"
  fi
}

# -----------------------------------------------------------------------------
# Repertoire RUNTIME jetable — copies de config PAR PROFIL.
# -----------------------------------------------------------------------------
# Probleme corrige : les steps montaient la SOURCE tp/config/ en :rw cote NU.
# L'attaque NU (step 05) reecrivait alors les fichiers de config et CORROMPAIT
# la source partagee, que le profil durci (step 06) monte ensuite en :ro ->
# 'run.sh all' n'etait PAS idempotent (durci demarrait d'une config alteree).
#
# Solution : la source tp/config/ reste INTACTE et SERT DE MODELE. Chaque profil
# travaille sur sa PROPRE copie jetable sous tp/.runtime/ :
#   - .runtime/nu-config/    : copie en droits NORMAUX (l'agent NU peut ecrire
#                              -> les attaques 1-4 reussissent, sur la COPIE).
#   - .runtime/durci-config/ : copie verrouillee (2e verrou root:root 0444/0555)
#                              puis montee en :ro (verrou kernel, le plus fort).
#
# RUNTIME_DIR est exporte pour que tous les steps partagent la meme racine.
RUNTIME_DIR="${RUNTIME_DIR:-$TP_ROOT/.runtime}"
export RUNTIME_DIR

# __rm_runtime_dir <chemin> — supprime une copie runtime, meme si elle a ete
#   figee (dirs 0555 / files 0444) et/ou appartient a root:root.
#   Strategie : (1) rendre inscriptible (chmod -R u+w) puis rm ; (2) si echec et
#   sudo non-interactif dispo, chmod+rm via sudo. No-op si le chemin est absent.
__rm_runtime_dir() {
  local dst="$1"
  [[ -e "$dst" ]] || return 0
  chmod -R u+w "$dst" 2>/dev/null || true
  rm -rf "$dst" 2>/dev/null && return 0
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    sudo chmod -R u+w "$dst" 2>/dev/null || true
    sudo rm -rf "$dst" 2>/dev/null || true
  fi
  rm -rf "$dst" 2>/dev/null || true
}

# make_runtime_config <profil> — (re)cree une copie FRAICHE de tp/config/ sous
#   $RUNTIME_DIR/<profil>-config/. La source n'est jamais mutee.
#   <profil> ∈ {nu, durci}. Idempotent : rm -rf puis cp -a (etat reproductible).
#   Echoue (die) si la source config/ est absente.
make_runtime_config() {
  local profile="$1"
  local src="$TP_ROOT/config"
  local dst="$RUNTIME_DIR/${profile}-config"
  [[ -d "$src" ]] || die "Source config introuvable: $src (groupe config non termine ?)."
  mkdir -p "$RUNTIME_DIR"
  # rm -rf de la copie precedente. Cas particulier : la copie durci-config a pu
  # etre figee par le step 03 en 0444 (fichiers) / 0555 (repertoires). Un dir en
  # 0555 (sans bit d'ecriture) empeche de supprimer son CONTENU meme pour le
  # proprietaire -> on REDONNE le droit d'ecriture (chmod -R u+w) avant rm. Si la
  # copie appartient a root:root (chown reussi), on passe par sudo si dispo.
  __rm_runtime_dir "$dst"
  mkdir -p "$dst"
  # cp -a : preserve l'arborescence (recursif), les liens et les attributs.
  # Le 'point' (config/.) copie le CONTENU de config/ DANS dst/.
  cp -a "$src/." "$dst/"
  printf '%s' "$dst"
}

# ensure_runtime_config <profil> — garantit la presence de la copie ; si elle
#   existe deja (step 03 deja passe), on la REUTILISE telle quelle. Sinon
#   fallback : on la cree (cas 'run.sh 04' ou 'run.sh 06' lances seuls).
#   Imprime le chemin de la copie sur stdout (a capturer par l'appelant).
ensure_runtime_config() {
  local profile="$1"
  local dst="$RUNTIME_DIR/${profile}-config"
  if [[ -d "$dst" ]]; then
    printf '%s' "$dst"
  else
    make_runtime_config "$profile"
  fi
}

# =============================================================================
# Helpers de PREUVE GRANULAIRE par attaque (evidence lisible pour le rapport).
# -----------------------------------------------------------------------------
# Objectif : pour CHAQUE attaque, tracer la commande tentee, son code retour, et
# — pour une reecriture de fichier — l'empreinte de la cible AVANT et APRES. Une
# empreinte INCHANGEE prouve objectivement que le verrou :ro a bloque l'ecriture
# (meme lancee en root sur nu), tandis qu'une empreinte MODIFIEE atteste la
# mutation reussie. C'est la preuve la plus directe du partitionnement FS.
# =============================================================================

# csha <container> <path> — empreinte courte (sha256, 12 hex) du fichier <path>
#   DANS <container>. Renvoie "ABSENT" si le fichier n'existe pas/illisible,
#   "ERR" si l'exec echoue. Ne fait JAMAIS echouer l'appelant (set -e safe).
csha() {
  local c="$1" p="$2"
  docker exec "$c" sh -c 'if [ -r "$1" ]; then sha256sum "$1" 2>/dev/null | cut -c1-12; else echo ABSENT; fi' _ "$p" 2>/dev/null || echo ERR
}

# attack_detail <profile> <id> <label> <verdict> <mech> [cmd] [rc] [cible] [sha_avant] [sha_apres]
#   Ecrit un bloc de preuve LISIBLE dans evidence/attacks-<profile>-detail.log
#   (en plus de la ligne TSV et du run.log). Les champs sha_* sont optionnels
#   (attaques non-fichier : exfil, destruction, reseau).
attack_detail() {
  local profile="$1" id="$2" label="$3" verdict="$4" mech="$5"
  local cmd="${6:-}" rc="${7:-}" cible="${8:-}" a="${9:-}" b="${10:-}"
  local f="$TP_EVIDENCE_DIR/attacks-${profile}-detail.log"
  {
    printf '=== [%s] Attaque %s — %s\n' "$profile" "$id" "$label"
    [[ -n "$cmd"   ]] && printf '    commande    : %s\n' "$cmd"
    [[ -n "$rc"    ]] && printf '    code retour : %s\n' "$rc"
    [[ -n "$cible" ]] && printf '    cible       : %s\n' "$cible"
    if [[ -n "$a$b" ]]; then
      printf '    sha AVANT   : %s\n' "$a"
      printf '    sha APRES   : %s\n' "$b"
      if [[ "$a" == "$b" ]]; then
        printf '    consequence : cible INCHANGEE (empreinte identique) => ecriture neutralisee\n'
      else
        printf '    consequence : cible MODIFIEE (empreinte differente) => ecriture aboutie\n'
      fi
    fi
    printf '    VERDICT     : %s  (%s)\n\n' "$verdict" "$mech"
  } >>"$f" 2>/dev/null || true
}

# attack_detail_reset <profile> — (re)initialise le fichier de detail au debut
#   d'une campagne, avec un en-tete horodate.
attack_detail_reset() {
  local profile="$1"
  local f="$TP_EVIDENCE_DIR/attacks-${profile}-detail.log"
  {
    printf '########################################################################\n'
    printf '# Preuve granulaire par attaque — profil %s — %s\n' "$profile" "$(__tp_ts)"
    printf '# (commande tentee, code retour, empreinte AVANT/APRES de la cible)\n'
    printf '########################################################################\n\n'
  } >"$f" 2>/dev/null || true
}
