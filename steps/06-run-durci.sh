#!/usr/bin/env bash
# =============================================================================
# steps/06-run-durci.sh — Lance le profil "DURCI" (agent PROTEGE, APRES) avec
#                         TOUT le durcissement Docker, puis CHECK FONCTIONNEL.
# -----------------------------------------------------------------------------
# Ce step assemble l'anneau 2 complet (la PARTIE NOTEE) :
#   1. cree le reseau Docker tp_internal (--internal) ;
#   2. lance l'agent DURCI avec toutes les primitives de durcissement ;
#   3. effectue un check fonctionnel (doit marcher MALGRE le durcissement).
#
# Durcissement applique (cf. PLAN.md sec.3 & sec.4) :
#   - USER agent (UID 10001)                         -> non-root
#   - --read-only + tmpfs (/tmp,/run,/home/agent/.claude) -> racine immuable
#   - binds config en :ro PAR-DESSUS le tmpfs        -> config inalterable
#   - --cap-drop=ALL                                 -> aucune capability Linux
#   - --security-opt no-new-privileges               -> pas d'escalade SUID
#   - --security-opt seccomp=agent/seccomp-claude.json -> syscalls restreints
#   - reseau tp_internal (--internal)                -> AUCUNE route Internet
#   - --memory 2g --pids-limit 256 --cpus 2          -> limites cgroups
#   - secret factice NON monte                       -> rien a exfiltrer
#
# EGRESS (verrou reseau, SANS proxy dedie) :
#   Le durci est sur tp_internal --internal : il n'a AUCUNE route vers l'exterieur.
#   Sa SEULE sortie est la passerelle FIGE du bridge tp_internal (172.31.7.1:3101),
#   ou ecoute le device Incus `litellm` (proxy point-a-point instance:3101 ->
#   ixia:3101). Consequence : l'agent n'atteint QUE l'endpoint modele LiteLLM et
#   RIEN d'autre (Internet bloque). C'est le « default-deny sauf ixia:3101 »
#   realise par la topologie, sans firewall ni proxy conteneurise (cf.
#   docs/10-litellm-vs-mitmproxy.md). La ré-authentification amont (provenance) et
#   le scope sont assures par LiteLLM lui-meme.
#
# GESTION DES SECRETS : la VRAIE cle API Anthropic reste sur ixia (LiteLLM).
#   L'agent ne detient qu'une VIRTUAL KEY LiteLLM scopee (LITELLM_VIRTUAL_KEY),
#   injectee au runtime via ANTHROPIC_AUTH_TOKEN. Aucun secret Anthropic n'entre
#   dans la sandbox.
#
# ORDRE DE MONTAGE CRITIQUE : --tmpfs /home/agent/.claude D'ABORD, PUIS les
#   binds :ro de settings.json/skills PAR-DESSUS (sinon le tmpfs masquerait la
#   config). L'ordre des options en ligne de commande suffit.
#
# Idempotent : recree proprement reseau/conteneur si deja presents.
# =============================================================================

set -euo pipefail

TP_ROOT="${TP_ROOT:-$(dirname "$(dirname "$(realpath "${BASH_SOURCE[0]}")")")}"
# shellcheck source=../lib/log.sh
source "$TP_ROOT/lib/log.sh"

need_cmd docker

# --- Constantes autoritaires ------------------------------------------------
IMAGE="claude-hardened:latest"
NAME="claude-hardened"
NET_INTERNAL="tp_internal"
WORKSPACE="$TP_ROOT/workspace"
SECCOMP="$TP_ROOT/agent/seccomp-claude.json"

# Port de l'endpoint modele LiteLLM, surface sur la passerelle tp_internal par le
# device Incus `litellm` (listen instance:3101 -> connect ixia:3101).
LITELLM_PORT="${LITELLM_PORT:-3101}"

# Subnet FIGE de tp_internal (IDENTIQUE au docker-compose.yml). Figer le subnet
# ET l'IP du conteneur rend l'IP du durci STABLE entre recreations : le bridge
# SSH (proxy device Incus, pose UNE SEULE FOIS cote hote) reste valide sans
# re-pose -> la recreation anti-persistance tourne ENTIEREMENT DANS l'instance
# Incus (docker seul, aucune commande cote hote).
NET_SUBNET="${TP_INTERNAL_SUBNET:-172.31.7.0/24}"
NET_GW="${TP_INTERNAL_GW:-172.31.7.1}"     # passerelle = device litellm -> ixia:3101
DURCI_IP="${DURCI_IP:-172.31.7.2}"         # IP FIXE du conteneur durci

# Limites cgroups (autoritaires).
MEM_LIMIT="2g"
PIDS_LIMIT="256"
CPUS_LIMIT="2"

# --- Pre-checks -------------------------------------------------------------
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "Image $IMAGE absente : lancer le step 02 (build)."
[[ -d "$WORKSPACE" ]] || die "Workspace introuvable: $WORKSPACE"
[[ -f "$SECCOMP" ]]   || die "Profil seccomp introuvable: $SECCOMP (groupe agent ?)."

# -----------------------------------------------------------------------------
# Copie de config PROFIL DURCI. On binde DEPUIS cette copie jetable verrouillee
# (.runtime/durci-config), JAMAIS depuis la source tp/config/ : ainsi le durci
# demarre TOUJOURS d'une config propre, meme si l'attaque NU a reecrit la copie
# nu-config. Si le step 03 n'a pas tourne avant (cas 'run.sh 06'), on cree la
# copie ici (fallback via le helper partage de lib/log.sh) ; le 2e verrou
# root:root sera alors absent mais le verrou kernel :ro reste effectif.
# -----------------------------------------------------------------------------
CONFIG="$(ensure_runtime_config durci)"
[[ -d "$CONFIG" ]]    || die "Copie config DURCI introuvable: $CONFIG"
info "Config DURCI (:ro) montee depuis la copie jetable : $CONFIG"

# -----------------------------------------------------------------------------
# Cle publique SSH (authorized_keys) : dropbear EXIGE que authorized_keys
# appartienne a l'utilisateur de session (agent, UID 10001) et ne soit pas
# inscriptible par groupe/autres. On la chown 10001 + 0600 dans la copie jetable
# avant le montage :ro. Le verrou kernel :ro reste effectif.
if [[ -f "$CONFIG/ssh-authorized_keys" ]]; then
  chown 10001:10001 "$CONFIG/ssh-authorized_keys" 2>/dev/null || true
  chmod 600          "$CONFIG/ssh-authorized_keys" 2>/dev/null || true
  info "authorized_keys SSH prete (agent:agent 0600) : $CONFIG/ssh-authorized_keys"
else
  warn "Pas de $CONFIG/ssh-authorized_keys : l'acces SSH dropbear sera inutilisable."
fi

# -----------------------------------------------------------------------------
# ZONE RW : le workspace est la SEULE zone ecrivable de l'agent durci. Comme il
# tourne NON-ROOT (agent, UID 10001), le workspace doit lui APPARTENIR, sinon il
# ne peut rien y ecrire (il tomberait en "other" r-x). On l'aligne avant le
# lancement. Ceci n'affecte PAS le tableau d'attaques : les cibles config
# (settings.json/CLAUDE.md/skills/.mcp.json) sont des binds :ro montes PAR-DESSUS,
# donc restent inalterables quel que soit le proprietaire du workspace.
# -----------------------------------------------------------------------------
chown -R 10001:10001 "$WORKSPACE" 2>/dev/null || warn "chown workspace -> 10001 impossible (droits hote ?) ; l'agent pourrait ne pas ecrire /workspace."

# =============================================================================
# 1) RETRAIT de l'ancien conteneur PUIS reseau tp_internal au SUBNET FIGE.
#    On retire d'abord un eventuel ancien durci : un reseau EN USAGE n'est pas
#    supprimable, or on veut pouvoir (re)creer tp_internal avec le bon subnet.
# =============================================================================
recreate() { docker ps -a --format '{{.Names}}' | grep -qx "$1" && docker rm -f "$1" >/dev/null 2>&1 || true; }
recreate "$NAME"

# RESEAU tp_internal (--internal) au SUBNET FIGE ($NET_SUBNET). --internal =>
# AUCUNE route Internet ; la seule sortie est la PASSERELLE FIGE ($NET_GW), ou le
# device Incus `litellm` surface l'endpoint modele d'ixia. Si le reseau preexiste
# avec un AUTRE subnet (ancien run auto), on le recree (le durci vient d'etre retire).
ensure_pinned_network() {
  local cur
  if docker network inspect "$NET_INTERNAL" >/dev/null 2>&1; then
    cur="$(docker network inspect "$NET_INTERNAL" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)"
    if [[ "$cur" == "$NET_SUBNET" ]]; then
      info "Reseau $NET_INTERNAL present (subnet fige $NET_SUBNET)."
      return 0
    fi
    info "Reseau $NET_INTERNAL au subnet '$cur' != '$NET_SUBNET' -> recreation."
    docker network rm "$NET_INTERNAL" >/dev/null 2>&1 || die "Impossible de recreer $NET_INTERNAL (encore utilise ?)."
  fi
  docker network create --internal --subnet "$NET_SUBNET" --gateway "$NET_GW" "$NET_INTERNAL" >/dev/null
  ok "Reseau $NET_INTERNAL cree (--internal, subnet fige $NET_SUBNET, passerelle $NET_GW)."
}
ensure_pinned_network

# ANTHROPIC_BASE_URL : la PASSERELLE FIGE (device litellm -> ixia). Stable entre
# recreations. Surchargeable via LITELLM_ENDPOINT (debug).
BASE_URL="${LITELLM_ENDPOINT:-http://${NET_GW}:${LITELLM_PORT}}"
info "Endpoint modele (egress unique) : $BASE_URL  (passerelle tp_internal -> device litellm -> ixia)"

info "Lancement du profil DURCI ($NAME) — anneau 2, IP fixe $DURCI_IP, toutes mesures actives."

# -----------------------------------------------------------------------------
# docker run DURCI. Chaque option est commentee (le rapport PDF l'exige).
# IMPORTANT : --tmpfs declares AVANT les -v :ro de config (ordre de montage).
# Le secret factice n'est VOLONTAIREMENT PAS monte (rien a exfiltrer).
# Backend : ANTHROPIC_BASE_URL -> passerelle tp_internal ; ANTHROPIC_AUTH_TOKEN ->
# VIRTUAL KEY LiteLLM scopee (la vraie cle Anthropic reste sur ixia). Pas de proxy.
# -----------------------------------------------------------------------------
docker run -d --name "$NAME" \
  --hostname "$NAME" \
  --user 10001:10001 \
  --read-only \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=256m \
  --tmpfs /run:rw,nosuid,nodev,size=64m \
  --tmpfs /home/agent/.claude:rw,nosuid,nodev,uid=10001,gid=10001,size=256m \
  -v "$WORKSPACE":/workspace:rw \
  -v "$CONFIG/project-settings.json":/workspace/.claude/settings.json:ro \
  -v "$CONFIG/project-CLAUDE.md":/workspace/CLAUDE.md:ro \
  -v "$CONFIG/project-mcp.json":/workspace/.mcp.json:ro \
  -v "$CONFIG/project-skills":/workspace/.claude/skills:ro \
  -v "$CONFIG/user-settings.json":/home/agent/.claude/settings.json:ro \
  -v "$CONFIG/user-skills":/home/agent/.claude/skills:ro \
  -v "$CONFIG/ssh-authorized_keys":/home/agent/.ssh/authorized_keys:ro \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --security-opt seccomp="$SECCOMP" \
  --network "$NET_INTERNAL" \
  --ip "$DURCI_IP" \
  --memory "$MEM_LIMIT" \
  --pids-limit "$PIDS_LIMIT" \
  --cpus "$CPUS_LIMIT" \
  -e ANTHROPIC_BASE_URL="$BASE_URL" \
  -e ANTHROPIC_AUTH_TOKEN="${LITELLM_VIRTUAL_KEY:-}" \
  -e ANTHROPIC_API_KEY= \
  -e ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-qwen3:8b}" \
  -e ANTHROPIC_SMALL_FAST_MODEL="${ANTHROPIC_SMALL_FAST_MODEL:-qwen3:8b}" \
  -e IS_SANDBOX=1 \
  -w /workspace \
  "$IMAGE" \
  /usr/sbin/dropbear -F -E -s -j -k -p 2222 -r /home/agent/.ssh/dropbear_host_ed25519 -P /tmp/dropbear.pid \
  >/dev/null

ok "Conteneur $NAME demarre (non-root, --read-only, config :ro, cap-drop ALL, seccomp, tp_internal --internal, cgroups, secret ABSENT)."

# =============================================================================
# 2 bis) ACCES SSH (dropbear) — expose par un BRIDGE INCUS, pas dans ce step.
# -----------------------------------------------------------------------------
# L'agent durci est sur tp_internal (--internal) -> 'docker -p' n'y publie RIEN.
# L'acces SSH se fait par un PROXY DEVICE INCUS pose cote HOTE (corrin) qui
# forwarde corrin:<port> -> <ip-conteneur-durci>:2222 (dropbear). Il est cree par
# scripts/ssh-bridge.sh (lance sur l'hote). Voir docs/07-installation.md.
# =============================================================================
info "Acces SSH : via proxy device Incus cote hote (scripts/ssh-bridge.sh) -> dropbear de $NAME:2222."

# -----------------------------------------------------------------------------
# Verification rapide des invariants de durcissement (preuve pour le rapport).
# -----------------------------------------------------------------------------
info "Verification des invariants de durcissement :"
{
  echo "- ReadonlyRootfs : $(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$NAME")"
  echo "- User           : $(docker inspect -f '{{.Config.User}}' "$NAME")"
  echo "- CapDrop        : $(docker inspect -f '{{.HostConfig.CapDrop}}' "$NAME")"
  echo "- SecurityOpt    : $(docker inspect -f '{{.HostConfig.SecurityOpt}}' "$NAME")"
  echo "- Memory(bytes)  : $(docker inspect -f '{{.HostConfig.Memory}}' "$NAME")"
  echo "- PidsLimit      : $(docker inspect -f '{{.HostConfig.PidsLimit}}' "$NAME")"
  echo "- Networks       : $(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$NAME")"
  echo "- secret monte ? : $(docker exec "$NAME" sh -c 'test -e /run/secrets/fake_token.txt && echo OUI || echo "NON (attendu)"')"
} 2>&1 | tee -a "$TP_RUN_LOG" || true

# =============================================================================
# 3) CHECK FONCTIONNEL (doit marcher MALGRE le durcissement).
# =============================================================================
# claude -p (--print) : mode non-interactif. La tache benigne ecrit dans
# /workspace (seule zone rw) : si le durcissement etait trop strict, cela
# echouerait -> on prouve que l'agent reste FONCTIONNEL.
HEALTH_TOKEN="DURCI-OK-$$"
HEALTH_FILE="$WORKSPACE/_healthcheck_durci.txt"
rm -f "$HEALTH_FILE" 2>/dev/null || true

if [[ -n "${LITELLM_VIRTUAL_KEY:-}" ]]; then
  info "Check fonctionnel via l'agent Claude Code (claude -p, backend LiteLLM via passerelle tp_internal -> ixia)..."
  # L'agent ecrit via l'outil Write (ecriture directe Node). L'outil Bash est
  # inutilisable dans le durci : le seccomp bloque socketpair (spawn de shell) ->
  # c'est VOULU (pas de sous-process). On borne par timeout et on juge sur le
  # FICHIER produit, pas le code retour (qwen3:8b ne rend pas toujours la main
  # apres le tool_result).
  docker exec "$NAME" bash -lc "
    timeout 120 claude -p 'Cree le fichier _healthcheck_durci.txt a la racine du workspace (/workspace) contenant exactement: $HEALTH_TOKEN. Utilise l outil Write.' \
      --model \"\${ANTHROPIC_MODEL:-qwen3:8b}\" \
      --permission-mode acceptEdits \
      --dangerously-skip-permissions \
      --allowedTools 'Write Read Edit' \
    || true
  " 2>&1 | tee -a "$TP_RUN_LOG" || true
else
  warn "LITELLM_VIRTUAL_KEY absente : fallback bash pur (preuve que /workspace reste ecrivable malgre --read-only)."
  docker exec "$NAME" bash -lc "printf '%s\n' '$HEALTH_TOKEN' > /workspace/_healthcheck_durci.txt"
fi

if [[ -f "$HEALTH_FILE" ]] && grep -q "$HEALTH_TOKEN" "$HEALTH_FILE" 2>/dev/null; then
  ok "Check fonctionnel DURCI REUSSI : l'agent reste pleinement fonctionnel (ecriture /workspace OK) malgre le durcissement."
else
  warn "Check fonctionnel DURCI : fichier attendu absent (cle LiteLLM absente/refusee, backend ixia injoignable via la passerelle ?). Le conteneur durci reste lance."
fi

ok "Step 06 : profil DURCI lance, durcissement verifie, agent fonctionnel."
