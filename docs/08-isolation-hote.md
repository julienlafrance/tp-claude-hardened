# 08 — Isolation de l'hote (anneau 1) : conteneur LXC vs VM

> L'enonce note le durcissement **Docker** (anneau 2). L'**anneau 1** (l'hote jetable qui
> contient tout le bac a sable Docker) est traite ici : on **implemente** un conteneur Incus
> (LXC) et on **documente** la VM Incus comme cible ideale. Ce chapitre justifie ce choix
> honnetement et formule une **recommandation explicite**.

---

## 8.1 Pourquoi un anneau 1 du tout ?

Principe Anthropic : « containment at the environment layer first » + **defense en profondeur**.
On empile deux frontieres :

- **Anneau 1** — hote jetable Incus `tp-claude-host` : isole **tout le TP** (Docker + agent) de
  la machine reelle de l'etudiant. Detruit d'un `incus delete --force` : aucune trace.
- **Anneau 2** — conteneur Docker `claude-hardened` (la **piece notee**) : applique le
  partitionnement read-only + le durcissement Docker.

Un agent compromis doit franchir **les deux** pour atteindre l'hote reel.

---

## 8.2 Implemente : conteneur Incus (LXC) + `security.nesting=true`

```bash
incus launch images:debian/12 tp-claude-host -c security.nesting=true
```

| Critere | Conteneur LXC (implemente) |
|---|---|
| Noyau | **PARTAGE** avec l'hote reel (un seul noyau) |
| `security.nesting=true` | **Requis** pour faire tourner Docker imbrique (assouplit l'isolation) |
| Surface d'evasion | Plus large : **une faille noyau = evasion** potentielle vers l'hote |
| Poids / demarrage | **Leger**, demarrage quasi instantane |
| Iteration TP | Rapide a creer/detruire/rejouer |
| Securite | **Moins sure** (noyau partage + nesting) |

> **Note honnete pour le rapport.** Un conteneur LXC partage le noyau de l'hote ; activer
> `security.nesting=true` pour autoriser Docker imbrique **affaiblit** l'isolation. C'est donc
> **moins sur** qu'une VM. On l'assume sciemment : la **partie notee** est le durcissement
> **Docker** (anneau 2), pas l'isolation de l'hote. Le choix LXC privilegie la **rapidite
> d'iteration** du TP.

---

## 8.3 Ideal documente : VM Incus (`--vm`, KVM)

```bash
# Cible IDEALE (non implementee dans ce TP, recommandee en production) :
incus launch images:debian/12 tp-claude-host --vm -c security.secureboot=false
```

| Critere | VM Incus / KVM (ideal) |
|---|---|
| Noyau | **DEDIE** (noyau invite separe de l'hote) |
| Surface d'evasion | **Reduite** : il faut casser l'**hyperviseur KVM**, pas juste le noyau |
| Isolation | Veritable **isolation noyau** |
| Poids / demarrage | Plus **lourd** (image disque, boot complet) |
| Securite | **Plus sure** — meme une evasion conteneur Docker ne livre pas le noyau de l'hote reel |

---

## 8.4 Comparaison synthetique

| Critere | LXC (implemente) | VM KVM (ideal) |
|---|---|---|
| Noyau | Partage | Dedie |
| Evasion = | faille **noyau** | faille **hyperviseur** (plus dur) |
| Poids | Leger | Lourd |
| Demarrage | Instantane | Boot complet |
| Nesting Docker | `security.nesting=true` (assouplit) | natif, sans assouplir l'hote |
| Verdict | **Choisi** (iteration rapide TP) | **Recommande en prod** |

---

## 8.5 Recommandation explicite

> **Le mieux serait une VM Incus (`--vm`, KVM).** Pour un deploiement reel d'un agent de codage
> autonome, l'anneau 1 devrait etre une **machine virtuelle** a **noyau dedie** : meme si
> l'attaquant evade le conteneur Docker durci (anneau 2) **et** le conteneur hote, il se heurte
> encore a la frontiere de l'**hyperviseur KVM**, bien plus difficile a franchir qu'une faille
> du noyau partage.
>
> Dans ce TP, nous avons sciemment retenu le **conteneur LXC** (plus leger, iteration rapide)
> parce que l'evaluation porte sur le **durcissement Docker** (anneau 2). Le compromis est
> assume et documente : **production -> VM ; TP -> LXC + nesting.**

---

## 8.6 Garde-fous communs aux deux options (rappel des pieges evites)

Quelle que soit l'option d'anneau 1, on **n'affaiblit jamais** l'anneau 2 :

- jamais `-v /var/run/docker.sock` dans le conteneur agent ;
- jamais `--privileged`, `--network=host`, `seccomp=unconfined`, ni `--cap-add` larges ;
- `realpath` (resolution des symlinks) **avant** toute validation de chemin.

Voir [`04-durcissement.md` §4.4](04-durcissement.md).
