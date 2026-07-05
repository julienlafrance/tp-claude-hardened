#!/usr/bin/env bash
# =============================================================================
#  entrypoint.sh — point d'entree de l'image claude-hardened:latest
#  Groupe "image" du TP — Durcissement d'un agent Claude Code en Docker
# -----------------------------------------------------------------------------
#  ROLE
#    Execute en tant que PID enfant de dumb-init, AVANT la commande demandee.
#    Trois responsabilites, dans cet ordre :
#      1) Configurer l'egress via PROXY si les variables d'env sont fournies
#         (HTTPS_PROXY / HTTP_PROXY / NO_PROXY) — octroi de capacite reseau.
#      2) Preparer l'etat EPHEMERE de Claude Code (~/.claude) SANS jamais
#         ecraser les fichiers montes en lecture seule (:ro) par-dessus le
#         tmpfs (settings.json, skills...).
#      3) `exec` la commande passee (par defaut: bash) — `exec` => le process
#         remplace le shell, les signaux de dumb-init lui parviennent direct.
#
#  CONTRAINTE FORTE : ce script doit fonctionner aussi bien
#    - sur le profil DURCI (racine read-only + tmpfs, USER agent non-root,
#      certains fichiers de ~/.claude montes :ro), QUE
#    - sur le profil NU (FS rw, root, config bindee rw, secret monte).
#    Il ne DOIT donc jamais echouer parce qu'un chemin est en lecture seule :
#    on teste l'inscriptibilite avant d'ecrire, et on ne force rien.
#
#  PRINCIPE : ce script ne fabrique, ne lit et n'exfiltre AUCUN secret.
#
#  CONTRAT AVEC LE SCRIPT DE RUN (07-run-durci.sh) — IMPORTANT
#    Le tmpfs de l'etat ephemere DOIT etre monte avec la PROPRIETE de l'agent,
#    sinon Docker le cree en root:root (mode 0755) et l'agent non-root (10001)
#    ne peut pas y ecrire. Monter par ex. :
#        --tmpfs /home/agent/.claude:rw,nosuid,nodev,uid=10001,gid=10001,mode=0700
#    Idem pour /tmp et /run (uid=10001 recommande). Ce script reste TOLERANT
#    si ce n'est pas le cas (il ignore les ecritures impossibles, ne plante
#    jamais), mais l'agent fonctionnera de maniere degradee.
# =============================================================================

# -----------------------------------------------------------------------------
#  Robustesse du shell :
#    -e : sortie immediate sur erreur non geree.
#    -u : variable non definie = erreur (evite les pieges de variables vides).
#    -o pipefail : un echec dans un pipe propage le code d'erreur.
#  On garde malgre tout des gardes explicites (|| true) la ou un echec est
#  ATTENDU et benin (ex. ecriture impossible car :ro sur le profil durci).
# -----------------------------------------------------------------------------
set -euo pipefail

# -----------------------------------------------------------------------------
#  Petit logueur prefixe, vers stderr (n'interfere pas avec la sortie utile).
#  Tout est en francais : le rapport PDF s'appuie sur ces traces.
# -----------------------------------------------------------------------------
log() { printf '[entrypoint] %s\n' "$*" >&2; }

# -----------------------------------------------------------------------------
#  Resolution du HOME et du repertoire de config Claude Code.
#  On retombe sur des valeurs sures si l'env n'est pas fourni (defense).
# -----------------------------------------------------------------------------
: "${HOME:=/home/agent}"
: "${CLAUDE_CONFIG_DIR:=${HOME}/.claude}"

# =============================================================================
#  ETAPE 1 — Configuration de l'egress via PROXY (si fournie au runtime)
# -----------------------------------------------------------------------------
#  Le durcissement reseau (allowlist + MITM token) vit dans le conteneur proxy.
#  Cote agent, il suffit d' orienter tout le trafic sortant vers ce proxy via
#  les variables d'environnement standard. On NE code en dur AUCUNE adresse :
#  c'est le script de run (07-run-durci.sh) qui injecte par ex. :
#      -e HTTPS_PROXY=http://egress-proxy:8080
#      -e HTTP_PROXY=http://egress-proxy:8080
#      -e NO_PROXY=localhost,127.0.0.1
#
#  Comportement :
#    - Si une variable PROXY est deja fournie (majuscule OU minuscule), on
#      l'honore et on synchronise les deux casses (certains outils ne lisent
#      que l'une des deux : node/curl lisent les minuscules, d'autres les MAJ).
#    - Si AUCUNE n'est fournie, on ne touche a rien : l'agent garde le
#      comportement par defaut (utile au profil NU = egress libre).
# =============================================================================
configurer_proxy_egress() {
    # Sources possibles, on prend la premiere non vide (MAJ prioritaire).
    local https_in="${HTTPS_PROXY:-${https_proxy:-}}"
    local http_in="${HTTP_PROXY:-${http_proxy:-}}"
    local no_in="${NO_PROXY:-${no_proxy:-}}"

    if [[ -n "${https_in}" || -n "${http_in}" ]]; then
        # Si une seule des deux directions est fournie, on aligne l'autre
        # dessus (cas courant : un seul proxy pour http et https).
        : "${https_in:=${http_in}}"
        : "${http_in:=${https_in}}"

        # NO_PROXY raisonnable par defaut : la boucle locale ne doit jamais
        # transiter par le proxy (healthchecks, sockets locaux).
        : "${no_in:=localhost,127.0.0.1,::1}"

        # Exporte dans les DEUX casses pour couvrir tous les clients.
        export HTTPS_PROXY="${https_in}" https_proxy="${https_in}"
        export HTTP_PROXY="${http_in}"  http_proxy="${http_in}"
        export NO_PROXY="${no_in}"      no_proxy="${no_in}"

        log "Egress via proxy configure : HTTPS_PROXY=${HTTPS_PROXY} (NO_PROXY=${NO_PROXY})"
    else
        log "Aucun proxy d'egress fourni (HTTPS_PROXY/HTTP_PROXY absents) — egress par defaut."
    fi
}

# =============================================================================
#  ETAPE 2 — Preparation de l'etat EPHEMERE de Claude Code (~/.claude)
# -----------------------------------------------------------------------------
#  Au runtime, ~/.claude est typiquement un tmpfs (profil durci) ; certains
#  fichiers (settings.json, skills) sont ensuite REMONTES en :ro par-dessus.
#  L'agent a malgre tout besoin d'ecrire son etat ephemere ailleurs dans
#  ~/.claude (historique de session, caches, projets...).
#
#  Regles strictes :
#    - On NE cree un repertoire/fichier QUE si le parent est INSCRIPTIBLE.
#    - On N'ECRASE JAMAIS un chemin existant monte en :ro (test -w avant).
#    - Tout echec d'ecriture est traite comme BENIN (le durcissement est
#      precisement cense empecher certaines ecritures) -> on log et continue.
# =============================================================================

# Cree un repertoire seulement si son parent est inscriptible et qu'il n'existe
# pas deja. Ne provoque jamais d'arret du script (echec benin tolere).
creer_repertoire_si_possible() {
    local dir="$1"
    local parent
    parent="$(dirname "${dir}")"

    if [[ -d "${dir}" ]]; then
        return 0  # deja present (peut etre un montage :ro) -> ne rien faire
    fi
    if [[ -w "${parent}" ]]; then
        mkdir -p "${dir}" 2>/dev/null \
            && log "Repertoire ephemere cree : ${dir}" \
            || log "Creation impossible (ignore) : ${dir}"
    else
        log "Parent non inscriptible, repertoire non cree (ignore) : ${dir}"
    fi
}

preparer_etat_ephemere() {
    # S'assure que le repertoire de config existe (souvent deja monte/tmpfs).
    creer_repertoire_si_possible "${CLAUDE_CONFIG_DIR}"

    # Sous-repertoires d'etat usuels de Claude Code (creation best-effort).
    # Ils ne sont PAS montes :ro -> l'agent peut y ecrire son etat de session.
    creer_repertoire_si_possible "${CLAUDE_CONFIG_DIR}/projects"
    creer_repertoire_si_possible "${CLAUDE_CONFIG_DIR}/todos"
    creer_repertoire_si_possible "${CLAUDE_CONFIG_DIR}/statsig"
    creer_repertoire_si_possible "${CLAUDE_CONFIG_DIR}/shell-snapshots"

    # NB : on ne cree PAS settings.json ni skills/ ici. S'ils sont fournis,
    # ils sont montes :ro par le script de run ; s'ils ne le sont pas, Claude
    # Code fonctionne avec ses valeurs par defaut. Dans tous les cas, on evite
    # d'ecrire par-dessus un eventuel montage en lecture seule.

    # Trace l'etat des cibles montees :ro (diagnostic pour le rapport).
    local cible
    for cible in \
        "${CLAUDE_CONFIG_DIR}/settings.json" \
        "${CLAUDE_CONFIG_DIR}/skills" \
        "/workspace/.claude/settings.json" \
        "/workspace/CLAUDE.md" \
        "/workspace/.mcp.json" \
        "/workspace/.claude/skills"
    do
        if [[ -e "${cible}" ]]; then
            if [[ -w "${cible}" ]]; then
                log "Config presente (INSCRIPTIBLE) : ${cible}"
            else
                log "Config presente (lecture seule :ro) : ${cible}"
            fi
        fi
    done
}

# =============================================================================
#  ETAPE 3 — Execution de la commande demandee
# -----------------------------------------------------------------------------
#  - Si une commande est passee (ex. depuis `docker run ... claude ...` ou la
#    suite d'attaques), on l'exec telle quelle.
#  - Sinon, on lance un bash interactif (CMD par defaut de l'image), ce qui
#    permet a la fois l'usage manuel et l'injection de commandes par les tests.
#  `exec` => remplacement du process courant : pas de shell parasite, dumb-init
#  reste PID 1 et relaie proprement SIGTERM/SIGINT au process final.
# =============================================================================
main() {
    configurer_proxy_egress
    preparer_etat_ephemere

    # -------------------------------------------------------------------------
    #  Depot de l'env BACKEND pour les sessions SSH (dropbear).
    #  dropbear ne propage PAS l'environnement du conteneur aux sessions ; le
    #  wrapper forced-command /usr/local/bin/claude-session relit ce fichier
    #  avant de lancer claude. /tmp est un tmpfs world-writable (1777) -> l'agent
    #  non-root peut y ecrire meme avec --read-only. Best-effort (jamais bloquant).
    # -------------------------------------------------------------------------
    {
        for __v in ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY \
                   ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL \
                   HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy \
                   IS_SANDBOX HOME CLAUDE_CONFIG_DIR; do
            [[ -n "${!__v:-}" ]] && printf '%s=%q\n' "$__v" "${!__v}"
        done
    } > /tmp/agent.env 2>/dev/null && chmod 600 /tmp/agent.env 2>/dev/null \
        && log "Env de session SSH depose dans /tmp/agent.env" \
        || log "Depot de l'env de session impossible (ignore — egress par defaut)."

    if [[ "$#" -gt 0 ]]; then
        log "Execution de la commande : $*"
        exec "$@"
    else
        log "Aucune commande fournie — lancement d'un shell bash interactif."
        exec bash
    fi
}

# Lancement : on transmet tous les arguments recus par l'entrypoint.
main "$@"
