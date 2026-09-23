# Documentation — TP « Durcissement d'un agent Claude Code en Docker »

> Le livrable du TP est le **rapport** [`RAPPORT.md`](RAPPORT.md) (PDF : [`RAPPORT.pdf`](RAPPORT.pdf)),
> complété par ses [`annexes.md`](annexes.md). C'est la **référence à jour** : les documents
> ci-dessous l'approfondissent sur des points précis.
>
> English translation of the report: [`en/REPORT.md`](en/REPORT.md).
>
> Agent réel : **Claude Code** (`claude` v2.1.191). Conteneurisation : **Docker 29.5.2**
> (imposé). Hôte jetable : **conteneur Incus LXC** `tp-claude-host` (`security.nesting=true`).

---

## Documents

| Document | Contenu |
|---|---|
| [`RAPPORT.md`](RAPPORT.md) | **Rapport** : environnement, modèle de menace, conception du durcissement, installation, démo avant/après (7/7), bonus, surface résiduelle, matrice de conformité |
| [`annexes.md`](annexes.md) | Annexes A/B/C : `docker run` durci, profil seccomp, Dockerfile, scénarios d'attaque, logs de preuve |
| [`02-threat-model.md`](02-threat-model.md) | Modèle de menace détaillé : actif protégé, 3 catégories de risque, cartographie de la surface de configuration |
| [`08-isolation-hote.md`](08-isolation-hote.md) | Isolation de l'hôte (anneau 1) : conteneur LXC (implémenté) vs VM Incus (idéal recommandé) |
| [`09-backend-modele.md`](09-backend-modele.md) | Backend modèle externe : LiteLLM v1.89.7 sur ixia (`backend-host:3101`), frontière de confiance, stack `docker compose` |
| [`10-litellm-vs-mitmproxy.md`](10-litellm-vs-mitmproxy.md) | Pourquoi une passerelle LiteLLM ré-authentifiante + `--internal` remplace un proxy MITM dédié (bonus) |
| [`11-backend-llm-local.md`](11-backend-llm-local.md) | Faire exécuter des outils à Claude Code avec un modèle local (recette `qwen3:8b`) et variante Claude Sonnet 5 |
| [`12-references-menaces.md`](12-references-menaces.md) | Références sourcées : OWASP, MITRE ATLAS, CVE Claude Code / MCP, recherche sur l'empoisonnement de modèles |
| [`preuves/`](preuves/) | Preuves publiées (sanitisées) : résultats 7/7, détail par attaque, niveau répertoire, détournement *live* |

---

## Générer le PDF

```bash
./scripts/build-pdf.sh          # docs/RAPPORT.md + docs/annexes.md -> out/RAPPORT.pdf (pandoc + lualatex)
```

---

## Conventions

| Élément | Valeur |
|---|---|
| Image | `claude-hardened:latest` (= `zurban/tp-claude-hardened` sur Docker Hub), commune aux deux profils |
| Utilisateur agent | `agent` (UID 10001), HOME `/home/agent`, workspace `/workspace` |
| Profils | `nu` (vulnérable, `--user 0:0`, config `:rw`, egress libre) vs `durci` (protégé) |
| Réseau du durci | `tp_internal` (`--internal`, subnet `172.31.7.0/24`, IP fixe `172.31.7.2`) ; seule sortie : passerelle `172.31.7.1:3101` → LiteLLM |
| Secret factice | `/run/secrets/fake_token.txt` = `FAKE-CORP-TOKEN-do-not-exfiltrate-1337` (monté sur `nu` uniquement) |
| Backend modèle | `ANTHROPIC_BASE_URL` → LiteLLM ; `ANTHROPIC_AUTH_TOKEN` = clé virtuelle scopée ; `ANTHROPIC_API_KEY` vide |

> **Sécurité du TP** : secrets **factices** uniquement, aucune action contre un système tiers
> réel. **Aucune clé Anthropic dans la sandbox** : l'auth est une clé LiteLLM scopée (`.env`
> gitignoré). Selon le modèle choisi dans LiteLLM, les requêtes restent locales (Ollama) ou
> partent vers l'API Anthropic avec la clé de LiteLLM, jamais celle de l'agent.
