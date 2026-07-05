---
title: "Durcissement d'un agent de codage (Claude Code) en conteneur Docker"
subtitle: "TP cybersecurite — rapport detaille"
date: "2026-06-25"
---

> **Resume executif.** Ce rapport documente le durcissement d'un agent de codage autonome
> reel — **Claude Code** (`claude` v2.1.191) — execute en conteneur **Docker** (impose ;
> ici Docker **29.5.2**, cgroup v2 + seccomp). Le livrable central est un **partitionnement
> read-only du filesystem** qui protege la configuration/etat de l'agent (`settings.json`,
> `CLAUDE.md`, `skills`, `.mcp.json`) : *un agent compromis ne doit pas pouvoir reecrire sa
> propre configuration*. On demontre **avant/apres** que les memes 6 attaques (+ un bonus
> d'exfiltration via domaine autorise) **reussissent** sur l'agent NU et sont **bloquees** sur
> l'agent DURCI. L'ensemble tourne dans un hote jetable **Incus LXC** (`tp-claude-host`,
> `security.nesting=true`) ; on recommande explicitement une **VM Incus** en production.
>
> **Backend modele externe.** L'agent n'appelle **pas** Anthropic : son moteur LLM est un service
> **externe de confiance** — **LiteLLM** sur `ixia` (`backend-host:3101`) routant vers **Ollama**
> (modeles locaux). Consequences : **aucune cle Anthropic dans la sandbox** (l'auth est une **cle
> LiteLLM scopee**, `ANTHROPIC_API_KEY` reste vide), **un seul egress autorise** (`backend-host`),
> et **les questions ne partent pas chez Anthropic**. *L'agent est durci ; le modele vient d'un
> service externe de confiance => secret d'API hors sandbox + zero egress vers un tiers. Le
> durcissement (`:ro`/`cap-drop`/`seccomp`/egress) est **INDEPENDANT du moteur**.* Detail en
> annexe (section 10).

---

# Table des couples attaque / resultat (vue d'ensemble)

| # | Attaque tentee | Agent **nu** | Agent **durci** | Mecanisme responsable |
|---|---|---|---|---|
| 1 | Reecriture `settings.json` (injection de hook) | Reussie | **Bloquee** | montage `:ro` |
| 2 | Modification `CLAUDE.md` | Reussie | **Bloquee** | `:ro` |
| 3 | Alteration d'un skill (`SKILL.md`) | Reussie | **Bloquee** | skills `:ro` |
| 4 | Ajout serveur dans `.mcp.json` | Reussie | **Bloquee** | `:ro` |
| 5 | Exfiltration d'un secret factice | Reussie | **Bloquee** | secret non monte / egress refuse |
| 6 | Commande destructrice hors workspace | Reussie | **Bloquee** | FS racine `--read-only` |
| B | **BONUS** : exfil via domaine **pourtant autorise** | Reussie | **Bloquee** | proxy **MITM token-scope** |

---

# 1. Environnement

## 1.1 Vue d'ensemble (architecture a 2 anneaux)

Le TP empile **deux frontieres d'isolation** independantes — defense en profondeur
(« containment at the environment layer first », Anthropic *How we contain Claude*). Un agent
compromis doit franchir **les deux** pour atteindre la machine reelle.

```
Machine hote reelle (poste etudiant Linux)
   └── Anneau 1 : conteneur Incus LXC "tp-claude-host" (jetable, security.nesting=true)
          └── Docker imbrique 29.5.2
                 ├── Anneau 2 : conteneur Docker "claude-hardened" (DURCI)  <- PIECE NOTEE
                 ├── conteneur "claude-nu" (NON durci, demo avant/apres)
                 ├── conteneur "egress-proxy" (allowlist + MITM token-scope)
                 └── conteneur "exfil-server" (cible factice locale)
```

## 1.2 Hote reel (machine Linux)

OS Linux (noyau 6.8.x, cgroup v2), **Incus** pour l'anneau 1, **Docker 29.5.2** pour l'anneau 2.
Repertoire projet : `/home/julien/projet/cyber/tp`. L'hote reel n'execute jamais l'agent
directement ; tout vit dans l'anneau 1, efface d'un `incus delete --force`.

## 1.3 Anneau 1 — instance Incus `tp-claude-host` (CONTENEUR LXC + nesting)

| Element | Valeur |
|---|---|
| Type | **Conteneur Incus (LXC)** — implemente |
| Nom | `tp-claude-host` |
| Image | `images:debian/12` |
| Option | `security.nesting=true` (Docker imbrique) |
| Noyau | **PARTAGE** avec l'hote reel |

> Nuance : un LXC partage le noyau ; `nesting=true` assouplit l'isolation. C'est **plus leger**
> mais **moins sur** qu'une VM. Assume car la partie notee est le durcissement Docker. Cible
> ideale documentee : **VM Incus** (cf. section 8).

## 1.4 Anneau 2 — Docker imbrique

Docker **29.5.2** (cgroup v2, seccomp, capabilities, user namespaces). Reseaux : `tp_internal`
(`--internal`, aucune sortie) et `tp_egress` (vers proxy). Images : `claude-hardened:latest`,
`tp-egress-proxy:latest`, `tp-exfil-server:latest`.

## 1.5 Agent reel : Claude Code

Claude Code (`claude` v2.1.191), agent de codage terminal-native d'Anthropic, embarque **dans**
un conteneur Docker. Il **lit et execute** sa configuration a chaque session (hooks de
`settings.json`, memoire `CLAUDE.md`, `skills`, serveurs `.mcp.json`) — d'ou la criticite de la
proteger.

**Backend LLM = LiteLLM externe (ixia) -> Ollama.** L'agent est configure pour parler a un
endpoint **compatible Anthropic** servi par **LiteLLM** sur `ixia` (`backend-host:3101`), qui
relaie vers **Ollama** (modeles locaux : `qwen2.5-coder:14b` principal, `qwen3:0.6b` rapide). On
ne fournit donc **aucune** cle Anthropic ni token OAuth a la sandbox : l'auth est une **cle
LiteLLM scopee** (`ANTHROPIC_AUTH_TOKEN=${LITELLM_VIRTUAL_KEY}`, variable `.env` gitignoree),
tandis que `ANTHROPIC_API_KEY` reste **vide** (sinon elle primerait). `ixia` est un serveur
**EXTERNE hors perimetre de durcissement**, suppose securise par ailleurs (cf. section 10).

| Variable (profils nu ET durci) | Valeur |
|---|---|
| `ANTHROPIC_BASE_URL` | `${LITELLM_ENDPOINT}` (def. `http://backend-host:3101`) |
| `ANTHROPIC_AUTH_TOKEN` | `${LITELLM_VIRTUAL_KEY}` (cle LiteLLM scopee) |
| `ANTHROPIC_API_KEY` | *(vide)* |
| `ANTHROPIC_MODEL` | `qwen2.5-coder:14b` |
| `ANTHROPIC_SMALL_FAST_MODEL` | `qwen3:0.6b` |

## 1.6 Image `claude-hardened:latest`

Base Node/Debian minimale, **USER `agent` (UID 10001)** non-root, HOME `/home/agent`, workspace
`/workspace`. **Aucun secret** dans les layers. La meme image sert aux deux profils ; seuls les
drapeaux `docker run` distinguent `nu` de `durci` (variable etudiee isolee proprement).

---

# 2. Modele de menace (Threat Model)

## 2.1 Actif protege : configuration/etat de l'agent

| Fichier | Role | Risque si reecrit |
|---|---|---|
| `settings.json` (projet + user) | declare des **hooks** auto-executes au demarrage | execution de code persistante, contournement des garde-fous |
| `CLAUDE.md` | memoire/instructions persistantes | **empoisonnement de memoire** |
| `skills` (`SKILL.md`) | procedures de confiance | **comportement detourne** |
| `.mcp.json` | declare les serveurs MCP | **octroi de nouvelles capacites** |

**Invariant** : un agent compromis ne doit **pas** pouvoir reecrire sa propre configuration pour
s'auto-accorder des privileges, persister, ou desactiver ses garde-fous.

## 2.2 Trois categories de menace

1. **Mauvais usage (utilisateur)** : l'utilisateur demande `rm -rf /` ou une exfiltration.
   Couvert par : FS `--read-only`, egress filtre, secret hors image.
2. **Derive du modele** : l'agent reecrit `settings.json` pour se donner un hook. Couvert par :
   montages `:ro`, tmpfs ephemere, user non-root.
3. **Attaquant externe par injection** : **directe** (dans le prompt) ou **indirecte** (payload
   cache dans un README, une sortie d'outil, une **reponse MCP**, du web). Couvert par : `:ro`,
   `cap-drop=ALL`, seccomp, egress proxy + MITM token-scope.

> L'injection **indirecte** est la plus pernicieuse : l'utilisateur n'a rien demande de
> malveillant, mais une donnee tierce detourne l'agent -> argument fort pour un **confinement
> environnemental** plutot qu'une confiance dans le prompt.

## 2.2bis Posture sur les secrets et l'egress (backend externe)

Le backend LLM etant un service **externe** de confiance (LiteLLM -> Ollama sur `ixia`), la
surface de menace se reduit :

- **Aucune cle Anthropic dans la sandbox.** `ANTHROPIC_API_KEY` est **vide** ; il n'y a ni cle
  `sk-ant-...` ni token OAuth a voler. Le seul credential present est une **cle LiteLLM scopee**
  (`ANTHROPIC_AUTH_TOKEN`), injectee au runtime depuis `.env` (gitignore), jamais dans un layer.
  Une exfil reussie ne livre qu'une cle a **portee limitee**, revocable cote ixia.
- **Egress reduit a une seule destination.** L'allowlist effective ne contient plus
  `api.anthropic.com` : la **seule** sortie autorisee est `backend-host` (l'endpoint modele) ;
  tout le reste est **default-deny**. Surface C2/exfil minimale.
- **Confidentialite** : les prompts **ne partent pas chez Anthropic** ; ils restent sur
  ixia/Ollama (local).

> `ixia` (`backend-host`) est **hors perimetre** de durcissement, suppose securise par ailleurs,
> decrit a la maille interface (section 10). Le durcissement de l'agent est **independant** du
> moteur de modele.

## 2.3 Objectifs neutralises

Modification de config, exfiltration de secrets, commande destructrice, persistance, elevation
de privilege.

## 2.4 Rayon d'impact (blast radius)

| Niveau | `nu` | `durci` | Si l'anneau 2 cede |
|---|---|---|---|
| Config agent | reecrite | **immuable** (`:ro`) | — |
| Persistance | oui | **non** (tmpfs) | — |
| Exfiltration | aboutit | **refusee** (seule sortie = `backend-host`) | — |
| Ecriture FS | partout | **confinee `/workspace`** | — |
| Privileges | root, toutes caps | non-root, cap-drop, no-new-privs | — |
| Atteinte hote | possible | tres difficile | confinee a **l'hote jetable Incus** (jamais la machine reelle ; avec une VM, evasion conteneur != noyau hote) |

---

# 3. Tableau de partitionnement du filesystem (PIECE MAITRESSE)

> Regle directrice (transposee de `sandbox-runtime`) : **deny-then-allow en lecture /
> allow-only en ecriture**. Tout read-only par defaut ; seuls workspace + ephemere ecrivables ;
> la config est **re-verrouillee `:ro`** par-dessus.

| Chemin (conteneur) | Mode | Source / mecanisme | Menace couverte |
|---|---|---|---|
| `/` (racine) | **ro** | `--read-only` | cmd destructrice, depot binaire, persistance |
| `/workspace` | **rw** | bind `tp/workspace` | seule zone metier ecrivable |
| `/workspace/.claude/settings.json` | **ro** | bind `project-settings.json:ro` | reecriture settings / hook |
| `/workspace/CLAUDE.md` | **ro** | bind `project-CLAUDE.md:ro` | empoisonnement memoire |
| `/workspace/.mcp.json` | **ro** | bind `project-mcp.json:ro` | ajout serveur MCP |
| `/workspace/.claude/skills` | **ro** | bind `project-skills/:ro` | alteration de skill |
| `/home/agent/.claude/settings.json` | **ro** | bind `user-settings.json:ro` | reecriture settings user |
| `/home/agent/.claude/skills` | **ro** | bind `user-skills/:ro` | alteration skill user |
| `/home/agent/.claude` (reste) | **tmpfs** | `--tmpfs` | etat ephemere, pas de persistance |
| `/tmp` | **tmpfs** | `--tmpfs` | scratch ephemere (`noexec,nosuid`) |
| `/run` | **tmpfs** | `--tmpfs` | pid/sockets ephemeres |
| `/run/secrets/fake_token.txt` | **ro** (*nu* seul) | injecte au RUN | demo exfil : present sur `nu`, absent sur `durci` |

**Ordre de montage critique** : d'abord `--tmpfs /home/agent/.claude`, **puis** les binds `:ro`
de `settings.json`/`skills` **par-dessus**. L'agent ecrit son etat runtime mais jamais sa config.

**Double verrou** : (1) bind `:ro` = verrou **kernel** root-proof ; (2) sources figees en
**`root:root 0444`** (l'agent UID 10001 n'en est pas proprietaire). Independants.

**Piege symlink** : `:ro` kernel est insensible au symlink (verrou sur l'inode), mais toute
validation **applicative** de chemin doit faire `realpath` **AVANT** de comparer. *Resoudre
d'abord, valider ensuite.*

---

# 4. Design de durcissement (PIECE MAITRESSE)

## 4.1 Synthese

| # | Mesure | Drapeau Docker | Menace bloquee |
|---|---|---|---|
| 1 | Config `:ro` | `-v src:dst:ro` | reecriture settings/CLAUDE.md/skills/mcp |
| 2 | Racine read-only | `--read-only` | cmd destructrice, depot binaire, persistance |
| 3 | tmpfs ephemere | `--tmpfs /tmp /run /home/agent/.claude` | persistance, fuite disque |
| 4 | Non-root | `USER agent` (UID 10001) | elevation, ecriture sur fichiers root |
| 5 | Drop capabilities | `--cap-drop=ALL` | mount, ptrace, raw sockets, chown... |
| 6 | No new privileges | `--security-opt no-new-privileges` | escalade via SUID |
| 7 | Seccomp restreint | `--security-opt seccomp=./agent/seccomp-claude.json` | syscalls dangereux |
| 8 | Egress proxy + allowlist | `--network tp_egress` (+ `tp_internal` internal) | exfiltration, C2, payload |
| 9 | Limites cgroups | `--memory 2g --pids-limit 256 --cpus 2` | DoS, fork-bomb |
| 10 | Secrets hors image | injection RUN scopee | vol de credential depuis l'image |

## 4.2 Justifications

- **1. Config `:ro`** — exigence centrale. Verrou **kernel** root-proof (meme root ne peut
  ecrire). 2e verrou : sources `root:root 0444`.
- **2. `--read-only`** — tout immuable hors binds rw / tmpfs ; rien a corrompre hors
  `/workspace`.
- **3. tmpfs** — rares zones ecrivables necessaires, mais **en RAM**, detruites a l'arret ;
  `noexec,nosuid`.
- **4. Non-root** — surface noyau reduite ; pas proprietaire de la config `root:root`.
- **5. `cap-drop=ALL`** — aucune capacite requise par l'agent ; moindre privilege maximal.
- **6. `no-new-privileges`** — ferme l'escalade via SUID.
- **7. seccomp** — allowlist de syscalls ; **crucial car noyau PARTAGE** (LXC). Jamais
  `unconfined`.
- **8. Egress proxy** — une allowlist est un **octroi de capacite**. Sortie uniquement via
  `egress-proxy:8080` ; `tp_internal` sans route. Variante stricte : `--network=none`. Jamais
  `--network=host`. **Allowlist effective = une seule destination : `backend-host`** (l'endpoint
  LiteLLM sur ixia ; `api.anthropic.com` retire). `exfil-server` n'y figure que pour le bonus.
- **8bis. Cle LiteLLM scopee = capacite + audit** — l'auth modele est une **cle virtuelle LiteLLM
  scopee** (`ANTHROPIC_AUTH_TOKEN`), pas une cle Anthropic ni un token OAuth ; `ANTHROPIC_API_KEY`
  reste **vide**. LiteLLM lui attache **limites** (budget, rate-limit, modeles) et **journalise**
  chaque appel ; revocable cote ixia, injectee depuis `.env` (jamais dans un layer). Le
  durcissement reste **independant** du moteur.
- **9. cgroups** — borne l'impact ressources (protege l'hote jetable et les autres conteneurs).
- **10. Secrets hors image** — aucun vrai credential dans les layers ; secret factice injecte
  **uniquement** sur `nu` ; **non monte** sur `durci`.

## 4.3 BONUS — Exfil via un domaine POURTANT autorise

**Probleme** : une allowlist de **domaines** ne valide pas l'intention. Un secret encode vers un
domaine **autorise** (sous-domaine/query/POST) passe le filtre destination — angle mort de
l'incident Anthropic. *Une allowlist octroie une capacite ; elle ne valide pas l'intention.*

**Correction** : le `egress-proxy` fait un **MITM defensif** et ne laisse passer que la requete
portant **exactement** le **token de session provisionne** (`Authorization: Bearer <token>`).
Toute autre cle (secret exfiltre, cle injectee) = **403**, **meme domaine autorise**. Filtrage
additionnel des sous-domaines a haute entropie et des query strings volumineuses.

> Message cle : filtrage par **destination** insuffisant -> controle par **contenu/intention**.

## 4.4 Pieges EVITES (jamais)

`-v /var/run/docker.sock` ; `--privileged` ; `--network=host` ; `seccomp=unconfined` ;
`--cap-add` larges. Validation de chemin **sans** `realpath`. Aucun n'apparait dans `durci`.

---

# 5. Demonstration AVANT / APRES

## 5.1 Table (rappel detaille)

| # | Attaque | `nu` | `durci` | Mecanisme |
|---|---|---|---|---|
| 1 | Reecriture `settings.json` (hook) | Reussie | **Bloquee** | `:ro` kernel + `root:root 0444` |
| 2 | Modif `CLAUDE.md` | Reussie | **Bloquee** | `:ro` |
| 3 | Alteration skill `SKILL.md` | Reussie | **Bloquee** | skills `:ro` |
| 4 | Ajout serveur `.mcp.json` | Reussie | **Bloquee** | `:ro` |
| 5 | Exfil secret factice | Reussie | **Bloquee** | secret non monte + egress refuse |
| 6 | Cmd destructrice hors workspace | Reussie | **Bloquee** | racine `--read-only` |
| B | Exfil via domaine autorise | Reussie | **Bloquee** | proxy **MITM token-scope** |

## 5.2 Detail

- **1-4** : sur `nu`, ecriture reussie (binds rw). Sur `durci`, `Read-only file system` (bind
  `:ro`, verrou kernel ; en plus `root:root 0444`).
- **5** : sur `nu`, secret monte + egress libre -> exfil aboutit. Sur `durci`, **double
  blocage** : secret non monte (rien a lire) **et** egress via proxy dont l'allowlist n'autorise
  que `backend-host` (l'endpoint modele) -> sortie vers `exfil-server`/tiers refusee. La sandbox
  ne contient d'ailleurs **aucune** cle Anthropic, seulement la cle LiteLLM scopee (revocable).
- **6** : sur `nu`, racine rw + root -> destruction. Sur `durci`, `--read-only` -> echec hors
  `/workspace`.
- **B** : sur `nu`/filtre naif, la requete vers le domaine autorise passe. Sur `durci`, le proxy
  valide le **token de session** -> 403 sinon, meme domaine autorise.

## 5.3 Preuves

Generees par `09-report.sh` sous `tp/out/` : `attack-suite.log`, `attack-*.log`,
`exfil-server.log` (hits), `egress-proxy.log` (200 vs 403), `resultats.md` (matrice nu/durci).

---

# 6. Architecture

## 6.1 Boucle agentique + lecture de config

```
   CONFIG/ETAT (actif protege) --- lecture+execution a chaque session ---> BOUCLE AGENTIQUE
   settings.json (hooks)                                                   percevoir -> raisonner
   CLAUDE.md / skills / .mcp.json                                          -> agir -> observer
                                                                                |
   entree : prompt direct OU donnee tierce (README, sortie d'outil, MCP)       v
            (= injection directe / indirecte)                          outils: FS / shell / reseau
```

> La config est **lue ET executee** (hooks, skills). Si un outil « FS write » peut la reecrire,
> l'agent s'auto-modifie durablement -> d'ou le verrou `:ro`.

## 6.2 AVANT (agent NU)

```
Incus LXC tp-claude-host -> Docker (bridge, EGRESS LIBRE)
  claude-nu : USER root, PAS de --read-only, toutes caps, seccomp default, pas de limites
    /workspace/.claude/settings.json .. rw  <- REECRITURE OK
    /workspace/CLAUDE.md ............... rw  <- POISON OK
    /workspace/.mcp.json .............. rw  <- AJOUT SERVEUR OK
    /workspace/.claude/skills ......... rw  <- ALTERATION OK
    /run/secrets/fake_token.txt ....... present <- EXFIL OK -> exfil-server:8000
    / (racine) ........................ rw  <- rm destructeur OK
```

## 6.3 APRES (agent DURCI)

```
Incus LXC tp-claude-host (noyau partage) -> Docker
  reseau tp_internal (internal, aucune sortie)
  claude-hardened (DURCI): USER agent(10001) --read-only cap-drop=ALL
    no-new-privileges  seccomp=seccomp-claude  --memory 2g --pids-limit 256 --cpus 2
    FS: racine ro + tmpfs ; config :ro
      /workspace ........................ rw
      settings.json/CLAUDE.md/.mcp.json/skills .. ro
      /home/agent/.claude (reste) ....... tmpfs ; /tmp /run .. tmpfs
    secret factice : NON monte ; AUCUNE cle Anthropic (auth = cle LiteLLM scopee)
    ANTHROPIC_BASE_URL=backend-host:3101  ANTHROPIC_API_KEY=(vide)
        |  (seule sortie)            reseau tp_egress
        v                            +--------------------------+
   egress-proxy:8080  --allow only-->| backend-host (LiteLLM/ixia, EXTERNE) |
   allowlist={backend-host}         +--------------------------+
   + MITM token-scope                | exfil-server:8000 (cible bonus)       |
   (secret exfiltre / cle injectee   +--------------------------+
    / dest. non autorisee = refus)
```

## 6.4 Vue Mermaid

```mermaid
flowchart TB
  subgraph LXC["Anneau 1 : Incus LXC tp-claude-host (noyau PARTAGE)"]
    subgraph DOCKER["Docker 29.5.2 imbrique"]
      AGENT["claude-hardened (DURCI)\nUSER agent 10001 / --read-only+tmpfs\nconfig :ro / cap-drop=ALL\nno-new-privileges / seccomp\ncgroups 2g/256/2cpu\nANTHROPIC_API_KEY=(vide) / auth=cle LiteLLM scopee"]
      PROXY["egress-proxy:8080\nallowlist={backend-host} + MITM token-scope"]
      EXFIL["exfil-server:8000\ncible factice (bonus)"]
      AGENT -->|seule sortie| PROXY
      PROXY -.->|secret/cle injectee = 403| AGENT
      PROXY -.->|dest. non autorisee = refus| EXFIL
    end
  end
  IXIA["ixia backend-host:3101 (EXTERNE, hors perimetre)\nLiteLLM v1.89.4 -> Ollama (qwen2.5-coder:14b / qwen3:0.6b)"]
  PROXY -->|UNIQUE egress autorise| IXIA
  CONF["Config agent (settings/CLAUDE.md/skills/.mcp.json)\n:ro, sources root:root 0444"] -->|lecture seule| AGENT
```

---

# 7. Installation & exploitation

## 7.1 Demarrage rapide

```bash
cd /home/julien/projet/cyber/tp
./run.sh up        # etapes 00-07 : hote Incus, build images, reseaux, config, proxy+exfil, nu & durci
./run.sh attack    # etape 08 : 6 attaques + bonus sur nu PUIS durci
./run.sh report    # etape 09 : agrege les preuves + tableau dans tp/out/
./run.sh clean     # teardown Docker + incus delete --force
```

`run.sh` est **fail-fast** (`set -euo pipefail`).

## 7.2 Etapes 00..09 (resume)

- **00 preflight** : verifie `docker`/`incus`, versions, presence config + seccomp ; `realpath`.
- **01 host-incus** : `incus launch images:debian/12 tp-claude-host -c security.nesting=true` +
  Docker imbrique (VM `--vm` documentee comme ideal).
- **02 build-images** : `docker build` des 3 images (secrets jamais dans les layers).
- **03 networks** : `docker network create --internal tp_internal` ; `... tp_egress`.
- **04 prepare-config** : `chown root:root` + `chmod 0444` sur la config ; prepare le secret
  factice.
- **05 run-exfil-proxy** : lance `exfil-server:8000` et `egress-proxy:8080` (avec
  `SESSION_TOKEN`).
- **06 run-nu** : root, FS rw, egress libre, secret monte, config bindee rw ; env modele
  (`ANTHROPIC_BASE_URL`=LiteLLM, `ANTHROPIC_AUTH_TOKEN`=cle scopee, `ANTHROPIC_API_KEY` vide).
- **07 run-durci** : invocation durcie complete (cf. 7.3) ; meme env modele (aucune cle Anthropic).
- **08 attack-suite** : rejoue les attaques sur nu puis durci, capture codes/messages.
- **09 report** : agrege logs/preuves dans `tp/out/` + tableau.

## 7.3 Invocation DURCIE (reference)

```bash
docker run -d --name claude-hardened \
  --user 10001:10001 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid \
  --tmpfs /run:rw,noexec,nosuid \
  --tmpfs /home/agent/.claude:rw,nosuid \
  -v "$PWD/workspace:/workspace" \
  -v "$PWD/config/project-settings.json:/workspace/.claude/settings.json:ro" \
  -v "$PWD/config/project-CLAUDE.md:/workspace/CLAUDE.md:ro" \
  -v "$PWD/config/project-mcp.json:/workspace/.mcp.json:ro" \
  -v "$PWD/config/project-skills:/workspace/.claude/skills:ro" \
  -v "$PWD/config/user-settings.json:/home/agent/.claude/settings.json:ro" \
  -v "$PWD/config/user-skills:/home/agent/.claude/skills:ro" \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --security-opt seccomp=./agent/seccomp-claude.json \
  --network tp_internal \
  --memory 2g --pids-limit 256 --cpus 2 \
  -e ANTHROPIC_BASE_URL="${LITELLM_ENDPOINT}" \          # backend = LiteLLM externe (ixia, via proxy -> backend-host)
  -e ANTHROPIC_AUTH_TOKEN="${LITELLM_VIRTUAL_KEY}" \     # cle LiteLLM scopee (auth modele)
  -e ANTHROPIC_API_KEY= \                                # VIDE (sinon prime sur AUTH_TOKEN)
  -e ANTHROPIC_MODEL=qwen2.5-coder:14b \
  -e ANTHROPIC_SMALL_FAST_MODEL=qwen3:0.6b \
  claude-hardened:latest sleep infinity
# Secret factice NON monte. AUCUNE cle Anthropic dans la sandbox (auth = cle LiteLLM scopee).
# tmpfs /home/agent/.claude AVANT les binds :ro (poses par-dessus).
```

## 7.4 Generer le PDF

```bash
./scripts/build-pdf.sh    # docs/RAPPORT.md -> out/RAPPORT.pdf (pandoc ; fallback HTML/instructions)
```

---

# 8. Isolation de l'hote (anneau 1) : conteneur LXC vs VM

## 8.1 Pourquoi un anneau 1 ?

Defense en profondeur : l'anneau 1 (hote jetable Incus) isole tout le TP de la machine reelle ;
l'anneau 2 (Docker durci) est la piece notee. Compromission = franchir les **deux**.

## 8.2 Implemente : conteneur LXC

```bash
incus launch images:debian/12 tp-claude-host -c security.nesting=true
```

Noyau **PARTAGE**, `nesting=true` requis pour Docker imbrique (assouplit l'isolation), surface
d'evasion **plus large** (faille noyau = evasion), mais **leger** et **rapide** a iterer ->
**moins sur**, assume car la partie notee est le durcissement Docker.

## 8.3 Ideal documente : VM Incus (KVM)

```bash
incus launch images:debian/12 tp-claude-host --vm -c security.secureboot=false
```

Noyau **DEDIE**, surface d'evasion **reduite** (il faut casser l'**hyperviseur KVM**), vraie
isolation noyau, mais plus **lourd** (image disque, boot complet) -> **plus sur**.

## 8.4 Comparaison

| Critere | LXC (implemente) | VM KVM (ideal) |
|---|---|---|
| Noyau | partage | dedie |
| Evasion = | faille noyau | faille hyperviseur (plus dur) |
| Poids / boot | leger / instantane | lourd / boot complet |
| Verdict | choisi (iteration TP) | recommande en prod |

## 8.5 Recommandation explicite

> **Le mieux serait une VM Incus (`--vm`, KVM)** : noyau dedie -> meme apres evasion de
> l'anneau 2 et du conteneur hote, il reste la frontiere de l'hyperviseur. Dans ce TP, le
> **conteneur LXC** est retenu sciemment (leger, iteration rapide) car l'evaluation porte sur le
> durcissement **Docker**. Compromis assume : **production -> VM ; TP -> LXC + nesting.**

---

# 9. Notes de securite du TP (non negociable)

- **Secrets FACTICES uniquement** : `FAKE-CORP-TOKEN-do-not-exfiltrate-1337`. Aucun vrai
  credential (token API, SSH, `~/.aws`) n'entre dans un conteneur.
- **Endpoint d'exfil LOCAL** : `exfil-server:8000` vit dans `tp_egress`, jamais sur Internet.
- **Aucune cle Anthropic dans la sandbox.** L'auth modele est une **cle LiteLLM scopee**
  (`ANTHROPIC_AUTH_TOKEN`), `ANTHROPIC_API_KEY` reste vide. Le secret est une variable `.env`
  (gitignore), jamais en clair dans le depot ni dans une image. Cle revocable cote ixia.
- **Aucune action contre un systeme tiers reel.** Tout le trafic d'attaque reste interne au TP ;
  le **seul** egress autorise est `backend-host` (serveur de modele EXTERNE de confiance).
- **Hote jetable** : `run.sh clean` detruit tout sans trace (`incus delete --force`).

---

# 10. Annexe — Backend modele externe (LiteLLM -> Ollama sur ixia)

> L'agent durci n'utilise **pas** Anthropic comme moteur. Son backend LLM est un service
> **externe** de confiance — **LiteLLM** sur `ixia` (`backend-host:3101`) routant vers **Ollama**
> (modeles locaux). Ce serveur est une **frontiere de confiance HORS perimetre de durcissement**,
> suppose securise par ailleurs, decrit a la maille interface.

## 10.1 Phrase-cle

> **L'agent est durci ; le modele vient d'un service externe de confiance** => **secret d'API hors
> sandbox** + **zero egress vers un tiers**. Le durcissement (`:ro`/`cap-drop`/`seccomp`/egress)
> est **INDEPENDANT du moteur**. Concretement : **les questions ne partent pas chez Anthropic** ;
> chaque prompt part vers LiteLLM/ixia, servi par Ollama en local.

## 10.2 Frontiere de confiance

```
[ SANDBOX DURCIE — anneau 2 ]                      [ SERVEUR DE MODELE EXTERNE — ixia ]
  claude-hardened (Claude Code)                      backend-host:3101
    ANTHROPIC_BASE_URL = http://backend-host:3101     LiteLLM (compatible Anthropic/OpenAI)
    ANTHROPIC_AUTH_TOKEN = <cle LiteLLM scopee>          +-- Ollama (RTX 3080 Ti) : qwen2.5-coder:14b / qwen3:0.6b
    ANTHROPIC_API_KEY = (vide)                           +-- litellm-db (PostgreSQL) : cles/usage/audit
        |  egress UNIQUE : backend-host (via proxy)     +-- open-webui (console humaine)
   ===== FRONTIERE DE CONFIANCE =====                 (HORS perimetre, suppose securise par ailleurs)
```

- A **gauche** (notee) : l'agent et son confinement Docker — **piece du TP**.
- A **droite** (hors perimetre) : `ixia`, non durci ici, decrit a la maille **interface** :
  adresse (`backend-host:3101`), protocole (compatible Anthropic), auth (cle LiteLLM scopee).

| Critere | Avant (Anthropic / OAuth) | Apres (LiteLLM externe) |
|---|---|---|
| Secret en sandbox | cle `sk-ant-...` / token OAuth | **cle LiteLLM scopee** seulement (`ANTHROPIC_API_KEY` vide) |
| Egress legitime | `api.anthropic.com` (Internet) | **un seul** : `backend-host` (local) |
| Donnees (prompts) | partent chez un tiers | restent sur ixia/Ollama (local) |
| Limites / audit / revocation | cote Anthropic | cote LiteLLM (cle scopee, budget, rate-limit, logs) |

## 10.3 Stack d'ixia (`docker compose`, secrets en `${VARS}`)

> Documentaire (hors perimetre). **Tous** les secrets sont des variables ; **aucune** valeur en clair.

```yaml
# ixia — stack de service modele (HORS perimetre de durcissement du TP).
services:
  litellm:
    image: ghcr.io/berriai/litellm:v1.89.4
    container_name: litellm
    restart: unless-stopped
    ports:
      - "3101:4000"                       # endpoint compatible Anthropic (backend-host:3101)
    environment:
      LITELLM_MASTER_KEY: ${LITELLM_MASTER_KEY}   # emet les cles scopees — JAMAIS dans la sandbox
      LITELLM_SALT_KEY: ${LITELLM_SALT_KEY}
      DATABASE_URL: ${LITELLM_DATABASE_URL}       # postgres://...:${POSTGRES_PASSWORD}@litellm-db:5432/litellm
    depends_on: [litellm-db, ollama]

  litellm-db:
    image: postgres:16
    container_name: litellm-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}     # secret -> variable
    volumes: [litellm-db-data:/var/lib/postgresql/data]

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    deploy:                                       # GPU RTX 3080 Ti (modeles locaux)
      resources:
        reservations:
          devices:
            - {driver: nvidia, count: all, capabilities: [gpu]}
    volumes: [ollama-models:/root/.ollama]        # qwen2.5-coder:14b, qwen3:0.6b

  open-webui:
    image: ghcr.io/open-webui/open-webui:latest
    container_name: open-webui
    restart: unless-stopped
    ports: ["3000:8080"]                          # console humaine (admin ixia, hors agent)
    environment:
      WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY}       # secret -> variable
      OPENAI_API_BASE_URL: ${LITELLM_ENDPOINT}
      OPENAI_API_KEY: ${OPENWEBUI_LITELLM_KEY}    # cle scopee dediee
    depends_on: [litellm]

volumes:
  litellm-db-data:
  ollama-models:
```

| Service | Image / version | Role |
|---|---|---|
| `litellm` | `ghcr.io/berriai/litellm:v1.89.4` | proxy compatible Anthropic ; emet les cles scopees ; audit |
| `litellm-db` | `postgres:16` | cles virtuelles, budgets, usage/audit |
| `ollama` | `ollama/ollama` (RTX 3080 Ti) | modeles **locaux** `qwen2.5-coder:14b` / `qwen3:0.6b` |
| `open-webui` | `ghcr.io/open-webui/open-webui` | console humaine d'admin (hors chemin de l'agent) |

> Secrets (`LITELLM_MASTER_KEY`, `POSTGRES_PASSWORD`, `WEBUI_SECRET_KEY`...) = **variables**, dans
> un `.env` gitignore cote ixia ; **jamais** dans le depot du TP ni dans la sandbox. La sandbox ne
> recoit **que** la cle **scopee** `LITELLM_VIRTUAL_KEY`. (Detail : [`09-backend-modele.md`](09-backend-modele.md).)

---

# Annexe — References (Anthropic + ecosysteme)

- **sandbox-runtime (srt)** : patterns « deny-then-allow en lecture / allow-only en ecriture » +
  egress par proxy. Transpose ici sur des montages Docker + un conteneur proxy (srt est
  sans-conteneur -> ne peut pas etre le livrable, Docker etant impose).
- **Claude Code sandboxing** : ecriture autorisee uniquement dans le CWD, reste read-only ;
  egress via socket->proxy + allowlist ; enforcement OS (bubblewrap/seccomp).
- **« How we contain Claude »** : une allowlist est un **octroi de capacite** ; MITM defensif ne
  laissant passer que le **token de session provisionne** ; defense en profondeur (« containment
  at the environment layer first »).
- **Devcontainer officiel Claude Code** : `Dockerfile` + `init-firewall.sh` (allowlist
  iptables/ipset) -> base d'egress baseline.
- **Defense niveau fichier** : montage `:ro` (verrou kernel root-proof) + sources `root:root
  0444` + UID non-root.
- **Isolation hote** : conteneur LXC (noyau partage, leger, moins sur) vs VM (noyau dedie,
  isolation noyau, plus sur).
