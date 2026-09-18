# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 0.0.x | ✅ |

## Trust model — read this before using agentctl on someone else's repo

agentctl executes commands that are defined **inside the repository it runs in**:

- `task finish` runs the test command resolved from (highest priority first) the
  `--test-command` flag, the task record, or `test_command` /
  `test_timeout` in `.agents/config/platforms.json` — a file that is **committed
  to the repo**.
- `task start` executes an agent CLI through built-in templates or
  `.agents/config/agents.json` — also committed to the repo.

Consequence: **repository write access is code-execution trust**, the same trust
level you already grant to CI. Practical rules:

- Review changes to `.agents/config/*` the way you review CI workflow changes.
- Never point agentctl at a repository whose maintainers you do not trust.
- Scoped `--allowed-paths` restricts what the *agent* may change; they are not a
  sandbox for the *test command*, which runs with your user's full privileges.

## Data handling

- All state is local: `.agents/` files and git refs. agentctl makes **no network
  requests** and collects **no telemetry**.
- Task metadata (`.agents/tasks/*.json`, `.agents/TASK.md`) stores paths, branch
  names, timestamps and whatever text you pass via `--title` / `--objective` /
  `--requirements`. **Never put credentials in those fields** — they are plain
  files in your working tree.
- Secrets used by test commands stay in your environment; agentctl only forwards
  its own environment to the child process.

## Reporting a vulnerability

Please use GitHub's **private security advisories** ("Report a vulnerability"
on the Security tab) instead of a public issue. I aim to respond within a week.
