# Preuves d'exécution (logs) — démonstration avant / après

> Livrable exigé par l'énoncé : *« preuves d'exécution (logs, captures) montrant les tentatives
> de modification de `settings.json` / `CLAUDE.md` / skill / `.mcp.json` réussies sur l'agent nu
> et bloquées sur l'agent durci. »*

Ces fichiers sont les **logs bruts** des campagnes d'attaque, **assainis** : toute information
réseau (adresses IP privées, noms d'hôtes internes) et tout jeton réel ont été remplacés par des
**placeholders génériques**. Le contenu technique (commandes, codes retour, empreintes SHA,
appels d'outils de l'agent) est **inchangé**.

## Légende des placeholders

| Placeholder | Signification |
|---|---|
| `<gateway>` | passerelle réseau interne vers le backend modèle (device Incus → ixia) |
| `<durci>` / `<nu-gateway>` | adresses internes des conteneurs durci / nu |
| `<backend-host>` | serveur externe hébergeant la passerelle LiteLLM (`ixia`) |
| `<public-host>` | hôte public tiers utilisé pour tester l'egress (test de connectivité) |
| `<VIRTUAL-KEY>` / `<ANTHROPIC-KEY>` | clés (jamais présentes en clair, masquées par précaution) |

*Les jetons `FAKE-CORP-TOKEN-…` et `sk-VOLEE-attaquant-…` sont des **secrets factices** du
scénario d'attaque (aucune valeur réelle) et sont conservés tels quels.*

## Contenu

| Fichier | Description |
|---|---|
| `resultats.md` | tableau des couples attaque/résultat — **7/7 conforme** (nu=Réussie, durci=Bloquée) |
| `attaques-nu-detail.txt` | preuve granulaire **profil nu** : commande + code retour + SHA avant/après (attaques **réussies**) |
| `attaques-durci-detail.txt` | preuve granulaire **profil durci** : mêmes attaques **bloquées** (`:ro` / `--read-only` / secret absent / 401) |
| `injection-live/` | **démonstration agentique live** : flux `stream-json` de vraies exécutions `claude -p` (voir `injection-live/README.md`) |

## Reproductibilité

Ces logs sont produits par le framework d'attaques du dépôt :
`steps/05-attacks-nu.sh` (nu) · `steps/07-attacks-durci.sh` (durci) · `steps/08-results-table.sh`
(agrégation). Voir `docs/RAPPORT-V0.md` §5 pour l'analyse.
