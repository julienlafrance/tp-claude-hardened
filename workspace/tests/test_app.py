#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
 TESTS du mini-projet de demonstration (workspace/src/app.py)
=============================================================================

Ces tests valident la "tache de codage reelle" confiee a l'agent. Ils servent
deux objectifs du TP :

  1. Prouver que le projet de demo est FONCTIONNEL (l'agent a un vrai travail).
  2. Servir de cible de travail LEGITIME pour l'agent durci : il doit pouvoir
     lire/ecrire dans /workspace (monte :rw) et faire passer ces tests, alors
     meme qu'il est EMPECHE de toucher a sa config (montee :ro).

Compatibilite : ecrits avec ``pytest`` si disponible, mais SANS aucune
dependance obligatoire — le bloc final permet aussi de lancer le fichier
directement avec l'interpreteur Python standard :

    python /workspace/tests/test_app.py     # mode autonome (stdlib)
    pytest  /workspace/tests/test_app.py     # mode pytest

On resout l'import de ``app`` de maniere robuste, que les tests soient lances
depuis /workspace, depuis tests/, ou via pytest (rootdir variable).
"""

from __future__ import annotations

import os
import sys

# --- Resolution robuste de l'import du module sous test ---------------------
# On ajoute .../workspace/src au sys.path pour pouvoir "import app" quel que
# soit le repertoire courant au moment de l'execution.
_HERE = os.path.dirname(os.path.abspath(__file__))
_SRC = os.path.normpath(os.path.join(_HERE, "..", "src"))
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)

import app  # noqa: E402  (import differe apres ajustement du sys.path)


# ---------------------------------------------------------------------------
# normalize
# ---------------------------------------------------------------------------
def test_normalize_compresse_espaces_et_casse():
    assert app.normalize("  Bonjour   LE   Monde ") == "bonjour le monde"


def test_normalize_chaine_vide():
    assert app.normalize("   ") == ""


# ---------------------------------------------------------------------------
# word_count
# ---------------------------------------------------------------------------
def test_word_count_simple():
    assert app.word_count("un deux trois") == 3


def test_word_count_vide():
    assert app.word_count("   ") == 0


def test_word_count_espaces_multiples():
    assert app.word_count("  a   b  ") == 2


# ---------------------------------------------------------------------------
# word_frequencies
# ---------------------------------------------------------------------------
def test_word_frequencies_casse_insensible():
    assert app.word_frequencies("Chat chat CHIEN") == {"chat": 2, "chien": 1}


def test_word_frequencies_vide():
    assert app.word_frequencies("") == {}


# ---------------------------------------------------------------------------
# most_common_word
# ---------------------------------------------------------------------------
def test_most_common_word_basique():
    assert app.most_common_word("a b a b a") == "a"


def test_most_common_word_texte_vide_renvoie_none():
    assert app.most_common_word("") is None


def test_most_common_word_egalite_premier_rencontre():
    # "x" et "y" a egalite -> "x" (premier insere) gagne.
    assert app.most_common_word("x y x y") == "x"


# ---------------------------------------------------------------------------
# parse_log_line
# ---------------------------------------------------------------------------
def test_parse_log_line_valide():
    assert app.parse_log_line("ERROR disque plein") == ("ERROR", "disque plein")


def test_parse_log_line_niveau_inconnu():
    assert app.parse_log_line("TRACE quelque chose") is None


def test_parse_log_line_sans_niveau():
    assert app.parse_log_line("ligne sans niveau") is None


def test_parse_log_line_espaces_de_bordure():
    assert app.parse_log_line("   INFO   demarrage   ") == ("INFO", "demarrage")


# ---------------------------------------------------------------------------
# summarize_logs
# ---------------------------------------------------------------------------
def test_summarize_logs_agregation():
    lignes = ["INFO ok", "ERROR boum", "INFO encore", "bruit"]
    assert app.summarize_logs(lignes) == {"INFO": 2, "ERROR": 1}


def test_summarize_logs_liste_vide():
    assert app.summarize_logs([]) == {}


def test_summarize_logs_ignore_lignes_invalides():
    lignes = ["pas un log", "ZZZ rien", "WARNING attention"]
    assert app.summarize_logs(lignes) == {"WARNING": 1}


# ---------------------------------------------------------------------------
# main (CLI) — verifie juste le code de retour et l'absence d'exception.
# ---------------------------------------------------------------------------
def test_main_retourne_zero():
    assert app.main(["le", "chat", "et", "le", "chien"]) == 0


def test_main_sans_argument():
    assert app.main([]) == 0


# ---------------------------------------------------------------------------
# Mode autonome : permet de lancer les tests sans pytest (stdlib uniquement).
# On detecte et execute toutes les fonctions "test_*" du module, en rapportant
# un resume. Code de sortie != 0 si au moins un test echoue (fail-fast amical).
# ---------------------------------------------------------------------------
def _run_standalone() -> int:
    tests = sorted(
        (name, obj)
        for name, obj in globals().items()
        if name.startswith("test_") and callable(obj)
    )
    failures = []
    for name, fn in tests:
        try:
            fn()
            print(f"PASS  {name}")
        except AssertionError as exc:  # echec d'assertion = test rouge
            failures.append((name, repr(exc)))
            print(f"FAIL  {name}  ->  {exc!r}")
        except Exception as exc:  # erreur inattendue = test rouge aussi
            failures.append((name, repr(exc)))
            print(f"ERROR {name}  ->  {exc!r}")

    total = len(tests)
    print(f"\nResume : {total - len(failures)}/{total} tests reussis.")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(_run_standalone())
