#!/usr/bin/env bash
# review-board 冒烟测试：造三个仓库覆盖 待人裁决 / 评审中 / triage 中，再造一份归档，
# 断言生成的 HTML 里状态、横幅、finding 行、Backlog、归档、自闭合都在，且不接触真实项目。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BOARD=${REVIEW_BOARD_BIN:-${ROOT}/bin/review-board}
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
OUT="${TMP}/board.html"

fail() { echo "FAIL: $*" >&2; exit 1; }
has() { grep -qF -e "$1" "${OUT}" || fail "$2 (missing: $1)"; }
lacks() { grep -qF -e "$1" "${OUT}" && fail "$2 (unexpected: $1)"; return 0; }

mk() {   # <name>：两个提交的仓库 + .review.conf + 交接目录
  local n="$1" r; r="${TMP}/$1/repo"
  mkdir -p "$r" "${TMP}/$n/review"
  git -C "$r" init -q -b main
  git -C "$r" config user.name t; git -C "$r" config user.email t@example.com
  printf 'a\n' > "$r/a.py"; git -C "$r" add .; git -C "$r" commit -qm base
  printf 'a\nb = 1\n' > "$r/a.py"; git -C "$r" add .; git -C "$r" commit -qm change
  printf 'REVIEW_KIND=claude\nREVIEW_WT=%s\nREVIEW_DIR=%s\n' "$r" "${TMP}/$n/review" > "$r/.review.conf"
}
mk alpha; mk beta; mk gamma; mk delta; mk epsilon; mk zeta
now=$(date +%s)

# 假 herdr：beta 的评审方 blocked，gamma 的在 working，其余 pane 不存在
cat > "${TMP}/herdr" <<'MOCK'
#!/usr/bin/env bash
case "$1 $2 $3" in
  'agent get beta-pane')  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n';;
  'agent get gamma-pane') printf '{"result":{"agent":{"agent_status":"working"}}}\n';;
  'agent get eps-plan')   printf '{"result":{"agent":{"agent_status":"working"}}}\n';;
  'agent list ') printf '{"result":{"agents":[{"agent":"codex","agent_status":"working","cwd":"%s","pane_id":"alpha-writer","terminal_title_stripped":"repo"},{"agent":"claude","agent_status":"working","cwd":"%s","pane_id":"gamma-pane","terminal_title_stripped":"Triage request"},{"agent":"claude","agent_status":"working","cwd":"%s","pane_id":"eps-plan","name":"pl-repo-","terminal_title_stripped":"Plan request"},{"agent":"codex","agent_status":"blocked","cwd":"%s","pane_id":"zeta-writer","terminal_title_stripped":"repo"}]}}\n' "${MOCK_ALPHA}" "${MOCK_GAMMA}" "${MOCK_EPS}" "${MOCK_ZETA}";;
  'agent read eps-plan') printf '✻ Drafting… (2m 01s · esc to interrupt)\n';;
  'agent read alpha-writer') printf 'some output\n• Working (12m 03s • esc to interrupt)\n\n› Ask Codex\n';;
  'agent read gamma-pane') printf '✻ Reviewing diff… (3m 10s · esc to interrupt)\n\n❯\n';;
  *) printf '{"error":{"code":"agent_not_found"}}\n' >&2; exit 1;;
esac
MOCK
chmod +x "${TMP}/herdr"
export MOCK_ALPHA="${TMP}/alpha/repo" MOCK_GAMMA="${TMP}/gamma/repo" MOCK_EPS="${TMP}/epsilon/repo" MOCK_ZETA="${TMP}/zeta/repo"
# alpha 的评审 worktree 另在别处，这样 cwd 是仓库的 agent 才算写手
sed -i '' "s|^REVIEW_WT=.*|REVIEW_WT=${TMP}/alpha/wt|" "${TMP}/alpha/repo/.review.conf"
sed -i '' "s|^REVIEW_WT=.*|REVIEW_WT=${TMP}/zeta/wt|" "${TMP}/zeta/repo/.review.conf"
printf 'REVIEW_AGENT_ARGS="--model claude-opus-5"\n' >> "${TMP}/alpha/repo/.review.conf"
printf 'PLAN_KIND=codex\nPLAN_AGENT_ARGS='"'"'--dangerously-bypass-approvals-and-sandbox -c model_reasoning_effort="high"'"'"'\n' >> "${TMP}/epsilon/repo/.review.conf"

# alpha：round 2 的 request 指向 HEAD，r1 里 F2 reject、F3(blocking) defer，无裁决 → 待人裁决
H=$(git -C "${TMP}/alpha/repo" rev-parse HEAD); B=$(git -C "${TMP}/alpha/repo" rev-parse HEAD~1)
D="${TMP}/alpha/review"
printf 'artifact: a.py tests/test_a.py\nkind: code\nbase sha: %s\ntarget sha: %s\nround: 2/3\nout of scope: no perf work\nrisk areas: key construction\nchecks: pytest -q\n' "$B" "$H" > "$D/request.md"
sed 's|round: 2/3|round: 1/3|' "$D/request.md" > "$D/.cycle-request.md"
printf '%s\n%s\npane\n' "$((now - 2280))" "$H" > "$D/.r1.sent"
cat > "$D/r1-findings.md" <<'EOF'
# r1

## Findings

F1 | should
claim:    receipt 检查缺失
evidence: a.py:2

F2 | nit
claim:    RSS 文案无据
evidence: docs/x.json:8

F3 | blocking
claim:    聚合上限未回显
evidence: a.py:1

## 过程
读了 a.py 全文和 tests/test_a.py；跑了 pytest -q，12 passed；没有查性能。

REVIEW-COMPLETE
EOF
printf 'F1 accept — 已补\nF2 reject — 实测有据\nF3 defer — 下轮再改\n' > "$D/r1-responses.md"

# beta：round 1 已派发、findings 未完成 → 评审中
H=$(git -C "${TMP}/beta/repo" rev-parse HEAD); B=$(git -C "${TMP}/beta/repo" rev-parse HEAD~1)
D="${TMP}/beta/review"
printf 'artifact: a.py\nkind: code\nbase sha: %s\ntarget sha: %s\nround: 1/3\n' "$B" "$H" > "$D/request.md"
cp "$D/request.md" "$D/.cycle-request.md"
printf '%s\n%s\nbeta-pane\n' "$((now - 240))" "$H" > "$D/.r1.sent"
printf '2 %s\n' "$((now - 120))" > "$D/.last"
printf 'NOTE: something\nERROR: request 的 kind 是 plan，但脚本对这个 HEAD 的路由判定是 code。\n' > "$D/.last.out"

# delta：round 1 已完成且写手已回应、无 accepted 改动 → 闭合未归档，页面上收成一行
H=$(git -C "${TMP}/delta/repo" rev-parse HEAD); B=$(git -C "${TMP}/delta/repo" rev-parse HEAD~1)
D="${TMP}/delta/review"
printf 'artifact: a.py\nkind: code\nbase sha: %s\ntarget sha: %s\nround: 1/3\n' "$B" "$H" > "$D/request.md"
cp "$D/request.md" "$D/.cycle-request.md"
printf '%s\n%s\ndelta-pane\n' "$((now - 600))" "$H" > "$D/.r1.sent"
printf 'F1 | nit\nclaim:    命名\nevidence: a.py:1\n\nREVIEW-COMPLETE\n' > "$D/r1-findings.md"
printf 'F1 defer — 以后\n' > "$D/r1-responses.md"
# epsilon：plan-request 已发给规划者，plan.md 还没写完 → 规划中
D="${TMP}/epsilon/review"
printf 'task: 做 M5，把矢量整饰产品化\nconstraints: 不改 WorldProposal\n' > "$D/plan-request.md"
printf '%s\nfingerprint\neps-plan\n' "$((now - 121))" > "$D/.plan.sent"

# delta 有简报，核实于 HEAD~1，上限 50 → 之后 1 个提交
mkdir -p "${TMP}/delta/repo/docs"
printf '<!-- verified at: %s -->\n# brief\n' "$(git -C "${TMP}/delta/repo" rev-parse HEAD~1)" > "${TMP}/delta/repo/docs/reviewer-brief.md"
# delta 还有一次更早的 code 评审（target = HEAD~1）：HEAD 之后没路由 → 累积 1 个、1 个未经路由
mkdir -p "${TMP}/delta/repo/docs/reviews"
printf '2026-09-01 | %s | round 1/3 | 60s\n' "$(git -C "${TMP}/delta/repo" rev-parse --short HEAD~1)" > "${TMP}/delta/repo/docs/reviews/timing.md"

# gamma：没有 request，.triage.sent 指向 HEAD 且 triage.md 未完成 → triage 中；另有一份归档和自闭合记录
H=$(git -C "${TMP}/gamma/repo" rev-parse HEAD)
D="${TMP}/gamma/review"
printf '%s\n%s\ngamma-pane\n' "$((now - 60))" "$H" > "$D/.triage.sent"
mkdir -p "${TMP}/gamma/repo/docs/reviews"
cat > "${TMP}/gamma/repo/docs/reviews/abc1234.md" <<'EOF'
# Review cycle @ abc1234

归档于 2026-09-01T10:00:00+08:00

## Request

artifact: a.py
kind: code
base sha: 0000000
target sha: abc1234
round: 1/3

## r1-findings.md

F1 | should
claim:    旧问题
evidence: a.py:1

F2 | nit
claim:    命名
evidence: a.py:2

REVIEW-COMPLETE

## r1-responses.md

F1 accept — 已改
F2 defer — 留到以后
EOF
printf '2026-09-01 | abc1234 | round 1/3 | 95s\n' > "${TMP}/gamma/repo/docs/reviews/timing.md"
printf '# 自行闭合记录\n\n2026-09-02 | def5678 | 纯文本 | 只改了 .md\n' > "${TMP}/gamma/repo/docs/reviews/self-closed.md"

# 「等你」栏的新信号 —— alpha：写手 exit 5 已由待裁决解释，不重复列；.wake 坏了（pid 不是数字），不能把整页弄崩
printf '5 %s\n' "$((now - 30))" > "${TMP}/alpha/review/.last"
printf 'STOP: round 1 有待人工裁决的 finding\n' > "${TMP}/alpha/review/.last.out"
printf 'x\nREVIEW-COMPLETE\nr\nalpha-bad\nt\ns\nm\nabc\n' > "${TMP}/alpha/review/.wake"
# epsilon：唤醒进程还活着（pid 是测试 shell 自己）→ 不报
printf '%s\nPLAN-COMPLETE\neps-plan\neps-writer\nt\ns\nm\n%s\n' "${TMP}/epsilon/review/plan.md" "$$" > "${TMP}/epsilon/review/.wake"
# zeta：写手卡在审批对话框（假 herdr 里 blocked）；唤醒进程已死，.wake.log 留下了原因；写手上次 exit 4
D="${TMP}/zeta/review"
sleep 0 & DEAD=$!; wait "${DEAD}" || true
printf '%s\nREVIEW-COMPLETE\nzeta-rv\nzeta-writer\nt\ns\nm\n%s\n' "$D/r1-findings.md" "${DEAD}" > "$D/.wake"
printf '2026-09-11 10:00:00 [%s] 开始：等 r1-findings.md 出现 REVIEW-COMPLETE\n2026-09-11 10:05:00 [%s] 写手 pane zeta-writer 换了 terminal（记的 t，现在 u）\n2026-09-11 10:05:00 [%s] 没叫醒，标记留给人\n' "${DEAD}" "${DEAD}" "${DEAD}" > "$D/.wake.log"
printf '4 %s\n' "$((now - 45))" > "$D/.last"
printf 'STOP: 无法确认 pane zeta-rv 的评审方身份\n' > "$D/.last.out"

printf '%s/alpha/repo\n%s/beta/repo\n%s/gamma/repo\n%s/delta/repo\n%s/epsilon/repo\n%s/zeta/repo\n# comment\n%s/nonexistent\n' "${TMP}" "${TMP}" "${TMP}" "${TMP}" "${TMP}" "${TMP}" "${TMP}" > "${TMP}/projects"
HERDR_BIN_PATH="${TMP}/herdr" python3 "${BOARD}" --projects "${TMP}/projects" --out "${OUT}" >/dev/null

# 项目发现与去重命名（三个 checkout 都叫 repo，用上级目录区分）
for n in alpha beta gamma delta epsilon zeta; do has "data-p=\"$n/repo\"" "project $n listed"; done
has '项目 · 6' 'project count'
has '<div class="mast"><span class="brand">Review board</span>' 'masthead'
has '<b>写手</b> codex ·' 'writer agent line'
grep -qE '<b>规划者</b> codex · [^<]+ · high</span>' "${OUT}" || fail 'planner agent line with effort override'
has '<b>评审方</b> claude · claude-opus-5 ·' 'reviewer agent line with model override'
has '<b>评审方</b> claude ·' 'reviewer agent line'
has 'class="cycle s-me"' 'cycle card bar coloured by state'

# 状态
has '待人裁决' 'alpha state'
has '评审中' 'beta state'
has 'triage 中' 'gamma state'
has 'prompt 已送达，等评审方写 findings' 'beta cycle note'
has '写手拒绝了 F2、暂缓了 F3，等人裁决' 'alpha cycle note'

# 评审方状态：beta blocked → 等你 + STOP；gamma working → 备注
has '<span class="badge me">评审中 · 评审方 blocked</span>' 'beta blocked state red'
has '<span class="badge rv">triage 中</span>' 'gamma waiting on reviewer blue'
has '<span class="badge none">已闭合</span>' 'delta closed grey'
has 'STOP · 评审方停在审批或提问对话框，去看 pane beta-pane' 'banner stop item'
has 'href="#w-beta/repo"' 'stop item jumps to the project 等你 section'
# 活动条：写手/评审方在干什么，来自 herdr agent list 的状态与标题，working 时再读 pane 最后那句
has '<span class="dot st-working"></span><b>写手</b><span class="st st-working">working</span><span class="act">Working (12m 03s)</span>' 'alpha writer chip with activity'
has '<b>评审方</b><span class="st st-working">working</span><span class="ttl">Triage request</span><span class="act">Reviewing diff… (3m 10s)</span>' 'gamma reviewer chip with title and activity'
# 写手上次停下的运行：退出码、多久前、ERROR 那行；exit 0/3 不显示
has '<b>上次运行 request-review：exit 2</b>' 'last run shown'
has 'ERROR: request 的 kind 是 plan' 'last run headline'
# evidence 的 path:line 链到 zed
has 'href="zed://file' 'evidence zed link'
# 规划中：状态、等规划者、任务一行、规划者芯片
has '<span class="badge pl">规划中</span>' 'epsilon planning badge'
has '<b>规划中</b>' 'planning line'
has '做 M5，把矢量整饰产品化' 'planning task shown'
has '<b>规划者</b><span class="st st-working">working</span><span class="ttl">Plan request</span><span class="act">Drafting… (2m 01s)</span>' 'planner chip'
# 「过程」一节折叠显示
has '评审方怎么看的' 'process fold present'
has '跑了 pytest -q，12 passed' 'process text shown'

# 横幅：两条裁决 + 一条 STOP；alpha 排在最前
has '等你 · 7' 'banner count: alpha 2 + beta 2 + zeta 3'
has 'F2 细节 · 写手拒绝' 'banner reject item'
has 'F3 阻断 · 写手暂缓' 'banner blocking-defer item'
has 'id="f-alpha/repo-F2"' 'finding anchor'
seen_plain=0
for c in $(grep -o 'class="proj[^"]*" data-p' "${OUT}" | sed 's/class="proj needs" data-p/needs/;s/class="proj" data-p/plain/'); do
  if [ "$c" = plain ]; then seen_plain=1; elif [ "${seen_plain}" = 1 ]; then fail 'a project that needs you sorted after a quiet one'; fi
done

# finding 表：三种回应、待裁决标记、evidence
has '<span class="verb accept" title="accept">接受</span>' 'accept verb translated with tooltip'
has 'class="verb reject"' 'reject verb'
has 'class="verb defer"' 'defer verb'
has '等你裁决' 'pending decision cell'
has '<span class="evbtn">evidence</span><code class="evteaser">docs/x.json:8</code>' 'evidence fold with teaser'
has 'class="frow pend"' 'pending row tint'
has '评审中，findings 尚未完成' 'unfinished round note'
has '回应 ' 'round timing shown'

# delta：闭合未归档 → 折叠成一行摘要
has '<details class="prev"><summary>' 'closed cycle collapsed'
has '1 轮</span><span>1 暂缓</span>' 'collapsed summary counts'
has '以来 <b>1</b> 个提交 · 0 个 SKIP · <b>1 个未经路由</b>' 'accumulation counter'
has '尚无已完成的代码评审' 'no-review accumulation note'
has '没有 .review-map，代码路径全部由评审方 triage' 'no-map note'
has '简报核实于 <code>' 'brief status line'
has '之后 1 个提交，上限 50' 'brief commit count'
lacks 'class="cycle stale"' 'old stale styling gone'

# request 字段与 diff
has 'class="chip">tests/test_a.py' 'artifact chips'
has '<div class="title">change</div>' 'commit subject as cycle title'
has '1 file changed, 1 insertion(+)' 'diff stat'
has '写手自述</div><div><details class="desc">' 'writer self-description folded'
has '3 条 · 1 阻断 · 1 应改 · 1 细节' 'round summary without zeros'
has '<span class="d-add">+b = 1</span>' 'diff add line coloured'
has 'class="d-hunk">@@' 'diff hunk coloured'

# 归档、Backlog、自闭合
has '<code>abc1234</code>' 'archive row'
has '1m35s' 'archive duration from timing.md'
has '留到以后' 'backlog reason'
has '<span class="who">写手</span>' 'backlog stacked layout'
has '暂缓清单<span class="sub">评审方指出、写手承认但没改的 · 1 条 · 1 个周期' 'backlog count'
has '<details class="bgrp" open><summary class="bhead" title="a.py">' 'newest backlog group open'
has 'class="filter" type="search"' 'backlog filter box'
has '<code>def5678</code>' 'self-closed row'
has '最近 1 条：1 条纯文本' 'self-closed summary line'
has '只改了 .md' 'self-closed reason'

# 「等你」栏：每个项目一栏，横幅只是汇总
has 'id="w-beta/repo"' 'beta has its own 等你 section'
has '写手停下 · exit 2 · ERROR: request 的 kind 是 plan' 'writer exit 2 listed as waiting on you'
lacks '写手停下 · exit 5' 'exit 5 already explained by pending decisions is not repeated'
has '写手停在审批或提问对话框，去看 pane zeta-writer' 'blocked writer listed'
has '写手停下 · exit 4 · STOP: 无法确认 pane zeta-rv 的评审方身份' 'writer exit 4 listed'
has '叫醒进程已不在' 'dead waker listed'
has '写手 zeta-writer 不会被自动叫醒' 'dead waker names the writer'
has '写手 pane zeta-writer 换了 terminal' 'dead waker shows its last reason from .wake.log'
lacks '写手 eps-writer' 'a live waker is not reported'
lacks 'alpha-bad' 'a malformed marker is ignored, not rendered'
has 'class="proj needs" data-p="zeta/repo"' 'zeta highlighted in the sidebar'

# 不接触真实项目
lacks 'jb-finetune' 'real project leaked into fixture board'
lacks '~/Developer' 'default discovery used'

# 默认输出路径：--out 未给时写到 ~/.review/board.html —— 不在测试里跑，避免碰真实目录
echo 'PASS review-board renders states, banner, findings, backlog, archives, self-closed'
