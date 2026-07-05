#!/usr/bin/env python3
# Prépare docs/RAPPORT-V0.md pour pandoc/lualatex :
#  - retire le front-matter YAML de tête
#  - injecte un bloc titre + encadré lavande (charte)
#  - remplace chaque bloc ```mermaid``` par un include TikZ (fig{N}.tex) s'il existe,
#    sinon par un placeholder ; sauvegarde les sources mermaid.
import re, sys, pathlib

SRC = pathlib.Path(sys.argv[1])          # docs/RAPPORT-V0.md
OUT = pathlib.Path(sys.argv[2])          # build/RAPPORT.md
FIGDIR = pathlib.Path(sys.argv[3])       # dossier des fig{N}.tex (TikZ)

text = SRC.read_text(encoding="utf-8")

# 1) retire le front-matter YAML de tête (--- ... ---) UNIQUEMENT en tête
if text.startswith("---"):
    m = re.match(r"^---\n.*?\n---\n", text, flags=re.DOTALL)
    if m:
        text = text[m.end():]

# 2) retire le premier blockquote "> **Dépôt du projet ...**" (repris dans le titre)
text = re.sub(r"\A\s*(?:>[^\n]*\n)+\s*", "", text)
# retire aussi un "---" isolé résiduel en tout début
text = re.sub(r"\A\s*---\s*\n", "", text)

# 3) bloc titre + encadré (charte) injecté en tête
TITLE = r"""```{=latex}
\thispagestyle{fancy}
\begin{center}
{\LARGE\bfseries\color{accent} Durcissement d'un agent de codage\\[2pt]
(Claude Code) en conteneur Docker}\\[7pt]
{\large\itshape TP cybersécurité — rapport · Julien · 2025–2026}
\end{center}
\vspace{1pt}
\begin{calloutbox}
\centering{\bfseries\color{accent2}Dépôt du projet — code · configurations · preuves}\\[3pt]
\small GitHub\quad\url{https://github.com/julienlafrance/tp-claude-hardened}\\[1pt]
\small Image Docker\quad\texttt{zurban/tp-claude-hardened:latest}
\end{calloutbox}
\vspace{4pt}
{\small\tableofcontents}
\clearpage
```

"""

# 4) mermaid -> TikZ include (ou placeholder)
counter = {"n": 0}
FIGDIR.mkdir(parents=True, exist_ok=True)
def repl_mermaid(m):
    counter["n"] += 1
    n = counter["n"]
    tikz = FIGDIR / f"fig{n}.tex"
    if tikz.exists():
        return ("```{=latex}\n\\begin{center}\\begin{adjustbox}{max width=\\linewidth}\n"
                "\\input{%s}\n\\end{adjustbox}\\end{center}\n```" % tikz.as_posix())
    # figure TikZ absente : on sauvegarde la source mermaid (pour l'auteur) + placeholder
    (FIGDIR / f"mermaid{n}.txt").write_text(m.group(1), encoding="utf-8")
    return ("```{=latex}\n\\begin{calloutbox}\\centering\\itshape "
            "[schéma %d — rendu TikZ en cours]\\end{calloutbox}\n```" % n)

text = re.sub(r"```mermaid\n(.*?)```", repl_mermaid, text, flags=re.DOTALL)

ANNEX = ""
if len(sys.argv) > 4:
    ap = pathlib.Path(sys.argv[4])
    if ap.exists():
        ANNEX = "\n\n" + ap.read_text(encoding="utf-8")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(TITLE + text + ANNEX, encoding="utf-8")
print(f"[preprocess] {counter['n']} bloc(s) mermaid ; annexes={'oui' if ANNEX else 'non'} ; écrit -> {OUT}")
