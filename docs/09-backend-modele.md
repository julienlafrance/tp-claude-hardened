# 09 — Backend modele externe (ANNEXE)

> **Annexe.** L'agent durci ne parle jamais directement a un fournisseur de modele. Son backend
> LLM est un service **externe** de confiance — **LiteLLM** sur la machine `ixia`
> (`backend-host:3101`) — qui route soit vers **Ollama** (modeles locaux), soit vers l'**API
> Anthropic** avec sa propre cle (cf. rapport §2.3). Cette annexe decrit ce serveur comme **frontiere de
> confiance HORS perimetre de durcissement**, donne la stack `docker compose` d'ixia (tous secrets
> en `${VARS}`), et explicite la phrase-cle du TP.

---

## 9.1 Phrase-cle

> **L'agent est durci ; le modele vient d'un service externe de confiance** => le **secret d'API
> est hors sandbox** et la sandbox n'a **aucun egress direct vers un tiers**. Le durcissement
> (`:ro` / `cap-drop` / `seccomp` / egress) est **INDEPENDANT du moteur** : on peut changer de
> modele sans toucher un seul verrou de l'anneau 2.

Concretement : chaque prompt de Claude Code part vers LiteLLM sur `ixia`, qui le sert selon le
modele demande :

- **route interne** — `qwen3:8b` via Ollama (GPU local) : aucune donnee ne quitte le perimetre ;
- **route externe** — `claude-sonnet-5` via l'API Anthropic, avec la cle API **de LiteLLM**
  (variable d'environnement cote ixia) : le prompt part chez Anthropic, mais aucune cle
  Anthropic n'est dans la sandbox.

---

## 9.2 Frontiere de confiance (ixia est HORS perimetre)

```
[ SANDBOX DURCIE — anneau 2 ]                      [ SERVEUR DE MODELE EXTERNE — ixia ]
  claude-hardened (Claude Code)                      backend-host:3101
    ANTHROPIC_BASE_URL = http://172.31.7.1:3101       LiteLLM (passerelle compatible Anthropic/OpenAI)
    ANTHROPIC_AUTH_TOKEN = <cle LiteLLM scopee>          |
    ANTHROPIC_API_KEY = (vide)                           +-- route --> Ollama (RTX 3080 Ti) : qwen3:8b
        |                                                +-- route --> API Anthropic : claude-sonnet-5
        |  egress UNIQUE : passerelle 172.31.7.1:3101    |             (cle API de LiteLLM, pas de l'agent)
        v  (tp_internal --internal, device Incus)        +-- litellm-db (PostgreSQL) : cles/usage/audit
   ============ FRONTIERE DE CONFIANCE ============       +-- open-webui (console humaine)
   (tout ce qui est a gauche est DURCI et NOTE ;          (suppose securise par ailleurs,
    ixia, a droite, est suppose securise par ailleurs)     decrit a la maille interface)
```

- **A gauche (notee)** : l'agent et son confinement Docker. C'est la **piece du TP**.
- **A droite (hors perimetre)** : `ixia`. On ne durcit **pas** ixia dans ce TP ; on le **suppose
  securise par ailleurs** et on ne le decrit qu'a la maille **interface** : une adresse
  (`backend-host:3101`), un protocole (compatible Anthropic), une auth (cle LiteLLM scopee).

### Pourquoi cette frontiere ameliore la posture

| Critere | Avant (Anthropic / OAuth) | Apres (LiteLLM externe) |
|---|---|---|
| Secret en sandbox | cle `sk-ant-...` / token OAuth Anthropic | **cle LiteLLM scopee** seulement (`ANTHROPIC_API_KEY` vide) |
| Egress legitime | `api.anthropic.com` (Internet) | **un seul** endpoint local : `backend-host` |
| Donnees (prompts) | partent chez un tiers | restent sur ixia/Ollama (route interne) ; partent chez Anthropic via LiteLLM (route externe) |
| Revocation / limites / audit | cote compte Anthropic | cote LiteLLM (cle scopee revocable, budget, rate-limit, logs) |

---

## 9.3 Interface vue par l'agent (contrat)

L'agent ne connait d'ixia que ces variables (injectees au runtime depuis `.env`, gitignore) :

| Variable | Valeur | Sens |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `${LITELLM_ENDPOINT}` (def. durci : `http://172.31.7.1:3101`) | ou envoyer les requetes |
| `ANTHROPIC_AUTH_TOKEN` | `${LITELLM_VIRTUAL_KEY}` | **cle LiteLLM scopee** (jamais la master key) |
| `ANTHROPIC_API_KEY` | *(vide)* | **doit rester vide** : sinon elle prime sur `AUTH_TOKEN` |
| `ANTHROPIC_MODEL` | `qwen3:8b` (par defaut) ou `claude-sonnet-5` | modele principal |
| `ANTHROPIC_SMALL_FAST_MODEL` | idem | modele rapide auxiliaire |

> La dependance a une cle Anthropic ou a `CLAUDE_CODE_OAUTH_TOKEN` comme auth principale est
> **supprimee**. L'unique credential present dans la sandbox est la cle **LiteLLM scopee**,
> revocable cote ixia (cf. rapport, §2.3 et §7.2).

---

## 9.4 Stack d'ixia (`docker compose`, secrets en `${VARS}`)

> Donne **a titre documentaire** : cette stack tourne sur `ixia` (hors perimetre du TP). **Tous**
> les secrets sont references par variable d'environnement ; **aucune** valeur en clair.

```yaml
# ixia — stack de service modele (HORS perimetre de durcissement du TP).
# Aucune valeur de secret en clair : tout vient de l'environnement / d'un .env gitignore.
services:

  litellm:
    image: ghcr.io/berriai/litellm:v1.89.4
    container_name: litellm
    restart: unless-stopped
    ports:
      - "3101:4000"                       # endpoint compatible Anthropic/OpenAI (backend-host:3101)
    environment:
      LITELLM_MASTER_KEY: ${LITELLM_MASTER_KEY}     # master key (emet les cles scopees) — JAMAIS dans la sandbox
      ANTHROPIC_API_KEY: ${ANTHROPIC_API_KEY}       # route externe claude-sonnet-5 — reste sur ixia
      LITELLM_SALT_KEY: ${LITELLM_SALT_KEY}         # chiffrement des cles stockees
      DATABASE_URL: ${LITELLM_DATABASE_URL}         # postgres://...:${POSTGRES_PASSWORD}@litellm-db:5432/litellm
    depends_on:
      - litellm-db
      - ollama
    # litellm_config.yaml (extrait) :
    #   - model_name: qwen3:8b         -> ollama_chat/qwen3:8b (num_ctx 32768, think: false)
    #   - model_name: claude-sonnet-5  -> anthropic/claude-sonnet-5 (api_key: os.environ/ANTHROPIC_API_KEY)
    #   (+ d'autres modeles Ollama, hors TP)

  litellm-db:
    image: postgres:16-alpine
    container_name: litellm-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}       # secret -> variable, jamais en clair
    volumes:
      - litellm-db-data:/var/lib/postgresql/data

  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    deploy:                                         # RTX 3080 Ti (modeles locaux)
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    volumes:
      - ollama-models:/root/.ollama                 # modeles locaux (dont qwen3:8b)

  open-webui:
    image: ghcr.io/open-webui/open-webui:latest
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "3000:8080"                                 # console humaine (admin ixia, hors agent)
    environment:
      WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY}         # secret -> variable
      OPENAI_API_BASE_URL: ${LITELLM_ENDPOINT}      # tape sur LiteLLM
      OPENAI_API_KEY: ${OPENWEBUI_LITELLM_KEY}      # cle scopee dediee a open-webui
    depends_on:
      - litellm

volumes:
  litellm-db-data:
  ollama-models:
```

| Service | Image / version | Role |
|---|---|---|
| `litellm` | `ghcr.io/berriai/litellm:v1.89.4` | proxy compatible Anthropic ; emet les cles scopees ; journalise l'usage (audit) |
| `litellm-db` | `postgres:16-alpine` | persiste cles virtuelles, budgets, usage/audit de LiteLLM |
| `ollama` | `ollama/ollama` (GPU RTX 3080 Ti) | sert les modeles **locaux** (dont `qwen3:8b`, retenu pour le TP) |
| `open-webui` | `ghcr.io/open-webui/open-webui` | console humaine d'administration (hors chemin de l'agent) |

> **`v1.89.4`** = version autoritaire de LiteLLM sur ixia. Les secrets (`LITELLM_MASTER_KEY`,
> `POSTGRES_PASSWORD`, `WEBUI_SECRET_KEY`, etc.) restent des **variables** : ils vivent dans un
> `.env` gitignore cote ixia, **jamais** dans le depot du TP ni dans la sandbox. La sandbox ne
> recoit **que** la cle **scopee** `LITELLM_VIRTUAL_KEY`.

---

## 9.5 En une phrase (pour le rapport)

> Le moteur de l'agent est **deporte** sur un service externe de confiance (LiteLLM sur ixia,
> vers Ollama ou l'API Anthropic) : **aucune cle Anthropic dans la sandbox**, **un seul egress
> autorise** (la passerelle LiteLLM). Le durcissement Docker reste **strictement
> inchange** — il est independant du moteur de modele.
