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
mk alpha; mk beta; mk gamma; mk delta
now=$(date +%s)

# 假 herdr：beta 的评审方 blocked，gamma 的在 working，其余 pane 不存在
cat > "${TMP}/herdr" <<'MOCK'
#!/usr/bin/env bash
case "$1 $2 $3" in
  'agent get beta-pane')  printf '{"result":{"agent":{"agent_status":"blocked"}}}\n';;
  'agent get gamma-pane') printf '{"result":{"agent":{"agent_status":"working"}}}\n';;
  *) printf '{"error":{"code":"agent_not_found"}}\n' >&2; exit 1;;
esac
MOCK
chmod +x "${TMP}/herdr"

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

REVIEW-COMPLETE
EOF
printf 'F1 accept — 已补\nF2 reject — 实测有据\nF3 defer — 下轮再改\n' > "$D/r1-responses.md"

# beta：round 1 已派发、findings 未完成 → 评审中
H=$(git -C "${TMP}/beta/repo" rev-parse HEAD); B=$(git -C "${TMP}/beta/repo" rev-parse HEAD~1)
D="${TMP}/beta/review"
printf 'artifact: a.py\nkind: code\nbase sha: %s\ntarget sha: %s\nround: 1/3\n' "$B" "$H" > "$D/request.md"
cp "$D/request.md" "$D/.cycle-request.md"
printf '%s\n%s\nbeta-pane\n' "$((now - 240))" "$H" > "$D/.r1.sent"

# delta：round 1 已完成且写手已回应、无 accepted 改动 → 闭合未归档，页面上收成一行
H=$(git -C "${TMP}/delta/repo" rev-parse HEAD); B=$(git -C "${TMP}/delta/repo" rev-parse HEAD~1)
D="${TMP}/delta/review"
printf 'artifact: a.py\nkind: code\nbase sha: %s\ntarget sha: %s\nround: 1/3\n' "$B" "$H" > "$D/request.md"
cp "$D/request.md" "$D/.cycle-request.md"
printf '%s\n%s\ndelta-pane\n' "$((now - 600))" "$H" > "$D/.r1.sent"
printf 'F1 | nit\nclaim:    命名\nevidence: a.py:1\n\nREVIEW-COMPLETE\n' > "$D/r1-findings.md"
printf 'F1 defer — 以后\n' > "$D/r1-responses.md"

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

printf '%s/alpha/repo\n%s/beta/repo\n%s/gamma/repo\n%s/delta/repo\n# comment\n%s/nonexistent\n' "${TMP}" "${TMP}" "${TMP}" "${TMP}" "${TMP}" > "${TMP}/projects"
HERDR_BIN_PATH="${TMP}/herdr" python3 "${BOARD}" --projects "${TMP}/projects" --out "${OUT}" >/dev/null

# 项目发现与去重命名（三个 checkout 都叫 repo，用上级目录区分）
for n in alpha beta gamma delta; do has "data-p=\"$n/repo\"" "project $n listed"; done
has '项目 · 4' 'project count'

# 状态
has '待人裁决' 'alpha state'
has '评审中' 'beta state'
has 'triage 中' 'gamma state'
has 'prompt 已送达，等评审方写 findings' 'beta cycle note'
has '写手 reject 了 F2、defer 了 F3，等人裁决' 'alpha cycle note'

# 评审方状态：beta blocked → 等你 + STOP；gamma working → 备注
has '评审中 · 评审方 blocked' 'beta blocked state'
has 'STOP · 评审方停在审批或提问对话框，去看 pane beta-pane' 'banner stop item'
has 'href="#p-beta/repo"' 'stop item links to project'
has '评审方 working' 'gamma working note'

# 横幅：两条裁决 + 一条 STOP；alpha 排在最前
has '等你 · 3' 'banner count'
has 'F2 nit · 写手 reject' 'banner reject item'
has 'F3 blocking · 写手 defer' 'banner blocking-defer item'
has 'id="f-alpha/repo-F2"' 'finding anchor'
[ "$(grep -o 'class="proj[^"]*" data-p="[^"]*"' "${OUT}" | head -1)" = 'class="proj needs" data-p="alpha/repo"' ] || fail 'alpha not first in sidebar'

# finding 表：三种回应、待裁决标记、evidence
has 'class="verb accept"' 'accept verb'
has 'class="verb reject"' 'reject verb'
has 'class="verb defer"' 'defer verb'
has '等你裁决' 'pending decision cell'
has '<details class="ev"><summary>evidence</summary><code class="evid">docs/x.json:8' 'evidence folded'
has 'class="frow pend"' 'pending row tint'
has '评审中，findings 尚未完成' 'unfinished round note'
has '回应 ' 'round timing shown'

# delta：闭合未归档 → 折叠成一行摘要
has '<details class="prev"><summary>' 'closed cycle collapsed'
has '1 轮</span><span>1 defer</span>' 'collapsed summary counts'
lacks 'class="cycle stale"' 'old stale styling gone'

# request 字段与 diff
has 'class="chip">tests/test_a.py' 'artifact chips'
has '1 file changed, 1 insertion(+)' 'diff stat'
has '写手自述</div><div><details class="desc">' 'writer self-description folded'
has '3 条 · 1 blocking · 1 should · 1 nit' 'round summary without zeros'
has '<span class="d-add">+b = 1</span>' 'diff add line coloured'
has 'class="d-hunk">@@' 'diff hunk coloured'

# 归档、Backlog、自闭合
has '<code>abc1234</code>' 'archive row'
has '1m35s' 'archive duration from timing.md'
has '留到以后' 'backlog reason'
has '<span class="who">写手</span>' 'backlog stacked layout'
has '历史归档中 defer 的 finding · 1 条 · 1 个周期' 'backlog count'
has '<details class="bgrp" open><summary class="bhead" title="a.py">' 'newest backlog group open'
has 'class="filter" type="search"' 'backlog filter box'
has '<code>def5678</code>' 'self-closed row'
has '最近 1 条：1 条纯文本' 'self-closed summary line'
has '只改了 .md' 'self-closed reason'

# 不接触真实项目
lacks 'jb-finetune' 'real project leaked into fixture board'
lacks '~/Developer' 'default discovery used'

# 默认输出路径：--out 未给时写到 ~/.review/board.html —— 不在测试里跑，避免碰真实目录
echo 'PASS review-board renders states, banner, findings, backlog, archives, self-closed'
