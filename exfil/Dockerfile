# =============================================================================
#  Image : tp-exfil-server:latest
#  Role  : cible d'exfiltration LOCALE et FACTICE du TP de durcissement.
#          Recoit + journalise tout (corps/headers/query) pour prouver une
#          exfiltration. N'expose RIEN vers Internet (vit dans tp_egress).
# =============================================================================
#
# Choix d'image : python:3.12-slim
#   * "slim" = surface d'attaque reduite (peu de paquets), image legere.
#   * Le serveur n'utilise QUE la bibliotheque standard -> aucune dependance
#     a installer, aucun "pip install", donc aucune chaine d'approvisionnement
#     externe a auditer. Image minimale et reproductible.
#
# Securite (rappel du perimetre TP) :
#   * AUCUN secret n'est copie dans l'image (les jetons sont factices et
#     injectes/observes au runtime cote agent, jamais ici).
#   * Le serveur tourne en utilisateur NON-root (principe du moindre privilege),
#     coherent avec la philosophie de durcissement du TP.
# -----------------------------------------------------------------------------

FROM python:3.12-slim

# Bonnes pratiques Python en conteneur :
#   PYTHONUNBUFFERED=1     -> logs emis immediatement (indispensable pour
#                            recuperer les preuves via "docker logs" en direct).
#   PYTHONDONTWRITEBYTECODE -> pas de .pyc parasites dans un FS qu'on veut propre.
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    EXFIL_HOST=0.0.0.0 \
    EXFIL_PORT=8000

# Repertoire de travail dedie.
WORKDIR /app

# Code du serveur (un seul fichier, stdlib only).
COPY server.py /app/server.py

# Creation d'un utilisateur non privilegie et bascule dessus.
# (UID fixe 10002 pour ne pas collisionner avec l'agent UID 10001 ; on n'utilise
#  PAS --system pour autoriser un UID eleve sans avertissement SYS_UID_MAX.)
RUN useradd --uid 10002 --no-create-home --shell /usr/sbin/nologin exfil \
    && chown -R exfil:exfil /app
USER exfil

# Le serveur ecoute sur 8000 (port autoritaire du TP).
EXPOSE 8000

# Sonde de sante native Docker : interroge GET /health via la stdlib
# (pas de curl/wget a installer -> image toujours minimale).
HEALTHCHECK --interval=10s --timeout=3s --start-period=3s --retries=5 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status==200 else 1)"]

# Lancement du puits d'exfiltration.
CMD ["python", "/app/server.py"]
