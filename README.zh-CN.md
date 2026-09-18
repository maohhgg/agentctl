# agentctl

**一条任务一个 git worktree——范围强制、门禁把关、零依赖、单文件。**

[![CI](https://github.com/maohhgg/agentctl/actions/workflows/ci.yml/badge.svg)](https://github.com/maohhgg/agentctl/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/maohhgg/agentctl)](https://github.com/maohhgg/agentctl/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Node](https://img.shields.io/badge/node-%E2%89%A520-brightgreen)](package.json)

[English](README.md)

多个 AI coding agent（Claude Code / Codex / OpenCode / OMP / …）共用同一个
checkout 时会互相覆盖文件、互相污染 git 状态——分支隔离解决不了工作区共享的
问题。**agentctl** 给每条任务一个独立 worktree + 任务分支，用 `allowed_paths`
限制 agent 可改动的路径范围，集成前过范围检查与测试门禁，让多 agent 真正并行。

它是一个 headless、agent-native 的工具：不依赖 tmux、Docker、常驻进程和 UI，
一个 Node 脚本零第三方依赖；并且让 **agent 自己** 充当 Coordinator / Worker——
只需读仓库内的文件即可自组织。

## 工作方式——两级 worktree 模型

```
主 checkout（枢纽：文档 / 契约 / 协调）
 │
 └── 平台 worktree   wt/backend @ feature/backend      ← integration 边界
      │                 只做 merge / test / review / release，agent 不在此开发
      │
      ├── 任务 worktree  ../my-repo-agent-worktrees/backend/backend-google-oauth-001
      │                  @ agent/codex/backend-google-oauth-001   ← 一个 agent
      │
      └── 任务 worktree  ../my-repo-agent-worktrees/backend/backend-payment-002
                         @ agent/omp/backend-payment-002          ← 另一个 agent
```

- **平台 worktree**（长期存在，每个交付目标一个：backend / web / 移动端…）：
  在 `.agents/config/platforms.json` 声明，或由 `git worktree list` 自动探测；
  是唯一的集成边界。
- **任务 worktree**（一条任务一个）：一条任务分支 + 一个独立 checkout +
  一个 agent。由 agentctl 创建与回收；任务上下文 `.agents/TASK.md` 写在其中，
  经 `.git/info/exclude` 排除、不进业务提交。

物理隔离解决覆盖问题；逻辑冲突留给 Git 在集成阶段暴露。agentctl 刻意
**不做文件锁**。

## 特性

- **零依赖单文件**：只要 Node ≥ 20 + git。拷一个可执行文件进仓库（或
  `npm i -g`）即可工作。
- **Agent 自治协议**：`agentctl task current` 判定当前是 Coordinator 还是
  Worker；Worker 读 `.agents/TASK.md` 获取任务简报。往 `AGENTS.md` 里贴一段
  协议，任何 agent 都能自组织（见下文）。
- **范围写集合强制**：`--allowed-paths` glob 定义任务可触达的路径。
  `task check` / `task finish` 对越界文件失败——未跟踪、未暂存、已暂存、
  已提交的改动全部检查。
- **finish 五项门禁**：worktree 与分支正确、无未提交改动、改动在范围内、
  至少一个 commit、测试通过。拒绝时不动你的任何文件。
- **只读合并预检**：`task merge-check` 用 `git merge-tree --write-tree`
  干跑合并（旧版 git 自动回退临时 worktree），报 `CLEAN` / `CONFLICT`，
  不移动任何分支、不碰平台 worktree。
- **冲突续做**：`task integrate` 冲突时**保留进行中的 merge**、状态置
  `conflict`、打印待解决文件；解决后重跑同一条命令即收尾提交。不回退、
  不丢弃任何内容。
- **基点刷新**：`task update-base` 把平台分支的新提交合并进长周期任务分支
  并刷新基点（同样的冲突续做语义）；ready 任务基点变更后状态退回 active，
  门禁重跑。
- **并发安全注册表**：任务记录在 mkdir 互斥锁内以「临时文件 + 原子 rename」
  读写；两个 agent 同时 `task create` 不会撞名、不会互相覆盖。记录丢失时
  可从任务 worktree 的 `.agents/TASK.md` 重建（`task adopt`）。
- **多平台注册表**：monorepo / 多端仓库可声明多个平台 worktree（别名 +
  各自的测试命令）；未声明的 worktree 自动探测。
- **Runner 不猜参数**：只为真实安装实测过的 CLI（`omp`、`opencode`）内置
  启动模板；其余在项目 `agents.json` 里声明，或降级为打印手工启动命令。
- **Agent 自识别**：`task create` 的 `--agent` 可省略——缺省时从
  `AGENTCTL_AGENT` 环境变量或进程祖先链解析执行者（`zcode`、`omp`、
  `commandcode`、`qoder` 等；`agentctl whoami` 查看识别结果）。Coordinator
  不再可能填错执行者。
- **可读 task id**：平台 `backend` + 标题 `Implement Google OAuth` →
  `backend-google-oauth-001`（去动词停用词，撞名自动递增）。

## 安装

```bash
# npm（包名 agent-task-worktree，二进制名 agentctl）
npm install -g agent-task-worktree

# 或：一行安装脚本
curl -fsSL https://raw.githubusercontent.com/maohhgg/agentctl/main/install.sh | sh

# 或：干脆不装——它就是一个文件，拷进仓库提交即可
curl -fsSL https://raw.githubusercontent.com/maohhgg/agentctl/main/agentctl -o agentctl && chmod +x agentctl
```

要求：**Node ≥ 20**、**git ≥ 2.31**（建议 ≥ 2.38，可走 `merge-tree` 快速
预检；旧版自动回退）。支持 Linux / macOS / **Windows 原生**（测试命令经
PowerShell 执行；测试套件自身在 Git Bash 下运行）。

## 快速上手

```bash
cd my-repo
agentctl init                          # 一次性初始化：登记探测平台 + 补 .gitignore 排除
agentctl doctor                        # 环境自检

# 建任务：codex worker，只许改 src/auth/**
# （--agent 可省略——agentctl 会自识别当前 CLI；这里显式给出是因为命令是复制到普通终端执行的）
agentctl task create --platform backend --agent codex \
  --title "Implement Google OAuth" \
  --requirements "login endpoint;callback;token refresh;tests" \
  --allowed-paths 'src/auth/**,tests/auth/**'

# 交给 agent——让 agentctl 直接启动：
agentctl task start backend-google-oauth-001
# …或自己进任务 worktree 手工启动：
cd ../my-repo-agent-worktrees/backend/backend-google-oauth-001 && codex

# worker 完成后（在仓库内任意目录执行）：
agentctl task check backend-google-oauth-001        # 范围审计
agentctl task update-base backend-google-oauth-001  # 可选：先把平台分支新提交并进任务
agentctl task merge-check backend-google-oauth-001  # 只读合并预检
agentctl task integrate backend-google-oauth-001    # --no-ff 并入平台分支
agentctl task remove backend-google-oauth-001       # 评审后回收 worktree 与分支
```

同平台已有未结束任务占用重叠 scope 时，`task create` 会拒绝并指出冲突任务；
确需并行时显式加 `--allow-overlap`。

## Coordinator / Worker 协议

往仓库的 `AGENTS.md`（或同等入口文档）里贴入并按需调整：

```markdown
## 多 agent 任务协议（agentctl）

用 `agentctl task current` 判定角色：
- 当前 worktree 里存在 `.agents/TASK.md` → 你是 **Worker**。
- 否则 → 你是 **Coordinator**。

### Coordinator（仓库根 / 平台 worktree）
1. `agentctl platform list` 与 `agentctl task list --json`——定平台、
   查在途任务与 scope 重叠。
2. `agentctl task create --platform <p> --agent <cli> --title '…' \
      --requirements 'a;b;c' --allowed-paths '<globs>'`
   （`--agent` 可省略——agentctl 会自识别当前 CLI；在 agent 会话内直接省略即可。）
3. `agentctl task start <id>` 启动 worker（或按打印的目录手工启动 agent CLI）。
4. 平台分支期间前进了：`agentctl task update-base <id>`。
5. 评审后：`agentctl task merge-check <id>` → `agentctl task integrate <id>`
   → `agentctl task remove <id>`。
   Coordinator 不直接改业务代码；不把任务并进 main——平台 worktree 才是
   integration 边界。

### Worker（任务 worktree）
1. 读 `.agents/TASK.md`——Objective / Requirements / Scope / Restrictions。
2. 只在 Scope 内实现；提交到任务分支。
3. `agentctl task check <id>`（无越界文件），然后
   `agentctl task finish <id>`（门禁：干净、范围内、≥1 commit、测试过）。
4. 不自行并入平台分支；不使用 `git reset --hard` / `git clean` /
   `git checkout -- .` / `git stash`。
```

`task current` 依据「worktree + `.agents/TASK.md`」判定模式，与目录名无关，
人和 agent 用同一套指令。

## 命令速查

```
agentctl [-C <目录>] [--json] <命令> [参数]
```

| 命令 | 说明 |
|---|---|
| `init` | 一次性初始化：按探测平台生成 `platforms.json`、补 `.gitignore` 排除（幂等，绝不覆盖） |
| `whoami` | 查看当前会话的 agent 自识别结果 |
| `doctor` | 自检：git / 仓库 / worktree / 注册表 / agent CLI / 当前模式 |
| `agent list` | Agent runner 与本机检测结果 |
| `platform list` | 平台注册表（探测 + 声明）、状态与别名 |
| `task current` | 当前目录是 Coordinator 还是 Worker 模式 |
| `task create` | 新任务：分支 + worktree + `.agents/TASK.md` + 注册表记录 |
| `task list` | 按 `--platform / --agent / --status / --feature` 过滤 |
| `task show <id>` | 完整元数据 + 实时状态（脏 / 领先 / 已并入） |
| `task start <id>` | 在任务 worktree 内启动 agent CLI |
| `task check <id>` | 范围审计——越界退出码 1 |
| `task diff <id>` | 相对 base 的差异（`--stat` / `--name-only` / `--working`） |
| `task finish <id>` | 五项门禁 → 状态 `ready`；`--no-test` / `--test-command` / `--timeout` |
| `task update-base <id>` | 把平台分支新提交合并进任务分支并刷新基点（冲突安全，`--dry-run`） |
| `task adopt` | 从当前 worktree 的 `.agents/TASK.md` 重建丢失的注册表记录 |
| `task set-status <id> <状态>` | 标记 `blocked` / `failed` / `cancelled` 等 |
| `task merge-check <id>` | 只读合并预检；冲突退出码 1 |
| `task integrate <id>` | `--no-ff` 并入平台分支；冲突可续做 |
| `task remove <id>` | 回收 worktree + 分支 + 记录（仅 merged + 干净） |

所有命令支持全局 `--json` 输出机器可读结果。

### 任务状态机

```
created ──► active ──finish（5 门禁）──► ready ──integrate──► integrating ──► merged ──remove──► （记录删除）
                                        ▲                        │
                                        │                        └─ 冲突 ──解决后续做 integrate──► merged
                         set-status ──► blocked / failed / cancelled
```

未结束状态（`created` … `integrating`）参与 scope 重叠判定。

## 配置

**`.agents/config/platforms.json`**（随仓库提交；`agentctl init` 可按探测平台自动生成）：

```jsonc
{
  "worktree_root": "../my-repo-agent-worktrees",  // 缺省 ../<仓库名>-agent-worktrees
  "branch_prefix": "agent",                        // 缺省 agent
  "platforms": {
    "backend": {
      "worktree": "wt/backend",        // 必填：平台 worktree 路径（相对仓库根）
      "branch": "feature/backend",     // 必填：其集成分支
      "aliases": ["api"],              // 可选：--platform 接受的别名
      "test_command": "composer test", // task finish 的默认测试门禁
      "test_timeout": 300              // 可选：测试挂起 N 秒后强杀
    }
  }
}
```

**`.agents/config/agents.json`**（可选——为没有实测内置模板的 CLI 声明启动
模板；`{worktree}` 与 `{prompt}` 会被替换）：

```json
{
  "claude": { "command": "claude", "args": ["-p", "{prompt}"] },
  "codex":  { "command": "codex",  "args": ["exec", "--cd", "{worktree}", "{prompt}"] }
}
```

内置模板只收录本机实测过参数的 CLI（`omp` 18.2.5、`opencode`）。其他
agent CLI 请按上面声明——或者不声明，`task start` 会打印手工启动命令。
此处声明的键名同时加入 `--agent` 自识别的已知名字集。

任务记录在 `.agents/tasks/<id>.json`、运行时产物在 `.agents/state/`——都是
运行时状态。`agentctl init` 会自动补 `.gitignore` 排除项，`doctor` 负责检查。

## 与同类工具的对比

| | agentctl | Claude Squad | Vibe Kanban | Conductor |
|---|---|---|---|---|
| 形态 | headless 单文件 CLI | TUI（Go + tmux） | 本地 Web 看板（Rust） | macOS App |
| 依赖 | 仅 Node + git | tmux | server + 浏览器 | 闭源 |
| 每任务独立 worktree | ✓ | ✓ | ✓ | ✓ |
| 范围写集合强制（allowed_paths） | ✓ | — | — | — |
| finish 门禁（范围 + 测试） | ✓ | — | — | — |
| 只读合并预检 | ✓ | — | — | — |
| 冲突续做状态机 | ✓ | — | — | — |
| Agent 自组织协议（AGENTS.md） | ✓ | — | — | — |
| 面向人的 UI | — | TUI | 看板 | 原生 |
| 支持任意 agent CLI | ✓ | ✓ | ✓ | Claude Code / Codex |

这个赛道迭代很快，表格只作定位快照、不作评测。agentctl 刻意做家族里
**headless、重强制** 的那一个——与评审 UI、CI 是组合关系而非替代关系。
CLI 文案目前为中文，英文输出在路线图中。

## 安全

agentctl 会执行仓库内定义的测试与 runner 命令——请把仓库写权限当作代码执行
信任级别看待，与 CI 相同。详见 [SECURITY.md](SECURITY.md)。

## 开发

```bash
bash tests/agent/agentctl-test.sh   # 21 个章节，端到端，只跑临时仓库
npm test                            # 同上
```

覆盖：doctor、平台探测与声明、任务创建（显式 / 自动 id）、TASK.md 排除、
范围检查、scope 重叠拦截、finish 全部门禁、merge-check（干净 + 冲突）、
integrate（含冲突续做）、状态机、Runner 启动与降级、并发创建、回收规则。
首次提交 PR 前请读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 路线图

- [ ] CLI 文案英文化 / i18n
- [ ] 为更多 agent CLI 补（实测过的）内置 runner 模板——欢迎 PR，但按
      [CONTRIBUTING](CONTRIBUTING.md) 约定，参数必须真实安装验证过
- [ ] 基于现有 `--json` 输出的可选 TUI
- [ ] GitHub PR 创建作为 integrate 的替代目标

## 许可证

[MIT](LICENSE) © 2026 maohhgg
