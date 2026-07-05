# PLAN D'IMPLEMENTATION — Durcissement d'un agent Claude Code en Docker

> Document d'architecture et plan d'implementation concret du TP
> « Durcissement d'un agent de codage (Agentic) en conteneur Docker ».
>
> Agent reel cible : **Claude Code** (`claude` v2.1.191, agent terminal-native d'Anthropic).
> Technologie de conteneurisation : **Docker** (impose) — ici Docker **29.5.2**, cgroup v2 + seccomp actifs.
> Hote du TP : **conteneur Incus (LXC)** jetable `tp-claude-host` avec `security.nesting=true` (Docker imbrique).
>
> Ce document est la **source de verite** pour tous les implementeurs. Les noms d'images, reseaux,
> ports, chemins et UID sont **autoritaires** : ne pas les diverger.

---

## 0. Conventions autoritaires (rappel)

| Element | Valeur exacte |
|---|---|
| Repertoire projet | `/home/julien/projet/cyber/tp` |
| Image agent | `claude-hardened:latest` |
| Image proxy egress | `tp-egress-proxy:latest` |
| Image serveur d'exfil | `tp-exfil-server:latest` |
| Utilisateur agent | `agent` (UID `10001`, GID `10001`) |
| HOME conteneur | `/home/agent` |
| Workspace (code a traiter) | `/workspace` |
| Profil seccomp | `./agent/seccomp-claude.json` |
| Reseau interne (sans egress) | `tp_internal` (internal, pas de route hors Docker) |
| Reseau egress (vers proxy) | `tp_egress` |
| Hostname proxy / port | `egress-proxy` : `8080` |
| Hostname exfil / port | `exfil-server` : `8000` |
| Secret factice | `/run/secrets/fake_token.txt` = `FAKE-CORP-TOKEN-do-not-exfiltrate-1337` |
| Limites cgroups | `--memory 2g`, `--pids-limit 256`, `--cpus 2` |
| Profils demontres | `nu` (vulnerable) vs `durci` (protege) |

---

## 1. Architecture a 2 anneaux (Incus hote jetable + Docker durci)

### 1.1 Principe : « containment at the environment layer first » (defense en profondeur)

On empile **deux frontieres d'isolation** independantes. Un agent compromis doit franchir
**les deux** pour atteindre l'hote reel — c'est la « defense en profondeur » recommandee par
Anthropic (*How we contain Claude*).

- **Anneau 1 — Hote jetable Incus (`tp-claude-host`)** : un conteneur LXC Debian 12
  isole le TP entier de la machine de l'etudiant. Tout le bac a sable Docker vit dedans.
  S'il est detruit, on relance `incus delete --force` : aucune trace sur l'hote reel.
- **Anneau 2 — Conteneur Docker durci (`claude-hardened`)** : c'est la piece **notee**.
  Il applique le partitionnement read-only du filesystem + toutes les primitives de
  durcissement Docker (non-root, cap-drop, seccomp, no-new-privileges, egress proxy, cgroups).

### 1.2 Nuance CRITIQUE : conteneur (LXC) vs VM (KVM)

| Critere | Implemente : **Incus LXC** (`security.nesting=true`) | Ideal documente : **Incus VM** (`--vm`, KVM) |
|---|---|---|
| Noyau | **Partage avec l'hote** (un seul noyau) | **Dedie** (noyau invite separe) |
| Surface d'evasion | Plus large : une faille noyau = evasion vers l'hote | Reduite : il faut casser l'hyperviseur KVM |
| Poids / demarrage | Leger, instantane | Plus lourd (image disque, boot complet) |
| Verdict TP | **Choisi** (rapide a iterer pour le TP) | **Recommande en prod** dans la doc |

> **Note honnete pour le rapport** : le LXC partage le noyau de l'hote ; `security.nesting=true`
> assouplit l'isolation pour permettre Docker imbrique. C'est **moins sur** qu'une VM. On
> l'assume car la **partie notee** est le durcissement **Docker** (anneau 2), pas l'isolation
> de l'hote. La doc PDF doit explicitement recommander l'Incus **VM** (KVM) comme cible prod.

### 1.3 Schema ASCII — APRES (cible durcie)

```
+=========================================================================================+
|  MACHINE HOTE REELLE (poste etudiant)  — Incus 7.1, Docker 29.5.2 (cgroup v2 + seccomp)   |
|                                                                                          |
|   +-----------------------------------------------------------------------------------+  |
|   | ANNEAU 1 : Incus LXC "tp-claude-host"  (images:debian/12, security.nesting=true)  |  |
|   |            >> NOYAU PARTAGE avec l'hote (leger, moins sur ; VM = ideal documente) |  |
|   |                                                                                   |  |
|   |   Docker imbrique :                                                               |  |
|   |                                                                                   |  |
|   |   reseau tp_internal (internal=true, AUCUNE route sortie)                         |  |
|   |   +---------------------------------------------+      reseau tp_egress           |  |
|   |   | ANNEAU 2 : "claude-hardened" (DURCI)        |      +------------------------+  |  |
|   |   |  USER agent(10001) --read-only  cap-drop ALL|----->| "egress-proxy" :8080   |  |  |
|   |   |  no-new-privileges  seccomp=seccomp-claude  | tp_  | allowlist + MITM token |  |  |
|   |   |  --memory 2g --pids-limit 256 --cpus 2      | egr  | (Squid/mitmproxy)      |  |  |
|   |   |                                             | ess  +-----------+------------+  |  |
|   |   |  FS : racine ro + tmpfs ; config montee :ro |                  | allow only   |  |  |
|   |   |   /workspace .................... rw         |                  v              |  |  |
|   |   |   /workspace/.claude/settings.json .. ro    |      +------------------------+  |  |
|   |   |   /workspace/CLAUDE.md .............. ro     |      | "exfil-server" :8000   |  |  |
|   |   |   /workspace/.mcp.json ............. ro      |<--X--| (cible factice locale) |  |  |
|   |   |   /workspace/.claude/skills ........ ro      |  bloque tant que pas de token |  |  |
|   |   |   /home/agent/.claude/settings.json  ro     |      +------------------------+  |  |
|   |   |   /home/agent/.claude/skills ....... ro     |                                  |  |
|   |   |   /home/agent/.claude (reste) ...... tmpfs  |   secret factice injecte au RUN  |  |
|   |   |   /tmp /run ........................ tmpfs  |   (jamais dans l'image)          |  |
|   |   +---------------------------------------------+                                  |  |
|   +-----------------------------------------------------------------------------------+  |
+=========================================================================================+
```

### 1.4 Schema ASCII — AVANT (agent NU, vulnerable)

```
+-----------------------------------------------------------------------+
| Incus LXC "tp-claude-host"  (meme anneau 1)                           |
|                                                                       |
|   Docker imbrique — reseau bridge par defaut (egress LIBRE)           |
|   +---------------------------------------------------------------+   |
|   | "claude-nu" (NON DURCI)                                       |   |
|   |  USER root   PAS de --read-only   toutes capabilities         |   |
|   |  seccomp=default   PAS de limites   reseau ouvert -> Internet |   |
|   |                                                               |   |
|   |  FS : TOUT en lecture-ECRITURE (bind classique, pas de :ro)   |   |
|   |   /workspace/.claude/settings.json .. rw  <- REECRITURE OK    |   |
|   |   /workspace/CLAUDE.md .............. rw  <- POISON OK        |   |
|   |   /workspace/.mcp.json ............. rw  <- AJOUT SERVEUR OK  |   |
|   |   /workspace/.claude/skills ........ rw  <- ALTERATION OK     |   |
|   |   secret present en clair          <- EXFIL vers exfil:8000 OK|   |
|   |   racine rw                        <- rm destructeur OK       |   |
|   +---------------------------------------------------------------+   |
+-----------------------------------------------------------------------+
```

> Les deux profils utilisent **le meme reseau d'exfil local** (`exfil-server:8000`) pour la
> demo : sur `nu` l'exfil aboutit, sur `durci` elle est refusee (secret absent + egress filtre).

---

## 2. Modele de menace (Threat Model)

### 2.1 Actif protege

**La surface de configuration et d'etat de l'agent** — fichiers lus *et souvent executes* a
chaque session, donc surface d'attaque de premier plan :

- `settings.json` (projet + utilisateur) : peut definir des **hooks** (commandes auto-executees
  au demarrage, *avant* le dialogue de confiance — « everything before the trust dialog »).
- `CLAUDE.md` : memoire/instructions persistantes, rechargees chaque session
  -> **empoisonnement de memoire persistant**.
- `skills` (`SKILL.md`) : procedures de confiance suivies par l'agent -> **comportement detourne**.
- `.mcp.json` : declare les serveurs MCP -> **octroi de nouvelles capacites** (elargit le blast radius).

**Invariant de securite** : un agent compromis ne doit PAS pouvoir **reecrire sa propre config**
pour s'auto-accorder des privileges, persister, ou desactiver ses garde-fous.

### 2.2 Trois categories de menace (couvertes)

| # | Categorie | Exemple dans le TP | Levier de couverture principal |
|---|---|---|---|
| 1 | **Mauvais usage utilisateur** | l'utilisateur demande `rm -rf /` ou d'exfiltrer un token | FS racine `--read-only`, egress filtre, secret hors image |
| 2 | **Derive du modele** | l'agent reecrit `settings.json` pour se donner un hook persistant | montages `:ro` de la config |
| 3 | **Attaquant externe (injection)** | **directe** (prompt) ou **indirecte** (payload cache dans README/skill/sortie d'outil/reponse MCP) qui pousse a modifier la config ou exfiltrer | `:ro` + cap-drop + seccomp + egress proxy |

### 2.3 Objectifs malveillants neutralises & rayon d'impact

Objectifs typiques a neutraliser : **modification de config** (settings/CLAUDE.md/skills/mcp),
**exfiltration de secrets**, **commande destructrice**, **persistance**.

**Rayon d'impact (blast radius) vise** :
- *Sans durcissement* : l'agent ecrit partout, exfiltre, persiste entre sessions, peut viser l'hote.
- *Avec durcissement (anneau 2)* : impact confine au **seul `/workspace` (rw ephemere)** ; config
  immuable, pas de persistance, pas d'exfil, pas d'ecriture hors workspace, pas d'elevation de privilege.
- *Si l'anneau 2 cede* : impact confine a l'**hote jetable Incus**, jamais a la machine reelle
  (et avec une VM KVM, meme une evasion conteneur ne donne pas le noyau hote).

---

## 3. Tableau de partitionnement du filesystem (PIECE MAITRESSE)

> Regle directrice (transposee de `sandbox-runtime`) : **deny-then-allow en lecture / allow-only
> en ecriture**. Tout est read-only par defaut ; seuls le workspace et l'ephemere sont accessibles
> en ecriture. La config/etat de l'agent est **explicitement re-verrouille `:ro`** par-dessus le tmpfs.

| Chemin (dans le conteneur) | Mode | Source / mecanisme | Menace couverte |
|---|---|---|---|
| `/` (racine) | **ro** | `--read-only` (Docker) | Cmd destructrice hors workspace ; depot de binaires/persistance |
| `/workspace` | **rw** | bind `tp/workspace` (rw) | Zone de travail legitime — **seul** endroit ecrivable « metier » |
| `/workspace/.claude/settings.json` | **ro** | bind `tp/config/project-settings.json:ro` | Reecriture settings / **injection de hook** (cat. 2,3) |
| `/workspace/CLAUDE.md` | **ro** | bind `tp/config/project-CLAUDE.md:ro` | Empoisonnement memoire persistant (cat. 2,3) |
| `/workspace/.mcp.json` | **ro** | bind `tp/config/project-mcp.json:ro` | Ajout serveur MCP = octroi de capacite (cat. 3) |
| `/workspace/.claude/skills` | **ro** | bind `tp/config/project-skills/:ro` | Alteration de skill = comportement detourne (cat. 3) |
| `/home/agent/.claude/settings.json` | **ro** | bind `tp/config/user-settings.json:ro` | Reecriture settings utilisateur / hook (cat. 2,3) |
| `/home/agent/.claude/skills` | **ro** | bind `tp/config/user-skills/:ro` | Alteration de skill utilisateur (cat. 3) |
| `/home/agent/.claude` (reste) | **tmpfs** | `--tmpfs /home/agent/.claude` | Etat runtime ephemere ; **pas de persistance** entre sessions |
| `/tmp` | **tmpfs** | `--tmpfs /tmp` | Scratch ephemere (`noexec,nosuid` recommande) |
| `/run` | **tmpfs** | `--tmpfs /run` | Pid/sockets runtime ephemeres |
| `/run/secrets/fake_token.txt` | **ro** (profil nu uniquement) | injecte au RUN (jamais dans l'image) | Demo exfil : present sur `nu`, **absent** sur `durci` |

**Ordre de montage critique** : d'abord `--tmpfs /home/agent/.claude` (zone ephemere
ecrivable), PUIS les binds `:ro` de `settings.json`/`skills` **par-dessus**. Ainsi l'agent peut
ecrire son etat runtime (sessions, cache) mais **jamais** sa config protegee.

**Piege symlink (a NE PAS oublier)** : la validation de chemin doit se faire **APRES** resolution
des liens symboliques. Un montage `:ro` au niveau **kernel** est insensible au symlink (le verrou
porte sur l'inode monte), mais toute logique applicative de validation de chemin (proxy, scripts
d'attaque) doit `realpath` avant de comparer.

---

## 4. Justification de chaque mesure de durcissement

| Mesure | Drapeau Docker | Menace bloquee | Justification |
|---|---|---|---|
| **Config en lecture seule** | `-v src:dst:ro` | reecriture settings/CLAUDE.md/skills/mcp | **Exigence centrale**. Verrou **kernel**, *root-proof* : meme un process root du conteneur ne peut ecrire sur un bind `:ro`. Renforce par fichiers `root:root 0444` cote source. |
| **Racine read-only** | `--read-only` | cmd destructrice, depot binaire, persistance | Tout le FS sauf tmpfs/binds rw est immuable -> rien a corrompre hors `/workspace`. |
| **tmpfs ephemere** | `--tmpfs ...` | persistance, fuite disque | L'etat runtime disparait a l'arret -> pas d'empoisonnement entre sessions. |
| **Utilisateur non-root** | `USER agent` (UID 10001) | elevation, ecriture sur fichiers root | L'agent n'est pas root : surface noyau reduite, ne possede pas les fichiers de config `root:root`. |
| **Drop de toutes capabilities** | `--cap-drop=ALL` | mount, ptrace, raw sockets, chown... | Retire toutes les capacites Linux ; aucune n'est requise pour faire tourner l'agent. |
| **Pas de nouveaux privileges** | `--security-opt no-new-privileges` | escalade via SUID/setuid | Empeche qu'un binaire SUID regagne des privileges -> ferme la voie d'escalade classique. |
| **Seccomp restreint** | `--security-opt seccomp=./agent/seccomp-claude.json` | syscalls dangereux (`mount`, `ptrace`, `keyctl`, `bpf`, modules noyau...) | Reduit la surface d'appel au **noyau partage** (crucial en LXC). Allowlist de syscalls. |
| **Egress par proxy + allowlist** | `--network tp_egress` + `tp_internal internal` | exfiltration, C2, telechargement de payload | **Une allowlist est un octroi de capacite**, pas un simple filtre. Sortie uniquement via `egress-proxy:8080`, destinations restreintes. Variante stricte : `--network=none`. |
| **Limites cgroups** | `--memory 2g --pids-limit 256 --cpus 2` | DoS local, fork-bomb, epuisement CPU/RAM | Borne le rayon d'impact ressources ; protege l'hote jetable et les autres conteneurs. |
| **Secrets hors image** | injection RUN scopee (`--mount type=...` / env minimal) | vol de credential depuis l'image/layer | Les secrets reels (token API, SSH, `~/.aws`) **n'entrent jamais** dans le conteneur. Pour la demo, un secret **factice** est injecte au run **uniquement sur le profil nu**. |

**Pieges explicitement evites (a NE JAMAIS faire)** :
`-v /var/run/docker.sock` (= controle du demon = evasion immediate), `--privileged`,
`--network=host`, `seccomp=unconfined`, `--cap-add` larges. Aucun n'apparait dans le profil durci.

---

## 5. BONUS — Exfil via un domaine POURTANT autorise (incident Anthropic)

### 5.1 Le probleme

Une allowlist de **domaines** ne suffit pas. Si `api.exemple-autorise.com` est dans l'allowlist
pour une raison legitime, un attaquant peut **exfiltrer un secret** en l'encodant dans une requete
vers ce **meme domaine autorise** (parametre d'URL, sous-domaine DNS, corps POST). Le filtre
« destination » laisse passer car la **destination est valide** — c'est exactement l'angle mort
decrit par Anthropic. *Une allowlist octroie une capacite ; elle ne valide pas l'intention.*

### 5.2 La correction : proxy validant le **token de session** (MITM defensif)

On transpose la defense Anthropic « ne laisser passer que le **token de session provisionne** » :

- Le `egress-proxy` (image `tp-egress-proxy:latest`) fait un **MITM defensif** sur le trafic sortant.
- Il **inspecte le contenu** : seule passe la requete qui porte **exactement** le token de session
  provisionne par l'hote au demarrage (en-tete `Authorization: Bearer <token-de-session>`).
- Toute requete portant une **autre** cle (ex. le `fake_token.txt` exfiltre, ou une cle injectee)
  est **rejetee** (HTTP 403), **meme si le domaine est dans l'allowlist**.
- Le proxy filtre aussi les canaux d'exfil sournois : sous-domaines a haute entropie, query strings
  volumineuses, corps suspects -> defense en profondeur cote contenu.

### 5.3 Demonstration du bonus

1. Ajouter `exfil-server` (ou un domaine « autorise ») a l'allowlist du proxy.
2. **Sans correction** : l'agent encode `FAKE-CORP-TOKEN-...` vers le domaine autorise -> **passe** (angle mort).
3. **Avec correction (MITM token-scope)** : meme requete -> **403** car le secret exfiltre n'est pas
   le token de session provisionne. Seul le trafic legitime portant le bon token transite.

> Message cle du rapport : le filtrage **par destination** est insuffisant ; il faut un controle
> **par contenu/intention** (token de session scope). Defense en profondeur, pas filtre unique.

---

## 6. Taches unitaires ordonnees du master `run.sh` (00..09, fail-fast)

> `run.sh` orchestre tout, en **fail-fast** (`set -euo pipefail`). Chaque etape est un script
> unitaire idempotent dans `tp/scripts/`. Echec d'une etape -> arret immediat avec code != 0.

| # | Script | Role | Verification de succes |
|---|---|---|---|
| **00** | `00-preflight.sh` | Verifie prerequis : `docker`, `incus`, versions ; valide la presence des fichiers de conf et du profil seccomp ; `realpath` sur les chemins. | binaires presents, fichiers conf existants |
| **01** | `01-host-incus.sh` | Cree/demarre l'hote jetable Incus `tp-claude-host` (`images:debian/12`, `security.nesting=true`) et y installe Docker (documenter VM KVM en ideal). | `incus exec ... docker info` OK |
| **02** | `02-build-images.sh` | Construit `claude-hardened:latest`, `tp-egress-proxy:latest`, `tp-exfil-server:latest` (secrets JAMAIS dans les layers). | 3 images presentes (`docker images`) |
| **03** | `03-networks.sh` | Cree les reseaux Docker : `tp_internal` (`--internal`, pas de route sortie) et `tp_egress`. | `docker network ls` montre les 2 reseaux |
| **04** | `04-prepare-config.sh` | Genere/fige la config de l'agent dans `tp/config/` en **`root:root 0444`** (settings/CLAUDE.md/mcp/skills, projet + user) ; prepare le secret factice. | fichiers en 0444, contenu attendu |
| **05** | `05-run-exfil-proxy.sh` | Lance `exfil-server:8000` (cible factice locale) et `egress-proxy:8080` (allowlist + MITM token-scope). | endpoints joignables depuis `tp_egress` |
| **06** | `06-run-nu.sh` | Lance le profil **`nu`** : root, FS rw, caps par defaut, egress libre, secret monte, config bindee **rw**. | conteneur `claude-nu` Up |
| **07** | `07-run-durci.sh` | Lance le profil **`durci`** : `USER agent`, `--read-only` + tmpfs, binds config `:ro`, `--cap-drop=ALL`, `no-new-privileges`, `seccomp=./agent/seccomp-claude.json`, egress via proxy, `--memory 2g --pids-limit 256 --cpus 2`, secret NON monte. | conteneur `claude-hardened` Up, montages `:ro` confirmes |
| **08** | `08-attack-suite.sh` | Rejoue les **6 attaques** sur `nu` PUIS `durci` (reecriture settings/CLAUDE.md/skill/mcp, exfil secret, cmd destructrice) + le **bonus** (exfil via domaine autorise). Capture les resultats. | matrice : `nu`=Reussie, `durci`=Bloquee |
| **09** | `09-report.sh` | Agrege logs/preuves dans `tp/out/`, genere le **tableau attaque/resultat** et les artefacts pour le PDF. | tableau genere, artefacts presents |

**Comportement fail-fast** : `run.sh` execute 00->09 sequentiellement ; toute etape non-zero
stoppe la chaine. Cibles utilitaires attendues : `run.sh up` (00-07), `run.sh attack` (08),
`run.sh report` (09), `run.sh clean` (teardown conteneurs/reseaux + `incus delete --force`).

---

## 7. Matrice de demonstration AVANT/APRES (objectif a atteindre)

| Attaque tentee | Agent **nu** | Agent **durci** | Mesure responsable |
|---|---|---|---|
| 1. Reecriture `settings.json` (injection de hook) | Reussie | **Bloquee** | montage `:ro` |
| 2. Modification `CLAUDE.md` | Reussie | **Bloquee** | montage `:ro` |
| 3. Alteration d'un skill | Reussie | **Bloquee** | skills `:ro` |
| 4. Ajout serveur dans `.mcp.json` | Reussie | **Bloquee** | `:ro` |
| 5. Exfiltration d'un secret factice | Reussie | **Bloquee** | secret non monte / egress refuse |
| 6. Commande destructrice hors workspace | Reussie | **Bloquee** | FS racine `--read-only` |
| BONUS. Exfil via domaine autorise | Reussie (filtre destination naif) | **Bloquee** | proxy MITM token-scope (validation contenu) |

---

## 8. Arborescence cible de `tp/`

```
tp/
├── PLAN.md                         (ce document — source de verite)
├── run.sh                          (master orchestrateur fail-fast 00..09)
├── agent/
│   ├── Dockerfile                  (image claude-hardened: USER agent 10001, non-root)
│   └── seccomp-claude.json         (profil seccomp restreint — allowlist syscalls)
├── proxy/
│   ├── Dockerfile                  (tp-egress-proxy: allowlist + MITM token-scope)
│   └── ...                         (conf Squid/mitmproxy + addon de validation token)
├── exfil/
│   ├── Dockerfile                  (tp-exfil-server: cible factice locale :8000)
│   └── ...                         (serveur HTTP qui logge les hits d'exfil)
├── config/                         (config de l'agent figee root:root 0444)
│   ├── project-settings.json   user-settings.json
│   ├── project-CLAUDE.md        project-mcp.json
│   └── project-skills/  user-skills/   (SKILL.md)
├── workspace/                      (depot de test, monte :rw)
├── scripts/
│   └── 00-preflight.sh ... 09-report.sh
└── out/                            (preuves : logs, captures, tableau genere)
```

---

## 9. Notes de securite du TP (non negociable)

- **Secrets FACTICES uniquement** : `FAKE-CORP-TOKEN-do-not-exfiltrate-1337`. Aucun vrai credential
  n'entre dans un conteneur (ni token API, ni SSH, ni `~/.aws`).
- **Endpoint d'exfil LOCAL** : `exfil-server:8000` vit dans `tp_egress`, jamais sur Internet.
- **Aucune action contre un systeme tiers reel.** Tout le trafic d'attaque reste interne au TP.
- **Hote jetable** : tout se passe dans `tp-claude-host` ; `run.sh clean` detruit tout sans trace.
```
