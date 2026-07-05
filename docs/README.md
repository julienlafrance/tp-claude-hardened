# Documentation — TP « Durcissement d'un agent Claude Code en Docker »

> Index de la documentation. Le livrable du TP est un **PDF** genere a partir de
> [`RAPPORT.md`](RAPPORT.md) (qui assemble toutes les sections ci-dessous).
>
> Agent reel : **Claude Code** (`claude` v2.1.191). Conteneurisation : **Docker 29.5.2**
> (impose). Hote jetable : **conteneur Incus LXC** `tp-claude-host` (`security.nesting=true`).
> Source de verite du design : [`../PLAN.md`](../PLAN.md).

---

## Sommaire des sections

| # | Document | Contenu |
|---|---|---|
| 01 | [`01-environnement.md`](01-environnement.md) | Environnement : hote Linux, instance Incus LXC `tp-claude-host`, agent Claude Code v2.1.191, image Docker `claude-hardened` |
| 02 | [`02-threat-model.md`](02-threat-model.md) | Modele de menace : actif protege (config/etat agent), 3 categories de menace, rayon d'impact |
| 03 | [`03-partition-table.md`](03-partition-table.md) | **Piece maitresse** : tableau de partitionnement du filesystem (chemin / ro-rw-tmpfs / menace) |
| 04 | [`04-durcissement.md`](04-durcissement.md) | **Piece maitresse** : design de durcissement, chaque mesure justifiee par une menace + bonus MITM |
| 05 | [`05-avant-apres.md`](05-avant-apres.md) | Demo avant/apres : table des 6 attaques + bonus (nu vs durci) + ou trouver les preuves |
| 06 | [`06-architecture.md`](06-architecture.md) | Schemas : boucle agentique, conteneur AVANT vs APRES, vue Mermaid |
| 07 | [`07-installation.md`](07-installation.md) | Installation/exploitation en commandes bash (reflet de `run.sh` et des etapes 00..09) |
| 08 | [`08-isolation-hote.md`](08-isolation-hote.md) | Isolation hote : conteneur LXC (implemente) vs VM Incus (ideal recommande) |
| 09 | [`09-backend-modele.md`](09-backend-modele.md) | **Annexe** : backend modele EXTERNE (LiteLLM v1.89.4 -> Ollama sur ixia `backend-host:3101`), frontiere de confiance, stack `docker compose` (secrets en `${VARS}`) |

---

## Generer le PDF

```bash
cd /home/julien/projet/cyber/tp
./scripts/build-pdf.sh          # produit out/RAPPORT.pdf via pandoc (voir le script pour le fallback)
```

Le rapport assemble pret a convertir est [`RAPPORT.md`](RAPPORT.md).

---

## Conventions autoritaires (rappel)

| Element | Valeur |
|---|---|
| Repertoire projet | `/home/julien/projet/cyber/tp` |
| Images | `claude-hardened:latest`, `tp-egress-proxy:latest`, `tp-exfil-server:latest` |
| User agent | `agent` (UID 10001), HOME `/home/agent`, workspace `/workspace` |
| Reseaux | `tp_internal` (internal), `tp_egress` |
| Proxy / exfil | `egress-proxy:8080` / `exfil-server:8000` |
| Secret factice | `/run/secrets/fake_token.txt` = `FAKE-CORP-TOKEN-do-not-exfiltrate-1337` |
| Profils | `nu` (vulnerable) vs `durci` (protege) |
| Backend modele (externe) | LiteLLM `backend-host:3101` -> Ollama ; `ANTHROPIC_BASE_URL=${LITELLM_ENDPOINT}`, `ANTHROPIC_AUTH_TOKEN=${LITELLM_VIRTUAL_KEY}` (scopee), `ANTHROPIC_API_KEY` vide |
| Unique egress autorise | `backend-host` (endpoint modele) — default-deny ailleurs |

> **Securite du TP** : secrets **factices** uniquement, endpoint d'exfil **local**, aucune
> action contre un systeme tiers reel. **Aucune cle Anthropic dans la sandbox** : l'auth modele
> est une cle **LiteLLM scopee** (`.env` gitignore) ; les questions ne partent pas chez Anthropic.
