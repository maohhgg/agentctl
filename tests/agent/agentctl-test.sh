#!/usr/bin/env bash
#
# agentctl 端到端测试（monorepo 单主线模型）
#
# 覆盖：doctor 自检、平台目录声明（paths / 别名 / 缺失目录 / 歧义）、任务创建（显式 / 自动 task id
# + <type>/<平台>-<slug> 任务分支 + 独立 worktree，含 --type 白名单校验）、TASK.md 任务上下文（含不进业务提交）、
# allowed_paths 范围检查、scope 重叠检测、finish 门禁（相关检查收窄 {filter} / {files} 与超时）
# 与 Worker 完成摘要、merge-check（只读）、integrate（在主 checkout 内并入 main，含冲突续做）、
# update-base（基点推进与冲突续做）、adopt（注册表重建）、手工合并放行回收、回收规则、
# init（.gitignore 排除项 / 幂等 / 不代写平台配置）、agent 自识别（whoami / env / flag 优先级）、
# 平台目录内建任务告警、AgentRunner（自动启动与降级），以及四个并发场景：
#   Case 1 两个 agent 同时创建任务　Case 2 两个任务改同一文件互不覆盖
#   Case 3 merge-check 发现 Git conflict　Case 4 scope 重叠被拦截
#
# 全程在 mktemp 临时仓库中进行，不触碰被测仓库本身。
# 运行：bash tests/agent/agentctl-test.sh

set -euo pipefail

AGENTCTL="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/agentctl"
[[ -x "$AGENTCTL" ]] || { printf 'agentctl 不存在或不可执行：%s\n' "$AGENTCTL" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agentctl-test.XXXXXX")"
# macOS：TMPDIR 位于 /var → /private/var 符号链接；CLI 与 git 均按 realpath 物理路径输出，
# 夹具路径必须对齐，否则 doctor / platform list 的路径断言在 macOS 上失败
WORK="$(cd "$WORK" && pwd -P)"
# Git Bash（Windows）：node.exe 是原生程序，报告 C:/... 物理路径而非 MSYS 虚拟路径 /tmp/...，
# 需用 cygpath 转换（-m = 正斜杠的 Windows 路径）；Linux/macOS 无 cygpath，此步为空操作
if command -v cygpath >/dev/null 2>&1; then
  WORK="$(cygpath -m "$WORK")"
fi
REPO="$WORK/project"
WTROOT="$WORK/project-agent-worktrees" # 默认：../<repo basename>-agent-worktrees
OUT=""
ERR=""
RC=0
PASS=0
FAILED=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

g() { git -C "$REPO" "$@"; }
gw() { git -C "$1" "${@:2}"; }

pass() {
  PASS=$((PASS + 1))
  printf 'ok   %s\n' "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf 'FAIL %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '     %s\n' "$2"
  return 0
}

run() {
  set +e
  OUT="$("$AGENTCTL" "$@" 2>"$WORK/.stderr")"
  RC=$?
  set -e
  ERR="$(cat "$WORK/.stderr")"
}

assert_rc() { if [[ "$RC" == "$2" ]]; then pass "$1"; else fail "$1" "退出码 期望=$2 实际=$RC｜stderr: $ERR"; fi; }
assert_rc_nonzero() { if [[ "$RC" != 0 ]]; then pass "$1"; else fail "$1" '退出码应为非 0'; fi; }
assert_out_contains() { if [[ "$OUT" == *"$2"* ]]; then pass "$1"; else fail "$1" "stdout 未包含：$2"; fi; }
assert_err_contains() { if [[ "$ERR" == *"$2"* ]]; then pass "$1"; else fail "$1" "stderr 未包含：$2"; fi; }

assert_file_content() {
  local d="$1" f="$2" e="$3"
  if [[ ! -f "$f" ]]; then fail "$d" "文件不存在：$f"; return 0; fi
  local a
  a="$(cat "$f")"
  if [[ "$a" == "$e" ]]; then pass "$d"; else fail "$d" "期望：$e｜实际：$a"; fi
}

assert_file_contains() {
  local d="$1" f="$2" e="$3"
  if [[ ! -f "$f" ]]; then fail "$d" "文件不存在：$f"; return 0; fi
  if grep -qF -- "$e" "$f"; then pass "$d"; else fail "$d" "$f 未包含：$e"; fi
}

assert_exists() { if [[ -e "$2" ]]; then pass "$1"; else fail "$1" "不存在：$2"; fi; }
assert_absent() { if [[ ! -e "$2" ]]; then pass "$1"; else fail "$1" "仍存在：$2"; fi; }

json_get() {
  node -e '
    const fs = require("node:fs");
    const v = process.argv[2].split(".").reduce((o, k) => (o == null ? o : o[k]), JSON.parse(fs.readFileSync(process.argv[1], "utf8")));
    process.stdout.write(v == null ? "" : String(v));
  ' "$1" "$2"
}

section() { printf '\n== %s ==\n' "$1"; }

# ============================ 夹具 ============================
# monorepo 单主线：只有一棵工作树 + 一条 main；没有平台分支，也没有平台 worktree。
# 平台 = 一段目录范围（apps/*），在 .agents/config/platforms.json 中以 paths 人工声明。

setup_fixture() {
  mkdir -p "$REPO"
  cd "$REPO"
  git init -q -b main
  git config user.name 'agentctl test'
  git config user.email 'agentctl@test.local'
  git config commit.gpgsign false
  git config rerere.enabled false
  mkdir -p apps/api/src/shared apps/api/src/auth apps/api/src/other apps/api/tests \
           apps/frontend/src/auth apps/frontend/src/web-auth tests
  printf 'export const config = "base";\n' >apps/api/src/shared/config.ts
  printf 'export const index = "base";\n' >apps/api/src/index.ts
  printf 'export const login = "base";\n' >apps/api/src/auth/login.ts
  printf 'export const other = "base";\n' >apps/api/src/other/thing.ts
  printf 'placeholder\n' >apps/api/tests/placeholder.txt
  printf 'export const webAuth = "base";\n' >apps/frontend/src/auth/web-auth.ts
  printf 'export const webAuthAlt = "base";\n' >apps/frontend/src/web-auth/web-auth.ts
  printf 'placeholder\n' >tests/placeholder.txt
  printf '# project\n' >README.md
  printf '# runtime\n/.agents/tasks/\n/.agents/state/\n' >.gitignore
  mkdir -p .agents/config
  cat >.agents/config/platforms.json <<'JSON'
{
  "main_branch": "main",
  "platforms": {
    "api": { "paths": ["apps/api"], "aliases": ["backend"] },
    "frontend": { "paths": ["apps/frontend"], "aliases": ["web"] }
  }
}
JSON
  git add -A
  git commit -qm 'init'
}

setup_fixture

section '1. doctor 自检'
run doctor
assert_rc 'doctor 退出码 0' 0
assert_out_contains 'doctor 报告 Git' 'Git: OK'
assert_out_contains 'doctor 报告平台目录' 'Platforms:'
assert_out_contains 'doctor 检查项名为 Platform paths' 'Platform paths: OK'
assert_out_contains 'doctor 报告 agent 检测' 'Agents:'
assert_out_contains 'doctor 报告任务 worktree 根' "$WTROOT"
run --json doctor
assert_rc 'doctor --json 退出码 0' 0
assert_out_contains 'doctor JSON 含 root' "\"root\": \"$REPO\""
run doctor --json
assert_rc '全局 --json 放在子命令之后同样生效' 0
assert_out_contains '后置 --json 输出 JSON' "\"worktree_root\""
run task list --json
assert_rc 'task list --json' 0
run agent list
assert_rc 'agent list 退出码 0' 0

section '2. platform list（平台 = 目录范围）'
run platform list
assert_rc 'platform list 退出码 0' 0
assert_out_contains '列出 platform api' 'api'
assert_out_contains '列出 platform frontend' 'frontend'
assert_out_contains '标注平台目录' 'apps/api'
assert_out_contains '集成分支统一是 main' 'main'
run --json platform list
assert_out_contains 'JSON 输出含 hub_branch' '"hub_branch": "main"'
assert_out_contains 'JSON 输出含 worktree_root（同级目录）' "\"worktree_root\": \"$WTROOT\""

if "$AGENTCTL" platform list 2>"$WORK/.pipe-err" | head -2 >/dev/null; then
  pass '输出被管道截断（| head）时正常结束'
else
  fail '输出被管道截断（| head）时正常结束'
fi
[[ -s "$WORK/.pipe-err" ]] && fail '管道截断不产生 stderr 噪音' "$(cat "$WORK/.pipe-err")" || pass '管道截断不产生 stderr 噪音'

section '3. task create：显式 task id + 独立 worktree + TASK.md'
run task create --platform backend --agent codex --task task-a --title 'Task A' \
  --objective '为 backend 增加 A 功能' --requirements '实现登录;补充测试' --allowed-paths 'apps/api/src/shared/**'
assert_rc '创建 task-a' 0
assert_out_contains '输出 Task created.' 'Task created.'
assert_out_contains '输出任务分支 <type>/<平台>-<slug>' 'feat/api-task-a'
assert_out_contains '输出 TASK.md 路径' 'TASK.md'
assert_exists 'task-a worktree 建在仓库同级目录' "$WTROOT/api/task-a"
assert_absent 'worktree 未落在仓库内' "$REPO/.agents-worktrees"
assert_exists 'task-a 元数据已写入' "$REPO/.agents/tasks/task-a.json"
assert_exists 'task-a 分支已创建' "$REPO/.git/refs/heads/feat/api-task-a"
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" platform)" == api ]] && pass '元数据 platform=api' || fail '元数据 platform=api'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" status)" == active ]] && pass '元数据 status=active' || fail '元数据 status=active'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" allowed_paths.0)" == 'apps/api/src/shared/**' ]] && pass '元数据 allowed_paths 落盘' || fail '元数据 allowed_paths 落盘'
[[ -n "$(json_get "$REPO/.agents/tasks/task-a.json" uuid)" ]] && pass '元数据含 UUID' || fail '元数据含 UUID'
[[ -n "$(json_get "$REPO/.agents/tasks/task-a.json" objective)" ]] && pass '元数据含 objective' || fail '元数据含 objective'

assert_file_contains 'TASK.md 含 Task ID' "$WTROOT/api/task-a/.agents/TASK.md" 'Task ID: task-a'
assert_file_contains 'TASK.md 含 Platform' "$WTROOT/api/task-a/.agents/TASK.md" 'Platform: api'
assert_file_contains 'TASK.md 含 Objective' "$WTROOT/api/task-a/.agents/TASK.md" '为 backend 增加 A 功能'
assert_file_contains 'TASK.md 含 Requirements' "$WTROOT/api/task-a/.agents/TASK.md" '- 补充测试'
assert_file_contains 'TASK.md 含 Scope' "$WTROOT/api/task-a/.agents/TASK.md" 'apps/api/src/shared/**'
assert_file_contains 'TASK.md 含 Restrictions' "$WTROOT/api/task-a/.agents/TASK.md" '## Restrictions'
assert_file_contains 'TASK.md 含 Completion Criteria' "$WTROOT/api/task-a/.agents/TASK.md" '## Completion Criteria'
assert_file_contains 'TASK.md 提示不要自行并入主干' "$WTROOT/api/task-a/.agents/TASK.md" '不要自行把任务分支并入 main'

[[ "$(gw "$WTROOT/api/task-a" status --porcelain)" == "" ]] && pass 'TASK.md 不污染任务 worktree 的 git status' || fail 'TASK.md 不污染任务 worktree 的 git status'
gw "$WTROOT/api/task-a" check-ignore -q .agents/TASK.md && pass 'TASK.md 已被 info/exclude 排除' || fail 'TASK.md 已被 info/exclude 排除'
g check-ignore -q .agents/tasks 2>/dev/null && pass '任务注册表已被仓库 .gitignore 排除' || fail '任务注册表已被仓库 .gitignore 排除'

section '4. task create：自动 task id'
run task create --platform web --agent omp --title 'Implement Google OAuth' --allowed-paths 'apps/frontend/src/auth/**'
assert_rc '未指定 --task 时自动生成 id' 0
[[ -n "$(json_get "$REPO/.agents/tasks/frontend-google-oauth-001.json" id)" ]] &&
  pass 'task id = <platform>-<slug>-001（去掉 Implement 等动词）' || fail 'task id = <platform>-<slug>-001'
assert_exists '自动 id 的 worktree 已创建' "$WTROOT/frontend/frontend-google-oauth-001"
run task create --platform web --agent omp --title 'Implement Google OAuth' --allowed-paths 'apps/frontend/src/web-auth/**'
assert_rc '同名标题再次创建（不同 scope）' 0
assert_exists '重名自动递增到 -002' "$WTROOT/frontend/frontend-google-oauth-002"
run task remove frontend-google-oauth-002 --force
assert_rc '清理 -002' 0

section '5. task current / task list / task show（Coordinator vs Worker）'
run task current
assert_out_contains '仓库根为 Coordinator 模式' 'Mode: coordinator'
run -C "$WTROOT/api/task-a" task current
assert_out_contains '任务 worktree 内为 Worker 模式' 'Mode: worker'
assert_out_contains 'Worker 模式显示任务 id' 'task-a'
run task list
assert_out_contains 'task list 列出 task-a' 'task-a'
assert_out_contains 'task list 列出 codex' 'codex'
run task show task-a
assert_rc 'task show 退出码 0' 0
assert_out_contains 'task show 显示平台目录与主干' 'apps/api @ main'
assert_out_contains 'task show 显示任务上下文' 'task context:  yes'
assert_out_contains '尚无提交的任务不误报已并入' 'merged:        no'

section '6. Case 2：两个 agent 改同一个文件，物理隔离'
run task create --platform backend --agent claude --task task-b --title 'Task B' --allowed-paths 'apps/api/src/shared/**' --allow-overlap
assert_rc '创建 task-b（另一 agent，与 task-a 同文件 → 显式确认重叠）' 0
printf 'export const config = "from-task-a";\n' >"$WTROOT/api/task-a/apps/api/src/shared/config.ts"
printf 'export const config = "from-task-b";\n' >"$WTROOT/api/task-b/apps/api/src/shared/config.ts"
assert_file_content 'task-a 工作区是自己的内容' "$WTROOT/api/task-a/apps/api/src/shared/config.ts" 'export const config = "from-task-a";'
assert_file_content 'task-b 工作区是自己的内容' "$WTROOT/api/task-b/apps/api/src/shared/config.ts" 'export const config = "from-task-b";'
assert_file_content '主 checkout 未被任务覆盖' "$REPO/apps/api/src/shared/config.ts" 'export const config = "base";'
gw "$WTROOT/api/task-a" add apps/api/src/shared/config.ts
gw "$WTROOT/api/task-a" commit -qm 'feat(a): config from task-a'
gw "$WTROOT/api/task-b" add apps/api/src/shared/config.ts
gw "$WTROOT/api/task-b" commit -qm 'feat(b): config from task-b'
[[ "$(g rev-list --count main..feat/api-task-a)" == 1 ]] && pass 'task-a 独立提交 1 个 commit' || fail 'task-a 独立提交 1 个 commit'
[[ "$(g rev-list --count main..feat/api-task-b)" == 1 ]] && pass 'task-b 独立提交 1 个 commit' || fail 'task-b 独立提交 1 个 commit'
[[ "$(g rev-list --count main)" == 1 ]] && pass '主干未被 agent 直接提交' || fail '主干未被 agent 直接提交'
[[ "$(gw "$WTROOT/api/task-a" show --name-only --oneline HEAD | grep -c 'TASK.md')" == 0 ]] &&
  pass '业务提交内不含 TASK.md' || fail '业务提交内不含 TASK.md'

section '7. task check：allowed_paths 范围'
run task check task-a
assert_rc '范围内改动 → 退出码 0' 0
assert_out_contains '输出 Result: OK' 'Result: OK'
printf 'export const stray = 1;\n' >"$WTROOT/api/task-a/apps/api/src/config.ts"
run task check task-a
assert_rc_nonzero '越界未跟踪文件 → 退出码非 0'
assert_err_contains '报错标明 Unexpected files' 'Unexpected files:'
assert_err_contains '报错列出越界文件' 'apps/api/src/config.ts'
assert_err_contains '报错列出 allowed scope' 'apps/api/src/shared/**'
rm -f "$WTROOT/api/task-a/apps/api/src/config.ts"
printf 'export const helper = 1;\n' >"$WTROOT/api/task-a/apps/api/src/shared/helper.ts"
run task check task-a
assert_rc '范围内新增文件 → 退出码 0' 0
rm -f "$WTROOT/api/task-a/apps/api/src/shared/helper.ts"

section '8. Case 4：scope 重叠检测'
run task create --platform backend --agent codex --task task-x --allowed-paths 'apps/api/src/auth/**'
assert_rc '建立 scope=apps/api/src/auth/** 的任务' 0
run task create --platform backend --agent omp --task task-y --allowed-paths 'apps/api/src/auth/login.ts'
assert_rc_nonzero 'scope 重叠 → 拒绝创建'
assert_err_contains '报错说明已有任务占用重叠 scope' '已有未结束任务占用重叠 scope'
assert_err_contains '报错列出冲突任务' 'task-x'
assert_absent '被拒绝后不留下 worktree' "$WTROOT/api/task-y"
assert_absent '被拒绝后不留下任务记录' "$REPO/.agents/tasks/task-y.json"
run task create --platform backend --agent omp --task task-y --allowed-paths 'apps/api/src/auth/login.ts' --allow-overlap
assert_rc '--allow-overlap 显式确认后可创建' 0
assert_err_contains '--allow-overlap 打印重叠警告' 'scope 与 task-x'
run task create --platform backend --agent omp --task task-z --allowed-paths 'apps/api/src/other/thing.ts'
assert_rc 'scope 不重叠 → 正常创建' 0
run task create --platform backend --agent omp --task task-w --title '无 scope 任务'
assert_rc '未指定 scope 可创建' 0
assert_err_contains '无 scope 时提示无法判定重叠' '无法判定'

section '9. task finish 门禁与 Worker 摘要'
printf 'export const config = "a-uncommitted";\n' >"$WTROOT/api/task-a/apps/api/src/shared/config.ts"
run task finish task-a --test-command true
assert_rc_nonzero '有未提交改动 → finish 拒绝'
assert_err_contains '拒绝原因含未提交改动' '未提交改动'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" status)" == active ]] && pass 'finish 失败不改状态' || fail 'finish 失败不改状态'
assert_file_content 'finish 失败不丢弃改动' "$WTROOT/api/task-a/apps/api/src/shared/config.ts" 'export const config = "a-uncommitted";'
gw "$WTROOT/api/task-a" add apps/api/src/shared/config.ts
gw "$WTROOT/api/task-a" commit -qm 'feat(a): follow-up'
run task finish task-a --test-command false
assert_rc_nonzero '相关检查失败 → finish 拒绝'
assert_err_contains '拒绝原因含相关检查未通过' '相关检查未通过'
run task finish task-a --test-command true
assert_rc '相关检查通过 + 干净 + 范围内 → finish 通过' 0
assert_out_contains 'finish 输出 Worker 完成摘要' 'Task completed.'
assert_out_contains '摘要含 Changed files' 'Changed files:'
assert_out_contains '摘要含 Tests' 'Tests:'
assert_out_contains '摘要含 Commit' 'Commit:'
assert_out_contains '摘要含 ready for integration' 'ready for integration'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" status)" == ready ]] && pass 'finish 后状态 ready' || fail 'finish 后状态 ready'

section '10. task set-status（状态机）'
run task set-status task-z blocked --note '等待上游接口'
assert_rc 'set-status blocked' 0
[[ "$(json_get "$REPO/.agents/tasks/task-z.json" status)" == blocked ]] && pass '状态已落盘 blocked' || fail '状态已落盘 blocked'
run task set-status task-z not-a-status
assert_rc_nonzero '非法状态被拒绝'
run task set-status task-z active
assert_rc 'set-status active' 0

section '11. merge-check 与 integrate（无冲突路径，合并在主 checkout 内并入 main）'
run task merge-check task-a
assert_rc 'merge-check 干净可合并' 0
assert_out_contains 'merge-check 判定 CLEAN' 'CLEAN'
run task integrate task-a
assert_rc 'integrate task-a' 0
assert_file_content '主干已含 task-a 内容' "$REPO/apps/api/src/shared/config.ts" 'export const config = "a-uncommitted";'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" status)" == merged ]] && pass 'integrate 后状态 merged' || fail 'integrate 后状态 merged'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" merged_into)" == main ]] && pass '记录 merged_into=main' || fail '记录 merged_into=main'
[[ "$(g log --merges --oneline main | wc -l | tr -d ' ')" != 0 ]] && pass '主干出现 merge commit' || fail '主干出现 merge commit'
[[ "$(g rev-parse --abbrev-ref HEAD)" == main ]] && pass '主 checkout 停在 main' || fail '主 checkout 停在 main'
g log -1 --format=%B main | grep -q '^chore(merge): 合并 api · Task A$' && pass '合并提交主题行 = chore(merge): 合并 <平台> · <任务标题>' || fail '合并提交主题行 = chore(merge): 合并 <平台> · <任务标题>' "subject=$(g log -1 --format=%s main)"
g log -1 --format=%B main | grep -q '^Task: task-a（agent codex）$' && pass '合并提交正文记 Task id 与 agent' || fail '合并提交正文记 Task id 与 agent'
g log -1 --format=%B main | grep -q 'feat(a): config from task-a' && pass '合并提交正文列带入的提交' || fail '合并提交正文列带入的提交'

section '12. Case 3：merge-check 发现冲突且不污染主 checkout'
HEAD_BEFORE="$(g rev-parse main)"
STATUS_BEFORE="$(g status --porcelain)"
run task merge-check task-b
assert_rc_nonzero '冲突 → merge-check 退出码非 0'
assert_out_contains '冲突文件被列出' 'apps/api/src/shared/config.ts'
assert_out_contains '判定 CONFLICT' 'CONFLICT'
[[ "$(g rev-parse main)" == "$HEAD_BEFORE" ]] && pass 'merge-check 未移动 main' || fail 'merge-check 未移动 main'
[[ "$(g status --porcelain)" == "$STATUS_BEFORE" ]] && pass 'merge-check 未污染主 checkout' || fail 'merge-check 未污染主 checkout'
assert_absent 'merge-check 未残留临时 worktree' "$REPO/.agents/state/tmp"

section '13. integrate 冲突：状态 conflict，解决后续做 → merged'
run task finish task-b --test-command true
assert_rc 'task-b finish 通过' 0
run task integrate task-b
assert_rc_nonzero '冲突时 integrate 退出码非 0'
assert_out_contains '冲突文件已列出' 'apps/api/src/shared/config.ts'
g -C "$REPO" rev-parse -q --verify MERGE_HEAD >/dev/null && pass '冲突保留进行中的 merge（主 checkout）' || fail '冲突保留进行中的 merge（主 checkout）'
[[ "$(json_get "$REPO/.agents/tasks/task-b.json" status)" == conflict ]] && pass '冲突时状态置 conflict' || fail '冲突时状态置 conflict'
run task integrate task-b
assert_rc_nonzero '冲突未解决时重跑 integrate 仍失败'
printf 'export const config = "merged-a-and-b";\n' >"$REPO/apps/api/src/shared/config.ts"
g -C "$REPO" add apps/api/src/shared/config.ts
run task integrate task-b
assert_rc '解决冲突后续做 integrate 成功' 0
assert_file_content '合并结果进入主干' "$REPO/apps/api/src/shared/config.ts" 'export const config = "merged-a-and-b";'
[[ -z "$(g -C "$REPO" rev-parse -q --verify MERGE_HEAD)" ]] && pass '收尾后 merge 已结束' || fail '收尾后 merge 已结束'
[[ "$(json_get "$REPO/.agents/tasks/task-b.json" status)" == merged ]] && pass 'task-b 状态 merged' || fail 'task-b 状态 merged'
[[ -z "$(g status --porcelain)" ]] && pass '主 checkout 收尾干净' || fail '主 checkout 收尾干净'

section '14. 主 checkout 有未提交改动时拒绝 integrate'
printf 'export const index = "task-z";\n' >"$WTROOT/api/task-z/apps/api/src/index.ts"
gw "$WTROOT/api/task-z" add apps/api/src/index.ts
gw "$WTROOT/api/task-z" commit -qm 'feat(z): index'
run task finish task-z --no-test
assert_rc_nonzero 'task-z 越界改动 → finish 拒绝（allowed_paths=apps/api/src/other/**）'
run task set-status task-z ready
printf 'dirty\n' >>"$REPO/apps/api/src/index.ts"
run task merge-check task-z
assert_rc '主 checkout 脏时 merge-check 仍可用' 0
assert_err_contains 'merge-check 警告主 checkout 脏' '未提交改动'
run task integrate task-z --force
assert_rc_nonzero '主 checkout 脏 → integrate 拒绝'
assert_err_contains '拒绝原因说明主 checkout 不干净' '未提交改动'
g checkout -- apps/api/src/index.ts
[[ -z "$(g status --porcelain)" ]] && pass '恢复主 checkout 清洁' || fail '恢复主 checkout 清洁'

section '15. case 1：两个 agent 同时创建任务（并发安全）'
set +e
"$AGENTCTL" task create --platform backend --agent codex --title 'Parallel One' --allowed-paths 'apps/api/src/parallel/p1/**' >"$WORK/p1.out" 2>&1 &
P1=$!
"$AGENTCTL" task create --platform backend --agent omp --title 'Parallel Two' --allowed-paths 'apps/api/src/parallel/p2/**' >"$WORK/p2.out" 2>&1 &
P2=$!
wait "$P1"
RC1=$?
wait "$P2"
RC2=$?
set -e
[[ "$RC1" == 0 && "$RC2" == 0 ]] && pass '并发创建两个任务都成功' || fail '并发创建两个任务都成功' "rc=$RC1/$RC2　$(cat "$WORK/p1.out" "$WORK/p2.out")"
assert_exists '并发任务 1 worktree' "$WTROOT/api/api-parallel-one-001"
assert_exists '并发任务 2 worktree' "$WTROOT/api/api-parallel-two-001"
if g show-ref --verify --quiet refs/heads/feat/api-parallel-one-001 &&
  g show-ref --verify --quiet refs/heads/feat/api-parallel-two-001; then
  pass '并发任务分支各自存在'
else
  fail '并发任务分支各自存在'
fi
[[ "$(json_get "$REPO/.agents/tasks/api-parallel-one-001.json" agent)" == codex &&
  "$(json_get "$REPO/.agents/tasks/api-parallel-two-001.json" agent)" == omp ]] &&
  pass '并发任务各自记录 agent' || fail '并发任务各自记录 agent'

section '16. AgentRunner：task start 自动启动与降级'
run task start api-parallel-two-001 --dry-run
assert_rc 'task start --dry-run 退出码 0' 0
if command -v omp >/dev/null 2>&1; then
  assert_out_contains 'omp 已安装 → 构造出实测参数的启动命令' '--cwd'
  assert_out_contains 'omp 非交互启动带 --auto-approve（否则工具调用空转）' '--auto-approve'
else
  assert_out_contains 'omp 未安装 → 降级提示' '降级'
fi
run task start api-parallel-one-001 --dry-run
assert_rc 'codex（未安装）的 task start 不报错' 0
assert_out_contains '未安装的 agent 走降级路径' '降级'
assert_out_contains '降级路径给出手工启动命令' 'cd '
run agent list
assert_out_contains 'agent list 显示检测结果' 'opencode'

section '17. 回收规则（task remove）'
run task remove task-z
assert_rc_nonzero '未 merged → 拒绝删除'
assert_err_contains '提示 --force' '--force'
assert_exists '拒绝后 worktree 仍在' "$WTROOT/api/task-z"
run task remove task-a
assert_rc '已 merged 且干净 → 自动回收' 0
assert_absent 'worktree 已回收' "$WTROOT/api/task-a"
assert_absent '任务分支已删除' "$REPO/.git/refs/heads/feat/api-task-a"
assert_absent '任务记录已删除' "$REPO/.agents/tasks/task-a.json"
printf 'leftover\n' >"$WTROOT/api/task-z/apps/api/src/index.ts"
run task remove task-z --force
assert_rc 'force 回收未 merged 任务' 0
assert_err_contains 'force 打印丢弃警告' 'WARNING'
assert_absent 'force 后 worktree 已回收' "$WTROOT/api/task-z"
run task remove task-x --force
assert_rc '回收 task-x' 0

section '18. 平台目录内创建任务会告警'
run -C "$REPO/apps/api" task create --platform backend --agent codex --task task-w2 --allowed-paths 'apps/api/src/other/w2/**'
assert_rc '平台目录内也能创建任务' 0
assert_err_contains '发出平台目录告警' '平台目录'
assert_exists '任务 worktree 仍建在同级目录' "$WTROOT/api/task-w2"
run task remove task-w2 --force
assert_rc '清理 task-w2' 0

section '19. 平台 registry 声明（id / paths / 别名 / 目录缺失 / 歧义 / --type）'
mkdir -p "$REPO/.agents/config"
cat >"$REPO/.agents/config/platforms.json" <<'JSON'
{
  "main_branch": "main",
  "platforms": {
    "api": { "paths": ["apps/api"], "aliases": ["backend"], "test_command": "true" },
    "frontend": { "paths": ["apps/frontend"], "aliases": ["web", "shared-name"] },
    "missing": { "paths": ["apps/missing"], "aliases": ["shared-name"] }
  }
}
JSON
run --json platform list
assert_out_contains '声明平台 api 生效' '"id": "api"'
assert_out_contains '声明平台来源标记 declared' '"source": "declared"'
assert_out_contains '声明平台目录为绝对路径' "$REPO/apps/api"
[[ "$(printf '%s' "$OUT" | grep -c '"id": "backend"')" == 0 ]] && pass '别名不重复成为独立平台' || fail '别名不重复成为独立平台'
assert_out_contains '声明但目录缺失被标记' '目录缺失'
# platforms.json 是入库配置：改完提交，保持主 checkout 干净
g add .agents/config/platforms.json
g commit -qm 'chore(config): 声明缺失目录的平台'
run task create --platform backend --agent codex --title 'Alias Task' --allowed-paths 'apps/api/src/other/alias/**'
assert_rc '别名 backend → 平台 api' 0
[[ "$(json_get "$REPO/.agents/tasks/api-alias-task-001.json" platform)" == api ]] && pass '任务记录使用声明平台 id' || fail '任务记录使用声明平台 id'
[[ "$(json_get "$REPO/.agents/tasks/api-alias-task-001.json" test_command)" == '' ]] && pass '未显式指定时 test_command 走平台配置' || fail '未显式指定时 test_command 走平台配置'
run task create --platform backend --agent codex --task backend-alias-flat-001 --title '别名归一' --allowed-paths 'apps/api/src/other/flat/**' --type fix
assert_rc '创建带别名前缀的 task id' 0
assert_out_contains '分支名用平台规范 id 与 --type（别名 backend → api）' 'fix/api-alias-flat-001'
assert_exists '归一后分支已创建' "$REPO/.git/refs/heads/fix/api-alias-flat-001"
assert_absent '旧格式分支未创建' "$REPO/.git/refs/heads/fix/codex/backend-alias-flat-001"
run task remove backend-alias-flat-001 --force
run task create --platform shared-name --agent codex --title 'Amb Task'
assert_rc_nonzero '别名歧义 → 拒绝'
assert_err_contains '歧义报错列出候选' '有歧义'
run task create --platform missing --agent codex --title 'Bad Task'
assert_rc_nonzero '目录缺失的平台不可用'
assert_err_contains '报错说明目录缺失' '目录缺失'
run task remove api-alias-task-001 --force
run task remove task-b --force
assert_rc '清理 task-b' 0

section '20. create --dry-run 不落盘'
run task create --platform backend --agent omp --title 'Dry Run Task' --allowed-paths 'apps/api/src/other/dry/**' --dry-run
assert_rc 'dry-run 退出码 0' 0
assert_out_contains 'dry-run 打印将创建内容' '[dry-run]'
assert_absent 'dry-run 不创建 worktree' "$WTROOT/api/api-dry-run-task-001"
assert_absent 'dry-run 不创建任务记录' "$REPO/.agents/tasks/api-dry-run-task-001.json"

section '21. task update-base：基点推进、冲突续做与守卫'
UB=api-parallel-one-001
UBW="$WTROOT/api/$UB"
mkdir -p "$UBW/apps/api/src/parallel/p1"
printf 'export const p1 = "one";\n' >"$UBW/apps/api/src/parallel/p1/one.ts"
gw "$UBW" add apps/api/src/parallel/p1
gw "$UBW" commit -qm 'feat(p1): one'
# 主干前进（模拟其他任务先集成）
printf 'export const drift = "platform";\n' >"$REPO/apps/api/src/shared/drift.ts"
g add apps/api/src/shared/drift.ts
g commit -qm 'chore(platform): drift'
BASE_BEFORE="$(json_get "$REPO/.agents/tasks/$UB.json" base_commit)"
run task update-base "$UB" --dry-run
assert_rc 'update-base --dry-run 退出码 0' 0
BEHIND="$(g rev-list --count "$BASE_BEFORE..main")"
[[ "$BEHIND" -ge 1 ]] && pass '主干已领先任务基点' || fail '主干已领先任务基点' "behind=$BEHIND"
assert_out_contains 'dry-run 报告主干领先提交数' "领先任务基点 $BEHIND 个提交"
[[ "$(json_get "$REPO/.agents/tasks/$UB.json" base_commit)" == "$BASE_BEFORE" ]] && pass 'dry-run 不改注册表' || fail 'dry-run 不改注册表'
run task update-base "$UB"
assert_rc 'update-base 合并主干' 0
assert_out_contains '报告基点更新' '基点已更新'
BASE_AFTER="$(json_get "$REPO/.agents/tasks/$UB.json" base_commit)"
[[ "$BASE_AFTER" != "$BASE_BEFORE" ]] && pass 'base_commit 已刷新' || fail 'base_commit 已刷新'
assert_file_contains '主干新提交进入任务 worktree' "$UBW/apps/api/src/shared/drift.ts" 'platform'
run task check "$UB"
assert_rc '新基点下 scope 检查仍通过' 0
run task update-base "$UB"
assert_out_contains '主干未前进时 no-op' '无需更新'
# 脏 worktree 拒绝
printf 'dirty\n' >"$UBW/apps/api/src/parallel/p1/tmp.txt"
run task update-base "$UB"
assert_rc_nonzero '脏 worktree → 拒绝'
assert_err_contains '提示先提交' '未提交改动'
rm -f "$UBW/apps/api/src/parallel/p1/tmp.txt"
# ready 任务基点变更后退回 active
run task set-status "$UB" ready
printf 'export const p1 = "one-more";\n' >"$UBW/apps/api/src/parallel/p1/one.ts"
gw "$UBW" add apps/api/src/parallel/p1
gw "$UBW" commit -qm 'feat(p1): more'
printf 'export const drift2 = "platform2";\n' >"$REPO/apps/api/src/shared/drift2.ts"
g add apps/api/src/shared/drift2.ts
g commit -qm 'chore(platform): drift2'
run task update-base "$UB"
assert_rc 'ready 任务 update-base' 0
assert_out_contains 'ready → active 提示' 'ready → active'
[[ "$(json_get "$REPO/.agents/tasks/$UB.json" status)" == active ]] && pass '状态退回 active' || fail '状态退回 active'
# merged 任务拒绝
run task set-status "$UB" merged
run task update-base "$UB"
assert_rc_nonzero 'merged 任务拒绝 update-base'
assert_err_contains '提示已并入' '无需 update-base'
run task set-status "$UB" active
# 冲突续做（用 parallel-two，与主干改同一文件）
UB2=api-parallel-two-001
UB2W="$WTROOT/api/$UB2"
printf 'export const shared = "from-task";\n' >"$UB2W/apps/api/src/shared/config.ts"
gw "$UB2W" add apps/api/src/shared/config.ts
gw "$UB2W" commit -qm 'feat(p2): shared config'
printf 'export const shared = "from-platform";\n' >"$REPO/apps/api/src/shared/config.ts"
g add apps/api/src/shared/config.ts
g commit -qm 'chore(platform): shared config'
run task update-base "$UB2"
assert_rc_nonzero '冲突 → update-base 退出码非 0'
assert_out_contains '列出冲突文件' 'apps/api/src/shared/config.ts'
assert_out_contains '说明保留进行中的 merge' '保留了进行中的 merge'
gw "$UB2W" rev-parse -q --verify MERGE_HEAD >/dev/null && pass '任务 worktree 保留进行中的 merge' || fail '任务 worktree 保留进行中的 merge'
run task update-base "$UB2"
assert_rc_nonzero '冲突未解决时重跑仍失败'
printf 'export const shared = "merged-base-update";\n' >"$UB2W/apps/api/src/shared/config.ts"
gw "$UB2W" add apps/api/src/shared/config.ts
run task update-base "$UB2"
assert_rc '解决后续做 update-base 成功' 0
[[ -z "$(gw "$UB2W" rev-parse -q --verify MERGE_HEAD)" ]] && pass '收尾后 merge 已结束' || fail '收尾后 merge 已结束'
assert_file_contains '合并结果含任务侧改动' "$UB2W/apps/api/src/shared/config.ts" 'merged-base-update'

section '22. task adopt：注册表丢失后从 TASK.md 重建'
rm "$REPO/.agents/tasks/$UB2.json"
run doctor
assert_out_contains 'doctor 发现未登记分支' 'Orphan task branches: FAIL'
run -C "$UB2W" task current
assert_out_contains '注册表丢失后退回 coordinator 模式' 'Mode: coordinator'
run task adopt
assert_rc_nonzero '无 TASK.md 的目录拒绝 adopt'
run -C "$UB2W" task adopt
assert_rc 'adopt 重建记录' 0
assert_out_contains 'adopt 输出 Task adopted' 'Task adopted:'
[[ -f "$REPO/.agents/tasks/$UB2.json" ]] && pass '注册表文件已重建' || fail '注册表文件已重建'
[[ "$(json_get "$REPO/.agents/tasks/$UB2.json" platform)" == api ]] && pass 'platform 从 TASK.md 恢复' || fail 'platform 从 TASK.md 恢复'
[[ "$(json_get "$REPO/.agents/tasks/$UB2.json" status)" == active ]] && pass 'status 从 TASK.md 恢复' || fail 'status 从 TASK.md 恢复'
[[ "$(json_get "$REPO/.agents/tasks/$UB2.json" allowed_paths.0)" == 'apps/api/src/parallel/p2/**' ]] && pass 'scope 从 TASK.md 恢复' || fail 'scope 从 TASK.md 恢复'
[[ "$(json_get "$REPO/.agents/tasks/$UB2.json" schema_version)" == 1 ]] && pass '记录含 schema_version' || fail '记录含 schema_version'
run -C "$UB2W" task current
assert_out_contains 'adopt 后恢复 worker 模式' 'Mode: worker'
run task show "$UB2"
assert_rc '重建后 task show 可用' 0
run -C "$UB2W" task adopt
assert_rc_nonzero '记录已存在 → 拒绝重复 adopt'
run doctor
assert_out_contains 'adopt 后 doctor 恢复' 'Orphan task branches: OK'

section '23. 手工合并放行回收、finish 相关检查超时与 worktree_root 守卫'
# 在 task-y 内提交，再绕过 agentctl 手工把分支并进 main → remove 无需 --force 放行
printf 'export const login = "manual";\n' >"$WTROOT/api/task-y/apps/api/src/auth/login.ts"
gw "$WTROOT/api/task-y" add apps/api/src/auth/login.ts
gw "$WTROOT/api/task-y" commit -qm 'feat(auth): manual work'
g merge --no-ff -m 'manual: task-y' feat/api-task-y
run task remove task-y
assert_rc '分支已并入主干 → 放行回收' 0
assert_out_contains '放行说明' '放行回收'
assert_absent 'worktree 已回收' "$WTROOT/api/task-y"
assert_absent '任务记录已删除' "$REPO/.agents/tasks/task-y.json"
# finish 相关检查超时
run task finish "$UB" --test-command 'sleep 3' --timeout 1
assert_rc_nonzero '相关检查超时 → finish 拒绝'
assert_err_contains '报错说明超时' '相关检查超时'
run task finish "$UB" --test-command true --timeout 60
assert_rc '未触发的超时不影响 finish' 0
# worktree_root 配置在仓库内部 → doctor 告警
mkdir -p "$REPO/.agents/config"
cat >"$REPO/.agents/config/platforms.json" <<'JSON'
{
  "worktree_root": "./inside",
  "platforms": {}
}
JSON
run doctor
assert_out_contains 'worktree_root 在仓库内 → doctor 提示' '位于主 checkout 内部'

section '24. finish 相关检查（scoped）：{filter} / {files} 模板与全量提示'
cat >"$REPO/.agents/config/platforms.json" <<'JSON'
{
  "main_branch": "main",
  "platforms": {
    "api": {
      "paths": ["apps/api"],
      "aliases": ["backend"],
      "test_command": "echo \"RUN filter={filter}\"",
      "test_globs": ["apps/api/tests/**"],
      "test_command_global": "echo GLOBAL-SUITE"
    },
    "frontend": {
      "paths": ["apps/frontend"],
      "aliases": ["web"],
      "test_command": "echo \"RUN files={files}\"",
      "test_globs": ["apps/frontend/src/**"],
      "test_command_global": "echo GLOBAL-LINT"
    }
  }
}
JSON
# (a) 任务声明 --test-filter：模板替换 + TASK.md / 创建输出 / 全量提示
run task create --platform backend --agent omp --task task-s1 --allowed-paths 'apps/api/tests/**,apps/api/src/s1/**' --test-filter 'Alpha|Beta'
assert_rc '创建声明选择子的任务' 0
assert_out_contains '创建输出相关检查（含声明选择子）' 'RUN filter=Alpha|Beta'
assert_out_contains '创建输出全量检查提示' 'echo GLOBAL-SUITE'
assert_file_contains 'TASK.md 记录声明的选择子' "$WTROOT/api/task-s1/.agents/TASK.md" 'Test Filter: Alpha|Beta'
assert_file_contains 'TASK.md 含相关检查模板' "$WTROOT/api/task-s1/.agents/TASK.md" 'RUN filter=Alpha|Beta'
assert_file_contains 'TASK.md 说明全量不在门禁内' "$WTROOT/api/task-s1/.agents/TASK.md" '不进 finish 门禁'
printf 'alpha\n' >"$WTROOT/api/task-s1/apps/api/tests/AlphaTest.php"
gw "$WTROOT/api/task-s1" add apps/api/tests/AlphaTest.php
gw "$WTROOT/api/task-s1" commit -qm 'test(s1): alpha'
run task finish task-s1
assert_rc '声明的选择子 → 相关检查通过' 0
assert_out_contains 'finish 按声明的选择子执行' 'RUN filter=Alpha|Beta'
assert_out_contains '摘要提示全量为可选' 'Check all: echo GLOBAL-SUITE（可选'
run task show task-s1
assert_out_contains 'task show 显示相关检查' 'RUN filter=Alpha|Beta'
assert_out_contains 'task show 显示全量检查' 'Check all:  echo GLOBAL-SUITE'
# adopt 从 TASK.md 恢复声明的选择子
rm "$REPO/.agents/tasks/task-s1.json"
run -C "$WTROOT/api/task-s1" task adopt
assert_rc 'adopt 重建 task-s1' 0
[[ "$(json_get "$REPO/.agents/tasks/task-s1.json" test_filter)" == 'Alpha|Beta' ]] && pass 'test_filter 从 TASK.md 恢复' || fail 'test_filter 从 TASK.md 恢复'
run task remove task-s1 --force
assert_rc '清理 task-s1' 0
# (b) 未声明选择子：由改动命中 test_globs 的文件推导（未命中的源文件不进选择子）
run task create --platform backend --agent omp --task task-s2 --allowed-paths 'apps/api/tests/**,apps/api/src/s2/**'
assert_rc '创建未声明选择子的任务' 0
assert_out_contains '未声明时预览留占位提示' 'RUN filter=<本次改动推导>'
mkdir -p "$WTROOT/api/task-s2/apps/api/src/s2"
printf 'gamma\n' >"$WTROOT/api/task-s2/apps/api/tests/GammaTest.php"
printf 'export const impl = 1;\n' >"$WTROOT/api/task-s2/apps/api/src/s2/impl.ts"
gw "$WTROOT/api/task-s2" add apps/api/tests/GammaTest.php apps/api/src/s2/impl.ts
gw "$WTROOT/api/task-s2" commit -qm 'feat(s2): gamma + impl'
run task finish task-s2
assert_rc '派生的选择子 → 相关检查通过' 0
assert_out_contains '选择子取自命中的测试文件' 'RUN filter=GammaTest'
[[ "$OUT" != *'filter=impl'* ]] && pass '未命中 test_globs 的源文件不进选择子' || fail '未命中 test_globs 的源文件不进选择子'
run task remove task-s2 --force
assert_rc '清理 task-s2' 0
# (c) 前端 {files}：对改动文件执行检查；--test-command 仍可原样覆盖
run task create --platform web --agent omp --task task-s3 --allowed-paths 'apps/frontend/src/a/**'
assert_rc '创建前端任务' 0
mkdir -p "$WTROOT/frontend/task-s3/apps/frontend/src/a"
printf 'export const a = 1;\n' >"$WTROOT/frontend/task-s3/apps/frontend/src/a/a.ts"
gw "$WTROOT/frontend/task-s3" add apps/frontend/src/a/a.ts
gw "$WTROOT/frontend/task-s3" commit -qm 'feat(a): a.ts'
run task finish task-s3
assert_rc '前端相关检查通过' 0
assert_out_contains '前端按改动文件执行检查' 'RUN files=apps/frontend/src/a/a.ts'
assert_out_contains '前端摘要提示全量检查' 'Check all: echo GLOBAL-LINT（可选'
run task finish task-s3 --test-command 'echo VERBATIM'
assert_rc '--test-command 覆盖模板仍可原样执行' 0
assert_out_contains '原样执行覆盖命令' 'VERBATIM'
run task remove task-s3 --force
assert_rc '清理 task-s3' 0
# (d) 改动未命中 test_globs 且未声明选择子 → skipped（不静默、不升级为全量）；--test-filter 可补
run task create --platform web --agent omp --task task-s4 --allowed-paths 'README.md'
assert_rc '创建未命中 test_globs 的任务' 0
printf 'more\n' >>"$WTROOT/frontend/task-s4/README.md"
gw "$WTROOT/frontend/task-s4" add README.md
gw "$WTROOT/frontend/task-s4" commit -qm 'docs: readme'
run task finish task-s4
assert_rc '无可推导的相关用例 → finish 仍通过' 0
assert_out_contains '第 5 项记为 skipped 并给出原因' 'skipped（本次改动未命中平台 test_globs'
assert_err_contains 'stderr 提示相关检查未执行' '相关检查未执行'
assert_err_contains 'stderr 给出全量检查命令' 'echo GLOBAL-LINT'
run task finish task-s4 --test-filter 'apps/frontend/src/any/**'
assert_rc '--test-filter 显式补出选择子' 0
assert_out_contains '显式选择子替换占位符' "RUN files='apps/frontend/src/any/**'"
run task remove task-s4 --force
assert_rc '清理 task-s4' 0
# (e) 已删除的文件不进选择子（检查工具对不存在的路径直接报错）
run task create --platform web --agent omp --task task-s5 --allowed-paths 'apps/frontend/src/b/**'
assert_rc '创建任务 task-s5' 0
mkdir -p "$WTROOT/frontend/task-s5/apps/frontend/src/b"
printf 'export const b = 1;\n' >"$WTROOT/frontend/task-s5/apps/frontend/src/b/b.ts"
gw "$WTROOT/frontend/task-s5" add apps/frontend/src/b/b.ts
gw "$WTROOT/frontend/task-s5" commit -qm 'feat(b): b.ts'
gw "$WTROOT/frontend/task-s5" rm -q apps/frontend/src/b/b.ts
mkdir -p "$WTROOT/frontend/task-s5/apps/frontend/src/b"
printf 'export const c = 1;\n' >"$WTROOT/frontend/task-s5/apps/frontend/src/b/c.ts"
gw "$WTROOT/frontend/task-s5" add apps/frontend/src/b/c.ts
gw "$WTROOT/frontend/task-s5" commit -qm 'refactor(b): b.ts → c.ts'
run task finish task-s5
assert_rc '删除 + 新增混合 → 相关检查通过' 0
assert_out_contains '选择子只含仍存在的改动文件' 'RUN files=apps/frontend/src/b/c.ts'
[[ "$OUT" != *'b/b.ts'* ]] && pass '已删除的文件不进选择子' || fail '已删除的文件不进选择子'
gw "$WTROOT/frontend/task-s5" rm -q apps/frontend/src/b/c.ts
gw "$WTROOT/frontend/task-s5" commit -qm 'chore(b): drop c.ts'
run task finish task-s5
assert_rc '全部删除 → finish 仍通过' 0
assert_out_contains '无可选文件 → skipped' 'skipped（本次改动未命中平台 test_globs（已删除的文件不计入）'
run task remove task-s5 --force
assert_rc '清理 task-s5' 0

section '25. agentctl init：补 .gitignore、幂等、不代写平台配置'
# 还原到「未初始化」状态：删平台配置、去掉 gitignore 排除项
rm -f "$REPO/.agents/config/platforms.json"
grep -v -e '^/\.agents/tasks/$' -e '^/\.agents/state/$' "$REPO/.gitignore" >"$REPO/.gitignore.tmp" && mv "$REPO/.gitignore.tmp" "$REPO/.gitignore"
run init
assert_rc 'init 退出码 0' 0
assert_out_contains 'init 提示平台需人工声明' '需手工声明'
assert_out_contains 'init 给出平台声明示例' '"paths"'
assert_out_contains 'init 报告补写 gitignore' '.gitignore'
grep -q '^/\.agents/tasks/$' "$REPO/.gitignore" && pass 'gitignore 已补 .agents/tasks/' || fail 'gitignore 已补 .agents/tasks/'
[[ ! -f "$REPO/.agents/config/platforms.json" ]] && pass 'init 不再自动生成平台配置' || fail 'init 不再自动生成平台配置'
run task create --platform backend --agent codex --task task-noplatform --title 'No Platform'
assert_rc_nonzero '无平台声明 → task create 拒绝'
assert_err_contains '报错说明未知平台' '未知平台'
# 平台一律人工声明：补上 platforms.json 后恢复正常
mkdir -p "$REPO/.agents/config"
cat >"$REPO/.agents/config/platforms.json" <<'JSON'
{
  "main_branch": "main",
  "platforms": {
    "api": { "paths": ["apps/api"], "aliases": ["backend"] },
    "frontend": { "paths": ["apps/frontend"], "aliases": ["web"] }
  }
}
JSON
run platform list
assert_rc '人工声明后 platform list 正常' 0
run task create --platform backend --agent codex --task task-init --allowed-paths 'apps/api/src/other/init/**'
assert_rc '人工声明平台后可直接建任务' 0
run task remove task-init --force
assert_rc '清理 task-init' 0
# 幂等：已有配置不覆盖、gitignore 不重复追加
cp "$REPO/.agents/config/platforms.json" "$WORK/platforms.before.json"
run init
assert_rc '重复 init 退出码 0' 0
assert_out_contains '已存在配置不覆盖' '不覆盖'
cmp "$WORK/platforms.before.json" "$REPO/.agents/config/platforms.json" && pass '配置未被改写' || fail '配置未被改写'
[[ "$(grep -c '^/\.agents/tasks/$' "$REPO/.gitignore")" == 1 ]] && pass 'gitignore 不重复追加' || fail 'gitignore 不重复追加'
run doctor
assert_out_contains 'doctor 确认 gitignore 排除' 'Runtime state gitignore: OK'

section '27. agent 自识别：--agent 缺省时的解析与拒绝'
# 拒绝用例仅在没有已知 agent 祖先时可测（如 CI；在 agent CLI 宿主内跳过）
PROC_HIT=$("$AGENTCTL" --json whoami | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{console.log(JSON.parse(s).process||"")})')
if [[ -z "$PROC_HIT" ]]; then
  run task create --platform backend --task task-who --title 'Who Task'
  assert_rc_nonzero '无法自识别 → 拒绝创建'
  assert_err_contains '提示显式传 --agent' '--agent'
else
  pass "无法自识别 → 拒绝创建（跳过：宿主进程链含已知 agent ${PROC_HIT}）"
fi
# env 显式指定生效，且创建输出标注来源
AGENTCTL_AGENT=qoder "$AGENTCTL" task create --platform backend --task task-env --title 'Env Task' >"$WORK/env.out" 2>&1
[[ "$(json_get "$REPO/.agents/tasks/task-env.json" agent)" == qoder ]] && pass 'AGENTCTL_AGENT 环境变量生效' || fail 'AGENTCTL_AGENT 环境变量生效'
grep -q 'AGENTCTL_AGENT 环境变量' "$WORK/env.out" && pass '创建输出标注来源' || fail '创建输出标注来源'
run task remove task-env --force
assert_rc '清理 task-env' 0
# flag 优先于 env
AGENTCTL_AGENT=qoder "$AGENTCTL" task create --platform backend --task task-flag --agent claude --title 'Flag Task' >/dev/null 2>&1
[[ "$(json_get "$REPO/.agents/tasks/task-flag.json" agent)" == claude ]] && pass 'flag 优先于 env' || fail 'flag 优先于 env'
run task remove task-flag --force
assert_rc '清理 task-flag' 0
run whoami
assert_rc 'whoami 退出码 0' 0
run --json whoami
assert_rc 'whoami --json 退出码 0' 0

section '28. 任务分支 type 白名单（--type 校验）'
# 放在最后：非法 --type 会在注册表临界区内 die，残留的锁会挡住后续所有注册表命令
run task create --platform backend --agent codex --task task-bad-type --title 'Bad Type' --type nope
assert_rc_nonzero '非法 --type → 拒绝创建'
assert_err_contains '报错列出 type 白名单' '分支 type 不合法'
assert_absent '非法 --type 不留下任务记录' "$REPO/.agents/tasks/task-bad-type.json"
assert_absent '非法 --type 不留下任务分支' "$REPO/.git/refs/heads/nope/api-task-bad-type"

section '29. 结束'
printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAILED"
[[ "$FAILED" == 0 ]] || exit 1
