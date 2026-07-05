# 03 — Tableau de partitionnement du filesystem (PIECE MAITRESSE)

> Livrable central de l'enonce : un **partitionnement read-only** du filesystem qui protege la
> configuration/etat de l'agent. La regle directrice, transposee de `sandbox-runtime` (srt) :
>
> **deny-then-allow en LECTURE / allow-only en ECRITURE.**
>
> Autrement dit : tout est read-only par defaut ; seuls le workspace et l'ephemere sont
> ecrivables ; et la config de l'agent est **explicitement re-verrouillee `:ro`** par-dessus.

---

## 3.1 Tableau de partitionnement

| Chemin (dans le conteneur) | Mode | Source / mecanisme Docker | Menace couverte |
|---|---|---|---|
| `/` (racine) | **ro** | `--read-only` | Commande destructrice hors workspace ; depot de binaires / persistance |
| `/workspace` | **rw** | bind `tp/workspace` (rw) | — *(seule zone de travail « metier » ecrivable)* |
| `/workspace/.claude/settings.json` | **ro** | bind `tp/config/project-settings.json:ro` | Reecriture settings / **injection de hook** (cat. 2, 3) |
| `/workspace/CLAUDE.md` | **ro** | bind `tp/config/project-CLAUDE.md:ro` | Empoisonnement de memoire persistant (cat. 2, 3) |
| `/workspace/.mcp.json` | **ro** | bind `tp/config/project-mcp.json:ro` | Ajout de serveur MCP = octroi de capacite (cat. 3) |
| `/workspace/.claude/skills` | **ro** | bind `tp/config/project-skills/:ro` | Alteration de skill = comportement detourne (cat. 3) |
| `/home/agent/.claude/settings.json` | **ro** | bind `tp/config/user-settings.json:ro` | Reecriture settings utilisateur / hook (cat. 2, 3) |
| `/home/agent/.claude/skills` | **ro** | bind `tp/config/user-skills/:ro` | Alteration de skill utilisateur (cat. 3) |
| `/home/agent/.claude` (reste) | **tmpfs** | `--tmpfs /home/agent/.claude` | Etat runtime ephemere ; **pas de persistance** entre sessions |
| `/tmp` | **tmpfs** | `--tmpfs /tmp` | Scratch ephemere (`noexec,nosuid` recommande) |
| `/run` | **tmpfs** | `--tmpfs /run` | PID / sockets runtime ephemeres |
| `/run/secrets/fake_token.txt` | **ro** *(profil `nu` uniquement)* | injecte au RUN (jamais dans l'image) | Demo exfil : present sur `nu`, **absent** sur `durci` |

**Legende des modes :**
- **ro** = read-only (verrou kernel, root-proof) ;
- **rw** = read-write (bind persistant) ;
- **tmpfs** = systeme de fichiers en RAM, **detruit a l'arret** du conteneur.

---

## 3.2 Ordre de montage CRITIQUE

L'ordre des montages n'est pas anodin et doit etre respecte a la lettre :

```
1) D'ABORD : --tmpfs /home/agent/.claude         (zone ephemere ECRIVABLE)
2) PUIS    : -v .../user-settings.json:/home/agent/.claude/settings.json:ro
             -v .../user-skills:/home/agent/.claude/skills:ro
             (binds :ro montes PAR-DESSUS le tmpfs)
```

Pourquoi cet ordre :
- Le **tmpfs** rend `/home/agent/.claude` ecrivable -> l'agent peut y poser son **etat runtime**
  legitime (sessions, cache, historique) sans erreur.
- Les **binds `:ro` par-dessus** re-verrouillent uniquement `settings.json` et `skills` : ces
  fichiers precis restent **immuables** meme si tout le reste du repertoire est ecrivable.

Resultat : l'agent fonctionne normalement (il ecrit son etat ephemere) mais **ne peut jamais
reecrire sa config protegee**. C'est l'application concrete de « allow-only en ecriture ».

---

## 3.3 Double verrou (defense en profondeur niveau fichier)

Le `:ro` Docker est un **premier** verrou (kernel). On ajoute un **second** verrou cote source :

| Verrou | Mecanisme | Propriete |
|---|---|---|
| Verrou 1 (kernel) | bind `:ro` | Le montage est en lecture seule au niveau noyau : **meme un process root** du conteneur ne peut ecrire. Root-proof. |
| Verrou 2 (permissions) | fichiers sources figes en **`root:root`, mode `0444`** dans `tp/config/` | Proprietaire root, lecture seule pour tous. L'agent (UID 10001) n'est pas proprietaire -> ne peut pas `chmod`/ecrire meme sans le `:ro`. |

Les deux sont independants : retirer l'un laisse l'autre actif (defense en profondeur).

---

## 3.4 Piege symlink (a NE PAS oublier) : `realpath` AVANT validation

Une attaque classique consiste a remplacer un fichier par un **lien symbolique** pointant
ailleurs, pour contourner une validation de chemin naive.

- **Cote montage kernel** : un bind `:ro` est insensible au symlink — le verrou porte sur
  l'**inode monte**, pas sur le nom. Le `:ro` reste robuste.
- **Cote logique applicative** (proxy, scripts d'attaque, toute validation de chemin) : il
  **FAUT resoudre les liens symboliques (`realpath`) AVANT** de comparer un chemin a une
  allowlist/denylist. Sinon `chemin-autorise -> /etc/shadow` passe le controle.

> Regle d'or : **resoudre (`realpath`) d'abord, valider ensuite.** Jamais l'inverse.

---

## 3.5 Profil `nu` (NON durci) — pour le contraste avant/apres

Sur le profil `nu`, toutes ces protections sont **absentes** : la racine est rw, et la config
est bindee **rw** (ou simplement presente sans `:ro`). C'est ce qui rend les 6 attaques
**reussies** sur `nu` et **bloquees** sur `durci` (voir [`05-avant-apres.md`](05-avant-apres.md)).

| Chemin | Mode sur `durci` | Mode sur `nu` |
|---|---|---|
| `/` racine | **ro** | rw |
| config (settings/CLAUDE.md/skills/mcp) | **ro** | **rw** (reecriture possible) |
| `/run/secrets/fake_token.txt` | absent | present (exfil possible) |
