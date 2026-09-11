#!/usr/bin/env bash
# review-task 测试：队列归人（queue.md），进度归工具（tasks.state），「做完了」由工具只读核对。
# 造一个假仓库和交接目录，把 request-review 会留下的文件手工摆出来；review-task 不许碰 herdr。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RT=${REVIEW_TASK_BIN:-${ROOT}/bin/review-task}
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
REPO="${TMP}/repo"; D="${TMP}/review"
mkdir -p "${REPO}" "${D}" "${TMP}/bin"
git -C "${REPO}" init -q -b main
git -C "${REPO}" config user.name t; git -C "${REPO}" config user.email t@example.com
printf '.review.conf\n' > "${REPO}/.gitignore"
printf 'a\n' > "${REPO}/a.py"
git -C "${REPO}" add .; git -C "${REPO}" commit -qm base
printf 'REVIEW_KIND=claude\nREVIEW_WT=%s\nREVIEW_DIR=%s\n' "${REPO}" "${D}" > "${REPO}/.review.conf"
# 假 herdr：只记录被调用过，好在最后断言 review-task 从没碰过它
printf '#!/usr/bin/env bash\necho "$*" >> "%s/herdr.log"\nexit 1\n' "${TMP}" > "${TMP}/bin/herdr"; chmod +x "${TMP}/bin/herdr"

fail() { echo "FAIL: $*" >&2; echo "--- 最后一次输出 ---" >&2; cat "${TMP}/out" >&2 || true; exit 1; }
rt() { set +e; ( cd "${REPO}" && PATH="${TMP}/bin:${PATH}" python3 "${RT}" "$@" ) > "${TMP}/out" 2>&1; RC=$?; set -e; }
has() { grep -qF -e "$1" "${TMP}/out" || fail "$2 (missing: $1)"; }
code() { [ "${RC}" = "$1" ] || fail "$2: exit ${RC}, expected $1"; }
edit() { mkdir -p "$(dirname "${REPO}/$1")"; printf '%s\n' "$2" >> "${REPO}/$1"; git -C "${REPO}" add "$1"; git -C "${REPO}" commit -qm "$2"; }
hsha() { git -C "${REPO}" rev-parse HEAD; }
short() { git -C "${REPO}" rev-parse --short HEAD; }

# ---- 加任务：编号自增；手写的可以不带编号，写在哪一块前面就排在哪 ----
rt add "给导出加进度条"; code 0 'add'; has 'T1' 'add numbers from T1'
rt add "订单列表分页" "约束：不改接口签名"; code 0 'add with a note'; has 'T2' 'add numbers T2'
grep -qx '## T2 订单列表分页' "${D}/queue.md" || fail 'add writes a ## T<n> block'
grep -qx '约束：不改接口签名' "${D}/queue.md" || fail 'add writes the note under its block'
python3 - "${D}/queue.md" <<'PY'
import sys; p = sys.argv[1]; s = open(p, encoding='utf-8').read(); i = s.index('## T1')
open(p, 'w', encoding='utf-8').write(s[:i] + '## 修一下登录页的超时\n\n' + s[i:])
PY

# ---- next：发第一个没做的；给手写的补编号；记下开始的 sha；任务文本自带交差办法 ----
rt next; code 0 'next issues a task'
has 'TASK T3: 修一下登录页的超时' 'hand-written block goes first and is numbered after the highest ID'
has 'review-task done T3' 'the task text says how to report done'
grep -q "$(hsha)" "${D}/tasks.state" || fail 'start sha recorded in tasks.state'
rt next; code 0 'next again'; has 'TASK T3: 修一下登录页的超时' 'next re-issues the in-progress task so a fresh writer can take over'

# ---- done：编号不对就拒绝；没有提交的任务直接通过；放行模式下停下等人 ----
rt done T1; code 2 'done for a task that is not in progress'
rt done T3; code 8 'done in release mode stops the writer'; has '等人放行' 'release mode says wait for release'
rt next; code 8 'next before release'; has '等人放行' 'next refuses until released'
rt go; code 0 'go'
has '运行 review-task next，按它的输出办' 'go says the sentence a fresh writer needs'
rt go; code 2 'go when nothing waits for release'
rt next; code 0 'next after release'; has 'TASK T1: 给导出加进度条' 'the finished hand-written block is not issued again'

# ---- 以下用自动模式：done 通过就直接发下一个 ----
printf 'TASK_GATE=0\n' >> "${REPO}/.review.conf"
edit a.py 'progress bar'
rt done T1; code 9 'unrouted commits refuse done'; has 'request-review' 'says the commits have not been routed'
printf 'x\n' >> "${REPO}/a.py"; printf 'junk\n' > "${REPO}/scratch.txt"
rt done T1; code 9 'a dirty tracked file refuses done'; has '工作区' 'names the dirty tree'
git -C "${REPO}" checkout -q a.py
printf '%s\nSKIP\n纯文本\ncode\n\nreview\n' "$(hsha)" > "${D}/.triage"
rt done T1; code 0 'triage SKIP at HEAD passes (untracked files do not count)'
has 'TASK T2: 订单列表分页' 'auto mode issues the next task'; has '约束：不改接口签名' 'the task body travels with the task'

# ---- 评审周期还没结束 → 拒绝；闭合在 HEAD → 通过 ----
edit a.py 'pagination'
H=$(hsha); B=$(git -C "${REPO}" rev-parse HEAD~1)
printf 'artifact: a.py\nkind: code\nbase sha: %s\ntarget sha: %s\nround: 1/3\n' "$B" "$H" > "${D}/request.md"
rt done T2; code 9 'request written but not dispatched'
printf '%s\n%s\nrv-pane\n' "$(date +%s)" "$H" > "${D}/.r1.sent"
rt done T2; code 9 'review still running'
printf 'F1 | should\nclaim: x\nevidence: a.py:1\n\nREVIEW-COMPLETE\n' > "${D}/r1-findings.md"
rt done T2; code 9 'findings not answered yet'
printf 'F1 accept — 改\n' > "${D}/r1-responses.md"
rt done T2; code 9 'an accepted finding still needs another round'
printf 'F1 reject — 不同意\n' > "${D}/r1-responses.md"
rt done T2; code 9 'a reject waits for the human'
printf 'F1 | blocking\nclaim: x\nevidence: a.py:1\n\nREVIEW-COMPLETE\n' > "${D}/r1-findings.md"; printf 'F1 defer — 下轮\n' > "${D}/r1-responses.md"
rt done T2; code 9 'a deferred blocking finding waits for the human'
printf 'F1 | should\nclaim: x\nevidence: a.py:1\n\nREVIEW-COMPLETE\n' > "${D}/r1-findings.md"; printf 'F1 defer — 以后\n' > "${D}/r1-responses.md"
rt done T2; code 8 'a cycle closed at HEAD passes'; has '队列空了' 'queue empty after the last pending task'

# ---- 规划者没交付 → 拒绝；开始之后只有评审记录的提交 → 当作过了路由 ----
rt add "清理旧的 feature flag"; rt next; code 0 'next T4'; has 'TASK T4' 'T4 issued'
printf '%s\nfp\npl-pane\n\n\n%s\n' "$(date +%s)" "$(hsha)" > "${D}/.plan.sent"
rt done T4; code 9 'planner has not delivered'
printf 'DIRECT\n边界：只删 flag\nPLAN-COMPLETE\n' > "${D}/plan.md"
edit docs/reviews/timing.md '2026-09-11 | abc1234 | round 1/3 | 60s | code'
rt done T4; code 8 'records-only commits since start count as routed'

# ---- 人用 SKIP_REVIEW 放过的提交不算没审 ----
rt add "补登录接口的回归测试"; rt next; has 'TASK T5' 'T5 issued'
edit a.py 'regression tests'
edit docs/reviews/skipped.md "2026-09-11 | $(short) | 人工免审"
rt done T5; code 8 'commits the human waived count as routed'

# ---- 编了号的任务改标题后仍认得出；正在做的按开始时的原文重发 ----
rt add "订单导出去重"; rt next; has 'TASK T6: 订单导出去重' 'T6 issued'
sed -i '' 's/^## T6 订单导出去重$/## T6 订单导出去重（含历史数据）/' "${D}/queue.md"
rt next; code 0 'next after editing the title'; has 'TASK T6: 订单导出去重' 'in-progress task re-issued from its snapshot'
grep -q '含历史数据' "${TMP}/out" && fail 'an edited in-progress task must not change under the writer'
printf '%s\nSKIP\n-\ncode\n\nreview\n' "$(hsha)" > "${D}/.triage"
rt done T6; code 8 'T6 done'; has '队列空了' 'an ID-matched edited task is not issued again'

# ---- 暂停、放弃、列表 ----
rt add "迁移到新日志库"
rt pause; code 0 'pause'; rt next; code 8 'paused refuses next'; has '暂停' 'says paused'
rt resume; code 0 'resume'; rt next; code 0 'next after resume'; has 'TASK T7' 'T7 issued'
rt drop T7 "和 T2 冲突"; code 0 'drop the current task'
rt next; code 8 'dropped task does not come back'; has '队列空了' 'queue empty after drop'
rt list; code 0 'list'
has '放弃' 'list shows dropped'; has '和 T2 冲突' 'list shows the drop reason'; has 'T5' 'list shows finished tasks'

[ ! -s "${TMP}/herdr.log" ] || { cat "${TMP}/herdr.log"; fail 'review-task must never call herdr'; }
echo 'PASS review-task queue, release gate, read-only done check, pause and drop'
