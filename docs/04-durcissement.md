# 04 — Design de durcissement (PIECE MAITRESSE)

> Le cœur du livrable. Chaque mesure de durcissement Docker est presentee avec son **drapeau
> exact**, la **menace precise** qu'elle bloque, et sa **justification**. Le principe directeur
> est la **defense en profondeur** : aucune mesure n'est suffisante seule ; leur combinaison
> reduit le rayon d'impact a chaque couche (« containment at the environment layer first »,
> Anthropic *How we contain Claude*).

---

## 4.1 Tableau de synthese des mesures

| # | Mesure | Drapeau Docker | Menace bloquee | Categorie(s) |
|---|---|---|---|---|
| 1 | Config en lecture seule | `-v src:dst:ro` | Reecriture settings/CLAUDE.md/skills/mcp | 2, 3 |
| 2 | Racine read-only | `--read-only` | Commande destructrice, depot binaire, persistance | 1, 2, 3 |
| 3 | tmpfs ephemere | `--tmpfs /tmp /run /home/agent/.claude` | Persistance, fuite disque | 2, 3 |
| 4 | Utilisateur non-root | `USER agent` (UID 10001, dans l'image) | Elevation, ecriture sur fichiers root | 1, 2, 3 |
| 5 | Drop de toutes capabilities | `--cap-drop=ALL` | mount, ptrace, raw sockets, chown... | 3 |
| 6 | Pas de nouveaux privileges | `--security-opt no-new-privileges` | Escalade via SUID/setuid | 3 |
| 7 | Seccomp restreint | `--security-opt seccomp=./agent/seccomp-claude.json` | Syscalls dangereux (mount, ptrace, keyctl, bpf, modules...) | 3 |
| 8 | Egress par proxy + allowlist | `--network tp_egress` (+ `tp_internal` internal) | Exfiltration, C2, telechargement de payload | 1, 3 |
| 9 | Limites cgroups | `--memory 2g --pids-limit 256 --cpus 2` | DoS local, fork-bomb, epuisement CPU/RAM | 1 |
| 10 | Secrets hors image | injection RUN scopee (jamais dans les layers) | Vol de credential depuis l'image/layer | 1, 3 |

---

## 4.2 Justification detaillee, mesure par mesure

### Mesure 1 — Config en lecture seule (`:ro`) — **exigence centrale**

```
-v $PWD/config/project-settings.json:/workspace/.claude/settings.json:ro
-v $PWD/config/project-CLAUDE.md:/workspace/CLAUDE.md:ro
-v $PWD/config/project-mcp.json:/workspace/.mcp.json:ro
-v $PWD/config/project-skills:/workspace/.claude/skills:ro
-v $PWD/config/user-settings.json:/home/agent/.claude/settings.json:ro
-v $PWD/config/user-skills:/home/agent/.claude/skills:ro
```

- **Menace bloquee** : reecriture de `settings.json` (injection de hook), empoisonnement de
  `CLAUDE.md`, alteration de skill, ajout de serveur dans `.mcp.json`.
- **Justification** : c'est le verrou demande par l'enonce. Un bind `:ro` est un verrou
  **kernel**, *root-proof* : **meme un process root du conteneur ne peut ecrire** sur le
  montage. Renforce par le **2e verrou** : fichiers sources en `root:root 0444` (l'agent UID
  10001 n'en est pas proprietaire). Voir [`03-partition-table.md`](03-partition-table.md).

### Mesure 2 — Racine read-only (`--read-only`)

- **Menace bloquee** : commande destructrice hors workspace, depot de binaire malveillant,
  persistance sur disque.
- **Justification** : tout le FS, **sauf** les binds rw et les tmpfs explicites, devient
  immuable. Il n'y a plus rien a corrompre en dehors de `/workspace`. `rm -rf /usr`, ecriture
  dans `/etc`, `/bin`... echouent toutes (`Read-only file system`).

### Mesure 3 — tmpfs ephemere (`--tmpfs`)

```
--tmpfs /tmp:rw,noexec,nosuid
--tmpfs /run:rw,noexec,nosuid
--tmpfs /home/agent/.claude:rw,nosuid
```

- **Menace bloquee** : persistance entre sessions, fuite disque.
- **Justification** : combinee a `--read-only`, elle fournit les **rares** zones ecrivables
  necessaires au fonctionnement, mais **en RAM** : tout disparait a l'arret du conteneur ->
  pas d'empoisonnement persistant. `noexec`/`nosuid` empechent d'executer un binaire depose la
  ou de profiter d'un SUID.

### Mesure 4 — Utilisateur non-root (`USER agent`, UID 10001)

- **Menace bloquee** : elevation de privilege, ecriture sur les fichiers `root:root`.
- **Justification** : l'agent ne tourne **jamais** en root. Surface noyau reduite, et l'agent
  n'est **pas proprietaire** des fichiers de config (`root:root`) -> 2e verrou des permissions.
  Defini dans le `Dockerfile` (`USER agent`), pas seulement au run.

### Mesure 5 — Drop de toutes les capabilities (`--cap-drop=ALL`)

- **Menace bloquee** : `mount`, `ptrace`, sockets raw, `chown`, manipulation reseau de bas
  niveau, etc.
- **Justification** : on retire **toutes** les capacites Linux. Claude Code n'en a besoin
  d'**aucune** pour fonctionner. Principe du moindre privilege applique au maximum : on ne
  `--cap-add` rien (un `--cap-add` large est un **piege interdit**).

### Mesure 6 — Pas de nouveaux privileges (`--security-opt no-new-privileges`)

- **Menace bloquee** : escalade via un binaire SUID/setuid.
- **Justification** : empeche tout process enfant de **regagner** des privileges via SUID ->
  ferme la voie d'escalade classique « binaire SUID -> root ». Complement direct de la mesure 4.

### Mesure 7 — Seccomp restreint (`seccomp=./agent/seccomp-claude.json`)

- **Menace bloquee** : appels systeme dangereux — `mount`, `ptrace`, `keyctl`, `bpf`,
  chargement de modules noyau, `pivot_root`, etc.
- **Justification** : reduit la surface d'appel au **noyau** — **crucial ici car le noyau est
  PARTAGE** (anneau 1 = LXC). Le profil est une **allowlist** de syscalls (deny par defaut). On
  n'utilise **jamais** `seccomp=unconfined` (piege interdit).

### Mesure 8 — Egress par proxy + allowlist (`--network tp_egress` ; `tp_internal` internal)

- **Menace bloquee** : exfiltration de donnees, command-and-control (C2), telechargement de
  payload.
- **Justification** : **une allowlist est un OCTROI DE CAPACITE**, pas un simple filtre
  (Anthropic). L'agent n'a **aucune** route directe vers Internet : sortie **uniquement** via
  `egress-proxy:8080`, vers des destinations explicitement autorisees. `tp_internal` est cree
  `--internal` (aucune route hors Docker). Variante la plus stricte : `--network=none`. On ne
  fait **jamais** `--network=host` (piege interdit). Le proxy ajoute la defense **bonus** par
  **MITM token-scope** (voir 4.3).
- **Allowlist effective = une seule destination.** Depuis la migration du backend, l'allowlist
  ne contient plus `api.anthropic.com` : la **seule** destination autorisee est `backend-host`
  (l'endpoint **LiteLLM** sur `ixia`, dont l'agent a besoin pour appeler le modele). Tout le reste
  est **default-deny** -> l'agent compromis ne peut atteindre **que** le serveur de modele, jamais
  un tiers. La cible factice locale `exfil-server` n'est conservee dans l'allowlist que pour
  **demontrer le bonus** (un domaine autorise ne garantit pas une intention sure).

### Mesure 8bis — Cle LiteLLM scopee = controle de capacite + audit (backend externe)

- **Menace bloquee** : usage illimite/non tracable du backend modele, fuite d'un credential a
  large portee, requetes vers un fournisseur tiers.
- **Justification** : l'auth du modele n'est **pas** une cle Anthropic ni un token OAuth, mais une
  **cle virtuelle LiteLLM scopee** (`ANTHROPIC_AUTH_TOKEN=${LITELLM_VIRTUAL_KEY}`), pendant que
  `ANTHROPIC_API_KEY` reste **vide** (sinon elle primerait). Cette cle est un **octroi de capacite**
  cote serveur externe : LiteLLM peut lui attacher des **limites** (budget, rate-limit, modeles
  autorises) et **journalise** chaque appel (`audit`). On peut la **revoquer** unilateralement sur
  `ixia` sans toucher la sandbox. Elle est injectee au runtime depuis `.env` (gitignore), **jamais**
  ecrite dans un layer d'image (coherent avec la mesure 10). Frontiere de confiance et stack
  detaillees en [`09-backend-modele.md`](09-backend-modele.md).

> Le durcissement de l'agent (`:ro`, `cap-drop`, seccomp, egress) est **independant** du moteur de
> modele : remplacer Anthropic par LiteLLM/Ollama ne change **aucun** des verrous ci-dessus ; cela
> ne fait que **reduire** le secret a proteger et l'unique destination d'egress.

### Mesure 9 — Limites cgroups (`--memory 2g --pids-limit 256 --cpus 2`)

- **Menace bloquee** : DoS local, fork-bomb, epuisement CPU/RAM de l'hote jetable.
- **Justification** : borne le rayon d'impact **ressources**. Protege l'hote Incus et les
  autres conteneurs (proxy, exfil) d'un agent qui s'emballe ou d'une fork-bomb (`pids-limit`).

### Mesure 10 — Secrets hors de l'image (injection runtime scopee)

- **Menace bloquee** : vol de credential lu depuis un layer d'image (les layers sont
  inspectables : `docker history`, export du FS...).
- **Justification** : aucun vrai secret (token API, SSH, `~/.aws`) n'entre dans l'image ni
  dans le conteneur durci. Pour la **demo**, un secret **factice**
  (`FAKE-CORP-TOKEN-do-not-exfiltrate-1337`) est injecte au run **uniquement sur le profil
  `nu`** ; sur `durci` il **n'est pas monte** du tout -> l'exfil n'a litteralement rien a voler.

---

## 4.3 BONUS — Exfil via un domaine POURTANT autorise (incident Anthropic)

### Le probleme

Une allowlist de **domaines** ne suffit pas. Si `api.exemple-autorise.com` est dans l'allowlist
pour une raison legitime, un attaquant peut **exfiltrer un secret** en l'encodant dans une
requete vers ce **meme domaine autorise** (parametre d'URL, sous-domaine DNS, corps POST). Le
filtre « destination » laisse passer car la destination **est** valide — c'est l'angle mort
decrit par Anthropic. *Une allowlist octroie une capacite ; elle ne valide pas l'intention.*

### La correction : proxy validant le token de session (MITM defensif)

On transpose la defense Anthropic « ne laisser passer que le **token de session provisionne** » :

- Le `egress-proxy` fait un **MITM defensif** sur le trafic sortant et **inspecte le contenu**.
- Seule passe la requete portant **exactement** le token de session provisionne par l'hote au
  demarrage (en-tete `Authorization: Bearer <token-de-session>`).
- Toute requete portant une **autre** cle — le `fake_token.txt` exfiltre, ou une cle injectee —
  est **rejetee en HTTP 403**, **meme si le domaine est dans l'allowlist**.
- Defense en profondeur cote contenu : le proxy filtre aussi les **sous-domaines a haute
  entropie**, les **query strings volumineuses** et les corps suspects (canaux d'exfil sournois).

### Message cle

> Le filtrage **par destination** est insuffisant. Il faut un controle **par contenu/intention**
> (token de session scope). Defense en profondeur, pas un filtre unique.

---

## 4.4 Pieges explicitement EVITES (a NE JAMAIS faire)

| Piege | Pourquoi c'est dangereux | Statut |
|---|---|---|
| `-v /var/run/docker.sock:...` | Donne le controle du **demon Docker** = evasion immediate vers l'hote | **Jamais monte** |
| `--privileged` | Desactive quasiment toutes les protections (caps, devices, seccomp) | **Jamais utilise** |
| `--network=host` | Supprime l'isolation reseau -> acces direct a la pile reseau de l'hote | **Jamais utilise** |
| `--security-opt seccomp=unconfined` | Reouvre **tous** les syscalls (surface noyau maximale) | **Jamais utilise** |
| `--cap-add` larges | Re-accorde des capacites retirees par `cap-drop=ALL` | **Jamais utilise** |
| Validation de chemin sans `realpath` | Contournement par symlink | **realpath AVANT validation** |

Aucun de ces elements n'apparait dans le profil **durci**.
