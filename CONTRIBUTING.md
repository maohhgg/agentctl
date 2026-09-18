# Contributing to agentctl

Thanks for considering a contribution! agentctl is intentionally small:
**one executable file, zero third-party dependencies** (Node ≥ 20 stdlib + git).
Most changes should keep it that way.

## Setup

```bash
git clone https://github.com/maohhgg/agentctl.git
cd agentctl
bash tests/agent/agentctl-test.sh   # full e2e suite, runs in temp repos only
```

## Ground rules

1. **No new dependencies.** Node stdlib and `git` only. If you need a library,
   you probably need to reconsider the feature.
2. **Single file.** `agentctl` is the whole product. Keep helpers inside it.
3. **Tests must pass** (`npm test`) and new behavior needs coverage in
   `tests/agent/agentctl-test.sh`. The suite runs in `mktemp` repos and must
   never touch the developer's own repositories.
4. **Never guess agent CLI flags.** Built-in runner templates are added only
   for CLIs whose flags were verified against a real installed version (state
   the version in the template `note`). Otherwise use the project-declared
   `agents.json` path or the degrade-to-print fallback.
5. **The tool never destroys work.** Any command that could discard data must
   refuse by default and require an explicit `--force`, printing exactly what
   would be discarded. This invariant is non-negotiable.
6. **CLI messages are currently Chinese.** Keep new messages consistent with
   the existing style; full i18n is tracked on the roadmap. JSON output keys
   stay English and stable — they are a public interface.

## Commits

Use [Conventional Commits](https://www.conventionalcommits.org/) style
(`feat:`, `fix:`, `docs:`, `test:`, `ci:`, …).

## Reporting issues

Include: OS, `node --version`, `git --version`, `agentctl --version`, the exact
command, full output (add `--json` where relevant), and what you expected to
happen. Redact anything sensitive — task metadata contains paths and branch
names only, but double-check anyway.
