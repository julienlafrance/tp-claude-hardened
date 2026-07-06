#!/usr/bin/env python3
# Prépare docs/RAPPORT.md pour pandoc/lualatex (charte Télécom Paris) :
#  - retire un éventuel front-matter YAML de tête ;
#  - injecte la PAGE DE TITRE (logos + école + titre + auteurs) puis la table des matières ;
#  - remplace chaque bloc ```mermaid``` par un include TikZ (fig{N}.tex) s'il existe ;
#  - concatène les annexes (arg 4).
#
# Identité de la page de titre — MODIFIER ICI si besoin :
#   auteur, encadrant, programme, année, sujet.
import re, sys, pathlib

SRC = pathlib.Path(sys.argv[1])          # docs/RAPPORT.md
OUT = pathlib.Path(sys.argv[2])          # build/RAPPORT.md
FIGDIR = pathlib.Path(sys.argv[3])       # dossier des fig{N}.tex (TikZ)

text = SRC.read_text(encoding="utf-8")

# 1) retire le front-matter YAML de tête (--- ... ---) UNIQUEMENT en tête
if text.startswith("---"):
    m = re.match(r"^---\n.*?\n---\n", text, flags=re.DOTALL)
    if m:
        text = text[m.end():]

# 2) PAGE DE TITRE (charte Télécom Paris / IMT) + table des matières
TITLE = r"""```{=latex}
\begin{titlepage}
\centering
\vspace*{0.3cm}
\noindent
\begin{minipage}[c]{0.55\textwidth}\raggedright\includegraphics[height=2.0cm]{telecom-paris.png}\end{minipage}%
\hfill
\begin{minipage}[c]{0.40\textwidth}\raggedleft\includegraphics[height=1.55cm]{imt.png}\end{minipage}

\vspace{1.8cm}
{\scshape\large École nationale supérieure des télécommunications\par}
\vspace{0.5cm}
{\scshape Cybersécurité --- sécurité des agents de codage autonomes\par}
\vspace{1.0cm}
\noindent\rule{\textwidth}{0.6pt}\\[0.55cm]
{\huge\bfseries Durcissement d'un agent de codage\\[5pt](Claude Code) en conteneur Docker\par}
\vspace{0.55cm}
\noindent\rule{\textwidth}{0.6pt}

\vspace{1.7cm}
\begin{flushleft}
{\itshape Réalisé par :}\\[6pt]
\hspace{1.2em}Julien \textsc{Lafrance}
\end{flushleft}
\vspace{0.7cm}
\begin{flushright}
{\itshape Dirigé par :}\\[6pt]
M. Julien \textsc{Dréano}\hspace{0.4em}
\end{flushright}

\vfill
{\bfseries MS IA Expert Data \& MLOps\par}
\vspace{0.3cm}
{Année universitaire 2025--2026\par}
\vspace{0.7cm}
\end{titlepage}

\clearpage
\microtypesetup{protrusion=false}
\tableofcontents
\microtypesetup{protrusion=true}
\clearpage
```

"""

# 3) mermaid -> TikZ include (ou placeholder)
counter = {"n": 0}
FIGDIR.mkdir(parents=True, exist_ok=True)
def repl_mermaid(m):
    counter["n"] += 1
    n = counter["n"]
    tikz = FIGDIR / f"fig{n}.tex"
    if tikz.exists():
        return ("```{=latex}\n\\begin{center}\\begin{adjustbox}{max width=\\linewidth}\n"
                "\\input{%s}\n\\end{adjustbox}\\end{center}\n```" % tikz.as_posix())
    (FIGDIR / f"mermaid{n}.txt").write_text(m.group(1), encoding="utf-8")
    return ("```{=latex}\n\\begin{calloutbox}\\centering\\itshape "
            "[schéma %d — rendu TikZ en cours]\\end{calloutbox}\n```" % n)

text = re.sub(r"```mermaid\n(.*?)```", repl_mermaid, text, flags=re.DOTALL)

# 4) annexes (arg 4)
ANNEX = ""
if len(sys.argv) > 4:
    ap = pathlib.Path(sys.argv[4])
    if ap.exists():
        ANNEX = "\n\n" + ap.read_text(encoding="utf-8")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(TITLE + text + ANNEX, encoding="utf-8")
print(f"[preprocess] {counter['n']} bloc(s) mermaid ; annexes={'oui' if ANNEX else 'non'} ; écrit -> {OUT}")
