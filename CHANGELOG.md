# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-09-19

First public, standalone release. (Versions 1.0–1.1 were internal iterations;
the tool was hardened in production on a four-platform monorepo before extraction.)

### Added

- Two-level worktree model: long-lived **platform worktrees** as integration
  boundaries (merge / test / review / release) plus one isolated **task worktree**
  per agent task (`agent/<agent>/<task-id>` branches, worktrees under
  `../<repo>-agent-worktrees/<platform>/<task-id>`).
- Task registry with a nine-state lifecycle
  (`created / active / ready / blocked / conflict / integrating / merged / failed / cancelled`),
  persisted as `.agent/tasks/<id>.json`, mutated under a mkdir mutex with
  atomic-rename writes (safe for concurrent `task create` / `task finish`).
- Scope write-set enforcement: `--allowed-paths` globs per task; `task check`
  and `task finish` reject any change outside the scope (untracked, unstaged,
  staged, and committed files are all checked).
- Same-platform scope-overlap detection at `task create`, with explicit
  `--allow-overlap` confirmation.
- Five-gate `task finish`: correct worktree and branch, clean tree, in-scope
  changes, at least one commit, tests pass. Rejections never modify files.
- Read-only `task merge-check` via `git merge-tree --write-tree`
  (automatic fallback to a temporary integration worktree on older gits).
- `task integrate` with conflict continuation: on conflict the in-progress merge
  is preserved, the task is marked `conflict`, and re-running the same command
  concludes the merge after conflicts are resolved.
- `task remove` guarded reclamation (merged + clean only; `--force` with warnings).
- Coordinator / Worker mode detection via `task current` and a per-worktree
  `.agent/TASK.md` context file (kept out of commits through `.git/info/exclude`).
- AgentRunner with verified-flag built-in launch templates (`omp`, `opencode`)
  and project-declared templates (`agents.json`) — never guesses unverified flags;
  degrades to printing the manual launch command.
- Auto-generated readable task ids (`<platform>-<slug>-NNN`, stop-word filtered).
- Cross-platform feature grouping metadata (`--feature` / `--parent`).
- `doctor` self-check, `platform list` / `agent list` inventories, `--json`
  output on every command, `task diff` (base / working / staged).
- End-to-end test suite (455 lines) running entirely in throwaway temp repos.

[1.1.0]: https://github.com/maohhgg/agentctl/releases/tag/v1.1.0
