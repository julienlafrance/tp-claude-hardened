# =============================================================================
#  Image: claude-hardened:latest
#  Groupe "image" du TP — Durcissement d'un agent Claude Code en Docker
# -----------------------------------------------------------------------------
#  ROLE
#    Cette image embarque l'agent reel "Claude Code" (CLI `claude`) ainsi que
#    le minimum d'outils dont il a besoin pour travailler (bash, git, jq...).
#
#  IMAGE UNIQUE POUR LES DEUX PROFILS
#    La MEME image sert a la fois au profil "nu" (vulnerable) et au profil
#    "durci" (protege). Ce qui differe entre les deux profils n'est PAS l'image
#    mais les options de `docker run` (USER, --read-only, --cap-drop, seccomp,
#    montages :ro de la config, reseau, limites cgroups, injection de secret).
#    => On NE durcit donc PAS dans le Dockerfile ce qui doit etre demontrable
#       AVANT/APRES : le durcissement vit au RUNTIME. Voir scripts 06/07.
#
#  PRINCIPE DE SECURITE CAPITAL : AUCUN SECRET DANS L'IMAGE
#    Aucune cle, aucun token, aucun credential n'est copie ni genere ici.
#    Les secrets (factices pour ce TP) sont injectes au RUN, jamais figes
#    dans une couche (layer) d'image — sinon ils fuiraient via `docker save`,
#    `docker history`, un registre, etc.
#
#  Build :  docker build -t claude-hardened:latest -f agent/Dockerfile agent/
#  (le contexte de build est le dossier agent/ ; voir .dockerignore)
# =============================================================================

# -----------------------------------------------------------------------------
#  Base : Node.js LTS sur Debian "slim".
#  - Claude Code est distribue via npm => il faut Node + npm.
#  - On prend l'image officielle Node "bookworm-slim" (Debian 12 slim) :
#      * Debian 12 = meme famille que l'hote Incus du TP (coherence),
#      * "slim" = surface d'attaque reduite (moins de paquets installes),
#      * tag majeur fige (Node 22 LTS) => reproductibilite raisonnable.
# -----------------------------------------------------------------------------
FROM node:22-bookworm-slim

# -----------------------------------------------------------------------------
#  Metadonnees (tracabilite pour le rapport / l'audit d'image).
# -----------------------------------------------------------------------------
LABEL org.opencontainers.image.title="claude-hardened"
LABEL org.opencontainers.image.description="Agent Claude Code conteneurise — image commune profils nu/durci (durcissement au runtime)"
LABEL org.opencontainers.image.vendor="TP durcissement agentic"
LABEL tp.role="agent"

# -----------------------------------------------------------------------------
#  Arguments d'identite de l'utilisateur non-root.
#  UID/GID 10001 = valeurs autoritaires du TP. Un UID >= 10000 evite toute
#  collision avec des comptes systeme et rend explicite le fait que l'agent
#  N'EST PAS root (defense en profondeur niveau fichier : meme un agent
#  compromis n'a pas les droits de root sur l'inode des fichiers montes).
# -----------------------------------------------------------------------------
ARG AGENT_USER=agent
ARG AGENT_UID=10001
ARG AGENT_GID=10001
ARG AGENT_HOME=/home/agent

# -----------------------------------------------------------------------------
#  Variables d'environnement utiles a Claude Code et a l'execution.
#  - NODE_ENV=production : desactive le superflu de dev cote npm.
#  - NPM_CONFIG_UPDATE_NOTIFIER=false / NPM_CONFIG_FUND=false : silence le bruit
#    reseau et les logs inutiles au demarrage.
#  - HOME : pointe vers le HOME de l'agent (etat ephemere ecrit la au runtime).
#  - IS_SANDBOX=1 : signale a Claude Code qu'il tourne en bac a sable conteneur
#    (deja isole) ; evite les avertissements/refus lies a l'execution as-root
#    et coherent avec le fait que l'isolation est assuree par Docker.
#  - CLAUDE_CONFIG_DIR : repertoire d'etat/config de Claude Code (par defaut
#    ~/.claude). On le fixe explicitement pour que l'entrypoint et les montages
#    :ro ciblent un chemin connu et stable.
# -----------------------------------------------------------------------------
ENV NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    HOME=${AGENT_HOME} \
    IS_SANDBOX=1 \
    CLAUDE_CONFIG_DIR=${AGENT_HOME}/.claude

# -----------------------------------------------------------------------------
#  Paquets systeme strictement necessaires :
#    - bash            : shell utilise par l'agent pour l'execution de commandes
#    - git             : operations de versionnage sur /workspace
#    - ca-certificates : verification TLS (sortie HTTPS via le proxy egress)
#    - jq              : manipulation JSON (utile a l'agent et aux scripts)
#    - dumb-init       : init PID 1 minimal (reaping des zombies + signaux)
#    - curl            : diagnostics/healthcheck egress (joindre le proxy)
#  On nettoie les listes apt dans la MEME couche pour ne pas gonfler l'image.
#  --no-install-recommends : evite les dependances superflues (surface reduite).
# -----------------------------------------------------------------------------
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        git \
        ca-certificates \
        jq \
        dumb-init \
        curl \
        dropbear-bin \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
#  Installation de l'agent reel : Claude Code (paquet npm officiel).
#  - Version EPINGLEE (@2.1.191) = reproductibilite + correspondance avec le
#    rapport ("claude v2.1.191"). Eviter "@latest" qui casse la reproductibilite.
#  - Installe globalement (-g) => binaire `claude` dans le PATH.
#  - On purge le cache npm dans la meme couche (image plus petite).
#  AUCUN credential n'est requis a l'install : la cle/token est fournie au RUN.
# -----------------------------------------------------------------------------
# Pourquoi --ignore-scripts PUIS postinstall manuel :
#   Le postinstall de claude-code est `sh -c "node install.cjs"`, lance par npm
#   via un spawn(sh,...). Dans CE build (Docker imbrique dans un conteneur Incus a
#   user-namespace mappe), ce spawn interne de npm echoue en `spawn sh EACCES`
#   (errno -13) -> le build casse. Le spawn de sh fonctionne pourtant en direct
#   (teste), c'est la combinaison npm-en-root + spawn-de-lifecycle qui pose
#   probleme dans le nesting. Contournement robuste et reproductible :
#     1) installer le paquet SANS executer les scripts (--ignore-scripts) ;
#     2) executer le postinstall NOUS-MEMES, directement via `node install.cjs`
#        en root (pas le spawn de npm) -> telecharge/installe les binaires natifs.
#   `claude --version` confirme ensuite la presence du binaire fonctionnel.
#   Le durcissement runtime (non-root, :ro, cap-drop) reste entier : il vit au RUN.
RUN npm install -g --ignore-scripts @anthropic-ai/claude-code@2.1.191 \
    && ( cd /usr/local/lib/node_modules/@anthropic-ai/claude-code && node install.cjs ) \
    && claude --version \
    && npm cache clean --force

# -----------------------------------------------------------------------------
#  Creation de l'utilisateur non-root "agent" (UID/GID 10001).
#  - Groupe puis utilisateur, HOME dedie, shell bash.
#  - On cree aussi le squelette de repertoires d'etat (~/.claude) ET les points
#    de montage de la config qui seront recouverts en :ro au runtime
#    (settings.json, skills). Les creer ici garantit que les montages binds
#    ":ro par-dessus" trouvent une cible existante, et evite des surprises de
#    permissions. Le proprietaire est l'agent pour la partie ephemere.
#  - On cree /workspace (WORKDIR) et on en donne la propriete a l'agent : c'est
#    le SEUL emplacement destine a l'ecriture cote profil durci (monte en :rw).
# -----------------------------------------------------------------------------
RUN groupadd --gid ${AGENT_GID} ${AGENT_USER} \
    && useradd --uid ${AGENT_UID} --gid ${AGENT_GID} \
        --home-dir ${AGENT_HOME} --create-home --shell /bin/bash ${AGENT_USER} \
    && mkdir -p ${AGENT_HOME}/.claude/skills \
    && mkdir -p /workspace \
    && chown -R ${AGENT_UID}:${AGENT_GID} ${AGENT_HOME} /workspace

# -----------------------------------------------------------------------------
#  Acces SSH par dropbear (sshd DANS le conteneur — choix d'archi assume).
#  dropbear est minuscule et tourne en NON-ROOT sur un port haut (2222 > 1024),
#  ce qui PRESERVE --cap-drop=ALL / --read-only / USER non-root du profil durci
#  (OpenSSH exigerait des capabilities pour le privilege-separation -> ecarte).
#    - Cle d'HOTE generee au BUILD (rootfs read-only au runtime : lecture seule OK).
#    - authorized_keys = PLACEHOLDER vide ici ; la vraie cle publique est injectee
#      au RUN par un montage :ro (cle "a chaque (re)creation" du conteneur).
#    - claude-session : wrapper forced-command (recharge l'env backend puis claude).
#  On est encore root ici (USER non-root fixe plus bas) -> generation/chown permis.
# -----------------------------------------------------------------------------
COPY claude-session /usr/local/bin/claude-session
RUN chmod 0755 /usr/local/bin/claude-session \
    && install -d -m 700 -o ${AGENT_UID} -g ${AGENT_GID} ${AGENT_HOME}/.ssh \
    && dropbearkey -t ed25519 -f ${AGENT_HOME}/.ssh/dropbear_host_ed25519 >/dev/null 2>&1 \
    && : > ${AGENT_HOME}/.ssh/authorized_keys \
    && chown -R ${AGENT_UID}:${AGENT_GID} ${AGENT_HOME}/.ssh \
    && chmod 600 ${AGENT_HOME}/.ssh/authorized_keys ${AGENT_HOME}/.ssh/dropbear_host_ed25519

# -----------------------------------------------------------------------------
#  Entrypoint : on copie le script et on le rend executable.
#  Place sous /usr/local/bin (dans le PATH) et lisible par tous.
# -----------------------------------------------------------------------------
# NB : on N'utilise PAS `COPY --chmod=...` (syntaxe BuildKit uniquement ; le
#   builder Docker "legacy" de l'hote Incus la refuse). COPY portable + RUN chmod
#   -> fonctionne avec les DEUX builders (legacy et BuildKit). On est encore root
#   ici (le USER non-root est fixe plus bas), donc le chmod est permis.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# -----------------------------------------------------------------------------
#  WORKDIR = /workspace : l'agent demarre dans le code a traiter.
#  Cote profil durci, /workspace est le seul repertoire inscriptible (CWD),
#  conformement au modele "ecriture autorisee uniquement dans le CWD".
# -----------------------------------------------------------------------------
WORKDIR /workspace

# -----------------------------------------------------------------------------
#  Bascule en utilisateur non-root.
#  Tout ce qui suit (et le conteneur au runtime) s'execute en tant qu'agent.
#  C'est une mesure de durcissement appliquee DANS l'image ; le profil "nu"
#  la neutralise au runtime en forcant `--user 0:0` (root) cote `docker run`.
# -----------------------------------------------------------------------------
USER ${AGENT_UID}:${AGENT_GID}

# -----------------------------------------------------------------------------
#  Healthcheck leger : verifie que le binaire `claude` repond.
#  (N'effectue aucun appel reseau sortant — juste --version en local.)
# -----------------------------------------------------------------------------
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD claude --version >/dev/null 2>&1 || exit 1

# -----------------------------------------------------------------------------
#  PID 1 = dumb-init (reaping zombies + propagation propre des signaux),
#  puis notre entrypoint qui prepare l'etat ephemere et configure le proxy
#  d'egress avant d'exec-er la commande demandee.
#
#  CMD par defaut : un shell interactif. Le profil "durci" passera typiquement
#  une commande explicite (ex. `claude` en mode non-interactif). Le shell par
#  defaut permet aussi a la suite d'attaques (08) d'injecter ses commandes.
# -----------------------------------------------------------------------------
ENTRYPOINT ["dumb-init", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
