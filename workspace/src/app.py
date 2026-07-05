#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
 MINI-PROJET DE DEMONSTRATION — "tache de codage reelle" pour l'agent
=============================================================================

POURQUOI CE FICHIER EXISTE
--------------------------
L'exigence #1 du TP impose que l'agent (Claude Code) tourne sur une VRAIE
tache de developpement, et pas dans le vide : on lui donne donc un petit
projet Python fonctionnel a faire evoluer/tester. Ce module est volontairement
simple, autonome (stdlib uniquement) et couvert par des tests, pour que :

  * l'agent ait un travail LEGITIME a executer dans /workspace (monte :rw) ;
  * on puisse verifier qu'apres durcissement l'agent reste PLEINEMENT
    fonctionnel sur sa tache (il ecrit/teste dans /workspace) tout en etant
    EMPECHE d'alterer sa propre configuration (montee :ro) ou d'exfiltrer.

THEME FONCTIONNEL : une petite calculatrice de "texte/log"
----------------------------------------------------------
Des utilitaires d'analyse de texte (comptage de mots, mot le plus frequent,
analyse de logs au format "NIVEAU message"). C'est typique d'une tache qu'un
agent de codage realise : parsing, agregation, fonctions pures testables.

Toutes les fonctions sont PURES (pas d'I/O, pas de reseau, pas d'effet de
bord) -> faciles a tester et sans risque pour le bac a sable.
"""

from __future__ import annotations

import re
from collections import Counter
from typing import Dict, List, Optional, Tuple

# Expression reguliere d'une ligne de log "NIVEAU message".
# Exemple : "ERROR connexion perdue" -> niveau="ERROR", message="connexion perdue".
_LOG_LINE_RE = re.compile(r"^\s*(?P<level>[A-Z]+)\s+(?P<msg>.*\S)\s*$")

# Niveaux de log reconnus, du moins grave au plus grave.
KNOWN_LEVELS: Tuple[str, ...] = ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL")


def normalize(text: str) -> str:
    """
    Normalise un texte : minuscules + espaces compresses + bords nettoyes.

    >>> normalize("  Bonjour   LE   Monde ")
    'bonjour le monde'
    """
    return re.sub(r"\s+", " ", text).strip().lower()


def word_count(text: str) -> int:
    """
    Compte le nombre de mots d'un texte (separes par des espaces).

    >>> word_count("un deux trois")
    3
    >>> word_count("   ")
    0
    """
    cleaned = normalize(text)
    if not cleaned:
        return 0
    return len(cleaned.split(" "))


def word_frequencies(text: str) -> Dict[str, int]:
    """
    Renvoie un dictionnaire {mot: occurrences}, casse/espaces normalises.

    >>> word_frequencies("Chat chat CHIEN")
    {'chat': 2, 'chien': 1}
    """
    cleaned = normalize(text)
    if not cleaned:
        return {}
    return dict(Counter(cleaned.split(" ")))


def most_common_word(text: str) -> Optional[str]:
    """
    Renvoie le mot le plus frequent, ou ``None`` si le texte est vide.
    En cas d'egalite, renvoie le premier rencontre (ordre stable de Counter).

    >>> most_common_word("a b a b a")
    'a'
    >>> most_common_word("") is None
    True
    """
    freqs = word_frequencies(text)
    if not freqs:
        return None
    # Counter.most_common conserve l'ordre d'insertion en cas d'egalite.
    return Counter(freqs).most_common(1)[0][0]


def parse_log_line(line: str) -> Optional[Tuple[str, str]]:
    """
    Analyse une ligne de log "NIVEAU message".

    Renvoie ``(niveau, message)`` si la ligne correspond a un niveau connu,
    sinon ``None`` (ligne ignoree).

    >>> parse_log_line("ERROR disque plein")
    ('ERROR', 'disque plein')
    >>> parse_log_line("ligne sans niveau") is None
    True
    """
    match = _LOG_LINE_RE.match(line)
    if not match:
        return None
    level = match.group("level")
    if level not in KNOWN_LEVELS:
        return None
    return level, match.group("msg")


def summarize_logs(lines: List[str]) -> Dict[str, int]:
    """
    Agrege une liste de lignes de log en comptant les occurrences par niveau.
    Les niveaux jamais rencontres ne figurent pas dans le resultat.

    >>> summarize_logs(["INFO ok", "ERROR boum", "INFO encore", "bruit"])
    {'INFO': 2, 'ERROR': 1}
    """
    counts: Counter = Counter()
    for line in lines:
        parsed = parse_log_line(line)
        if parsed is not None:
            counts[parsed[0]] += 1
    return dict(counts)


def main(argv: Optional[List[str]] = None) -> int:
    """
    Petite CLI de demonstration : lit du texte depuis les arguments et affiche
    le nombre de mots + le mot le plus frequent. Sans argument, montre un
    exemple. Permet a l'agent de "lancer le programme" trivialement.
    """
    import sys

    args = sys.argv[1:] if argv is None else argv
    text = " ".join(args) if args else "le chat et le chien et le chat"

    print(f"texte         : {text!r}")
    print(f"nombre de mots: {word_count(text)}")
    print(f"mot frequent  : {most_common_word(text)!r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
