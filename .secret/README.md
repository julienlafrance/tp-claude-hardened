# `.secret/` — secrets backend (hors dépôt public)

Ce répertoire **isole les secrets de backend LiteLLM** du dépôt public. Grâce à
`.gitignore`, seuls `README.md` et `*.example` sont committés ; le vrai fichier
de secrets (`litellm.env`) reste **local** et n'est **jamais** poussé.

## Contenu

| Fichier | Committé ? | Rôle |
|---|---|---|
| `README.md` | oui | ce document |
| `litellm.env.example` | oui | modèle à copier |
| `litellm.env` | **NON (gitignoré)** | vrai fichier : **virtual key LiteLLM scopée** + endpoint/modèle |

`litellm.env` est chargé automatiquement (export) par `lib/log.sh` — donc par
**tous les steps**, `run.sh` et `recreate-daily.sh`.

## Mise en place

```bash
cp .secret/litellm.env.example .secret/litellm.env
# éditer .secret/litellm.env : coller la virtual key scopée fournie par LiteLLM (ixia)
```

Déploiement **dans l'instance Incus** : ce fichier doit exister à
`/root/tp/.secret/litellm.env` dans l'instance (déposé hors dépôt, comme un `.env`).

## Règles

- ⚠️ **Jamais** committer `litellm.env`, ni y mettre la **master key** LiteLLM.
  Seule une **virtual key scopée** (révocable, budget/rate-limit, TTL) doit y figurer.
- La vraie clé API Anthropic **ne quitte jamais ixia** : la sandbox ne détient que
  la virtual key scopée (cf. `docs/10-litellm-vs-mitmproxy.md`).
