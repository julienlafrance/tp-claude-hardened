#!/usr/bin/env bash
# Test de la parade `global_disable_no_log_param: true` (LiteLLM, ixia) :
#   1. sauvegarde la config, ajoute le réglage sous litellm_settings, redémarre
#   2. envoie T5 (témoin) et T6 ("no-log": true) avec la clé du TP (qwen3:8b)
#   3. vérifie en base que T6 laisse bien une ligne
#   4. si la parade fonctionne : on GARDE le réglage ; sinon : config d'origine restaurée
set -uo pipefail
cd /home/julien/projet/cyber/tp; set -a; . .secret/litellm.env; set +a
CFG=/home/docker/litellm/litellm_config.yaml
BAK=$CFG.bak-20260923-avant-nolog-parade
RUN=$(date +%H%M%S)
wait_up() { ssh -o BatchMode=yes ixia 'for i in $(seq 1 60); do curl -s -o /dev/null -w "%{http_code}" localhost:3101/health/liveliness | grep -q 200 && exit 0; sleep 3; done; exit 1'; }
KEEP=0
finish() {
  if [ "$KEEP" = 1 ]; then echo "== parade EFFICACE : réglage CONSERVÉ (backup: $BAK)"
  else echo "== parade non prouvée : restauration"; ssh -o BatchMode=yes ixia "cp -p $BAK $CFG && docker restart litellm >/dev/null" && wait_up && echo "LiteLLM UP (config d'origine)"; fi
  ssh -o BatchMode=yes ixia "grep -nE 'global_disable_no_log_param|store_prompts' $CFG || echo '(aucun des deux réglages)'"
}

echo "== 1. activation"
ssh -o BatchMode=yes ixia "cp -p $CFG $BAK && python3 -c '
p=\"$CFG\"; s=open(p).read(); a=\"litellm_settings:\n\"; assert s.count(a)==1
open(p,\"w\").write(s.replace(a, a+\"  global_disable_no_log_param: true\n\"))' && docker restart litellm >/dev/null" || { echo "échec activation"; exit 1; }
trap finish EXIT
wait_up && echo "LiteLLM UP (global_disable_no_log_param activé)" || exit 1

send() {
  B=$(jq -nc --arg c "$2" --argjson x "${3:-{\}}" '{model:"qwen3:8b",max_tokens:5,messages:[{role:"user",content:$c}]} + $x')
  curl -s -m 150 -o /dev/null -w "$1 -> HTTP %{http_code}\n" "$LITELLM_ENDPOINT/v1/messages" \
    -H "Authorization: Bearer $LITELLM_VIRTUAL_KEY" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -d "$B"
}
T0=$(ssh -o BatchMode=yes ixia 'date -u +"%Y-%m-%d %H:%M:%S"')
echo "== 2. requêtes (run $RUN, depuis $T0 UTC)"
send T5-temoin "Reponds OK. temoin $RUN"
send T6-nolog  "Reponds OK. nolog $RUN" '{"no-log":true}'

echo "== 3. lignes en base depuis $T0 (clé du TP, attente max 3 min)"
for i in $(seq 1 36); do
  N=$(ssh -o BatchMode=yes ixia "U=\$(docker exec litellm-db printenv POSTGRES_USER); D=\$(docker exec litellm-db printenv POSTGRES_DB); docker exec -i litellm-db psql -U \$U -d \$D -At" <<SQL
select count(*) from "LiteLLM_SpendLogs" where "startTime" >= '$T0' and metadata->>'user_api_key_alias'='tp-claude-durci';
SQL
)
  [ "${N:-0}" -ge 2 ] && break; sleep 5
done
echo "lignes: $N (attendu 2 si la parade marche : témoin + no-log ; 1 si no-log efface encore)"
[ "${N:-0}" -ge 2 ] && KEEP=1
