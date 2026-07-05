# TP — Durcissement d'un agent Claude Code en conteneur Docker

> **Objectif** : faire tourner l'agent **Claude Code** dans un (des) conteneur(s)
> **Docker** durci(s) et demontrer, par une demo **AVANT/APRES**, que le
> durcissement par **partitionnement read-only du filesystem** protege la config
> et l'etat de l'agent (`settings.json`, `CLAUDE.md`, `SKILL.md`, `.mcp.json`)
> contre un agent compromis — la, ou un profil **nu** (non durci) se laisse
> attaquer.
>
> Le **livrable central** est un **PDF detaille** : [`docs/RAPPORT.md`](docs/RAPPORT.md)
> -> genere via [`scripts/build-pdf.sh`](scripts/build-pdf.sh) (`out/RAPPORT.pdf`).

---

## 1. Index / arborescence

```
tp/
├── README.md                  (ce fichier — index + quickstart)
├── CHECKS.md                  (matrice des 6 attaques + statut de verification)
├── PLAN.md                    (source de verite du design)
├── run.sh                     (orchestrateur fail-fast : ./run.sh all|up|attacks|down)
├── docker-compose.yml         (variante declarative : profils "nu" et "durci")
├── .env.example               (modele d'env ; copier en .env — secrets FACTICES/runtime)
│
├── agent/                     (image de l'agent : claude-hardened:latest)
│   ├── Dockerfile             (USER agent UID 10001, non-root)
│   ├── entrypoint.sh
│   ├── seccomp-claude.json    (profil seccomp restreint — allowlist de syscalls)
│   └── .dockerignore
├── proxy/                     (proxy d'egress : tp-egress-proxy:latest)
│   ├── Dockerfile             (mitmproxy)
│   ├── addon.py               (allowlist default-deny + MITM defensif token-scope)
│   └── allowlist.txt          (domaines autorises : backend-host (endpoint LiteLLM), exfil-server (cible demo))
├── exfil/                     (cible factice LOCALE : tp-exfil-server:latest, :8000)
│   ├── Dockerfile
│   └── server.py              (logge les tentatives d'exfil — preuve)
│
├── config/                    (SOURCES figees root:root 0444/0555 de la config agent)
│   ├── project-settings.json  -> /workspace/.claude/settings.json     (:ro durci)
│   ├── project-CLAUDE.md       -> /workspace/CLAUDE.md                 (:ro durci)
│   ├── project-mcp.json        -> /workspace/.mcp.json                 (:ro durci)
│   ├── project-skills/         -> /workspace/.claude/skills            (:ro durci)
│   ├── user-settings.json      -> /home/agent/.claude/settings.json    (:ro durci)
│   ├── user-skills/            -> /home/agent/.claude/skills           (:ro durci)
│   ├── fake_token.txt          -> /run/secrets/fake_token.txt  (profil NU UNIQUEMENT)
│   └── README-perms.md         (2e verrou : permissions POSIX, defense en profondeur)
├── workspace/                 (depot de test, monte :rw — seule zone metier ecrivable)
│
├── steps/                     (etapes unitaires 00..09 appelees par run.sh)
│   ├── 00-preflight.sh        06-run-durci.sh
│   ├── 01-incus-host.sh       07-attacks-durci.sh
│   ├── 02-build.sh            08-results-table.sh
│   ├── 03-config-perms.sh     09-teardown.sh
│   ├── 04-run-nu.sh
│   └── 05-attacks-nu.sh
├── attacks/                   (scenarios d'attaque documentes 01..06 + payloads)
├── lib/log.sh                 (logger partage : info/ok/warn/err/die + run.log)
├── scripts/
│   ├── incus-host.sh          (provisionne l'hote Incus jetable "tp-claude-host")
│   └── build-pdf.sh           (docs/RAPPORT.md -> out/RAPPORT.pdf)
├── docs/                      (documentation : sections 01..08 + RAPPORT.md assemble)
├── evidence/                  (preuves generees au RUN : run.log, *.tsv, results.md)
└── out/                       (artefacts : RAPPORT.pdf)
```

---

## 2. Prerequis

| Prerequis | Statut | Detail |
|---|---|---|
| **Docker** (demon joignable) | **REQUIS** | Impose par le TP. L'agent ET son execution tournent DANS des conteneurs Docker. |
| **`LITELLM_VIRTUAL_KEY`** (-> `ANTHROPIC_AUTH_TOKEN`) | requis au **runtime** | Cle LiteLLM **scopee** (jamais la master key) servant d'auth de l'agent vers le backend LiteLLM externe (ixia `backend-host:3101`). Injectee au RUN (jamais dans l'image). `ANTHROPIC_API_KEY` reste **vide** (sinon elle primerait). Sans `LITELLM_VIRTUAL_KEY`, les steps basculent sur un fallback bash et les attaques FS/egress fonctionnent quand meme. |
| **Incus** (LXC/VM) | **OPTIONNEL** | Anneau 1 = hote jetable `tp-claude-host`. Si absent ou si l'on travaille deja dans l'hote, poser `SKIP_INCUS=1`. |
| `pandoc` + moteur LaTeX | optionnel | Pour generer le PDF. `scripts/build-pdf.sh` a un fallback documente si absent. |

> **Securite (rappel non negociable)** : tous les secrets sont **FACTICES**
> (`FAKE-CORP-TOKEN-do-not-exfiltrate-1337`), l'endpoint d'exfil est **LOCAL**
> (`exfil-server:8000`, jamais Internet), et **aucune action** n'est menee contre
> un systeme tiers reel. Aucun vrai credential n'entre dans un conteneur.

---

## 3. QUICKSTART

```bash
cd /home/julien/projet/cyber/tp

# 1) Configurer l'environnement (secrets FACTICES / runtime).
cp .env.example .env
#    Editer .env : renseigner LITELLM_VIRTUAL_KEY (cle LiteLLM scopee, runtime)
#    et LITELLM_ENDPOINT (def. http://backend-host:3101). ANTHROPIC_API_KEY
#    doit rester VIDE. Le SESSION_TOKEN de demo peut etre laisse tel quel
#    (le runner en genere un aleatoire).
export LITELLM_VIRTUAL_KEY="sk-litellm-..."   # cle scopee ; ou via .env / votre shell
#    (ANTHROPIC_AUTH_TOKEN=${LITELLM_VIRTUAL_KEY}, ANTHROPIC_API_KEY vide)

# 2) Chaine complete fail-fast : 00 -> 08 (sans teardown).
#    Ajouter SKIP_INCUS=1 si Incus est absent ou si l'on est deja dans l'hote.
SKIP_INCUS=1 ./run.sh all

# 3) Lire la preuve AVANT/APRES : table des 6 attaques + bonus.
cat evidence/results.md
#    Journal central detaille :
cat evidence/run.log
```

### Sous-commandes de `run.sh`

| Commande | Effet |
|---|---|
| `./run.sh all` | Enchaine 00 -> 08 en fail-fast (prerequis, hote, build, perms, NU+attaques, DURCI+attaques, table). |
| `./run.sh up` | Prepare l'infra et lance NU + DURCI (00,01,02,03,04,06) sans rejouer les attaques. |
| `./run.sh attacks` | Rejoue les attaques NU + DURCI puis agrege `evidence/results.md` (05,07,08). |
| `./run.sh down` | Teardown : arret conteneurs/reseaux (Incus optionnel, `KEEP_INCUS=1` pour le garder). |
| `./run.sh <step>` | Execute un step isole, ex. `./run.sh 03` ou `./run.sh 03-config-perms`. |
| `./run.sh list` | Liste les steps disponibles. |

> **Variante Compose** (declarative) : `docker compose --profile durci up -d`
> (ou `--profile nu`). Les sources protegees sont bind-montees `:ro` (profil
> durci) / `:rw` (profil nu). Le runner `run.sh` reste la voie de reference pour
> la demo complete (il provisionne aussi l'hote, les permissions et les preuves).

---

## 4. Generer le livrable PDF

```bash
./scripts/build-pdf.sh            # produit out/RAPPORT.pdf depuis docs/RAPPORT.md
```

- Source assemblee : [`docs/RAPPORT.md`](docs/RAPPORT.md) (sections 01..08).
- Index documentaire : [`docs/README.md`](docs/README.md).
- Si `pandoc`/LaTeX absents, le script l'indique et propose un fallback.

---

## 5. Pour aller plus loin

- **Modele de menace & partitionnement** : [`docs/02-threat-model.md`](docs/02-threat-model.md),
  [`docs/03-partition-table.md`](docs/03-partition-table.md).
- **Design de durcissement** (chaque mesure justifiee) : [`docs/04-durcissement.md`](docs/04-durcissement.md).
- **Defense en profondeur niveau fichier** : [`config/README-perms.md`](config/README-perms.md).
- **Isolation hote (LXC vs VM Incus)** : [`docs/08-isolation-hote.md`](docs/08-isolation-hote.md).
- **Matrice de verification** : [`CHECKS.md`](CHECKS.md).
