# =============================================================================
# Makefile — interface conviviale au-dessus de run.sh (groupe "runner").
# -----------------------------------------------------------------------------
# Cibles principales (mappees sur PLAN.md sec.6) :
#   make all      -> chaine complete 00..08 (fail-fast)        [= ./run.sh all]
#   make up       -> prepare l'infra + lance NU et DURCI       [= ./run.sh up]
#   make attack   -> rejoue les attaques NU+DURCI + table       [= ./run.sh attacks]
#   make report   -> (re)genere la table de resultats          [= ./run.sh 08]
#   make clean    -> teardown (conteneurs/reseaux + Incus)      [= ./run.sh down]
#   make list     -> liste les steps disponibles
#
# Cibles par step : make 00 ... make 09 (execute un step isole).
#
# Variables transmises a run.sh (export) :
#   SKIP_INCUS=1   ne provisionne pas l'hote Incus (anneau 1)
#   KEEP_INCUS=1   conserve l'instance Incus au teardown
#   FORCE_BUILD=1  rebuild des images sans cache
#
# Exemple : make all SKIP_INCUS=1
# =============================================================================

# Repertoire de ce Makefile (racine du projet tp/).
TP_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RUN     := $(TP_ROOT)/run.sh

# On exporte les variables d'option afin que run.sh/steps les voient.
export SKIP_INCUS
export KEEP_INCUS
export FORCE_BUILD

# Toutes les cibles sont "phony" (pas de fichiers du meme nom a produire).
.PHONY: all up attack attacks report clean down list help \
        00 01 02 03 04 05 06 07 08 09

# Cible par defaut : aide.
help:
	@echo "Cibles : all | up | attack | report | clean | list | 00..09"
	@echo "Options: SKIP_INCUS=1  KEEP_INCUS=1  FORCE_BUILD=1"
	@echo "Exemple: make all SKIP_INCUS=1"

# --- Chaine complete --------------------------------------------------------
all:
	@bash "$(RUN)" all

# --- Preparation + lancement des deux profils -------------------------------
up:
	@bash "$(RUN)" up

# --- Attaques (NU + DURCI) + table ------------------------------------------
attack attacks:
	@bash "$(RUN)" attacks

# --- (Re)generation de la table de resultats --------------------------------
report:
	@bash "$(RUN)" 08-results-table

# --- Teardown ---------------------------------------------------------------
clean down:
	@bash "$(RUN)" down

# --- Liste des steps --------------------------------------------------------
list:
	@bash "$(RUN)" list

# --- Steps isoles (00..09) --------------------------------------------------
00:
	@bash "$(RUN)" 00-preflight
01:
	@bash "$(RUN)" 01-incus-host
02:
	@bash "$(RUN)" 02-build
03:
	@bash "$(RUN)" 03-config-perms
04:
	@bash "$(RUN)" 04-run-nu
05:
	@bash "$(RUN)" 05-attacks-nu
06:
	@bash "$(RUN)" 06-run-durci
07:
	@bash "$(RUN)" 07-attacks-durci
08:
	@bash "$(RUN)" 08-results-table
09:
	@bash "$(RUN)" 09-teardown
