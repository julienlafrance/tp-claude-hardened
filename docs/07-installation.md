# 07 — Installation & exploitation

> Processus d'installation et d'execution, en commandes bash. Reflete le master `run.sh` et ses
> etapes unitaires `00..09` (fail-fast, `set -euo pipefail`). En pratique, **on n'execute pas les
> commandes a la main** : on lance `run.sh`. Cette page documente ce que fait chaque etape, pour
> le rapport et le debug.

---

## 7.1 Prerequis

| Outil | Version attendue | Verifie par |
|---|---|---|
| Incus | >= 6.x / 7.x | `00-preflight.sh` |
| Docker | 29.5.2 (cgroup v2 + seccomp) | `00-preflight.sh` |
| bash | >= 5 | — |
| pandoc *(optionnel)* | pour generer le PDF du rapport | `scripts/build-pdf.sh` |
| Backend modele externe | **LiteLLM** sur `ixia` (`backend-host:3101`) -> Ollama, joignable | `00-preflight.sh` |

L'agent reel est **Claude Code** (`claude` v2.1.191), installe **dans** l'image Docker (jamais
sur l'hote). Son **backend LLM** est un service **externe** (LiteLLM -> Ollama) sur `ixia` ;
voir [`09-backend-modele.md`](09-backend-modele.md).

### Variables d'environnement du backend modele (profils nu ET durci)

L'agent est configure pour parler a LiteLLM via le protocole **compatible Anthropic**. Ces
variables sont injectees au runtime depuis `.env` (gitignore) ; aucune n'entre dans une image.

| Variable | Valeur | Role |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `${LITELLM_ENDPOINT}` (def. `http://backend-host:3101`) | endpoint LiteLLM (au lieu d'Anthropic) |
| `ANTHROPIC_AUTH_TOKEN` | `${LITELLM_VIRTUAL_KEY}` | **cle LiteLLM scopee** (jamais la master key) |
| `ANTHROPIC_API_KEY` | *(vide)* | **doit rester vide** — sinon elle prime sur `AUTH_TOKEN` |
| `ANTHROPIC_MODEL` | `qwen2.5-coder:14b` | modele principal |
| `ANTHROPIC_SMALL_FAST_MODEL` | `qwen3:0.6b` | modele rapide auxiliaire |

> La dependance a une cle Anthropic / `CLAUDE_CODE_OAUTH_TOKEN` comme auth principale est
> **supprimee**. L'auth se fait **uniquement** par la cle LiteLLM scopee.

### Creer la cle LiteLLM scopee (cote ixia, hors sandbox)

La cle virtuelle est emise par LiteLLM sur `ixia` (jamais la master key), avec une **portee
limitee** (modeles autorises, budget/rate-limit), puis copiee dans `.env` :

```bash
# Sur ixia (serveur EXTERNE) — emettre une cle scopee via l'API LiteLLM :
curl -s http://backend-host:3101/key/generate \
  -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"models":["qwen2.5-coder:14b","qwen3:0.6b"],"max_budget":5}'
# -> recupere la "key" (sk-litellm-...) retournee.

# Cote TP, la deposer dans .env (gitignore) — JAMAIS en clair dans le depot :
#   LITELLM_ENDPOINT=http://backend-host:3101
#   LITELLM_VIRTUAL_KEY=<cle-scopee-retournee>
```

---

## 7.2 Demarrage rapide (cibles du master)

```bash
cd /home/julien/projet/cyber/tp

# Met en place tout l'environnement (etapes 00 a 07) :
#   hote Incus, build des 3 images, reseaux, config figee, proxy+exfil, profils nu & durci.
./run.sh up

# Rejoue les 6 attaques + le bonus sur nu PUIS sur durci (etape 08) :
./run.sh attack

# Agrege les preuves et genere le tableau de resultats dans tp/out/ (etape 09) :
./run.sh report

# Detruit tout sans laisser de trace (teardown Docker + incus delete --force) :
./run.sh clean
```

> `run.sh` est **fail-fast** : toute etape non-zero stoppe la chaine avec un code != 0.

---

## 7.3 Detail des etapes `00..09`

> Les commandes ci-dessous sont **illustratives** (elles refletent l'intention de chaque
> script du groupe `scripts`). Les drapeaux exacts du profil durci sont en 7.4.

### 00 — `00-preflight.sh` (prerequis)

```bash
command -v docker incus >/dev/null            # binaires presents
docker --version ; incus --version            # versions attendues
test -f agent/seccomp-claude.json             # profil seccomp present
test -f config/project-settings.json          # config presente
# Backend modele externe : verifie que l'auth scopee et l'endpoint sont definis
# (warn si LITELLM_VIRTUAL_KEY / ANTHROPIC_AUTH_TOKEN absent ; plus de controle sur ANTHROPIC_API_KEY) :
test -n "${ANTHROPIC_AUTH_TOKEN:-${LITELLM_VIRTUAL_KEY:-}}"
test -n "${LITELLM_ENDPOINT:-}"
# Resolution des symlinks AVANT toute validation de chemin :
realpath config/project-settings.json
```

### 01 — `01-host-incus.sh` (anneau 1 : hote jetable Incus)

```bash
# CONTENEUR LXC (implemente : leger, noyau PARTAGE) :
incus launch images:debian/12 tp-claude-host -c security.nesting=true
incus exec tp-claude-host -- bash -c 'apt-get update && apt-get install -y docker.io'
incus exec tp-claude-host -- docker info     # verifie Docker imbrique OK

# IDEAL documente (non implemente) : VM Incus (noyau DEDIE, isolation plus forte) :
#   incus launch images:debian/12 tp-claude-host --vm -c security.secureboot=false
# Voir docs/08-isolation-hote.md pour la justification du choix.
```

### 02 — `02-build-images.sh` (build des 3 images, secrets JAMAIS dans les layers)

```bash
docker build -t claude-hardened:latest   ./agent
docker build -t tp-egress-proxy:latest   ./proxy
docker build -t tp-exfil-server:latest   ./exfil
docker images | grep -E 'claude-hardened|tp-egress-proxy|tp-exfil-server'
```

### 03 — `03-networks.sh` (reseaux Docker)

```bash
# tp_internal : --internal => AUCUNE route vers l'exterieur de Docker.
docker network create --internal tp_internal
# tp_egress : reseau ou vivent l'agent (cote sortie), le proxy et l'exfil.
docker network create tp_egress
docker network ls | grep -E 'tp_internal|tp_egress'
```

### 04 — `04-prepare-config.sh` (config figee root:root 0444)

```bash
# Les fichiers de config sont figes en lecture seule, proprietaire root (2e verrou) :
sudo chown root:root config/project-settings.json config/project-CLAUDE.md \
                      config/project-mcp.json config/user-settings.json
sudo chmod 0444       config/project-settings.json config/project-CLAUDE.md \
                      config/project-mcp.json config/user-settings.json
# (idem pour project-skills/ et user-skills/ et leurs SKILL.md)
# Prepare aussi le secret factice (monte UNIQUEMENT sur le profil nu).
```

### 05 — `05-run-exfil-proxy.sh` (cible factice + proxy)

```bash
docker run -d --name exfil-server  --network tp_egress -p 8000 tp-exfil-server:latest
docker run -d --name egress-proxy  --network tp_egress -p 8080 \
  -e SESSION_TOKEN="<token-de-session-provisionne>" tp-egress-proxy:latest
```

### 06 — `06-run-nu.sh` (profil NU, vulnerable)

```bash
docker run -d --name claude-nu \
  --network tp_egress \                          # egress libre
  -v "$PWD/workspace:/workspace" \               # workspace rw
  -v "$PWD/config/project-settings.json:/workspace/.claude/settings.json" \  # bind RW (pas de :ro)
  -v "$PWD/config/project-CLAUDE.md:/workspace/CLAUDE.md" \
  -v "$PWD/config/project-mcp.json:/workspace/.mcp.json" \
  -v "$PWD/config/project-skills:/workspace/.claude/skills" \
  -v "$PWD/secret/fake_token.txt:/run/secrets/fake_token.txt" \  # secret MONTE
  -e ANTHROPIC_BASE_URL="${LITELLM_ENDPOINT}" \                  # backend = LiteLLM externe (ixia)
  -e ANTHROPIC_AUTH_TOKEN="${LITELLM_VIRTUAL_KEY}" \             # cle LiteLLM scopee (auth modele)
  -e ANTHROPIC_API_KEY= \                                        # VIDE (sinon prime sur AUTH_TOKEN)
  -e ANTHROPIC_MODEL=qwen2.5-coder:14b \
  -e ANTHROPIC_SMALL_FAST_MODEL=qwen3:0.6b \
  --user 0:0 \                                   # root
  claude-hardened:latest sleep infinity
# => root, FS rw, caps par defaut, seccomp default, secret present, config reecrivable.
```

### 07 — `07-run-durci.sh` (profil DURCI, protege) — le cœur

Voir 7.4 pour l'invocation complete et commentee.

### 08 — `08-attack-suite.sh` (6 attaques + bonus, sur nu puis durci)

```bash
# Pour chaque attaque (reecriture settings/CLAUDE.md/skill/mcp, exfil, rm destructeur, bonus) :
#   - la lancer dans claude-nu      => attendu : Reussie
#   - la lancer dans claude-hardened => attendu : Bloquee
# Capture les codes retour et messages (ex. "Read-only file system", "403").
```

### 09 — `09-report.sh` (agregation des preuves)

```bash
mkdir -p out
# Agrege logs, decisions proxy, hits exfil, et genere le tableau attaque/resultat dans out/.
```

---

## 7.4 Invocation complete du profil DURCI (reference)

```bash
docker run -d --name claude-hardened \
  --user 10001:10001 \                                   # 4) non-root (UID agent)
  --read-only \                                          # 2) racine en lecture seule
  --tmpfs /tmp:rw,noexec,nosuid \                        # 3) ephemere
  --tmpfs /run:rw,noexec,nosuid \                        # 3) ephemere
  --tmpfs /home/agent/.claude:rw,nosuid \                # 3) ETAT ephemere (monte EN PREMIER)
  -v "$PWD/workspace:/workspace" \                       #    workspace rw (seule zone metier)
  -v "$PWD/config/project-settings.json:/workspace/.claude/settings.json:ro" \  # 1) :ro
  -v "$PWD/config/project-CLAUDE.md:/workspace/CLAUDE.md:ro" \                   # 1) :ro
  -v "$PWD/config/project-mcp.json:/workspace/.mcp.json:ro" \                    # 1) :ro
  -v "$PWD/config/project-skills:/workspace/.claude/skills:ro" \                 # 1) :ro
  -v "$PWD/config/user-settings.json:/home/agent/.claude/settings.json:ro" \     # 1) :ro (PAR-DESSUS le tmpfs)
  -v "$PWD/config/user-skills:/home/agent/.claude/skills:ro" \                   # 1) :ro (PAR-DESSUS le tmpfs)
  --cap-drop=ALL \                                       # 5) plus aucune capability
  --security-opt no-new-privileges \                     # 6) pas d'escalade SUID
  --security-opt seccomp=./agent/seccomp-claude.json \   # 7) seccomp restreint
  --network tp_internal \                                # 8) pas de route directe (sortie via proxy)
  --memory 2g --pids-limit 256 --cpus 2 \                # 9) limites cgroups
  -e ANTHROPIC_BASE_URL="${LITELLM_ENDPOINT}" \          #    backend = LiteLLM externe (ixia, via proxy -> backend-host)
  -e ANTHROPIC_AUTH_TOKEN="${LITELLM_VIRTUAL_KEY}" \     #    cle LiteLLM scopee (8bis : capacite + audit)
  -e ANTHROPIC_API_KEY= \                                #    VIDE (sinon prime sur AUTH_TOKEN)
  -e ANTHROPIC_MODEL=qwen2.5-coder:14b \
  -e ANTHROPIC_SMALL_FAST_MODEL=qwen3:0.6b \
  claude-hardened:latest sleep infinity
# 10) le secret factice n'est PAS monte sur ce profil. Aucune cle Anthropic dans la sandbox :
#     l'auth modele est la SEULE cle LiteLLM scopee, l'egress n'autorise que backend-host.
```

> **Ordre de montage critique** : `--tmpfs /home/agent/.claude` est declare **avant** les binds
> `:ro` de `settings.json`/`skills` afin que ceux-ci se posent **par-dessus** le tmpfs (l'agent
> ecrit son etat runtime, mais jamais sa config). Voir [`03-partition-table.md`](03-partition-table.md).

> Les valeurs exactes des drapeaux et l'attachement reseau (proxy via `tp_egress` /
> `HTTP_PROXY`) sont fixes par le groupe `scripts` (07) ; cette page documente l'intention.
