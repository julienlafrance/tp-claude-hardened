# 10 — LiteLLM (gateway) vs mitmproxy dédié — justification de conception

> Section d'argumentation pour le rapport : pourquoi, dans **cette** architecture, le
> proxy MITM dédié devient **redondant**, et quelles couches assurent réellement les
> quatre défenses attendues — provenance, destination, contenu, observabilité.

---

## 1. Le cas que le mitmproxy à terminaison TLS est censé couvrir

Le MITM défensif à terminaison TLS (le « proxy dans la VM » d'Anthropic) est la
mitigation d'**un cas précis** : celui où **l'egress doit inclure un domaine public
multi-tenant**. C'est l'incident **Claude Cowork** décrit par Anthropic :

> « Claude, following the instructions, read other files in the workspace and
> called Anthropic's Files API using the attacker's key. The egress proxy checked
> the destination, saw `api.anthropic.com`, and let it through. »
> — *Anthropic, « How we contain Claude across products »*

Trois conditions rendent l'attaque possible :

1. `api.anthropic.com` est **joignable en direct** depuis la sandbox ;
2. le proxy d'egress est un **simple filtre de destination** (il voit le host, pas l'identité) ;
3. la requête est **relayée telle quelle**, avec la **clé de l'attaquant** → upload vers le compte de l'attaquant.

Le MITM à terminaison TLS corrige (2) et (3) : il inspecte le trafic déchiffré,
valide la **provenance** (jeton de session provisionné par la VM) et **rejette
toute clé étrangère**, même vers une destination autorisée.

---

## 2. Cette architecture supprime le cas à la source

L'attaque suppose un **domaine public multi-tenant joignable en direct**. Or ici :

- **La seule destination d'egress est une gateway interne** (LiteLLM sur ixia),
  **pas** `api.anthropic.com`.
- Cette gateway **ré-authentifie en amont** avec sa **propre** clé (celle d'ixia)
  et **n'honore jamais** une clé fournie par le client.
- Le **réseau interdit le contournement** : le conteneur est sur un réseau Docker
  `--internal` (aucune route externe) + un **default-deny Incus/nftables** ; il ne
  peut atteindre **que** la gateway.

Le vecteur Cowork (clé attaquant relayée vers un domaine public) **n'existe donc
plus** : même si un agent compromis glisse une clé Anthropic dans la charge,
LiteLLM l'**ignore** et tape l'API avec la clé d'ixia ; et l'agent ne peut de
toute façon **pas** joindre `api.anthropic.com` en direct.

---

## 3. Qui assure quelle défense

| Défense attendue (rôle du MITM Anthropic) | Assurée ici par |
|---|---|
| **Provenance / identité** — rejeter une clé étrangère | **Ré-auth LiteLLM** : virtual key validée, clé cliente ignorée, appel amont avec la clé d'ixia |
| **Destination** — empêcher de joindre autre chose | **Verrou réseau** : Docker `--internal` + default-deny Incus/nftables |
| **Inspection de contenu** — canari, secret dans le corps | **Guardrails / logs LiteLLM** (côté ixia) |
| **Observabilité des tentatives** — tracer les deny | **Log de deny nftables** (+ logs LiteLLM) |

Les **deux défenses qui comptent** — provenance et destination — sont donc déjà
assurées, chacune par un composant **dédié et mieux placé** que le proxy :
la provenance là où vit le vrai crédentiel (la gateway), la destination là où se
fait le routage (le réseau).

---

## 4. Le seul rôle « en plus » d'un proxy — et pourquoi son gain est NUL ici

Le seul rôle **non** couvert par LiteLLM + réseau serait le **swap jeton-de-session ↔
virtual key** : garder la virtual key **hors de la sandbox** (l'agent ne détiendrait
qu'un jeton opaque qu'un proxy validerait puis substituerait par la vraie clé amont).
Dans **cette** architecture, ce swap n'apporte **rien** — voici pourquoi, point par point.

Le swap ne protège que **contre un seul scénario** : une virtual key qui **fuit** de la
sandbox et qu'un **tiers rejoue** contre la gateway. Or :

1. **L'egress est verrouillé** (`--internal`) : l'agent ne peut physiquement **rien**
   envoyer ailleurs qu'à la gateway → la clé **ne peut pas fuir**. Isoler la clé
   protège donc contre une fuite **qui ne peut pas se produire**.
2. **Le jeton de session = exactement la même capacité que la clé** : le proxy le
   re-substitue en amont, donc un agent compromis **fait la même chose** avec l'un ou
   l'autre. Le swap ne réduit **pas** ce qu'il peut *faire*, seulement à quoi
   *ressemble* une chaîne exfiltrée.
3. La virtual key est déjà **scopée et révocable** (modèles/budget/rate-limit/TTL) :
   même une fuite hypothétique aurait un impact **borné et tuable**.

Le swap n'a donc de valeur que **sans** verrou d'egress — c'est-à-dire dans le cas
**Cowork** (egress vers un domaine public multi-tenant non maîtrisé), précisément celui
qu'on a **supprimé** ici. **Gain résiduel du proxy dans cette architecture : nul.**

---

## 5. Décision de conception

Le **proxy MITM dédié est redondant** sur les deux défenses qui comptent
(identité → LiteLLM ; destination → réseau) et n'apporte **aucun** gain résiduel :
son seul rôle « en plus » (le swap clé-hors-sandbox) ne protège que contre une fuite
**rendue impossible par le verrou d'egress** (cf. §4). On retient donc :

- **Gateway LiteLLM ré-authentifiante** — provenance + scope + budget + audit ;
- **verrou réseau** `--internal` + default-deny Incus/nftables — destination ;
- **guardrails / logs LiteLLM** — contenu ; **log de deny nftables** — observabilité.

Le MITM à terminaison TLS reste **documenté** comme la mitigation *du cas qu'on a
précisément supprimé* (egress vers un domaine public multi-tenant). Le mentionner
montre qu'on a compris **pourquoi** Anthropic l'a déployé — et **pourquoi cette
architecture n'en a pas besoin**.

---

## 6. Réponse directe au bonus de l'énoncé

L'énoncé demande de « **proposer une correction** (proxy inspectant le contenu,
token de session scoppé, MITM défensif) ». Le verbe est **proposer** — et les
**trois** aspects listés sont fournis **nativement par LiteLLM**, un composant
réel et éprouvé, pas un proxy jouet :

| Aspect demandé | Fourni par LiteLLM |
|---|---|
| **MITM défensif** | Intermédiaire explicite (gateway) qui interpose, **termine** la connexion et **ré-authentifie** en amont avec la clé d'ixia (provenance) |
| **Token de session scopé** | Les **virtual keys** LiteLLM *sont* des jetons scopés : modèle(s) autorisé(s), budget, rate-limit, TTL, révocables |
| **Proxy inspectant le contenu** | LiteLLM voit et **journalise** le corps (audit) ; les **guardrails** (PII / canari) permettent l'inspection active |

Nuance d'honnêteté : l'inspection de contenu est, par défaut, de la **visibilité**
(logs), pas du blocage actif — ce qui est le bon choix sur le canal modèle
(bloquer un prompt contenant légitimement des données est intrusif et vain). Un
**guardrail canari** peut être activé pour la rendre démontrable ; les deux autres
aspects (provenance + jeton scopé) sont natifs et actifs.

**Conclusion :** démontrer qu'une gateway ré-authentifiante couvre ces trois
aspects — **plus** le verrou réseau pour la destination — est une correction
**complète** au sens de l'énoncé, et plus solide qu'un proxy MITM ad hoc.
