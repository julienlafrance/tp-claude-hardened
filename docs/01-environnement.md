# 01 — Environnement

> Description complete de l'environnement materiel et logiciel dans lequel le TP
> « Durcissement d'un agent de codage (Agentic) en conteneur Docker » est realise.
> Objectif : que le correcteur puisse **reproduire** l'environnement a l'identique.

---

## 1.1 Vue d'ensemble (architecture a 2 anneaux)

Le TP empile **deux frontieres d'isolation** independantes — c'est la « defense en
profondeur » recommandee par Anthropic (*How we contain Claude* : « containment at the
environment layer first »). Un agent compromis doit franchir **les deux** pour atteindre
la machine reelle de l'etudiant.

```
Machine hote reelle (poste etudiant Linux)
   └── Anneau 1 : conteneur Incus LXC "tp-claude-host" (jetable, security.nesting=true)
          └── Docker imbrique 29.5.2
                 ├── Anneau 2 : conteneur Docker "claude-hardened" (DURCI)  <- PIECE NOTEE
                 ├── conteneur "claude-nu" (NON durci, pour la demo avant/apres)
                 ├── conteneur "egress-proxy" (allowlist + MITM token-scope)
                 └── conteneur "exfil-server" (cible factice locale)

Serveur de modele EXTERNE (HORS perimetre de durcissement, suppose securise par ailleurs)
   ixia backend-host:3101  ──  LiteLLM (proxy OpenAI/Anthropic-compatible) -> Ollama (modeles locaux)
```

> **Frontiere de confiance (nouveau).** L'agent ne parle **plus** a Anthropic. Son backend LLM
> est un service **externe** sur la machine `ixia` (`backend-host:3101`) : **LiteLLM** route
> vers **Ollama** (modeles locaux, GPU). C'est la **seule** destination d'egress autorisee depuis
> la sandbox -> aucun secret Anthropic, aucun appel vers un tiers. Voir
> [`09-backend-modele.md`](09-backend-modele.md).

---

## 1.2 Hote reel (machine Linux de l'etudiant)

| Element | Valeur |
|---|---|
| OS | Linux (noyau 6.8.x, cgroup v2 actif) |
| Gestionnaire de conteneurs systeme | **Incus** (>= 6.x / 7.x) pour l'anneau 1 |
| Moteur de conteneurs applicatif | **Docker 29.5.2** (cgroup v2 + seccomp actifs) |
| Repertoire projet | `/home/julien/projet/cyber/tp` |

L'hote reel n'execute **jamais** l'agent directement. Tout le bac a sable (Docker + agent)
vit dans l'anneau 1 (Incus), de sorte qu'un `incus delete --force` efface toute trace.

---

## 1.3 Anneau 1 — instance Incus `tp-claude-host` (CONTENEUR LXC + nesting)

| Element | Valeur exacte |
|---|---|
| Type | **Conteneur Incus (LXC)** — *implemente* |
| Nom de l'instance | `tp-claude-host` |
| Image de base | `images:debian/12` |
| Option critique | `security.nesting=true` (autorise **Docker imbrique**) |
| Noyau | **PARTAGE** avec l'hote reel (un seul noyau) |
| Role | Hote jetable : isole tout le TP Docker de la machine etudiante |

> **Nuance de securite (a retenir pour le rapport).** Un conteneur LXC partage le noyau de
> l'hote. `security.nesting=true` assouplit l'isolation pour permettre Docker imbrique : c'est
> **plus leger** mais **moins sur** qu'une machine virtuelle. On l'assume car la **partie notee**
> du TP est le durcissement **Docker** (anneau 2), pas l'isolation de l'hote. La cible **ideale**
> documentee est une **VM Incus** (`incus launch ... --vm`, KVM, noyau dedie) — voir
> [`08-isolation-hote.md`](08-isolation-hote.md).

---

## 1.4 Anneau 2 — moteur Docker imbrique

| Element | Valeur |
|---|---|
| Version Docker | **29.5.2** |
| Fonctions noyau utilisees | cgroup v2 (limites ressources), seccomp (filtrage syscalls), capabilities, user namespaces |
| Reseaux crees | `tp_internal` (`--internal`, **aucune** route sortie) et `tp_egress` (vers le proxy) |
| Images construites | `claude-hardened:latest`, `tp-egress-proxy:latest`, `tp-exfil-server:latest` |

C'est dans Docker que se joue toute la demonstration **avant/apres** (profils `nu` vs `durci`).

---

## 1.5 Agent reel cible : Claude Code

| Element | Valeur |
|---|---|
| Agent | **Claude Code** (`claude`), agent de codage terminal-native d'Anthropic |
| Version | **v2.1.191** |
| Mode d'execution | Embarque **dans** un conteneur Docker (impose par l'enonce) |
| Backend LLM | **LiteLLM externe** sur `ixia` (`backend-host:3101`) -> **Ollama** (modeles locaux) |
| Modele principal | `qwen2.5-coder:14b` (`ANTHROPIC_MODEL`) |
| Modele rapide | `qwen3:0.6b` (`ANTHROPIC_SMALL_FAST_MODEL`) |
| Surface protegee | `settings.json`, `CLAUDE.md`, `skills` (`SKILL.md`), `.mcp.json` |

Claude Code lit — et **execute** — sa configuration a chaque session : les `settings.json`
peuvent declarer des **hooks** (commandes lancees automatiquement, avant meme le dialogue de
confiance), `CLAUDE.md` est une memoire persistante rechargee, les `skills` sont des procedures
suivies, et `.mcp.json` declare des serveurs MCP (= octroi de nouvelles capacites). Cette surface
de config/etat est l'**actif protege** du TP (voir [`02-threat-model.md`](02-threat-model.md)).

> **Backend LLM = service externe de confiance.** Claude Code est configure pour parler a un
> endpoint **compatible Anthropic** servi par **LiteLLM** sur `ixia` (`backend-host:3101`), qui
> relaie vers **Ollama** (modeles locaux). On ne fournit donc **aucune** cle Anthropic ni token
> OAuth a la sandbox : l'authentification se fait par une **cle LiteLLM scopee** (`ANTHROPIC_AUTH_TOKEN`,
> variable `.env` gitignoree), pendant que `ANTHROPIC_API_KEY` reste **vide** (sinon elle prendrait
> le dessus sur le token d'auth). Consequence directe pour le durcissement : **les questions ne
> partent pas chez Anthropic** et l'unique egress autorise est `backend-host`. Detail complet en
> [`09-backend-modele.md`](09-backend-modele.md).

---

## 1.6 Image Docker de l'agent : `claude-hardened:latest`

| Propriete | Valeur |
|---|---|
| Tag | `claude-hardened:latest` |
| Base | image Node/Debian minimale (Claude Code = paquet npm `@anthropic-ai/claude-code`) |
| Utilisateur | **`agent`** (UID `10001`, GID `10001`) — **jamais root** au runtime |
| HOME | `/home/agent` |
| Workspace | `/workspace` (code a traiter, monte `:rw`) |
| Secrets | **AUCUN** secret n'est inscrit dans les layers de l'image (injection au run) |

La meme image sert aux deux profils ; c'est l'**invocation `docker run`** (drapeaux de
durcissement) qui distingue `nu` de `durci` — pas l'image. Cela isole proprement la variable
etudiee : « a image identique, quels drapeaux runtime protegent la config ? ».

---

## 1.7 Conventions autoritaires (rappel synthetique)

| Element | Valeur exacte |
|---|---|
| Repertoire projet | `/home/julien/projet/cyber/tp` |
| Image agent / proxy / exfil | `claude-hardened:latest` / `tp-egress-proxy:latest` / `tp-exfil-server:latest` |
| User agent | `agent` (UID 10001, GID 10001), HOME `/home/agent`, workspace `/workspace` |
| Profil seccomp | `./agent/seccomp-claude.json` |
| Reseaux | `tp_internal` (internal) et `tp_egress` |
| Proxy / exfil | `egress-proxy:8080` / `exfil-server:8000` |
| Secret factice | `/run/secrets/fake_token.txt` = `FAKE-CORP-TOKEN-do-not-exfiltrate-1337` |
| Limites cgroups | `--memory 2g`, `--pids-limit 256`, `--cpus 2` |
| Profils | `nu` (vulnerable) vs `durci` (protege) |
| Backend LLM (externe) | `ANTHROPIC_BASE_URL=${LITELLM_ENDPOINT}` (def. `http://backend-host:3101`) |
| Auth modele | `ANTHROPIC_AUTH_TOKEN=${LITELLM_VIRTUAL_KEY}` (cle LiteLLM scopee, `.env`) ; `ANTHROPIC_API_KEY=` **vide** |
| Modeles | `ANTHROPIC_MODEL=qwen2.5-coder:14b`, `ANTHROPIC_SMALL_FAST_MODEL=qwen3:0.6b` |
| Unique egress autorise | `backend-host` (endpoint LiteLLM ixia) — tout le reste default-deny |
