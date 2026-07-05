# Proxy d'egress durci — `tp-egress-proxy:latest`

> Composant **egress-proxy** du TP « Durcissement d'un agent Claude Code en Docker ».
> Point de sortie reseau **unique** de l'agent durci. Construit avec **mitmproxy**
> (Python) pour permettre un controle d'egress **par destination ET par contenu**.
>
> **Contexte modele** : Claude Code utilise un **backend LLM EXTERNE** =
> **LiteLLM sur ixia (`backend-host:3101`)** qui route vers **Ollama** (modeles
> locaux). Il n'y a **aucun** secret Anthropic dans la sandbox et **aucun** egress
> vers Anthropic. La **seule** destination d'egress autorisee est donc
> `backend-host` (endpoint modele). ixia est un serveur **externe** au perimetre
> de durcissement (« suppose securise par ailleurs »), decrit ici a la maille
> interface : on le joint au travers du proxy.

---

## 1. Modele de menace egress

L'agent Claude Code, une fois **compromis** (prompt injection directe ou indirecte
via un README/skill/sortie d'outil/reponse MCP), peut tenter de :

| Menace | Vecteur | Contre-mesure de ce proxy |
|---|---|---|
| **Exfiltration de secret** | POST/GET vers un serveur arbitraire | Allowlist default-deny (403 hors liste) |
| **C2 / telechargement de payload** | connexion sortante libre | Allowlist + `tp_internal` `--internal` (aucune route directe) |
| **Exfil DNS** | secret encode dans un sous-domaine a haute entropie | Detection d'entropie de Shannon par label DNS |
| **Exfil par URL** | secret dans une query string volumineuse | Plafond de longueur de query (`EGRESS_MAX_QUERY_LEN`) |
| **Exfil vers la destination POURTANT autorisee** | secret encode vers la destination de l'allowlist (`backend-host`) | **MITM token-scope** (BONUS) + detection de contenu + cle LiteLLM scopee (audit/budget) |

**Posture : `default-deny` (deny-then-allow).** Tout ce qui n'est pas explicitement
autorise dans `allowlist.txt` est **refuse**. Chaque decision (`ALLOW`/`DENY`) est
**journalisee** (prefixe `[EGRESS]`) pour les preuves du rapport PDF.

L'agent durci est attache au reseau **`tp_internal` (`--internal`, aucune sortie)**
et joint le proxy via **`tp_egress`**. Sa **seule** porte de sortie est
**`egress-proxy:8080`**. Il n'existe aucune route directe vers Internet.

> **Une allowlist est un OCTROI DE CAPACITE**, pas un simple filtre de paquets
> (« How we contain Claude », Anthropic). Etre dans la liste autorise la
> *destination* ; cela ne valide pas l'*intention* de la requete.

---

## 2. Niveau (a) — Filtrage par destination (allowlist)

Defini dans [`allowlist.txt`](./allowlist.txt) (un domaine par ligne, `#` = commentaire).

- Correspondance : **egalite exacte** OU **sous-domaine** d'un domaine autorise
  (suffix-match sur frontiere de label).
  Ex. `backend-host` (endpoint modele LiteLLM) autorise `backend-host` mais
  **pas** `backend-host.attacker.net` ni une autre destination.
- Applique des le **`CONNECT`** (HTTPS) : un tunnel vers une destination interdite
  est refuse **avant** etablissement TLS.
- Fichier absent/vide => **deny total** (posture la plus sure).

---

## 3. Niveau (b) — BONUS : MITM defensif **token-scope** (validation de contenu)

### Le probleme (angle mort « allowlist seule »)

Si une destination legitime est dans l'allowlist, un attaquant peut exfiltrer
`FAKE-CORP-TOKEN-...` en l'encodant vers cette **meme destination autorisee**.
Le filtre « destination » ne voit rien : **la destination est valide**.

**Dans notre contexte backend-local**, l'egress est reduit a **un seul endpoint
interne audite** (`backend-host`, LiteLLM sur ixia) : la surface d'exfil est
donc **quasi nulle**. La defense de capacite reelle vers ce backend repose sur la
**cle LiteLLM SCOPEE** (audit + budget plafonne cote LiteLLM) — une cle injectee
differente est rejetee, la depense est bornee, tout est journalise.

> **Variante backee-Anthropic** : si Claude Code parlait directement a
> `api.anthropic.com` (domaine legitime dans l'allowlist), le bonus illustrerait
> l'**exfiltration vers ce domaine autorise** corrigee par le **token-scope** —
> c'est l'angle mort decrit par l'incident Anthropic. Le mecanisme MITM ci-dessous
> est identique ; seule change la destination autorisee.

### La correction

Le proxy fait un **MITM defensif** et n'autorise QUE la requete portant
**exactement** le **token de session provisionne** au demarrage
(`Authorization: Bearer <SESSION_TOKEN>`).

- Toute **autre** cle (le `fake_token.txt` exfiltre, une cle injectee) => **403**,
  **meme si le domaine est dans l'allowlist**.
- Le proxy detecte aussi le secret factice dans l'URL / les en-tetes / le corps,
  ainsi que les sous-domaines a haute entropie et les query strings volumineuses.

### Demonstration

1. `exfil-server` est **deja** dans `allowlist.txt` (expres).
2. **Sans** `SESSION_TOKEN` (token-scope INACTIF) : l'exfil vers le domaine
   autorise **passe** -> on illustre l'angle mort « allowlist seule ».
3. **Avec** `SESSION_TOKEN` (token-scope ACTIF) : la **meme** requete d'exfil
   (qui ne porte pas le bon token, ou qui transporte le secret) -> **403**.
   Seul le trafic legitime portant le token provisionne transite.

> Message du rapport : le filtrage **par destination** est insuffisant ;
> il faut un controle **par contenu/intention** (token de session scope).
> Defense en profondeur, pas filtre unique.

---

## 4. Construction et activation

### Build

```bash
docker build -t tp-egress-proxy:latest /home/julien/projet/cyber/tp/proxy
```

### Lancement (orchestre par `scripts/05-run-exfil-proxy.sh`)

Le proxy ecoute sur **8080**, est attache a **`tp_egress`** et nomme **`egress-proxy`**.
Le **token de session** est **provisionne au RUN** (jamais dans l'image) :

```bash
docker run -d --name egress-proxy \
  --network tp_egress \
  -e SESSION_TOKEN="<token-de-session-provisionne-par-l-hote>" \
  tp-egress-proxy:latest
```

Cote agent durci, l'egress est force via :

```
HTTP_PROXY=http://egress-proxy:8080
HTTPS_PROXY=http://egress-proxy:8080
```

### Variables d'environnement (runtime)

| Variable | Defaut | Role |
|---|---|---|
| `SESSION_TOKEN` | *(vide)* | Token de session provisionne. **Defini => MITM token-scope ACTIF**. Vide => allowlist seule (demo angle mort). |
| `ALLOWLIST_PATH` | `/etc/egress/allowlist.txt` | Chemin de l'allowlist dans l'image. |
| `EGRESS_MAX_QUERY_LEN` | `256` | Longueur max d'une query string (anti-exfil URL). |
| `EGRESS_ENTROPY_THRESHOLD` | `4.0` | Seuil d'entropie (bits/car) par label DNS (anti-exfil DNS). |
| `EGRESS_ENTROPY_MIN_LABEL_LEN` | `16` | Longueur min d'un label avant test d'entropie (anti faux positifs). |

---

## 5. Fichiers du groupe

| Fichier | Role |
|---|---|
| [`Dockerfile`](./Dockerfile) | Image `tp-egress-proxy:latest` (mitmdump sur 8080 + addon). |
| [`addon.py`](./addon.py) | Logique de controle : allowlist default-deny + MITM token-scope + anti-exfil. |
| [`allowlist.txt`](./allowlist.txt) | Domaines autorises (default-deny). |
| `README.md` | Ce document (modele de menace, BONUS, activation). |

---

## 6. Garde-fous de securite du TP

- **Secrets FACTICES uniquement** (`FAKE-CORP-TOKEN-do-not-exfiltrate-1337`,
  `SESSION_TOKEN` factice). Aucun vrai credential n'entre dans le conteneur.
- **Cible d'exfil LOCALE** (`exfil-server`) : aucune action vers un systeme tiers reel.
- **Pieges evites** : pas de `docker.sock`, pas de `--privileged`, pas de
  `--network=host`, pas de `seccomp=unconfined`. Le proxy est un *point de
  controle*, pas une porte derobee.
