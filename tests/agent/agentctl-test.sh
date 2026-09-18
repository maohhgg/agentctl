#!/usr/bin/env bash
#
# agentctl 端到端测试
#
# 覆盖：doctor 自检、平台探测与声明、任务创建（显式 / 自动 task id + 任务分支 + 独立 worktree）、
# TASK.md 任务上下文（含不进业务提交）、allowed_paths 范围检查、scope 重叠检测、
# finish 门禁（含测试超时）与 Worker 完成摘要、merge-check（只读）、integrate（含冲突续做）、
# update-base（基点推进与冲突续做）、adopt（注册表重建）、手工合并放行回收、回收规则、
# init（配置生成 / gitignore / 幂等）、agent 自识别（whoami / env / flag 优先级）、
# 平台 worktree 告警、AgentRunner（自动启动与降级），以及四个并发场景：
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

setup_fixture() {
  mkdir -p "$REPO"
  cd "$REPO"
  git init -q -b master
  git config user.name 'agentctl test'
  git config user.email 'agentctl@test.local'
  git config commit.gpgsign false
  git config rerere.enabled false
  mkdir -p src/shared src/auth src/other tests
  printf 'export const config = "base";\n' >src/shared/config.ts
  printf 'export const index = "base";\n' >src/index.ts
  printf 'export const login = "base";\n' >src/auth/login.ts
  printf 'export const other = "base";\n' >src/other/thing.ts
  printf 'placeholder\n' >tests/placeholder.txt
  printf '# project\n' >README.md
  printf '# runtime\n/.agents/tasks/\n/.agents/state/\n' >.gitignore
  git add -A
  git commit -qm 'init'
  git branch backend
  git branch web
  mkdir -p wt
  git worktree add -q wt/backend backend
  git worktree add -q wt/web web
}

setup_fixture

section '1. doctor 自检'
run doctor
assert_rc 'doctor 退出码 0' 0
assert_out_contains 'doctor 报告 Git' 'Git: OK'
assert_out_contains 'doctor 报告平台 worktree' 'Platform Worktrees:'
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

section '2. 平台探测（git worktree list）'
run platform list
assert_rc 'platform list 退出码 0' 0
assert_out_contains '列出 platform backend' 'backend'
assert_out_contains '列出 platform web' 'web'
assert_out_contains '标注 worktree 路径' 'wt/backend'
run --json platform list
assert_out_contains 'JSON 输出含 hub_branch' '"hub_branch": "master"'
assert_out_contains 'JSON 输出含 worktree_root（同级目录）' "\"worktree_root\": \"$WTROOT\""

if "$AGENTCTL" platform list 2>"$WORK/.pipe-err" | head -2 >/dev/null; then
  pass '输出被管道截断（| head）时正常结束'
else
  fail '输出被管道截断（| head）时正常结束'
fi
[[ -s "$WORK/.pipe-err" ]] && fail '管道截断不产生 stderr 噪音' "$(cat "$WORK/.pipe-err")" || pass '管道截断不产生 stderr 噪音'

section '3. task create：显式 task id + 独立 worktree + TASK.md'
run task create --platform backend --agent codex --task task-a --title 'Task A' \
  --objective '为 backend 增加 A 功能' --requirements '实现登录;补充测试' --allowed-paths 'src/shared/**'
assert_rc '创建 task-a' 0
assert_out_contains '输出 Task created.' 'Task created.'
assert_out_contains '输出任务分支' 'agent/codex/task-a'
assert_out_contains '输出 TASK.md 路径' 'TASK.md'
assert_exists 'task-a worktree 建在仓库同级目录' "$WTROOT/backend/task-a"
assert_absent 'worktree 未落在仓库内' "$REPO/.agents-worktrees"
assert_exists 'task-a 元数据已写入' "$REPO/.agents/tasks/task-a.json"
assert_exists 'task-a 分支已创建' "$REPO/.git/refs/heads/agent/codex/task-a"
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" platform)" == backend ]] && pass '元数据 platform=backend' || fail '元数据 platform=backend'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" status)" == active ]] && pass '元数据 status=active' || fail '元数据 status=active'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" allowed_paths.0)" == 'src/shared/**' ]] && pass '元数据 allowed_paths 落盘' || fail '元数据 allowed_paths 落盘'
[[ -n "$(json_get "$REPO/.agents/tasks/task-a.json" uuid)" ]] && pass '元数据含 UUID' || fail '元数据含 UUID'
[[ -n "$(json_get "$REPO/.agents/tasks/task-a.json" objective)" ]] && pass '元数据含 objective' || fail '元数据含 objective'

assert_file_contains 'TASK.md 含 Task ID' "$WTROOT/backend/task-a/.agents/TASK.md" 'Task ID: task-a'
assert_file_contains 'TASK.md 含 Platform' "$WTROOT/backend/task-a/.agents/TASK.md" 'Platform: backend'
assert_file_contains 'TASK.md 含 Objective' "$WTROOT/backend/task-a/.agents/TASK.md" '为 backend 增加 A 功能'
assert_file_contains 'TASK.md 含 Requirements' "$WTROOT/backend/task-a/.agents/TASK.md" '- 补充测试'
assert_file_contains 'TASK.md 含 Scope' "$WTROOT/backend/task-a/.agents/TASK.md" 'src/shared/**'
assert_file_contains 'TASK.md 含 Restrictions' "$WTROOT/backend/task-a/.agents/TASK.md" '## Restrictions'
assert_file_contains 'TASK.md 含 Completion Criteria' "$WTROOT/backend/task-a/.agents/TASK.md" '## Completion Criteria'
assert_file_contains 'TASK.md 提示不要并入平台分支' "$WTROOT/backend/task-a/.agents/TASK.md" '不并入平台分支'

[[ "$(gw "$WTROOT/backend/task-a" status --porcelain)" == "" ]] && pass 'TASK.md 不污染任务 worktree 的 git status' || fail 'TASK.md 不污染任务 worktree 的 git status'
gw "$WTROOT/backend/task-a" check-ignore -q .agents/TASK.md && pass 'TASK.md 已被 info/exclude 排除' || fail 'TASK.md 已被 info/exclude 排除'
g check-ignore -q .agents/tasks 2>/dev/null && pass '任务注册表已被仓库 .gitignore 排除' || fail '任务注册表已被仓库 .gitignore 排除'

section '4. task create：自动 task id'
run task create --platform web --agent omp --title 'Implement Google OAuth' --allowed-paths 'src/auth/**'
assert_rc '未指定 --task 时自动生成 id' 0
[[ -n "$(json_get "$REPO/.agents/tasks/web-google-oauth-001.json" id)" ]] &&
  pass 'task id = <platform>-<slug>-001（去掉 Implement 等动词）' || fail 'task id = <platform>-<slug>-001'
assert_exists '自动 id 的 worktree 已创建' "$WTROOT/web/web-google-oauth-001"
run task create --platform web --agent omp --title 'Implement Google OAuth' --allowed-paths 'src/web-auth/**'
assert_rc '同名标题再次创建（不同 scope）' 0
assert_exists '重名自动递增到 -002' "$WTROOT/web/web-google-oauth-002"
run task remove web-google-oauth-002 --force
assert_rc '清理 -002' 0

section '5. task current / task list / task show（Coordinator vs Worker）'
run task current
assert_out_contains '仓库根为 Coordinator 模式' 'Mode: coordinator'
run -C "$WTROOT/backend/task-a" task current
assert_out_contains '任务 worktree 内为 Worker 模式' 'Mode: worker'
assert_out_contains 'Worker 模式显示任务 id' 'task-a'
run task list
assert_out_contains 'task list 列出 task-a' 'task-a'
assert_out_contains 'task list 列出 codex' 'codex'
run task show task-a
assert_rc 'task show 退出码 0' 0
assert_out_contains 'task show 显示 base 分支' 'backend @ '
assert_out_contains 'task show 显示任务上下文' 'task context:  yes'
assert_out_contains '尚无提交的任务不误报已并入' 'merged:        no'

section '6. Case 2：两个 agent 改同一个文件，物理隔离'
run task create --platform backend --agent claude --task task-b --title 'Task B' --allowed-paths 'src/shared/**' --allow-overlap
assert_rc '创建 task-b（另一 agent，与 task-a 同文件 → 显式确认重叠）' 0
printf 'export const config = "from-task-a";\n' >"$WTROOT/backend/task-a/src/shared/config.ts"
printf 'export const config = "from-task-b";\n' >"$WTROOT/backend/task-b/src/shared/config.ts"
assert_file_content 'task-a 工作区是自己的内容' "$WTROOT/backend/task-a/src/shared/config.ts" 'export const config = "from-task-a";'
assert_file_content 'task-b 工作区是自己的内容' "$WTROOT/backend/task-b/src/shared/config.ts" 'export const config = "from-task-b";'
assert_file_content '平台 worktree 未被覆盖' "$REPO/wt/backend/src/shared/config.ts" 'export const config = "base";'
gw "$WTROOT/backend/task-a" add src/shared/config.ts
gw "$WTROOT/backend/task-a" commit -qm 'feat(a): config from task-a'
gw "$WTROOT/backend/task-b" add src/shared/config.ts
gw "$WTROOT/backend/task-b" commit -qm 'feat(b): config from task-b'
[[ "$(g rev-list --count backend..agent/codex/task-a)" == 1 ]] && pass 'task-a 独立提交 1 个 commit' || fail 'task-a 独立提交 1 个 commit'
[[ "$(g rev-list --count backend..agent/claude/task-b)" == 1 ]] && pass 'task-b 独立提交 1 个 commit' || fail 'task-b 独立提交 1 个 commit'
[[ "$(g rev-list --count backend)" == 1 ]] && pass '平台分支未被 agent 直接提交' || fail '平台分支未被 agent 直接提交'
[[ "$(gw "$WTROOT/backend/task-a" show --name-only --oneline HEAD | grep -c 'TASK.md')" == 0 ]] &&
  pass '业务提交内不含 TASK.md' || fail '业务提交内不含 TASK.md'

section '7. task check：allowed_paths 范围'
run task check task-a
assert_rc '范围内改动 → 退出码 0' 0
assert_out_contains '输出 Result: OK' 'Result: OK'
printf 'export const stray = 1;\n' >"$WTROOT/backend/task-a/src/config.ts"
run task check task-a
assert_rc_nonzero '越界未跟踪文件 → 退出码非 0'
assert_err_contains '报错标明 Unexpected files' 'Unexpected files:'
assert_err_contains '报错列出越界文件' 'src/config.ts'
assert_err_contains '报错列出 allowed scope' 'src/shared/**'
rm -f "$WTROOT/backend/task-a/src/config.ts"
printf 'export const helper = 1;\n' >"$WTROOT/backend/task-a/src/shared/helper.ts"
run task check task-a
assert_rc '范围内新增文件 → 退出码 0' 0
rm -f "$WTROOT/backend/task-a/src/shared/helper.ts"

section '8. Case 4：scope 重叠检测'
run task create --platform backend --agent codex --task task-x --allowed-paths 'src/auth/**'
assert_rc '建立 scope=src/auth/** 的任务' 0
run task create --platform backend --agent omp --task task-y --allowed-paths 'src/auth/login.ts'
assert_rc_nonzero 'scope 重叠 → 拒绝创建'
assert_err_contains '报错说明已有任务占用重叠 scope' '已有未结束任务占用重叠 scope'
assert_err_contains '报错列出冲突任务' 'task-x'
assert_absent '被拒绝后不留下 worktree' "$WTROOT/backend/task-y"
assert_absent '被拒绝后不留下任务记录' "$REPO/.agents/tasks/task-y.json"
run task create --platform backend --agent omp --task task-y --allowed-paths 'src/auth/login.ts' --allow-overlap
assert_rc '--allow-overlap 显式确认后可创建' 0
assert_err_contains '--allow-overlap 打印重叠警告' 'scope 与 task-x'
run task create --platform backend --agent omp --task task-z --allowed-paths 'src/other/thing.ts'
assert_rc 'scope 不重叠 → 正常创建' 0
run task create --platform backend --agent omp --task task-w --title '无 scope 任务'
assert_rc '未指定 scope 可创建' 0
assert_err_contains '无 scope 时提示无法判定重叠' '无法判定'

section '9. task finish 门禁与 Worker 摘要'
printf 'export const config = "a-uncommitted";\n' >"$WTROOT/backend/task-a/src/shared/config.ts"
run task finish task-a --test-command true
assert_rc_nonzero '有未提交改动 → finish 拒绝'
assert_err_contains '拒绝原因含未提交改动' '未提交改动'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" status)" == active ]] && pass 'finish 失败不改状态' || fail 'finish 失败不改状态'
assert_file_content 'finish 失败不丢弃改动' "$WTROOT/backend/task-a/src/shared/config.ts" 'export const config = "a-uncommitted";'
gw "$WTROOT/backend/task-a" add src/shared/config.ts
gw "$WTROOT/backend/task-a" commit -qm 'feat(a): follow-up'
run task finish task-a --test-command false
assert_rc_nonzero '测试失败 → finish 拒绝'
assert_err_contains '拒绝原因含测试未通过' '测试未通过'
run task finish task-a --test-command true
assert_rc '测试通过 + 干净 + 范围内 → finish 通过' 0
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

section '11. merge-check 与 integrate（无冲突路径）'
run task merge-check task-a
assert_rc 'merge-check 干净可合并' 0
assert_out_contains 'merge-check 判定 CLEAN' 'CLEAN'
run task integrate task-a
assert_rc 'integrate task-a' 0
assert_file_content '平台分支已含 task-a 内容' "$REPO/wt/backend/src/shared/config.ts" 'export const config = "a-uncommitted";'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" status)" == merged ]] && pass 'integrate 后状态 merged' || fail 'integrate 后状态 merged'
[[ "$(json_get "$REPO/.agents/tasks/task-a.json" merged_into)" == backend ]] && pass '记录 merged_into=backend' || fail '记录 merged_into=backend'
[[ "$(g log --merges --oneline backend | wc -l | tr -d ' ')" != 0 ]] && pass '平台分支出现 merge commit' || fail '平台分支出现 merge commit'
[[ "$(g rev-parse --abbrev-ref HEAD)" == master ]] && pass '未污染主 checkout 的分支' || fail '未污染主 checkout 的分支'

section '12. Case 3：merge-check 发现冲突且不污染平台 worktree'
HEAD_BEFORE="$(g rev-parse backend)"
STATUS_BEFORE="$(g -C "$REPO/wt/backend" status --porcelain)"
run task merge-check task-b
assert_rc_nonzero '冲突 → merge-check 退出码非 0'
assert_out_contains '冲突文件被列出' 'src/shared/config.ts'
assert_out_contains '判定 CONFLICT' 'CONFLICT'
[[ "$(g rev-parse backend)" == "$HEAD_BEFORE" ]] && pass 'merge-check 未移动平台分支' || fail 'merge-check 未移动平台分支'
[[ "$(g -C "$REPO/wt/backend" status --porcelain)" == "$STATUS_BEFORE" ]] && pass 'merge-check 未污染平台 worktree' || fail 'merge-check 未污染平台 worktree'
assert_absent 'merge-check 未残留临时 worktree' "$REPO/.agents/state/tmp"

section '13. integrate 冲突：状态 conflict，解决后续做 → merged'
run task finish task-b --test-command true
assert_rc 'task-b finish 通过' 0
run task integrate task-b
assert_rc_nonzero '冲突时 integrate 退出码非 0'
assert_out_contains '冲突文件已列出' 'src/shared/config.ts'
g -C "$REPO/wt/backend" rev-parse -q --verify MERGE_HEAD >/dev/null && pass '冲突保留进行中的 merge' || fail '冲突保留进行中的 merge'
[[ "$(json_get "$REPO/.agents/tasks/task-b.json" status)" == conflict ]] && pass '冲突时状态置 conflict' || fail '冲突时状态置 conflict'
run task integrate task-b
assert_rc_nonzero '冲突未解决时重跑 integrate 仍失败'
printf 'export const config = "merged-a-and-b";\n' >"$REPO/wt/backend/src/shared/config.ts"
g -C "$REPO/wt/backend" add src/shared/config.ts
run task integrate task-b
assert_rc '解决冲突后续做 integrate 成功' 0
assert_file_content '合并结果进入平台分支' "$REPO/wt/backend/src/shared/config.ts" 'export const config = "merged-a-and-b";'
[[ -z "$(g -C "$REPO/wt/backend" rev-parse -q --verify MERGE_HEAD)" ]] && pass '收尾后 merge 已结束' || fail '收尾后 merge 已结束'
[[ "$(json_get "$REPO/.agents/tasks/task-b.json" status)" == merged ]] && pass 'task-b 状态 merged' || fail 'task-b 状态 merged'
[[ -z "$(g -C "$REPO/wt/backend" status --porcelain)" ]] && pass '平台 worktree 收尾干净' || fail '平台 worktree 收尾干净'

section '14. 平台 worktree 有未提交改动时拒绝 integrate'
printf 'export const index = "task-d";\n' >"$WTROOT/backend/task-z/src/index.ts"
gw "$WTROOT/backend/task-z" add src/index.ts
gw "$WTROOT/backend/task-z" commit -qm 'feat(z): index'
run task finish task-z --no-test
assert_rc_nonzero 'task-z 越界改动 → finish 拒绝（allowed_paths=src/other/**）'
run task set-status task-z ready
printf 'dirty\n' >>"$REPO/wt/backend/src/index.ts"
run task merge-check task-z
assert_rc '平台脏时 merge-check 仍可用' 0
assert_err_contains 'merge-check 警告平台 worktree 脏' '未提交改动'
run task integrate task-z --force
assert_rc_nonzero '平台脏 → integrate 拒绝'
assert_err_contains '拒绝原因说明平台 worktree 不干净' '未提交改动'
g -C "$REPO/wt/backend" checkout -- src/index.ts
[[ -z "$(g -C "$REPO/wt/backend" status --porcelain)" ]] && pass '恢复平台 worktree 清洁' || fail '恢复平台 worktree 清洁'

section '15. case 1：两个 agent 同时创建任务（并发安全）'
set +e
"$AGENTCTL" task create --platform backend --agent codex --title 'Parallel One' --allowed-paths 'src/parallel/p1/**' >"$WORK/p1.out" 2>&1 &
P1=$!
"$AGENTCTL" task create --platform backend --agent omp --title 'Parallel Two' --allowed-paths 'src/parallel/p2/**' >"$WORK/p2.out" 2>&1 &
P2=$!
wait "$P1"
RC1=$?
wait "$P2"
RC2=$?
set -e
[[ "$RC1" == 0 && "$RC2" == 0 ]] && pass '并发创建两个任务都成功' || fail '并发创建两个任务都成功' "rc=$RC1/$RC2　$(cat "$WORK/p1.out" "$WORK/p2.out")"
assert_exists '并发任务 1 worktree' "$WTROOT/backend/backend-parallel-one-001"
assert_exists '并发任务 2 worktree' "$WTROOT/backend/backend-parallel-two-001"
if g show-ref --verify --quiet refs/heads/agent/codex/backend-parallel-one-001 &&
  g show-ref --verify --quiet refs/heads/agent/omp/backend-parallel-two-001; then
  pass '并发任务分支各自存在'
else
  fail '并发任务分支各自存在'
fi
[[ "$(json_get "$REPO/.agents/tasks/backend-parallel-one-001.json" agent)" == codex &&
  "$(json_get "$REPO/.agents/tasks/backend-parallel-two-001.json" agent)" == omp ]] &&
  pass '并发任务各自记录 agent' || fail '并发任务各自记录 agent'

section '16. AgentRunner：task start 自动启动与降级'
run task start backend-parallel-two-001 --dry-run
assert_rc 'task start --dry-run 退出码 0' 0
if command -v omp >/dev/null 2>&1; then
  assert_out_contains 'omp 已安装 → 构造出实测参数的启动命令' '--cwd'
  assert_out_contains 'omp 非交互启动带 --auto-approve（否则工具调用空转）' '--auto-approve'
else
  assert_out_contains 'omp 未安装 → 降级提示' '降级'
fi
run task start backend-parallel-one-001 --dry-run
assert_rc 'codex（未安装）的 task start 不报错' 0
assert_out_contains '未安装的 agent 走降级路径' '降级'
assert_out_contains '降级路径给出手工启动命令' 'cd '
run agent list
assert_out_contains 'agent list 显示检测结果' 'opencode'

section '17. 回收规则（task remove）'
run task remove task-z
assert_rc_nonzero '未 merged → 拒绝删除'
assert_err_contains '提示 --force' '--force'
assert_exists '拒绝后 worktree 仍在' "$WTROOT/backend/task-z"
run task remove task-a
assert_rc '已 merged 且干净 → 自动回收' 0
assert_absent 'worktree 已回收' "$WTROOT/backend/task-a"
assert_absent '任务分支已删除' "$REPO/.git/refs/heads/agent/codex/task-a"
assert_absent '任务记录已删除' "$REPO/.agents/tasks/task-a.json"
printf 'leftover\n' >"$WTROOT/backend/task-z/src/index.ts"
run task remove task-z --force
assert_rc 'force 回收未 merged 任务' 0
assert_err_contains 'force 打印丢弃警告' 'WARNING'
assert_absent 'force 后 worktree 已回收' "$WTROOT/backend/task-z"
run task remove task-x --force
assert_rc '回收 task-x' 0

section '18. 平台 worktree 内创建任务会告警'
run -C "$REPO/wt/backend" task create --platform backend --agent codex --task task-w2 --allowed-paths 'src/other/w2/**'
assert_rc '平台 worktree 内也能创建任务' 0
assert_err_contains '发出平台 worktree 警告' '平台 worktree'
assert_exists '任务 worktree 仍建在同级目录' "$WTROOT/backend/task-w2"
run task remove task-w2 --force
assert_rc '清理 task-w2' 0

section '19. 平台 registry 声明（id / 别名 / 失配检测）'
mkdir -p "$REPO/.agents/config"
cat >"$REPO/.agents/config/platforms.json" <<'JSON'
{
  "branch_prefix": "agent",
  "platforms": {
    "api": { "worktree": "wt/backend", "branch": "backend", "aliases": ["backend"], "test_command": "true" },
    "frontend": { "worktree": "wt/web", "branch": "web", "aliases": ["web", "shared-name"] },
    "ambiguous": { "worktree": "/nonexistent/whatever", "branch": "nope", "aliases": ["shared-name"] }
  }
}
JSON
run --json platform list
assert_out_contains '声明平台 api 生效' '"id": "api"'
assert_out_contains '声明平台来源标记 declared' '"source": "declared"'
[[ "$(printf '%s' "$OUT" | grep -c '"id": "backend"')" == 0 ]] && pass '已被声明的 worktree 不再重复出现' || fail '已被声明的 worktree 不再重复出现'
assert_out_contains '声明但 worktree 缺失被标记' 'worktree 缺失'
run task create --platform backend --agent codex --title 'Alias Task' --allowed-paths 'src/other/alias/**'
assert_rc '别名 backend → 平台 api' 0
[[ "$(json_get "$REPO/.agents/tasks/api-alias-task-001.json" platform)" == api ]] && pass '任务记录使用声明平台 id' || fail '任务记录使用声明平台 id'
[[ "$(json_get "$REPO/.agents/tasks/api-alias-task-001.json" test_command)" == '' ]] && pass '未显式指定时 test_command 走平台配置' || fail '未显式指定时 test_command 走平台配置'
run task create --platform shared-name --agent codex --title 'Amb Task'
assert_rc_nonzero '别名歧义 → 拒绝'
assert_err_contains '歧义报错列出候选' '有歧义'
run task create --platform ambiguous --agent codex --title 'Bad Task'
assert_rc_nonzero 'worktree 缺失的平台不可用'
assert_err_contains '报错说明 worktree 缺失' 'worktree 缺失'
run task remove api-alias-task-001 --force
run task remove task-b --force
assert_rc '清理 task-b' 0

section '20. create --dry-run 不落盘'
run task create --platform backend --agent omp --title 'Dry Run Task' --allowed-paths 'src/other/dry/**' --dry-run
assert_rc 'dry-run 退出码 0' 0
assert_out_contains 'dry-run 打印将创建内容' '[dry-run]'
assert_absent 'dry-run 不创建 worktree' "$WTROOT/backend/backend-dry-run-task-001"
assert_absent 'dry-run 不创建任务记录' "$REPO/.agents/tasks/backend-dry-run-task-001.json"

section '21. task update-base：基点推进、冲突续做与守卫'
UB=backend-parallel-one-001
UBW="$WTROOT/backend/$UB"
mkdir -p "$UBW/src/parallel/p1"
printf 'export const p1 = "one";\n' >"$UBW/src/parallel/p1/one.ts"
gw "$UBW" add src/parallel/p1
gw "$UBW" commit -qm 'feat(p1): one'
# 平台分支前进（模拟其他任务先集成）
printf 'export const drift = "platform";\n' >"$REPO/wt/backend/src/shared/drift.ts"
g -C "$REPO/wt/backend" add src/shared/drift.ts
g -C "$REPO/wt/backend" commit -qm 'chore(platform): drift'
BASE_BEFORE="$(json_get "$REPO/.agents/tasks/$UB.json" base_commit)"
run task update-base "$UB" --dry-run
assert_rc 'update-base --dry-run 退出码 0' 0
assert_out_contains 'dry-run 报告平台领先提交数' '领先任务基点 1 个提交'
[[ "$(json_get "$REPO/.agents/tasks/$UB.json" base_commit)" == "$BASE_BEFORE" ]] && pass 'dry-run 不改注册表' || fail 'dry-run 不改注册表'
run task update-base "$UB"
assert_rc 'update-base 合并平台分支' 0
assert_out_contains '报告基点更新' '基点已更新'
BASE_AFTER="$(json_get "$REPO/.agents/tasks/$UB.json" base_commit)"
[[ "$BASE_AFTER" != "$BASE_BEFORE" ]] && pass 'base_commit 已刷新' || fail 'base_commit 已刷新'
assert_file_contains '平台新提交进入任务 worktree' "$UBW/src/shared/drift.ts" 'platform'
run task check "$UB"
assert_rc '新基点下 scope 检查仍通过' 0
run task update-base "$UB"
assert_out_contains '平台未前进时 no-op' '无需更新'
# 脏 worktree 拒绝
printf 'dirty\n' >"$UBW/src/parallel/p1/tmp.txt"
run task update-base "$UB"
assert_rc_nonzero '脏 worktree → 拒绝'
assert_err_contains '提示先提交' '未提交改动'
rm -f "$UBW/src/parallel/p1/tmp.txt"
# ready 任务基点变更后退回 active
run task set-status "$UB" ready
printf 'export const p1 = "one-more";\n' >"$UBW/src/parallel/p1/one.ts"
gw "$UBW" add src/parallel/p1
gw "$UBW" commit -qm 'feat(p1): more'
printf 'export const drift2 = "platform2";\n' >"$REPO/wt/backend/src/shared/drift2.ts"
g -C "$REPO/wt/backend" add src/shared/drift2.ts
g -C "$REPO/wt/backend" commit -qm 'chore(platform): drift2'
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
# 冲突续做（用 parallel-two，与平台改同一文件）
UB2=backend-parallel-two-001
UB2W="$WTROOT/backend/$UB2"
printf 'export const shared = "from-task";\n' >"$UB2W/src/shared/config.ts"
gw "$UB2W" add src/shared/config.ts
gw "$UB2W" commit -qm 'feat(p2): shared config'
printf 'export const shared = "from-platform";\n' >"$REPO/wt/backend/src/shared/config.ts"
g -C "$REPO/wt/backend" add src/shared/config.ts
g -C "$REPO/wt/backend" commit -qm 'chore(platform): shared config'
run task update-base "$UB2"
assert_rc_nonzero '冲突 → update-base 退出码非 0'
assert_out_contains '列出冲突文件' 'src/shared/config.ts'
assert_out_contains '说明保留进行中的 merge' '保留了进行中的 merge'
gw "$UB2W" rev-parse -q --verify MERGE_HEAD >/dev/null && pass '任务 worktree 保留进行中的 merge' || fail '任务 worktree 保留进行中的 merge'
run task update-base "$UB2"
assert_rc_nonzero '冲突未解决时重跑仍失败'
printf 'export const shared = "merged-base-update";\n' >"$UB2W/src/shared/config.ts"
gw "$UB2W" add src/shared/config.ts
run task update-base "$UB2"
assert_rc '解决后续做 update-base 成功' 0
[[ -z "$(gw "$UB2W" rev-parse -q --verify MERGE_HEAD)" ]] && pass '收尾后 merge 已结束' || fail '收尾后 merge 已结束'
assert_file_contains '合并结果含任务侧改动' "$UB2W/src/shared/config.ts" 'merged-base-update'

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
[[ "$(json_get "$REPO/.agents/tasks/$UB2.json" platform)" == backend ]] && pass 'platform 从 TASK.md 恢复' || fail 'platform 从 TASK.md 恢复'
[[ "$(json_get "$REPO/.agents/tasks/$UB2.json" status)" == active ]] && pass 'status 从 TASK.md 恢复' || fail 'status 从 TASK.md 恢复'
[[ "$(json_get "$REPO/.agents/tasks/$UB2.json" allowed_paths.0)" == 'src/parallel/p2/**' ]] && pass 'scope 从 TASK.md 恢复' || fail 'scope 从 TASK.md 恢复'
[[ "$(json_get "$REPO/.agents/tasks/$UB2.json" schema_version)" == 1 ]] && pass '记录含 schema_version' || fail '记录含 schema_version'
run -C "$UB2W" task current
assert_out_contains 'adopt 后恢复 worker 模式' 'Mode: worker'
run task show "$UB2"
assert_rc '重建后 task show 可用' 0
run -C "$UB2W" task adopt
assert_rc_nonzero '记录已存在 → 拒绝重复 adopt'
run doctor
assert_out_contains 'adopt 后 doctor 恢复' 'Orphan task branches: OK'

section '23. 手工合并放行回收、finish 测试超时与 worktree_root 守卫'
# 在 task-y 内提交，再绕过 agentctl 手工把分支并进平台分支 → remove 无需 --force 放行
printf 'export const login = "manual";\n' >"$WTROOT/backend/task-y/src/auth/login.ts"
gw "$WTROOT/backend/task-y" add src/auth/login.ts
gw "$WTROOT/backend/task-y" commit -qm 'feat(auth): manual work'
g -C "$REPO/wt/backend" merge --no-ff -m 'manual: task-y' agent/omp/task-y
run task remove task-y
assert_rc '分支已并入平台 → 放行回收' 0
assert_out_contains '放行说明' '放行回收'
assert_absent 'worktree 已回收' "$WTROOT/backend/task-y"
assert_absent '任务记录已删除' "$REPO/.agents/tasks/task-y.json"
# finish 测试超时
run task finish "$UB" --test-command 'sleep 3' --timeout 1
assert_rc_nonzero '测试超时 → finish 拒绝'
assert_err_contains '报错说明超时' '测试超时'
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

section '24. agentctl init：生成配置、补 .gitignore、幂等'
# 还原到「未初始化」状态：删平台配置、去掉 gitignore 排除项
rm -f "$REPO/.agents/config/platforms.json"
grep -v -e '^/\.agents/tasks/$' -e '^/\.agents/state/$' "$REPO/.gitignore" >"$REPO/.gitignore.tmp" && mv "$REPO/.gitignore.tmp" "$REPO/.gitignore"
run init
assert_rc 'init 退出码 0' 0
assert_out_contains 'init 报告生成 platforms.json' 'platforms.json'
assert_out_contains 'init 报告补写 gitignore' '.gitignore'
[[ -f "$REPO/.agents/config/platforms.json" ]] && pass '配置文件已生成' || fail '配置文件已生成'
[[ "$(json_get "$REPO/.agents/config/platforms.json" platforms.backend.branch)" == backend ]] && pass '探测平台 backend 已登记' || fail '探测平台 backend 已登记'
[[ "$(json_get "$REPO/.agents/config/platforms.json" platforms.web.branch)" == web ]] && pass '探测平台 web 已登记' || fail '探测平台 web 已登记'
grep -q '^/\.agents/tasks/$' "$REPO/.gitignore" && pass 'gitignore 已补 .agents/tasks/' || fail 'gitignore 已补 .agents/tasks/'
run platform list
assert_out_contains '生成配置后 platform list 正常' 'backend'
run task create --platform backend --agent codex --task task-init --allowed-paths 'src/other/init/**'
assert_rc '生成配置后可直接建任务' 0
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

section '26. agent 自识别：--agent 缺省时的解析与拒绝'
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

section '27. 结束'
printf '\n通过 %d 项，失败 %d 项\n' "$PASS" "$FAILED"
[[ "$FAILED" == 0 ]] || exit 1
