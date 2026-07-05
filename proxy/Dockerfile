# =============================================================================
#  Dockerfile — Image du proxy d'egress durci : tp-egress-proxy:latest
# =============================================================================
#
#  ROLE
#  ----
#  Construit le conteneur `egress-proxy` : l'UNIQUE point de sortie reseau de
#  l'agent durci. Il execute mitmproxy (mitmdump) en mode proxy transparent/HTTP
#  sur le port 8080, charge notre addon de controle (proxy/addon.py) et applique
#  l'allowlist (proxy/allowlist.txt) + le MITM defensif token-scope (BONUS).
#
#  Pourquoi mitmproxy plutot que Squid ?
#    - mitmproxy permet une INSPECTION DE CONTENU programmable en Python
#      (validation du token de session, detection d'exfil), indispensable au
#      BONUS « allowlist != intention ». Un Squid ACL ne filtre que la
#      destination ; il ne sait pas valider un Bearer token de session.
#
#  IMAGE DE BASE : image officielle mitmproxy (Python embarque, CA MITM gere).
# =============================================================================
FROM mitmproxy/mitmproxy:latest

# -- Metadonnees -------------------------------------------------------------
LABEL org.opencontainers.image.title="tp-egress-proxy" \
      org.opencontainers.image.description="Proxy d'egress mitmproxy : allowlist default-deny + MITM defensif token-scope (TP durcissement Claude Code)" \
      tp.role="egress-proxy"

# -- Emplacement des fichiers de configuration dans l'image ------------------
#  L'addon lit l'allowlist via ALLOWLIST_PATH (defaut: /etc/egress/allowlist.txt).
ENV ALLOWLIST_PATH=/etc/egress/allowlist.txt

# Copie de l'allowlist (figee dans l'image) et de l'addon de controle.
COPY allowlist.txt /etc/egress/allowlist.txt
COPY addon.py      /opt/egress/addon.py

# -- Variables d'environnement de runtime ------------------------------------
#  SESSION_TOKEN n'est VOLONTAIREMENT PAS declare ici : c'est un secret de
#  session, PROVISIONNE par l'hote au RUN (`docker run -e SESSION_TOKEN=...`),
#  JAMAIS baked dans un layer de l'image (cf. piege "secrets dans l'image").
#  L'addon le lit via os.environ et defaute a "" (=> token-scope inactif,
#  pour pouvoir demontrer l'angle mort AVANT correction).
#  Seuils anti-exfil : valeurs par defaut, surchargeables au RUN.
ENV EGRESS_MAX_QUERY_LEN=256 \
    EGRESS_ENTROPY_THRESHOLD=4.0 \
    EGRESS_ENTROPY_MIN_LABEL_LEN=16

# -- Port d'ecoute du proxy (conforme aux conventions : egress-proxy:8080) ---
EXPOSE 8080

# -- Lancement ---------------------------------------------------------------
#  mitmdump : variante non-interactive de mitmproxy (adaptee aux conteneurs).
#    --listen-port 8080  : conforme aux conventions du TP.
#    --mode regular      : proxy HTTP/HTTPS explicite (l'agent pointe
#                          HTTP(S)_PROXY=http://egress-proxy:8080).
#    -s addon.py         : charge notre logique de controle d'egress.
#    --set ...           : reglages durcis (pas de mode web, logs lisibles).
#  Note CA MITM : mitmproxy genere son CA au premier run. Pour intercepter le
#  TLS (BONUS contenu), l'agent durci approuve ce CA (provisionne par l'hote) ;
#  sinon le proxy filtre quand meme la destination via le hook CONNECT.
ENTRYPOINT ["mitmdump"]
CMD ["--listen-host", "0.0.0.0", \
     "--listen-port", "8080", \
     "--mode", "regular", \
     "-s", "/opt/egress/addon.py", \
     "--set", "block_global=false", \
     "--set", "termlog_verbosity=info", \
     "--set", "flow_detail=1"]
