# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.2] - 2026-09-19

### Added

- `agentctl init`: one-command project setup — registers detected platform
  worktrees into `.agents/config/platforms.json` (leaving `test_command` /
  `aliases` for manual refinement) and appends the `.agents/tasks/` /
  `.agents/state/` exclusions to `.gitignore`. Idempotent: existing config is
  never overwritten. When no platform worktrees exist yet, prints the exact
  `git worktree add` command to bootstrap the integration boundary.
- `doctor` now checks the runtime-state `.gitignore` entries
  (`Runtime state gitignore`), completing the init/doctor pair.

### Changed

- **Breaking:** the state and config directory is renamed `.agent/` →
  `.agents/` (project config, task registry, runtime state, and the
  per-worktree `TASK.md`). Migrating an existing project: `mv .agent .agents`;
  move `.agent/TASK.md` → `.agents/TASK.md` inside every task worktree; update
  `.gitignore`, `.git/info/exclude`, and doc references. No dual-path
  fallback — the old name is not read.

### Fixed

- e2e fixture on macOS: the mktemp path is now resolved through `pwd -P`.
  macOS `TMPDIR` sits behind the `/var` → `/private/var` symlink, so the
  fixture's expectations diverged from the CLI's realpath-normalized output
  and three path assertions failed (`doctor` text, `doctor --json` root,
  `platform list --json` worktree_root) on the macOS CI matrix.

## [0.0.1] - 2026-09-19

Initial public development release.

### Added

- Two-level worktree model: long-lived **platform worktrees** as integration
  boundaries (merge / test / review / release) plus one isolated **task worktree**
  per agent task (`agent/<agent>/<task-id>` branches, worktrees under
  `../<repo>-agent-worktrees/<platform>/<task-id>` by default).
- Task registry with a nine-state lifecycle
  (`created / active / ready / blocked / conflict / integrating / merged / failed / cancelled`),
  persisted as `.agents/tasks/<id>.json` (schema version 1), mutated under a
  mkdir mutex with atomic-rename writes (safe for concurrent `task create` /
  `task finish`).
- Scope write-set enforcement: `--allowed-paths` globs per task; `task check`
  and `task finish` reject any change outside the scope (untracked, unstaged,
  staged, and committed files are all checked).
- Same-platform scope-overlap detection at `task create`, with explicit
  `--allow-overlap` confirmation.
- Five-gate `task finish`: correct worktree and branch, clean tree, in-scope
  changes, at least one commit, tests pass. Rejections never modify files.
  Test commands support an optional timeout (`--timeout`, per-task
  `test_timeout`, or per-platform `test_timeout`).
- Read-only `task merge-check` via `git merge-tree --write-tree`
  (automatic fallback to a temporary integration worktree on older gits).
- `task integrate` with conflict continuation: on conflict the in-progress merge
  is preserved, the task is marked `conflict`, and re-running the same command
  concludes the merge commit. Nothing is reverted.
- `task update-base`: pulls the platform branch's new commits into the task
  branch and refreshes the recorded base, so long-running tasks stay current.
  Same conflict-continuation semantics as `integrate`; a `ready` task whose
  base moved returns to `active` so its gates re-run.
- `task adopt`: rebuilds a lost registry record from a task worktree's
  `.agents/TASK.md` and task branch (merge-base), recovering orphaned tasks;
  `doctor` lists registered-branch orphans.
- `task remove` reclamation that follows reality: a task whose branch was
  merged by hand outside agentctl is detected as merged and reclaimed without
  `--force`.
- Coordinator / Worker mode detection via `task current` and a per-worktree
  `.agents/TASK.md` context file (kept out of commits through `.git/info/exclude`).
- AgentRunner with verified-flag built-in launch templates (`omp`, `opencode`)
  and project-declared templates (`agents.json`) — never guesses unverified flags;
  degrades to printing the manual launch command.
- Auto-generated readable task ids (`<platform>-<slug>-NNN`, stop-word filtered).
- Cross-platform feature grouping metadata (`--feature` / `--parent`).
- `doctor` self-check (git, node ≥ 20, worktree support, platform worktrees,
  registry, orphan branches, worktree-root placement, agent CLIs, mode),
  `platform list` / `agent list` inventories, `--json` output on every command,
  `task diff` (base / working / staged).
- End-to-end test suite running entirely in throwaway temp repos.

[0.0.2]: https://github.com/maohhgg/agentctl/releases/tag/v0.0.2
[0.0.1]: https://github.com/maohhgg/agentctl/releases/tag/v0.0.1
