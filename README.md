# Hardening a Claude Code agent in a Docker container

[![CI](https://github.com/julienlafrance/tp-claude-hardened/actions/workflows/ci.yml/badge.svg)](https://github.com/julienlafrance/tp-claude-hardened/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

> Version française : [README.fr.md](README.fr.md)

> **Goal**: run the **Claude Code** agent inside a hardened **Docker** container
> and show, with a **BEFORE/AFTER** demo, that hardening through **read-only
> filesystem partitioning** protects the agent's configuration and state
> (`settings.json`, `CLAUDE.md`, `SKILL.md`, `.mcp.json`) against a compromised
> agent, whereas a **bare** (non-hardened) profile gets attacked successfully.
>
> This repository is a graded assignment for the DATA707 course (*Cybersecurity
> for Big Data & AI*, Télécom Paris). The main deliverable is a detailed report:
> **English translation in [`docs/en/REPORT.md`](docs/en/REPORT.md)**; French
> original in [`docs/RAPPORT.md`](docs/RAPPORT.md) / [`docs/RAPPORT.pdf`](docs/RAPPORT.pdf).
> The rest of the documentation (`docs/`, `attacks/`, appendices) and the code
> comments are in French.

---

## Results at a glance

Each attack is replayed against both profiles. The proof for each attempt is the
command, its exit code, and the (truncated) SHA-256 of the target **before and after**
(see [`docs/preuves/`](docs/preuves/)).

| # | Attempted attack | **Bare** agent | **Hardened** agent | Responsible mechanism |
|---|---|---|---|---|
| 1 | Rewrite `settings.json` (add a hook) | Succeeded | **Blocked** | `:ro` bind mount (kernel-enforced) |
| 2 | Modify `CLAUDE.md` | Succeeded | **Blocked** | `:ro` bind mount |
| 3 | Tamper with a skill (`SKILL.md`) | Succeeded | **Blocked** | skills mounted `:ro` |
| 4 | Add a server to `.mcp.json` | Succeeded | **Blocked** | `:ro` bind mount |
| 5 | Exfiltrate a (fake) secret | Succeeded | **Blocked** | secret not mounted + no egress (`--internal` network) |
| 6 | Destructive command outside the workspace | Succeeded | **Blocked** | `--read-only` root filesystem |
| 7 | BONUS: exfiltration through an allowed domain | Succeeded | **Blocked** | foreign API key rejected by LiteLLM (HTTP 401) + no network bypass |

**7 / 7** pairs match the expected matrix (bare = succeeded, hardened = blocked).
Full table: [`docs/preuves/resultats.md`](docs/preuves/resultats.md).

The hardened container runs with: non-root user (UID 10001), `--read-only` root,
`/tmp` as `noexec` tmpfs, `--cap-drop=ALL`, `no-new-privileges`, a restricted
seccomp allowlist, an internal-only network, memory/CPU/PID limits, and the
whole project `.claude/` directory mounted read-only, as well as the config
files (`CLAUDE.md`, `.mcp.json`, user settings and skills). Read-only
placeholders block the creation of new config files such as `CLAUDE.local.md`,
`settings.local.json`, `commands/` or `agents/`. Known residual risk: `~/.claude`
stays a writable tmpfs (runtime state), so other new file names can still be
created there (report, §8). See
[`steps/06-run-durci.sh`](steps/06-run-durci.sh), where every flag is commented.

---

## 1. Architecture (two rings)

```
corrin (physical host)
  └── Incus "tp-claude-host" (disposable lab host = RING 1)
        └── nested Docker
              ├── claude-hardened (HARDENED = RING 2, the graded part)   fixed IP 172.31.7.2
              └── claude-nu       (bare, the BEFORE demo)
```

- **Everything runs INSIDE the Incus instance** (`docker`/`bash`); no operational
  command is run from the physical host.
- **Model backend** = an external **LiteLLM** on **ixia** (`backend-host:3101`,
  out of scope). The hardened container reaches it **only** through the fixed
  `tp_internal` gateway `172.31.7.1:3101` (Incus device `litellm` → ixia).
  The `tp_internal` network is created with `--internal`: **no route to the Internet**.
- **No MITM proxy, no exfiltration server**: **provenance** is enforced by
  LiteLLM re-authenticating upstream with its own key (a foreign client key →
  **401**), **destination** by the network (`--internal`). See
  [`docs/10-litellm-vs-mitmproxy.md`](docs/10-litellm-vs-mitmproxy.md).
- **No Anthropic key ever enters the sandbox**: the agent authenticates to
  LiteLLM with a **scoped virtual key**; `ANTHROPIC_API_KEY` stays empty.
- **SSH**: bridge chain **corrin → incus → docker:2222** (dropbear), set up once
  (the hardened container's IP is fixed). SSH sessions are pinned to Claude Code
  by a forced command, never a shell. See [`scripts/ssh-bridge.sh`](scripts/ssh-bridge.sh).

## 2. Repository layout

```
tp/
├── README.md                  (this file; French version in README.fr.md)
├── run.sh                     (fail-fast orchestrator: ./run.sh all|up|attacks|down)
├── Makefile                   (shortcuts on top of run.sh: make all|up|attack|clean)
├── docker-compose.yml         (declarative variant: "nu" and "durci" profiles)
├── .env.example               (env template for Compose; copy to .env)
│
├── .secret/                   (backend secrets, NOT in the repo, gitignored)
│   ├── README.md
│   └── litellm.env.example    (template: scoped LiteLLM virtual key, endpoint, model)
│
├── agent/                     (agent image: claude-hardened:latest = zurban/tp-claude-hardened)
│   ├── Dockerfile             (USER agent UID 10001, non-root; dropbear for SSH)
│   ├── entrypoint.sh
│   ├── claude-session         (SSH forced command: starts Claude Code, never a shell)
│   ├── seccomp-claude.json    (restricted seccomp profile, syscall allowlist)
│   └── .dockerignore
│
├── config/                    (frozen root:root 0444/0555 sources of the agent config)
│   ├── project-settings.json   -> /workspace/.claude/settings.json     (:ro when hardened)
│   ├── project-CLAUDE.md       -> /workspace/CLAUDE.md                 (:ro when hardened)
│   ├── project-mcp.json        -> /workspace/.mcp.json                 (:ro when hardened)
│   ├── project-skills/         -> /workspace/.claude/skills            (:ro when hardened)
│   ├── user-settings.json      -> /home/agent/.claude/settings.json    (:ro when hardened)
│   ├── user-skills/            -> /home/agent/.claude/skills           (:ro when hardened)
│   ├── fake_token.txt          -> /run/secrets/fake_token.txt   (BARE profile ONLY)
│   ├── ssh-authorized_keys.example  (authorized SSH key, forced-command hardening)
│   └── README-perms.md         (second lock: POSIX permissions, defense in depth)
├── workspace/                 (test repo, mounted :rw, the only writable work area)
│
├── steps/                     (unit steps 00..09 called by run.sh)
│   ├── 00-preflight.sh        05-attacks-nu.sh
│   ├── 01-incus-host.sh       06-run-durci.sh
│   ├── 02-build.sh            07-attacks-durci.sh
│   ├── 03-config-perms.sh     08-results-table.sh
│   └── 04-run-nu.sh           09-teardown.sh
├── attacks/                   (documented attack scenarios 01..06 + injection payloads)
├── lib/log.sh                 (shared logger + loading of .secret/litellm.env)
├── scripts/
│   ├── incus-host.sh          (provisions the disposable Incus host "tp-claude-host")
│   ├── ssh-bridge.sh          (SSH bridge corrin → incus → docker, set up once)
│   ├── recreate-daily.sh      (anti-persistence re-creation, runs inside the instance)
│   ├── systemd/               (tp-recreate.service + .timer: re-creation every 24 h)
│   └── build-pdf.sh           (docs/RAPPORT.md -> PDF)
├── docs/                      (report RAPPORT.md/.pdf + appendices, in-depth notes, preuves/, en/)
│   └── preuves/               (sanitized evidence: attack logs, before/after hashes)
├── evidence/                  (raw evidence generated at run time; gitignored)
└── out/                       (build artifacts; gitignored)
```

*"nu" = bare, "durci" = hardened, "preuves" = evidence.*

---

## 3. Prerequisites

| Prerequisite | Status | Details |
|---|---|---|
| **Docker** (reachable daemon, INSIDE the instance) | **REQUIRED** | Imposed by the assignment. The agent and everything it runs live in Docker containers. |
| **`.secret/litellm.env`** (LiteLLM virtual key) | required at **runtime** | **Scoped** LiteLLM key (never the master key), used by the agent to authenticate to the external LiteLLM backend. Loaded by `lib/log.sh`, never baked into the image or committed. Without it the steps fall back to bash, and the filesystem/egress attacks still run. |
| **Incus** (LXC/VM) | ring 1 | Disposable host `tp-claude-host`. If you are already inside a host, set `SKIP_INCUS=1`. |
| `pandoc` + a LaTeX engine | optional | To build the PDF report. |

> **Safety**: every secret used in the attacks is **FAKE**
> (`FAKE-CORP-TOKEN-do-not-exfiltrate-1337`), no real third-party target is
> attacked, and **no Anthropic key enters the sandbox**.

---

## 4. Quickstart (inside the Incus instance)

```bash
# 0) Agent image: build locally, OR pull it from Docker Hub on a fresh VM
docker pull zurban/tp-claude-hardened:latest \
  && docker tag zurban/tp-claude-hardened:latest claude-hardened:latest

# 1) Backend secret (outside the repo): paste the scoped LiteLLM virtual key
cp .secret/litellm.env.example .secret/litellm.env
#    edit .secret/litellm.env: LITELLM_VIRTUAL_KEY=sk-... (otherwise bash fallback)

# 2) Authorized SSH key (hardened profile): put your public key in it
cp config/ssh-authorized_keys.example config/ssh-authorized_keys
#    edit config/ssh-authorized_keys

# 3) Full fail-fast chain: 00 -> 08 (no teardown)
SKIP_INCUS=1 ./run.sh all       # SKIP_INCUS=1 if you are already inside the instance

# 4) Read the BEFORE/AFTER proof
cat evidence/results.md
cat evidence/attacks-durci-detail.log   # command + exit code + hash before/after
```

### Trying it on your own machine (no Incus, no LiteLLM backend)

Verified on 2026-09-23 from a fresh clone, as a non-root user with Docker only:

```bash
git clone https://github.com/julienlafrance/tp-claude-hardened && cd tp-claude-hardened
docker pull zurban/tp-claude-hardened:latest && docker tag zurban/tp-claude-hardened:latest claude-hardened:latest
cp config/ssh-authorized_keys.example config/ssh-authorized_keys
SKIP_INCUS=1 KEEP_INCUS=1 ./run.sh all     # a few seconds (steps 00–08); results in evidence/results.md
SKIP_INCUS=1 KEEP_INCUS=1 ./run.sh down    # removes containers and networks
```

Expected result: attacks 1–6 **succeed on the bare profile and are blocked on the hardened one**
(6/7). The bonus (#7) is reported as **not tested**: proving that a foreign key is rejected needs
the LiteLLM gateway (`.secret/litellm.env`), which is not part of the repository. Without root,
the second lock (`root:root` ownership of the config sources) is skipped with a warning; the
kernel-enforced `:ro` mounts are unaffected.

### `run.sh` subcommands

| Command | Effect |
|---|---|
| `./run.sh all` | Runs 00 → 08 fail-fast (prerequisites, host, build, permissions, bare + attacks, hardened + attacks, results table). |
| `./run.sh up` | Prepares the infrastructure and starts bare + hardened (00, 01, 02, 03, 04, 06) without replaying the attacks. |
| `./run.sh attacks` | Replays the attacks on bare + hardened, then builds `evidence/results.md` (05, 07, 08). |
| `./run.sh down` | Teardown: stops containers/networks (Incus optional, `KEEP_INCUS=1` keeps it). |
| `./run.sh <step>` | Runs a single step, e.g. `./run.sh 06-run-durci`. |

> **Anti-persistence re-creation**: `scripts/recreate-daily.sh` (runs inside the
> instance) destroys and re-creates the hardened container; the fixed IP keeps
> the SSH bridge valid. 24 h timer in `scripts/systemd/`.
>
> **Compose variant** (declarative): `docker compose --profile durci up -d`
> (or `--profile nu`). `run.sh` remains the reference path (it also provisions
> the host, the permissions and the evidence).

---

## 5. Building the PDF report

```bash
./scripts/build-pdf.sh            # builds the PDF from docs/RAPPORT.md
```

---

## 6. Further reading

In English, the full report [`docs/en/REPORT.md`](docs/en/REPORT.md):
[threat model](docs/en/REPORT.md#3-threat-model),
[hardening design](docs/en/REPORT.md#4-hardening-design),
[before/after demonstration](docs/en/REPORT.md#6-before--after-demonstration),
[bonus: exfiltration through an allowed domain](docs/en/REPORT.md#7-bonus--exfiltration-through-an-allowed-domain),
[residual surface](docs/en/REPORT.md#8-residual-surface-and-limits).

In French:

- **Appendices** (scripts, seccomp profile, Dockerfile, evidence logs): [`docs/annexes.md`](docs/annexes.md).
- **File-level defense in depth**: [`config/README-perms.md`](config/README-perms.md).
- **Gateway observability** (LiteLLM logging, measured; settings to merge): [`backend/litellm-observabilite.yaml`](backend/litellm-observabilite.yaml), evidence in [`docs/preuves/litellm-journalisation/`](docs/preuves/litellm-journalisation/).
- **LiteLLM backend vs MITM proxy** (why there is no proxy): [`docs/10-litellm-vs-mitmproxy.md`](docs/10-litellm-vs-mitmproxy.md).
- **Model backend (LiteLLM on ixia)**: [`docs/09-backend-modele.md`](docs/09-backend-modele.md); running Claude Code on a local model: [`docs/11-backend-llm-local.md`](docs/11-backend-llm-local.md).
- **Host isolation (Incus LXC vs VM)**: [`docs/08-isolation-hote.md`](docs/08-isolation-hote.md).
- **Detailed threat model**: [`docs/02-threat-model.md`](docs/02-threat-model.md).
- **Threat references** (OWASP, MITRE ATLAS, Claude Code CVEs): [`docs/12-references-menaces.md`](docs/12-references-menaces.md).

---

## License

[MIT](LICENSE) © 2026 Julien Lafrance.
