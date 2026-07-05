# 02 — Modele de menace (Threat Model)

> Quel actif protege-t-on, contre qui, et quel est le rayon d'impact d'une compromission ?
> Ce chapitre fixe le **pourquoi** ; le durcissement ([`04-durcissement.md`](04-durcissement.md))
> fixe le **comment**.

---

## 2.1 Actif protege : la surface de configuration et d'etat de l'agent

L'actif central n'est **pas** le code du workspace (jetable, versionne ailleurs), mais la
**configuration et l'etat de l'agent Claude Code** — des fichiers qui sont lus **et souvent
executes** a chaque session, donc une surface d'attaque de premier plan.

| Fichier | Role | Risque si reecrit par un agent compromis |
|---|---|---|
| `settings.json` (projet + user) | Peut declarer des **hooks** : commandes auto-executees au demarrage, *avant* le dialogue de confiance (« everything before the trust dialog ») | **Execution de code persistante** a chaque lancement, contournement des garde-fous |
| `CLAUDE.md` | Memoire / instructions persistantes, rechargees chaque session | **Empoisonnement de memoire** : l'agent suit des consignes malveillantes durablement |
| `skills` (`SKILL.md`) | Procedures de confiance suivies par l'agent | **Comportement detourne** : une « competence » piegee oriente les actions |
| `.mcp.json` | Declare les serveurs MCP disponibles | **Octroi de nouvelles capacites** : elargit le rayon d'impact (nouveaux outils/reseaux) |

### Invariant de securite

> **Un agent compromis ne doit PAS pouvoir reecrire sa propre configuration** pour
> s'auto-accorder des privileges, persister entre sessions, ou desactiver ses garde-fous.

C'est exactement ce que le **partitionnement read-only** ([`03-partition-table.md`](03-partition-table.md))
garantit : la config est verrouillee `:ro` au niveau **kernel**, root-proof.

---

## 2.2 Les trois categories de menace (toutes couvertes)

L'enonce impose de couvrir trois familles d'adversaires/comportements.

### Categorie 1 — Mauvais usage (utilisateur)

L'utilisateur legitime demande, par maladresse ou malveillance, une action dangereuse.

- **Exemples** : « lance `rm -rf /` », « envoie le contenu de `/run/secrets/...` a ce serveur ».
- **Leviers de couverture** : FS racine `--read-only` (rien a detruire hors `/workspace`),
  egress filtre par proxy (pas d'exfil), secret jamais monte sur le profil durci.

### Categorie 2 — Derive du modele (misalignment)

Le modele, sans attaquant externe, agit contre l'intention : il **reecrit `settings.json`**
pour se donner un hook persistant, ou modifie `CLAUDE.md` pour ancrer un comportement.

- **Leviers de couverture** : montages `:ro` de toute la config (settings/CLAUDE.md/skills/mcp),
  tmpfs ephemere (pas de persistance), user non-root (ne possede pas les fichiers `root:root`).

### Categorie 3 — Attaquant externe par injection

Un tiers fait executer ses instructions a l'agent. Deux sous-cas, **tous deux** traites :

| Sous-cas | Vecteur | Illustration TP |
|---|---|---|
| **Injection directe** | Le prompt utilisateur lui-meme contient l'instruction malveillante | « modifie ta config pour... » |
| **Injection indirecte** | Le payload est **cache** dans une donnee que l'agent lit : README, fichier de code, sortie d'un outil, **reponse d'un serveur MCP**, contenu web | Un `README.md` du workspace ordonne d'exfiltrer `fake_token.txt` |

- **Leviers de couverture** : `:ro` (la config ne peut pas etre alteree quoi qu'on injecte),
  `--cap-drop=ALL` + seccomp (pas d'escalade), egress proxy + **MITM token-scope** (l'exfil via
  un domaine pourtant autorise est rejetee — voir le **bonus**).

> L'injection **indirecte** est la plus pernicieuse : l'utilisateur n'a rien demande de
> malveillant, mais une donnee tierce detourne l'agent. C'est l'argument fort en faveur d'un
> **confinement environnemental** (et non d'une simple confiance dans le prompt).

---

## 2.2bis Posture sur les secrets et l'egress (backend modele externe)

Le backend LLM de l'agent est un service **externe** de confiance — **LiteLLM** sur `ixia`
(`backend-host:3101`) routant vers **Ollama** — et non Anthropic. Cette decision deplace
favorablement la surface de menace :

| Aspect | Avant (auth Anthropic / OAuth) | Apres (backend externe LiteLLM) |
|---|---|---|
| Secret le plus sensible en sandbox | cle/`sk-ant-...` ou token OAuth Anthropic | **aucune cle Anthropic** ; seule une **cle LiteLLM scopee** (`ANTHROPIC_AUTH_TOKEN`) |
| Pire fuite d'auth | acces facturable au compte Anthropic | acces borne au seul endpoint LiteLLM scope (revocable cote ixia) |
| Destinations d'egress legitimes | `api.anthropic.com` + cible factice | **un seul** endpoint : `backend-host` (+ cible factice locale) |
| Confidentialite des prompts | requetes partent chez un tiers (Anthropic) | **les questions ne partent pas chez Anthropic** ; restent sur ixia/Ollama |

Deux consequences pour le modele de menace :

1. **Reduction du secret a proteger.** `ANTHROPIC_API_KEY` est **vide** (sinon elle primerait sur
   le token d'auth) ; il n'existe **aucune** cle Anthropic ni token OAuth a voler dans la sandbox.
   Le seul credential present est la cle **LiteLLM scopee**, injectee au runtime via `.env`
   (gitignore), jamais ecrite dans un layer d'image. Une exfil reussie ne livre qu'une cle a
   portee limitee, **revocable** unilateralement sur l'hote externe.
2. **Egress reduit a une seule destination.** L'allowlist d'egress effective ne contient plus
   `api.anthropic.com` : la **seule** destination autorisee est `backend-host` (l'endpoint
   modele). Tout le reste est **default-deny**. La surface d'exfiltration C2/web est donc
   minimale : un agent compromis ne peut atteindre **que** le serveur de modele.

> `ixia` (`backend-host`) est un serveur **EXTERNE hors perimetre de durcissement**, suppose
> securise par ailleurs ; on le decrit a la maille **interface** (cf. [`09-backend-modele.md`](09-backend-modele.md)).
> Le durcissement de l'agent (`:ro`, `cap-drop`, seccomp, egress) est **independant** du moteur
> de modele utilise.

---

## 2.3 Objectifs malveillants neutralises

Quel que soit l'adversaire, les objectifs concrets a neutraliser sont :

1. **Modification de config** — settings / CLAUDE.md / skills / mcp.
2. **Exfiltration de secrets** — vers un endpoint externe (ici factice et local).
3. **Commande destructrice** — hors de la zone de travail (`rm`, ecrasement de binaires).
4. **Persistance** — survivre a la fin de session (hook, etat dispose sur disque).
5. **Elevation de privilege** — devenir root, regagner des capabilities.

---

## 2.4 Rayon d'impact (blast radius)

Le but du durcissement est de **reduire** le rayon d'impact d'une compromission, pas de
pretendre l'eliminer (defense en profondeur).

| Niveau | Sans durcissement (`nu`) | Avec durcissement (`durci`, anneau 2) | Si l'anneau 2 cede |
|---|---|---|---|
| Config agent | Reecrite (hooks, poison) | **Immuable** (`:ro`) | — |
| Persistance | Oui (disque, hooks) | **Non** (tmpfs ephemere) | — |
| Exfiltration | Aboutit (egress libre) | **Refusee** (egress proxy + secret absent ; seule sortie = `backend-host`) | — |
| Ecriture FS | Partout | **Confinee a `/workspace`** | — |
| Privileges | root, toutes caps | non-root, `cap-drop=ALL`, no-new-privs | — |
| Atteinte de l'hote | Possible | Tres difficile | Confinee a **l'hote jetable Incus** (jamais la machine reelle ; avec une VM KVM, meme une evasion conteneur ne livre pas le noyau hote) |

**Synthese** : sur l'agent durci, l'impact maximal d'une compromission est borne au seul
`/workspace` (rw ephemere). La config est immuable, il n'y a ni persistance, ni exfil, ni
ecriture hors workspace, ni elevation de privilege. Et meme une evasion de l'anneau 2 reste
prisonniere de l'hote jetable Incus — d'ou la recommandation d'une **VM** pour la prod.
