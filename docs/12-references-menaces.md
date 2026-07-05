# 12 — Références : paysage de menaces & durcissements recommandés (sourcé)

> Annexe documentaire du modèle de menace (`docs/02`). Chaque point provient d'une source
> autoritative, citée. Objectif : ancrer notre design dans l'état de l'art (containment Anthropic,
> frameworks OWASP/MITRE, CVE réelles, bonnes pratiques Docker) plutôt que dans notre seule opinion.

---

## A. Guidance de containment d'Anthropic (l'éditeur de l'agent)

- **Taxonomie 3 catégories** (User Misuse / Model Misbehavior / External Attacker) = celle de
  l'énoncé. — *How we contain Claude across products* : <https://www.anthropic.com/engineering/how-we-contain-claude>
- **Principe directeur** : *« Design for containment at the environment layer first, then steer
  behavior at the model layer. The deterministic boundary is what gets hit when everything
  probabilistic misses. »* — *ibid.*
- **Approval fatigue** : les utilisateurs approuvent *« roughly 93% of permission prompts »* → la
  revue humaine est un contrôle faible à l'échelle. — *ibid.*
- **Incident « Cowork »** (exfil via domaine *autorisé* `api.anthropic.com`, avec une **clé
  attaquant**) ; correctif = **MITM défensif liant un token de session scopé, qui rejette la clé
  injectée** et bloque les en-têtes de server-side fetch. *« Every function reachable through any
  domain on an allowlist is now an attack surface. »* — *ibid.* → **c'est notre bonus** (LiteLLM
  ré-authentifie : clé étrangère → 401 ; `docs/10`).
- **Filesystem/réseau tous deux requis** : *« effective sandboxing requires both filesystem and
  network isolation »*. — *Claude Code sandboxing* : <https://www.anthropic.com/engineering/claude-code-sandboxing>
- **sandbox-runtime (srt)** : écritures **deny-by-default** ; *« denies write access to Claude
  Code's settings.json files at every scope … so a sandboxed command cannot modify its own
  policy »* ; protège aussi `.bashrc`/`.zshrc`, git hooks, `.vscode/`,`.idea/` ; **résoudre les
  symlinks avant validation**. — <https://github.com/anthropic-experimental/sandbox-runtime> ·
  <https://code.claude.com/docs/en/sandboxing>
- **Devcontainer Anthropic** (Docker) : egress **default-deny** (`init-firewall.sh` + iptables/ipset),
  **non-root**, **ne pas monter les secrets hôte** (`~/.ssh`, creds cloud), managed-settings,
  version épinglée, `DISABLE_AUTOUPDATER`. — <https://code.claude.com/docs/en/devcontainer>
- **Honnêteté** : *« Sandboxing reduces risk but is not a complete isolation boundary »* ; échelle
  d'isolation faible→forte : bash-sandbox → srt → devcontainer → conteneur → **VM** (noyau
  propre). — <https://code.claude.com/docs/en/sandbox-environments>

## B. Frameworks de menace LLM / agentique

- **OWASP Top 10 for LLM Apps (2025)** — <https://owasp.org/www-project-top-10-for-large-language-model-applications/>
  - **LLM01 Prompt Injection** (direct/indirect ; *« ne requiert pas d'être lisible par un
    humain »*). — <https://genai.owasp.org/llmrisk/llm01-prompt-injection/>
  - **LLM06 Excessive Agency** (fonctionnalité/permissions/autonomie excessives ; préférer des
    outils granulaires au shell ouvert). — <https://genai.owasp.org/llmrisk/llm062025-excessive-agency/>
  - **LLM07 System Prompt Leakage** (ne pas déléguer l'autorisation au LLM ; l'appliquer
    **hors** modèle, de façon déterministe). — <https://genai.owasp.org/llmrisk/llm072025-system-prompt-leakage/>
- **OWASP Agentic — Threats & Mitigations (T1–T15)** : **T1 Memory Poisoning** (injection
  persistante en mémoire ; mitigations : validation, **isolation de session**, sanitization,
  rollback). — <https://genai.owasp.org/resource/agentic-ai-threats-and-mitigations/>
- **MITRE ATLAS** — <https://atlas.mitre.org/>
  - **AML.T0051 LLM Prompt Injection** (Execution/Initial Access). — <https://atlas.mitre.org/techniques/AML.T0051>
  - **AML.T0081 Modify AI Agent Configuration** : *« change agent configuration files (system
    prompts, tool allowlists, role definitions), causing malicious changes to persist across every
    agent that inherits the config »* — **la technique la plus on-point pour notre actif**.
  - **AML.T0080 AI Agent Context Poisoning** (.000 Memory). — via Zenity Labs :
    <https://zenity.io/blog/current-events/zenity-labs-and-mitre-atlas-collaborate-to-advances-ai-agent-security-with-the-first-release-of>
  - *Étude de cas config-tampering (OpenClaw)* : <https://www.mitre.org/sites/default/files/2026-02/PR-26-00176-1-MITRE-ATLAS-OpenClaw-Investigation.pdf>
  - *(IDs ATLAS versionnés ; vérifier sur atlas.mitre.org avant citation « dure ».)*
- **Injection indirecte** (Greshake et al., AISec'23) : payloads dans des données récupérées =
  *« arbitrary code »*. — <https://arxiv.org/abs/2302.12173>
- **Willison** — « lethal trifecta » (données privées + contenu non fiable + canal d'exfil) ;
  *« 95% is a failing grade »* ; défense = **ne pas réunir les trois**. —
  <https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/>

## C. CVE / incidents réels (⇒ l'agent = code non fiable)

- **CVE-2025-59536 / CVE-2026-21852** (Check Point) : hook d'un `.claude/settings.json` commité +
  MCP `enableAllProjectMcpServers` **exécutés AVANT le trust dialog** ; `ANTHROPIC_BASE_URL` piloté
  par le repo **exfiltre la clé API en clair**. — <https://research.checkpoint.com/2026/rce-and-api-token-exfiltration-through-claude-code-project-files-cve-2025-59536/>
- **CVE-2025-54795** (RCE, injection de commande dans une commande allowlistée) et **CVE-2025-54794**
  (bypass de sandbox par test de préfixe `startsWith`). — <https://cymulate.com/blog/cve-2025-547954-54795-claude-inverseprompt/>
- **CVE-2025-52882** (WebSocket d'extension IDE non authentifié → lecture fichiers / exec). —
  <https://securitylabs.datadoghq.com/articles/claude-mcp-cve-2025-52882/>
- **MCP tool poisoning** (instructions cachées dans la description d'un outil ; PoC lit `~/.ssh/id_rsa`).
  — <https://invariantlabs.ai/blog/mcp-security-notification-tool-poisoning-attacks>
- **CVE-2025-54136 « MCPoison »** (rug-pull : définition MCP validée bénigne puis remplacée). —
  <https://research.checkpoint.com/2025/cursor-vulnerability-mcpoison/>
- **Exfil via domaine autorisé** (Cowork ; clé attaquant + Files API) + **exfil DNS** (Rehberger).
  — <https://www.promptarmor.com/resources/claude-cowork-exfiltrates-files> ·
  <https://www.oasis.security/blog/claude-ai-prompt-injection-data-exfiltration-vulnerability>
- **Spec MCP — Security Best Practices** (confused deputy, token passthrough interdit, SSRF,
  session hijacking, consentement explicite avant exécution locale). —
  <https://modelcontextprotocol.io/specification/2025-06-18/basic/security_best_practices>

## D. Durcissement Docker (CIS / OWASP) — chaque contrôle ↔ l'évasion qu'il bloque

| Contrôle | Évasion/abus bloqué | Source |
|---|---|---|
| **Ne jamais monter `/var/run/docker.sock`** | contrôle du démon → takeover hôte | OWASP Docker Cheat Sheet ; <https://docs.docker.com/engine/security/> |
| **Pas de `--privileged` / `--network=host`** | évasion cgroup `release_agent` (CVE-2022-0492) | Trail of Bits ; Sysdig |
| **`--cap-drop=ALL`** | `CAP_SYS_ADMIN` → mount/escape | OWASP ; Docker docs |
| **`--security-opt=no-new-privileges`** | escalade SUID/SGID | CIS Docker Benchmark |
| **Non-root `USER` (+ userns)** | breakout = root hôte | OWASP ; Docker docs |
| **seccomp (défaut ou +strict)** | `mount`,`ptrace`,`bpf`,`io_uring`,namespaces | <https://docs.docker.com/engine/security/seccomp/> |
| **`--read-only` + tmpfs** | dépôt de binaires, persistance | OWASP Docker Cheat Sheet |
| **cgroups `--memory/--pids-limit/--cpus`** | DoS, **fork-bomb** | CIS ; <https://docs.docker.com/engine/security/> |
| **AppArmor/SELinux (ne pas `unconfined`)** | précondition d'évasions | OWASP ; Trail of Bits |

Cheat Sheet OWASP : <https://cheatsheetseries.owasp.org/cheatsheets/Docker_Security_Cheat_Sheet.html> ·
CIS Docker Benchmark : <https://github.com/dev-sec/cis-docker-benchmark>

---

**Synthèse.** Prompt injection **non résolue** au niveau modèle (OWASP LLM01 / MITRE AML.T0051 /
Greshake / Willison) → la défense d'un actif config/état doit être **architecturale** : traiter la
config clonée comme **donnée non fiable**, verrouiller toute mutation de config/état de façon
**déterministe** (montages `:ro` **au niveau répertoire**, racine read-only, egress bordé), et
protéger l'intégrité mémoire/config contre les techniques désormais cataloguées (ATLAS
AML.T0080/T0081). Ce constat vaut **d'autant plus** avec un modèle OSS auto-hébergé **sans
garde-fous internes** (`docs/02` §2.4).
