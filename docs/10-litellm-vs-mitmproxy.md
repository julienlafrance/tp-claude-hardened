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

## 4. Ce qu'il reste au proxy dédié — et pourquoi c'est marginal

Le seul rôle **non** couvert par LiteLLM + réseau est le **swap jeton-de-session ↔
virtual key** : garder la virtual key **hors de la sandbox** (l'agent ne détient
qu'un jeton opaque, cf. [`addon.py`](../proxy/addon.py) — validation `SESSION_TOKEN`
puis substitution `UPSTREAM_AUTH_TOKEN`). C'est un incrément **réel mais non
catégoriel** :

- son bénéfice ne se matérialise que si un crédentiel peut **fuir** — or l'egress
  est déjà verrouillé ;
- on obtient ~la même propriété **sans proxy** avec une virtual key **courte,
  scopée et révocable** injectée au runtime — ce que l'énoncé demande déjà
  (« injecter par variable d'environnement scoping minimal au runtime »).

---

## 5. Décision de conception

Le **proxy MITM dédié est redondant** sur les deux défenses qui comptent
(identité → LiteLLM ; destination → réseau) et n'apporte qu'un gain **marginal**
(clé hors sandbox). On retient donc :

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
