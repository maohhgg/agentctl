# agentctl

**One git worktree per AI coding agent task — scope-enforced, gate-checked, zero dependencies, single file.**

[![CI](https://github.com/maohhgg/agentctl/actions/workflows/ci.yml/badge.svg)](https://github.com/maohhgg/agentctl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Node](https://img.shields.io/badge/node-%E2%89%A520-brightgreen)](package.json)
[![PRs welcome](https://img.shields.io/badge/PRs-welcome-ff69b4.svg)](CONTRIBUTING.md)

[中文文档](README.zh-CN.md)

Run several AI coding agents (Claude Code, Codex, OpenCode, OMP, …) against the
same repository and they will clobber each other's files and git state. Branches
alone don't help — every checkout shares one working tree. **agentctl** gives
each task its own git worktree and task branch, restricts *which paths an agent
may touch*, and gates integration behind scope checks and tests — so agents can
work truly in parallel.

It is a headless, agent-native tool: no tmux, no Docker, no daemon, no UI.
One Node script, zero npm dependencies, and it is designed so that **the agents
themselves** can act as coordinator and workers by reading files in the repo.

---

## How it works — the two-level worktree model

```
main checkout (hub: docs, contracts, coordination)
 │
 └── platform worktree   wt/backend @ feature/backend          ← integration boundary
      │                     only merge / test / review / release happen here;
      │                     agents never develop here
      │
      ├── task worktree  ../my-repo-agent-worktrees/backend/backend-google-oauth-001
      │                     @ agent/codex/backend-google-oauth-001   ← one agent
      │
      └── task worktree  ../my-repo-agent-worktrees/backend/backend-payment-002
                            @ agent/omp/backend-payment-002         ← another agent
```

- **Platform worktree** — long-lived, one per deliverable target (backend, web,
  mobile…). Registered in `.agents/config/platforms.json` or auto-detected from
  `git worktree list`.
- **Task worktree** — one per task: one task branch + one isolated checkout +
  one agent. Created and reclaimed by agentctl. A task brief (`.agents/TASK.md`)
  is written into it and kept out of commits via `.git/info/exclude`.

Physical isolation prevents overwriting; logical conflicts are left to Git at
integration time. agentctl deliberately implements **no file locks**.

## Features

- **Zero dependencies, single file** — Node ≥ 20 and git, nothing else. Copy one
  executable into your repo (or `npm i -g`) and it works.
- **Agent-native protocol** — `agentctl task current` tells any agent whether it
  is a *Coordinator* or a *Worker*; the worker reads its brief from
  `.agents/TASK.md`. One copy-paste block in your `AGENTS.md` makes any agent
  self-organizing (see [below](#the-coordinator--worker-protocol)).
- **Scope write-set enforcement** — `--allowed-paths` globs define what a task
  may touch. `task check` / `task finish` fail on any out-of-scope file:
  untracked, unstaged, staged, *and* committed changes are all inspected.
- **Five-gate finish** — correct worktree and branch, clean tree, in-scope
  changes, ≥ 1 commit, tests pass. A rejected finish never touches your files.
- **Read-only merge pre-check** — `task merge-check` dry-runs the merge with
  `git merge-tree --write-tree` (older gits fall back to a temporary worktree)
  and reports `CLEAN` / `CONFLICT` without moving any branch or worktree.
- **Conflict continuation** — on conflict, `task integrate` *keeps the
  in-progress merge*, marks the task `conflict`, and tells you what to resolve;
  re-run the same command to conclude the merge commit. Nothing is reverted.
- **Base refresh** — `task update-base` pulls the platform branch's new commits
  into a long-running task branch with the same conflict-continuation semantics;
  a `ready` task whose base moved returns to `active` so its gates re-run.
- **Concurrent-safe registry** — task records are mutated under a mkdir mutex
  with atomic-rename writes; two agents can `task create` at the same instant.
  Lost records are recoverable from a task worktree's `.agents/TASK.md`
  (`task adopt`).
- **Multi-platform registries** — monorepo / multi-target repos declare several
  platform worktrees with aliases and per-platform test commands; undeclared
  worktrees are auto-detected.
- **Runner that never guesses flags** — built-in launch templates exist only for
  CLIs verified on a real install (`omp`, `opencode`); anything else is declared
  per-project in `agents.json`, or degrades to printing the manual command.
- **Human-readable task ids** — `Implement Google OAuth` on platform `backend`
  becomes `backend-google-oauth-001` (stop-words dropped, collisions numbered).

## Install

```bash
# npm (package name is agent-task-worktree; the binary is agentctl)
npm install -g agent-task-worktree

# or: one-line installer
curl -fsSL https://raw.githubusercontent.com/maohhgg/agentctl/main/install.sh | sh

# or: no install at all — it's one file; copy it into your repo and commit it
curl -fsSL https://raw.githubusercontent.com/maohhgg/agentctl/main/agentctl -o agentctl && chmod +x agentctl
```

Requirements: **Node ≥ 20** and **git ≥ 2.31** (git ≥ 2.38 recommended — enables
the fast `merge-tree` pre-check; older gits use an automatic fallback).
Linux and macOS; Windows via Git Bash / WSL.

## Quickstart

```bash
cd my-repo
agentctl init                          # one-time setup: register detected platforms + fix .gitignore
agentctl doctor                        # environment self-check

# create a task for a codex worker, confined to src/auth/**
agentctl task create --platform backend --agent codex \
  --title "Implement Google OAuth" \
  --requirements "login endpoint;callback;token refresh;tests" \
  --allowed-paths 'src/auth/**,tests/auth/**'

# hand it to the agent — either let agentctl launch it:
agentctl task start backend-google-oauth-001
# …or run the CLI yourself inside the printed task worktree:
cd ../my-repo-agent-worktrees/backend/backend-google-oauth-001 && codex

# when the worker reports done (run from anywhere in the repo):
agentctl task check backend-google-oauth-001        # scope audit
agentctl task update-base backend-google-oauth-001  # optional: pull newer platform commits into the task first
agentctl task merge-check backend-google-oauth-001  # read-only merge dry-run
agentctl task integrate backend-google-oauth-001    # --no-ff merge into the platform branch
agentctl task remove backend-google-oauth-001       # reclaim worktree + branch after review
```

If another task is already open over a overlapping scope on the same platform,
`task create` refuses and names the conflicting task — pass `--allow-overlap`
only when you are sure the parallelism is intended.

## The Coordinator / Worker protocol

The tool is built for repos whose `AGENTS.md` (or equivalent) teaches agents the
protocol. Paste and adapt:

```markdown
## Multi-agent task protocol (agentctl)

Decide your role with `agentctl task current`:
- If `.agents/TASK.md` exists in the current worktree → you are a **Worker**.
- Otherwise → you are the **Coordinator**.

### Coordinator (repo root / platform worktrees)
1. `agentctl platform list` and `agentctl task list --json` — pick the platform,
   check in-flight tasks and scope overlaps.
2. `agentctl task create --platform <p> --agent <cli> --title '…' \
      --requirements 'a;b;c' --allowed-paths '<globs>'`
3. `agentctl task start <id>` to launch the worker (or open the agent CLI in the
   printed worktree).
4. If the platform branch moved meanwhile: `agentctl task update-base <id>`.
5. After review: `agentctl task merge-check <id>` → `agentctl task integrate <id>`
   → `agentctl task remove <id>`.
   The coordinator never edits business code directly, and never merges tasks
   into the main branch — platform worktrees are the integration boundary.

### Worker (task worktree)
1. Read `.agents/TASK.md` — Objective / Requirements / Scope / Restrictions.
2. Implement **within Scope only**; commit to the task branch.
3. `agentctl task check <id>` (no out-of-scope files), then
   `agentctl task finish <id>` (gates: clean tree, scope, ≥ 1 commit, tests).
4. Never merge into the platform branch yourself; never use
   `git reset --hard` / `git clean` / `git checkout -- .` / `git stash`.
```

`task current` decides the mode from the worktree + `.agents/TASK.md` pair, not
from directory names, so the same instructions work for humans and agents.

## CLI reference

```
agentctl [-C <dir>] [--json] <command> [args]
```

| Command | Purpose |
|---|---|
| `init` | One-time setup: generate `platforms.json` from detected worktrees, add `.gitignore` entries (idempotent, never overwrites) |
| `doctor` | Self-check: git, repo, worktrees, registry, agent CLIs, mode |
| `agent list` | Agent runners and whether they're detected on PATH |
| `platform list` | Platform registry (auto-detected + declared), state and aliases |
| `task current` | Coordinator or Worker mode for the current directory |
| `task create` | New task: branch + worktree + `.agents/TASK.md` + registry record |
| `task list` | Filter by `--platform / --agent / --status / --feature` |
| `task show <id>` | Full metadata + live state (dirty, ahead, merged) |
| `task start <id>` | Launch the agent CLI inside the task worktree |
| `task check <id>` | Scope audit — exit 1 if any changed file is out of scope |
| `task diff <id>` | Diff vs base (`--stat`, `--name-only`, `--working` for uncommitted) |
| `task finish <id>` | Five gates → status `ready`; `--no-test` / `--test-command` / `--timeout` |
| `task update-base <id>` | Merge platform-branch new commits into the task branch and refresh its base (conflict-safe, `--dry-run`) |
| `task adopt` | Rebuild a lost task record from the current worktree's `.agents/TASK.md` |
| `task set-status <id> <status>` | Mark `blocked` / `failed` / `cancelled` / … |
| `task merge-check <id>` | Read-only merge dry-run; exit 1 on conflict |
| `task integrate <id>` | `--no-ff` merge into the platform branch; conflict-safe |
| `task remove <id>` | Reclaim worktree + branch + record (merged + clean only) |

Every command also emits machine-readable output with the global `--json` flag.

### Task lifecycle

```
created ──► active ──finish (5 gates)──► ready ──integrate──► integrating ──► merged ──remove──► (record deleted)
                                        ▲                        │
                                        │                        └─ conflict ──resolve, integrate──► merged
                         set-status ──► blocked / failed / cancelled
```

Open statuses (`created` … `integrating`) participate in scope-overlap detection.

## Configuration

**`.agents/config/platforms.json`** (committed to your repo; `agentctl init`
generates it from detected worktrees):

```jsonc
{
  "worktree_root": "../my-repo-agent-worktrees",  // default: ../<repo>-agent-worktrees
  "branch_prefix": "agent",                        // default: agent
  "platforms": {
    "backend": {
      "worktree": "wt/backend",      // required: platform worktree path
      "branch": "feature/backend",   // required: its integration branch
      "aliases": ["api"],            // optional: extra names accepted by --platform
      "test_command": "composer test", // default test gate for task finish
      "test_timeout": 300              // optional: kill hung test runs after N seconds
    }
  }
}
```

**`.agents/config/agents.json`** (optional — launch templates for CLIs without a
verified built-in one; `{worktree}` and `{prompt}` are substituted):

```json
{
  "claude": { "command": "claude", "args": ["-p", "{prompt}"] },
  "codex":  { "command": "codex",  "args": ["exec", "--cd", "{worktree}", "{prompt}"] }
}
```

We ship built-in templates only for flags we verified against a real installed
version (`omp` 18.2.5, `opencode`). For your own agent CLIs, declare them as
above — or don't, and `task start` will print the manual command.

Task records live in `.agents/tasks/<id>.json` and runtime files in
`.agents/state/` — both are runtime state. `agentctl init` adds the
`.gitignore` entries for you and `doctor` checks them.

## How it compares

| | agentctl | Claude Squad | Vibe Kanban | Conductor |
|---|---|---|---|---|
| Form | headless single-file CLI | TUI (Go + tmux) | local web kanban (Rust) | macOS app |
| Dependencies | Node + git only | tmux | server + browser | proprietary |
| Worktree per task | ✓ | ✓ | ✓ | ✓ |
| Scope write-set enforcement (`allowed_paths`) | ✓ | — | — | — |
| Task finish gates (scope + tests) | ✓ | — | — | — |
| Read-only merge pre-check | ✓ | — | — | — |
| Conflict continuation state machine | ✓ | — | — | — |
| Agent self-organization protocol (`AGENTS.md`) | ✓ | — | — | — |
| Human-facing UI | — | TUI | kanban board | native |
| Works with any agent CLI | ✓ | ✓ | ✓ | Claude Code / Codex |

The space moves fast; treat the table as a snapshot of positioning, not a
benchmark. agentctl is intentionally the **headless, enforcement-focused** member
of the family — it composes well with review UIs and CI instead of replacing
them. CLI messages are currently in Chinese; English output is on the roadmap.

## Security

agentctl executes test and runner commands defined inside the repository —
treat repository write access as code-execution trust, the same as CI.
Details and rules of thumb in [SECURITY.md](SECURITY.md).

## Development

```bash
bash tests/agent/agentctl-test.sh   # 21 sections, e2e, temp repos only
npm test                            # same thing
```

The suite covers: doctor, platform detection/declaration, task creation (explicit
+ auto ids), TASK.md exclusion, scope checks, overlap rejection, all finish gates,
merge-check (clean + conflict), integrate (incl. conflict continuation), the
status machine, runner launch + degradation, concurrent `task create`, and
reclamation rules. See [CONTRIBUTING.md](CONTRIBUTING.md) before your first PR.

## Roadmap

- [ ] English CLI output / i18n
- [ ] Built-in (verified) runner templates for more agent CLIs — PRs welcome,
      but flags must be verified against a real install, per [CONTRIBUTING](CONTRIBUTING.md)
- [ ] Optional TUI over the existing `--json` output
- [ ] GitHub PR creation as an alternative integrate target

## License

[MIT](LICENSE) © 2026 maohhgg
