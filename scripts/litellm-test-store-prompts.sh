#!/usr/bin/env bash
# Test de store_prompts_in_spend_logs sur LiteLLM (ixia) :
#   1. sauvegarde la config, active l'option, redémarre LiteLLM
#   2. envoie 4 requêtes marquées (qwen3:8b, local) avec la clé du TP
#   3. lit la base : le marqueur est-il conservé ?
#   4. REMET la config d'origine et redémarre (pas de capture durable d'Open WebUI)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1; set -a; . .secret/litellm.env; set +a
CFG=/home/docker/litellm/litellm_config.yaml
BAK=$CFG.bak-20260923-avant-store-prompts
RUN=$(date +%H%M%S)
wait_up() { ssh -o BatchMode=yes ixia 'for i in $(seq 1 60); do curl -s -o /dev/null -w "%{http_code}" localhost:3101/health/liveliness | grep -q 200 && exit 0; sleep 3; done; exit 1'; }
restore() {
  echo "== restauration de la config d'origine"
  ssh -o BatchMode=yes ixia "cp -p $BAK $CFG && docker restart litellm >/dev/null" && wait_up && echo "LiteLLM UP (config d'origine)"
  ssh -o BatchMode=yes ixia "grep -c store_prompts $CFG" | sed 's/^/occurrences store_prompts restantes: /'
}

echo "== 1. activation"
ssh -o BatchMode=yes ixia "cp -p $CFG $BAK && python3 -c '
p=\"$CFG\"; s=open(p).read(); a=\"general_settings:\n\"; assert s.count(a)==1
open(p,\"w\").write(s.replace(a, a+\"  store_prompts_in_spend_logs: true\n\"))' && docker restart litellm >/dev/null" || { echo "échec activation"; exit 1; }
trap restore EXIT
wait_up && echo "LiteLLM UP (store_prompts activé)"

send() { # $1=tag  $2=contenu  $3=json extra (fusionné au corps)
  B=$(jq -nc --arg c "$2" --argjson x "${3:-{\}}" '{model:"qwen3:8b",max_tokens:5,messages:[{role:"user",content:$c}]} + $x')
  curl -s -m 150 -o /dev/null -w "$1 -> HTTP %{http_code}\n" "$LITELLM_ENDPOINT/v1/messages" \
    -H "Authorization: Bearer $LITELLM_VIRTUAL_KEY" -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -d "$B"
}
M=FAKE-CORP-TOKEN-do-not-exfiltrate-1337
PAD=$(head -c 5000 /dev/zero | tr '\0' 'x')
echo "== 2. requêtes (run $RUN)"
send T1-court   "Reponds OK. $M-T1-$RUN"
send T2-milieu  "Reponds OK. $PAD $M-T2-$RUN $PAD"
send T3-fin     "Reponds OK. $PAD$PAD $M-T3-$RUN"
send T4-nolog   "Reponds OK. $M-T4-$RUN" '{"no-log":true}'

echo "== 3. lecture de la base (attente de l'écriture des logs, max 3 min)"
for _ in $(seq 1 36); do
  # shellcheck disable=SC2087  # expansion cote client voulue ($RUN/$T0)
  OUT=$(ssh -o BatchMode=yes ixia "U=\$(docker exec litellm-db printenv POSTGRES_USER); D=\$(docker exec litellm-db printenv POSTGRES_DB); docker exec -i litellm-db psql -U \$U -d \$D -At" <<SQL
select t, count(*) filter (where txt like '%'||t||'-$RUN%') from (values ('T1'),('T2'),('T3'),('T4')) v(t)
 cross join (select messages::text||' '||proxy_server_request::text as txt from "LiteLLM_SpendLogs" where "startTime" > now() - interval '15 minutes') s group by t order by t;
select 'lignes_15min', count(*), sum((length(messages::text)>2)::int) from "LiteLLM_SpendLogs" where "startTime" > now() - interval '15 minutes';
select 'troncature_T2', position('litellm_truncated' in messages::text)>0 from "LiteLLM_SpendLogs" where messages::text like '%xxxxxxxx%' and "startTime" > now() - interval '15 minutes' limit 3;
SQL
)
  echo "$OUT" | grep -q '^lignes_15min|[4-9]' && break; sleep 5
done
echo "$OUT"
