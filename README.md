# TP — Durcissement d'un agent Claude Code en conteneur Docker

> **Objectif** : faire tourner l'agent **Claude Code** dans un conteneur **Docker**
> durci et démontrer, par une démo **AVANT/APRÈS**, que le durcissement par
> **partitionnement read-only du filesystem** protège la config et l'état de
> l'agent (`settings.json`, `CLAUDE.md`, `SKILL.md`, `.mcp.json`) contre un agent
> compromis — là où un profil **nu** (non durci) se laisse attaquer.
>
> Le **livrable central** est un **PDF détaillé** : [`docs/RAPPORT.md`](docs/RAPPORT.md)
> → généré via [`scripts/build-pdf.sh`](scripts/build-pdf.sh) (`out/RAPPORT.pdf`).

---

## 1. Architecture (2 anneaux)

```
corrin (hôte réel)
  └── Incus « tp-claude-host » (simule une VM jetable = ANNEAU 1)
        └── Docker imbriqué
              ├── claude-hardened (DURCI = ANNEAU 2, PIÈCE NOTÉE)   IP fixe 172.31.7.2
              └── claude-nu       (NON durci, démo AVANT)
```

- **Tout tourne DANS l'instance Incus** (`docker`/`bash`) ; aucune commande
  opérationnelle depuis corrin.
- **Backend modèle** = **LiteLLM** externe sur **ixia** (`backend-host:3101`,
  hors périmètre). Le durci l'atteint **uniquement** via la passerelle figée
  `tp_internal` `172.31.7.1:3101` (device Incus `litellm` → ixia). Réseau
  `tp_internal --internal` : **aucune route Internet**.
- **Pas de proxy MITM ni de serveur d'exfil** : la **provenance** est assurée par
  la ré-auth LiteLLM (une clé cliente étrangère → **401**), la **destination** par
  le réseau (`--internal`). Cf. [`docs/10-litellm-vs-mitmproxy.md`](docs/10-litellm-vs-mitmproxy.md).
- **SSH** : chaîne de bridges **corrin → incus → docker:2222** (dropbear), posée
  une seule fois (l'IP du durci est fixe). Cf. [`scripts/ssh-bridge.sh`](scripts/ssh-bridge.sh).

## 2. Index / arborescence

```
tp/
├── README.md                  (ce fichier — index + quickstart)
├── run.sh                     (orchestrateur fail-fast : ./run.sh all|up|attacks|down)
├── Makefile                   (raccourcis au-dessus de run.sh : make all|up|attack|clean)
├── docker-compose.yml         (variante déclarative : profils "nu" et "durci")
├── .env.example               (modèle d'env pour Compose ; copier en .env)
│
├── .secret/                   (secrets backend — HORS dépôt, gitignoré)
│   ├── README.md
│   └── litellm.env.example    (modèle : virtual key LiteLLM scopée, endpoint, modèle)
│
├── agent/                     (image de l'agent : claude-hardened:latest = zurban/tp-claude-hardened)
│   ├── Dockerfile             (USER agent UID 10001, non-root ; dropbear pour SSH)
│   ├── entrypoint.sh
│   ├── claude-session         (forced-command SSH : lance Claude Code, jamais un shell)
│   ├── seccomp-claude.json    (profil seccomp restreint — allowlist de syscalls)
│   └── .dockerignore
│
├── config/                    (SOURCES figées root:root 0444/0555 de la config agent)
│   ├── project-settings.json  -> /workspace/.claude/settings.json     (:ro durci)
│   ├── project-CLAUDE.md       -> /workspace/CLAUDE.md                 (:ro durci)
│   ├── project-mcp.json        -> /workspace/.mcp.json                 (:ro durci)
│   ├── project-skills/         -> /workspace/.claude/skills            (:ro durci)
│   ├── user-settings.json      -> /home/agent/.claude/settings.json    (:ro durci)
│   ├── user-skills/            -> /home/agent/.claude/skills           (:ro durci)
│   ├── fake_token.txt          -> /run/secrets/fake_token.txt   (profil NU UNIQUEMENT)
│   ├── ssh-authorized_keys.example  (clé SSH autorisée — durcissement forced-command)
│   └── README-perms.md         (2e verrou : permissions POSIX, défense en profondeur)
├── workspace/                 (dépôt de test, monté :rw — seule zone métier écrivable)
│
├── steps/                     (étapes unitaires 00..09 appelées par run.sh)
│   ├── 00-preflight.sh        05-attacks-nu.sh
│   ├── 01-incus-host.sh       06-run-durci.sh
│   ├── 02-build.sh            07-attacks-durci.sh
│   ├── 03-config-perms.sh     08-results-table.sh
│   └── 04-run-nu.sh           09-teardown.sh
├── attacks/                   (scénarios d'attaque documentés 01..06 + payloads d'injection)
├── lib/log.sh                 (logger partagé + chargement de .secret/litellm.env)
├── scripts/
│   ├── incus-host.sh          (provisionne l'hôte Incus jetable "tp-claude-host")
│   ├── ssh-bridge.sh          (bridge SSH corrin → incus → docker, posé une fois)
│   ├── recreate-daily.sh      (recréation anti-persistance, interne à l'instance)
│   ├── systemd/               (tp-recreate.service + .timer : recréation 24 h)
│   └── build-pdf.sh           (docs/RAPPORT.md -> out/RAPPORT.pdf)
├── docs/                      (documentation : sections 01..10 + RAPPORT.md assemblé)
├── evidence/                  (preuves générées au RUN : run.log, *.tsv, results.md ; gitignoré)
└── out/                       (artefacts : RAPPORT.pdf ; gitignoré)
```

*(Le code écarté du design à proxy — `proxy/`, `exfil/` — est conservé en local
sous `old/` mais n'est **pas** dans le dépôt.)*

---

## 3. Prérequis

| Prérequis | Statut | Détail |
|---|---|---|
| **Docker** (démon joignable, DANS l'instance) | **REQUIS** | Imposé par le TP. L'agent ET son exécution tournent DANS des conteneurs Docker. |
| **`.secret/litellm.env`** (virtual key LiteLLM) | requis au **runtime** | Clé LiteLLM **scopée** (jamais la master key) = auth de l'agent vers le backend LiteLLM externe (ixia). Chargée par `lib/log.sh`, jamais dans l'image ni le dépôt. Sans elle, les steps basculent sur un fallback bash et les attaques FS/egress fonctionnent quand même. |
| **Incus** (LXC/VM) | anneau 1 | Hôte jetable `tp-claude-host`. Si l'on travaille déjà dans l'hôte, poser `SKIP_INCUS=1`. |
| `pandoc` + moteur LaTeX | optionnel | Pour générer le PDF. `scripts/build-pdf.sh` a un fallback documenté. |

> **Sécurité (rappel non négociable)** : tous les secrets sont **FACTICES**
> (`FAKE-CORP-TOKEN-do-not-exfiltrate-1337`), aucune cible tierce réelle n'est
> visée, et **aucune clé Anthropic n'entre dans la sandbox** (seule une virtual
> key LiteLLM scopée sert d'auth ; `ANTHROPIC_API_KEY` reste vide).

---

## 4. QUICKSTART (dans l'instance Incus)

```bash
# 0) Image de l'agent : build local, OU pull depuis DockerHub sur une VM neuve
docker pull zurban/tp-claude-hardened:latest \
  && docker tag zurban/tp-claude-hardened:latest claude-hardened:latest

# 1) Secret backend (hors dépôt) : coller la virtual key LiteLLM scopée
cp .secret/litellm.env.example .secret/litellm.env
#    éditer .secret/litellm.env : LITELLM_VIRTUAL_KEY=sk-... (sinon fallback bash)

# 2) Clé SSH autorisée (durci) : y mettre votre clé publique
cp config/ssh-authorized_keys.example config/ssh-authorized_keys
#    éditer config/ssh-authorized_keys

# 3) Chaîne complète fail-fast : 00 -> 08 (sans teardown).
SKIP_INCUS=1 ./run.sh all       # SKIP_INCUS=1 si l'on est déjà dans l'instance

# 4) Lire la preuve AVANT/APRÈS : table des 6 attaques + bonus.
cat evidence/results.md
cat evidence/attacks-durci-detail.log   # commande + code retour + hash avant/après
```

### Sous-commandes de `run.sh`

| Commande | Effet |
|---|---|
| `./run.sh all` | Enchaîne 00 → 08 en fail-fast (préreq, hôte, build, perms, NU+attaques, DURCI+attaques, table). |
| `./run.sh up` | Prépare l'infra et lance NU + DURCI (00,01,02,03,04,06) sans rejouer les attaques. |
| `./run.sh attacks` | Rejoue les attaques NU + DURCI puis agrège `evidence/results.md` (05,07,08). |
| `./run.sh down` | Teardown : arrêt conteneurs/réseaux (Incus optionnel, `KEEP_INCUS=1` pour le garder). |
| `./run.sh <step>` | Exécute un step isolé, ex. `./run.sh 06-run-durci`. |

> **Recréation anti-persistance** : `scripts/recreate-daily.sh` (interne à
> l'instance) détruit et recrée le durci ; l'IP fixe garde le bridge SSH valide.
> Timer 24 h dans `scripts/systemd/`.
>
> **Variante Compose** (déclarative) : `docker compose --profile durci up -d`
> (ou `--profile nu`). `run.sh` reste la voie de référence (il provisionne aussi
> l'hôte, les permissions et les preuves).

---

## 5. Générer le livrable PDF

```bash
./scripts/build-pdf.sh            # produit out/RAPPORT.pdf depuis docs/RAPPORT.md
```

- Source assemblée : [`docs/RAPPORT.md`](docs/RAPPORT.md) (sections 01..10).
- Si `pandoc`/LaTeX absents, le script l'indique et propose un fallback.

---

## 6. Pour aller plus loin

- **Modèle de menace & partitionnement** : [`docs/02-threat-model.md`](docs/02-threat-model.md),
  [`docs/03-partition-table.md`](docs/03-partition-table.md).
- **Design de durcissement** (chaque mesure justifiée) : [`docs/04-durcissement.md`](docs/04-durcissement.md).
- **Défense en profondeur niveau fichier** : [`config/README-perms.md`](config/README-perms.md).
- **Backend LiteLLM vs proxy MITM** (justification « pas de proxy ») : [`docs/10-litellm-vs-mitmproxy.md`](docs/10-litellm-vs-mitmproxy.md).
- **Isolation hôte (LXC vs VM Incus)** : [`docs/08-isolation-hote.md`](docs/08-isolation-hote.md).
- **Matrice de vérification** : `evidence/results.md` (générée au run).
