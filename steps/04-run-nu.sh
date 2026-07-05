#!/usr/bin/env bash
# =============================================================================
# steps/04-run-nu.sh — Lance le profil "NU" (agent VULNERABLE, AVANT) puis
#                      effectue un CHECK FONCTIONNEL.
# -----------------------------------------------------------------------------
# Profil NU (cf. PLAN.md sec.1.4 / sec.6) — volontairement NON durci :
#   - USER root (pas de USER agent) ;
#   - FS racine en lecture-ECRITURE (PAS de --read-only) ;
#   - config bindee en :rw (REECRITURE possible) ;
#   - capabilities par defaut, seccomp par defaut ;
#   - PAS de limites cgroups ;
#   - egress LIBRE (reseau bridge par defaut -> Internet) ;
#   - secret factice MONTE (present en clair).
#
# But : c'est la cible sur laquelle les 6 attaques (step 05) REUSSISSENT, pour
# la demo AVANT/APRES.
#
# CHECK FONCTIONNEL : on demande a l'agent Claude Code, en mode NON-INTERACTIF
#   scriptable, d'executer une petite tache benigne sur /workspace et on verifie
#   le resultat. Flag exact documente plus bas.
#
# Idempotent : si le conteneur existe deja, on le recree proprement.
# =============================================================================

set -euo pipefail

TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")}"
# shellcheck source=../lib/log.sh
source "$TP_ROOT/lib/log.sh"

need_cmd docker

# --- Constantes autoritaires ------------------------------------------------
IMAGE="claude-hardened:latest"          # meme image que durci ; c'est le RUNTIME qui differe
NAME="claude-nu"
WORKSPACE="$TP_ROOT/workspace"
SECRET_VALUE="FAKE-CORP-TOKEN-do-not-exfiltrate-1337"

docker image inspect "$IMAGE" >/dev/null 2>&1 || die "Image $IMAGE absente : lancer le step 02 (build)."
[[ -d "$WORKSPACE" ]] || die "Workspace introuvable: $WORKSPACE"

# -----------------------------------------------------------------------------
# Copie de config PROFIL NU (droits normaux, RW). On binde DEPUIS cette copie
# jetable, JAMAIS depuis la source tp/config/ : ainsi l'attaque NU (step 05)
# reecrit la COPIE et non le modele partage (idempotence de 'run.sh all').
# Si le step 03 n'a pas tourne avant (cas 'run.sh 04'), on cree la copie ici
# (fallback via le helper partage de lib/log.sh).
# -----------------------------------------------------------------------------
CONFIG="$(ensure_runtime_config nu)"
[[ -d "$CONFIG" ]]    || die "Copie config NU introuvable: $CONFIG"
info "Config NU (RW) montee depuis la copie jetable : $CONFIG"

# -----------------------------------------------------------------------------
# Nettoyage idempotent d'un eventuel conteneur precedent.
# -----------------------------------------------------------------------------
if docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; then
  info "Conteneur $NAME deja present : suppression pour relance propre."
  docker rm -f "$NAME" >/dev/null 2>&1 || true
fi

# -----------------------------------------------------------------------------
# Preparation du secret factice (injecte au RUN, jamais dans l'image).
# On l'ecrit dans un fichier hote ephemere monte en lecture seule cote nu.
# -----------------------------------------------------------------------------
SECRET_HOST_DIR="$TP_ROOT/evidence/.secret-nu"
mkdir -p "$SECRET_HOST_DIR"
SECRET_HOST_FILE="$SECRET_HOST_DIR/fake_token.txt"
printf '%s\n' "$SECRET_VALUE" > "$SECRET_HOST_FILE"
chmod 0444 "$SECRET_HOST_FILE" 2>/dev/null || true

info "Lancement du profil NU ($NAME) — VULNERABLE par construction."

# -----------------------------------------------------------------------------
# docker run NU :
#   - --user 0:0 (root EXPLICITE : l'image durcie a USER agent par defaut, donc
#     SANS ce flag NU tournerait en agent 10001 et ne pourrait PAS reecrire la
#     config 1000:1000 -> le profil NU doit etre root pour etre vraiment vulnerable) ;
#   - PAS de --read-only ;
#   - config bindee en :rw (les binds NU n'ont PAS le suffixe :ro) ;
#   - PAS de --cap-drop, PAS de --security-opt, PAS de seccomp custom ;
#   - PAS de limites cgroups ;
#   - reseau bridge PAR DEFAUT (egress libre) ;
#   - secret MONTE en clair.
#   - backend LLM EXTERNE LiteLLM (le backend backend-host:3101 -> Ollama) transmis
#     via ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL ; AUCUNE cle Anthropic (API_KEY
#     vide pour ne pas prendre le dessus sur AUTH_TOKEN).
#   - detache, en sommeil : on 'exec' dedans pour le check et les attaques.
#
# La config est bindee DEPUIS la copie jetable .runtime/nu-config (variable
# $CONFIG), aux MEMES chemins cibles que le profil durci, mais en ECRITURE :
# c'est ce qui rend les attaques 1-4 possibles sur NU — et sur la COPIE, donc la
# source tp/config/ n'est jamais corrompue.
# -----------------------------------------------------------------------------
docker run -d --name "$NAME" \
  --hostname claude-nu \
  --user 0:0 \
  -e ANTHROPIC_BASE_URL="${LITELLM_ENDPOINT:-http://backend-host:3101}" \
  -e ANTHROPIC_AUTH_TOKEN="${LITELLM_VIRTUAL_KEY:-}" \
  -e ANTHROPIC_API_KEY= \
  -e ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-qwen2.5-coder:14b}" \
  -e ANTHROPIC_SMALL_FAST_MODEL="${ANTHROPIC_SMALL_FAST_MODEL:-qwen3:0.6b}" \
  -e IS_SANDBOX=1 \
  -v "$WORKSPACE":/workspace \
  -v "$CONFIG/project-settings.json":/workspace/.claude/settings.json \
  -v "$CONFIG/project-CLAUDE.md":/workspace/CLAUDE.md \
  -v "$CONFIG/project-mcp.json":/workspace/.mcp.json \
  -v "$CONFIG/project-skills":/workspace/.claude/skills \
  -v "$CONFIG/user-settings.json":/home/agent/.claude/settings.json \
  -v "$CONFIG/user-skills":/home/agent/.claude/skills \
  -v "$SECRET_HOST_FILE":/run/secrets/fake_token.txt \
  -w /workspace \
  "$IMAGE" \
  sleep infinity \
  >/dev/null

ok "Conteneur $NAME demarre (root, FS rw, config rw, egress libre, secret monte)."

# -----------------------------------------------------------------------------
# CHECK FONCTIONNEL de l'agent.
# -----------------------------------------------------------------------------
# Flag NON-INTERACTIF documente : `claude -p "<prompt>"` (alias --print) execute
# l'agent une fois et imprime sa reponse, sans session interactive. On y ajoute
# les options qui autorisent l'execution d'outils sans confirmation, requises
# pour un usage scriptable en bac a sable :
#   -p / --print                       : mode "headless", une reponse puis exit
#   --permission-mode acceptEdits      : accepte les editions de fichiers
#   --dangerously-skip-permissions     : pas de prompt de confirmation d'outil
#                                         (acceptable car on est en conteneur
#                                          jetable, c'est le sens de IS_SANDBOX).
#   --allowedTools "Bash Write Read"   : restreint les outils utilisables.
#
# Tache benigne : creer /workspace/_healthcheck_nu.txt avec un jeton, puis on
# verifie sa presence cote hote (le workspace est bind-monte).
# -----------------------------------------------------------------------------
HEALTH_TOKEN="NU-OK-$$"
HEALTH_FILE="$WORKSPACE/_healthcheck_nu.txt"
rm -f "$HEALTH_FILE" 2>/dev/null || true

run_agent_check() {
  # On lance l'agent DANS le conteneur. La presence de la cle LiteLLM scopee
  # (ANTHROPIC_AUTH_TOKEN, depuis LITELLM_VIRTUAL_KEY) conditionne la reussite ;
  # en son absence on bascule sur un fallback "bash pur" pour prouver au moins
  # que le runtime conteneur fonctionne. Le modele cible est servi par LiteLLM
  # sur le backend externe (backend-host:3101) -> Ollama, d'ou --model qwen2.5-coder:14b.
  if [[ -n "${LITELLM_VIRTUAL_KEY:-}" ]]; then
    info "Check fonctionnel via l'agent Claude Code (claude -p, backend LiteLLM)..."
    docker exec "$NAME" bash -lc "
      claude -p 'Cree le fichier _healthcheck_nu.txt a la racine du workspace contenant exactement: $HEALTH_TOKEN. Utilise l outil Bash.' \
        --model \"\${ANTHROPIC_MODEL:-qwen2.5-coder:14b}\" \
        --permission-mode acceptEdits \
        --dangerously-skip-permissions \
        --allowedTools 'Bash Write Read' \
      || true
    " 2>&1 | tee -a "$TP_RUN_LOG" || true
  else
    warn "LITELLM_VIRTUAL_KEY absente : fallback bash pur (preuve runtime conteneur)."
    docker exec "$NAME" bash -lc "printf '%s\n' '$HEALTH_TOKEN' > /workspace/_healthcheck_nu.txt"
  fi
}

run_agent_check

# Verification du resultat cote hote (workspace bind-monte).
if [[ -f "$HEALTH_FILE" ]] && grep -q "$HEALTH_TOKEN" "$HEALTH_FILE" 2>/dev/null; then
  ok "Check fonctionnel NU REUSSI : $HEALTH_FILE contient le jeton attendu."
else
  warn "Check fonctionnel NU : le fichier attendu n'a pas le jeton (cle LiteLLM absente/refusee, backend injoignable ?)."
  warn "Le profil NU reste lance et utilisable pour les attaques (step 05)."
fi

ok "Step 04 : profil NU lance et verifie."
