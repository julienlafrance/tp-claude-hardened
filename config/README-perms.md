# Permissions des fichiers de config — 2e verrou (defense en profondeur)

> Ce document explique le **deuxieme verrou** appliquee aux actifs proteges du TP
> (config et etat de l'agent Claude Code) : des permissions POSIX restrictives
> (`root:root`, `0444` pour les fichiers, `0555` pour les dossiers), et **pourquoi**
> le montage Docker `:ro` reste le verrou **principal** (strictement plus fort).
>
> Principe directeur : **defense en profondeur**. On ne se repose pas sur une seule
> barriere. Si l'une est mal configuree ou contournee, l'autre tient encore.

---

## 1. Les deux verrous, et leur articulation

Les actifs proteges (`ro_targets`) sont :

| Cible dans le conteneur | Source figee (cote hote) |
|---|---|
| `/workspace/.claude/settings.json` | `tp/config/project-settings.json` |
| `/workspace/CLAUDE.md` | `tp/config/project-CLAUDE.md` |
| `/workspace/.mcp.json` | `tp/config/project-mcp.json` |
| `/workspace/.claude/skills` | `tp/config/project-skills/` |
| `/home/agent/.claude/settings.json` | `tp/config/user-settings.json` |
| `/home/agent/.claude/skills` | `tp/config/user-skills/` |

> **Convention de SOURCE figee** : toutes les sources protegees vivent sous
> `tp/config/` (noms autoritaires `project-*` / `user-*`). C'est CETTE copie qui
> est figee `root:root 0444`/`0555` (step `03-config-perms.sh`) puis bind-montee
> `:ro` (steps `04`/`06`). Les fichiers homonymes presents sous `tp/workspace/`
> sont des copies « vivantes » de reference : au RUN, les binds `config/*` les
> RECOUVRENT sur leurs points de montage respectifs.

Sur ces sources, **deux mecanismes independants** sont empiles :

1. **Verrou 1 — montage `:ro` (KERNEL, verrou principal)** : chaque source est
   bind-montee en lecture seule (`-v src:dst:ro`). Le noyau marque le point de
   montage `MS_RDONLY` ; **aucune ecriture** n'est possible, **quel que soit l'UID**
   du process dans le conteneur (y compris root). C'est le verrou *root-proof*.

2. **Verrou 2 — permissions POSIX (defense en profondeur)** : les fichiers sources
   sont figes en `root:root` avec le mode `0444` (lecture seule pour tous, aucun
   bit d'ecriture), et les dossiers en `0555` (lecture + traversee, pas d'ecriture).
   Cette etape est **appliquee par `steps/03-config-perms.sh`** (step de
   preparation de la config) au moment de figer les sources sous `tp/config/`,
   avant les montages.

> Note de nommage : dans l'implementation finale, c'est **`steps/03-config-perms.sh`**
> (appele par `run.sh`) qui applique les permissions `root:root 0444` / `0555` aux
> sources de `tp/config/` — c'est **cette etape** qui pose le verrou 2. Le verrou 1
> (`:ro`) est pose plus tard, au lancement des conteneurs (`steps/04`, `steps/06`).

---

## 2. Le verrou 2 en detail : `root:root`, `0444` / `0555`

```text
# Fichiers de config (settings.json, CLAUDE.md, .mcp.json, SKILL.md)
-r--r--r--  root root   settings.json     (mode 0444)
-r--r--r--  root root   CLAUDE.md         (mode 0444)
-r--r--r--  root root   .mcp.json         (mode 0444)
-r--r--r--  root root   SKILL.md          (mode 0444)

# Dossiers (skills/, format-helper/, ...)
dr-xr-xr-x  root root   skills/           (mode 0555)
dr-xr-xr-x  root root   format-helper/    (mode 0555)
```

**Pourquoi `root:root` + `0444` :**

- **Proprietaire `root`** : l'agent tourne sous `USER agent` (UID `10001`, non-root).
  Il **ne possede pas** ces fichiers. La regle POSIX « seul le proprietaire (ou root)
  peut changer le mode/contenu » joue donc contre lui.
- **Mode `0444`** : aucun bit `w` (ecriture) pour proprietaire/groupe/autres. Meme le
  proprietaire `root` ne peut pas ecrire sans d'abord re-`chmod` (ce que l'agent
  non-root ne peut pas faire faute d'etre proprietaire).
- **Dossiers `0555`** : bit `x` (traversee) conserve pour pouvoir LIRE le contenu,
  mais aucun bit `w` -> **impossible de creer/supprimer/renommer** un fichier dedans
  (donc pas d'ajout de skill malveillant, pas de remplacement de `SKILL.md`).

Ce verrou seul (sans `:ro`) **suffirait deja a bloquer un agent non-root**. Mais on ne
s'arrete pas la, car il a des limites (section 4).

---

## 3. Pourquoi le montage `:ro` est STRICTEMENT plus fort

Le montage `:ro` est le verrou **principal** ; les permissions POSIX sont une
**ceinture en plus des bretelles**. Trois raisons le rendent strictement superieur :

### 3.1 Verrou au niveau KERNEL, applique au point de montage

Le `:ro` n'est pas une propriete du fichier mais du **montage**. Le noyau refuse
toute ecriture (`EROFS` — *Read-only file system*) sur l'ensemble du sous-arbre monte,
**independamment** du proprietaire et du mode du fichier sous-jacent.

### 3.2 *Root-proof* : meme root dans le conteneur ne peut pas ecrire

Les permissions POSIX `0444` peuvent etre **contournees par root** : un process root
peut `chmod u+w` puis ecrire (si le fichier lui appartient). Le `:ro`, lui, **resiste
meme a root du conteneur** : root peut bien faire `chmod`, l'ecriture echoue quand
meme car le **montage** est en lecture seule. C'est decisif pour le profil **NU**
(qui tourne en root) et pour tout scenario d'elevation de privilege.

### 3.3 Pas de remontage en rw sans `CAP_SYS_ADMIN`

Pour repasser un montage `:ro` en `rw` il faut `mount -o remount,rw`, qui exige la
capacite **`CAP_SYS_ADMIN`**. Or le profil DURCI applique `--cap-drop=ALL` (+ `seccomp`
bloquant `mount`/`umount` + `--security-opt no-new-privileges`). La voie de
contournement est donc **fermee a trois niveaux** : pas de capability, syscall
`mount` interdit, pas de regain de privilege.

> **Resume** : `0444 root:root` = verrou *applicatif* (bon, mais re-modifiable par
> root). `:ro` = verrou *kernel* (root-proof, non remontable sans `CAP_SYS_ADMIN`).
> `:ro` >> POSIX. On garde les **deux** : defense en profondeur.

---

## 4. Limites de chaque verrou (et pourquoi les combiner)

| Limite | `0444 root:root` (verrou 2) | `:ro` (verrou 1) |
|---|---|---|
| Contourne par root du conteneur ? | **Oui** (`chmod`+ecriture si proprietaire) | **Non** (montage kernel) |
| Survit a une elevation de privilege ? | Non | **Oui** |
| Necessite `CAP_SYS_ADMIN` pour lever ? | Non | **Oui** (remount) |
| Protege si le bind `:ro` est oublie a tort ? | **Oui** (filet de securite) | n/a |
| Protege si le fichier est mal `chmode` a tort ? | n/a | **Oui** (filet de securite) |

La derniere ligne est la cle de la **defense en profondeur** : si un operateur oublie
le `:ro` au montage, le `0444 root:root` limite encore les degats face a un agent
non-root ; inversement, si un fichier est livre par erreur en `0644`, le `:ro` tient.

---

## 5. Piege des symlinks (rappel)

La validation de chemin (cote scripts d'attaque, proxy, logique applicative) doit
**resoudre les liens symboliques (`realpath`) AVANT** de comparer un chemin a la liste
des cibles protegees. Sinon un attaquant peut viser un symlink pointant vers un actif
protege et tromper une verification naive.

> A noter : le verrou `:ro` **kernel** est, lui, insensible au symlink — il porte sur
> l'**inode du montage**, pas sur le nom. C'est uniquement la logique *applicative* de
> validation de chemin qui doit `realpath`. Encore un argument en faveur du `:ro`.

---

## 6. Lien avec la matrice d'attaque

Ces deux verrous, combines, realisent la colonne « durci = Bloquee » pour les
attaques **#1 a #4** (reecriture `settings.json`/`CLAUDE.md`, alteration d'un skill,
ajout de serveur dans `.mcp.json`). L'attaque #6 (commande destructrice hors
`/workspace`) est couverte par `--read-only` sur la racine ; les #5 et le bonus par
le secret non monte + l'egress filtre/MITM. Voir `PLAN.md` (sections 3, 4 et 7).
