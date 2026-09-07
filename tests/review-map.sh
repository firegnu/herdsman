#!/usr/bin/env bash
# review-map 冒烟测试：造一个小仓库（两个包、测试、文档、一份归档），断言等级与理由。
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MAP=${REVIEW_MAP_BIN:-${ROOT}/bin/review-map}
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
R="${TMP}/repo"
mkdir -p "$R/src/pkg/core" "$R/src/pkg/util" "$R/src/pkg/untested" "$R/tests" "$R/docs/plans" "$R/docs/notes" "$R/docs/reviews"
printf 'X = 1\n' > "$R/src/pkg/core/a.py"
printf 'from pkg.core import a\n' > "$R/src/pkg/util/b.py"
printf 'from pkg.core import a\nfrom pkg.util import b\n' > "$R/src/pkg/untested/c.py"
printf 'from pkg.core import a\nfrom pkg.util import b\n' > "$R/tests/test_all.py"
printf '# plan\n' > "$R/docs/plans/p.md"
printf '# note\n' > "$R/docs/notes/n.md"
printf '# rules\n' > "$R/AGENTS.md"
cat > "$R/docs/reviews/abc1234.md" <<'EOF'
# Review cycle @ abc1234

归档于 2026-09-01T10:00:00+08:00

## Request

artifact: src/pkg/util/b.py tests/test_all.py
kind: code
round: 1/3

## r1-findings.md

F1 | blocking
claim:    util breaks
evidence: `src/pkg/util/b.py:1`

F2 | nit
claim:    naming
evidence: 没有路径

REVIEW-COMPLETE

## r1-responses.md

F1 accept — fixed
F2 defer — later
EOF
printf '2026-09-01 | abc1234 | round 1/3 | 60s\n' > "$R/docs/reviews/timing.md"

OUT="${TMP}/map"
python3 "${MAP}" "$R" --out "${OUT}" >/dev/null
fail() { echo "FAIL: $*" >&2; cat "${OUT}" >&2; exit 1; }
has() { grep -qE "$1" "${OUT}" || fail "$2"; }

has '^src/pkg/util/\*\*\s+deep\s+# 1 个周期里 1 条阻断' 'blocking evidence → deep'
has '^src/pkg/core/\*\*\s+deep\s+# 被 3 个文件依赖' 'fan-in → deep'
has '^src/pkg/untested/\*\*\s+review\s+# 无测试' 'no tests → review, not lower'
has '^tests/\*\*\s+review' 'tests → review'
has '^docs/plans/\*\*\s+plan' 'plan paths → plan'
has '^AGENTS\.md\s+plan\s+# 规则文件' 'rule file → plan'
has '^docs/notes/\*\*\s+light' 'notes → light'
has '^docs/reviews/\*\*\s+skip' 'archives → skip'
has '2 条带严重度的 finding（其中 1 条 evidence 没写路径' 'unplaced share reported'
# 没写路径的 nit 归到 artifact 的目录：tests/** 也应记到 1 个周期
has '^tests/\*\*\s+review\s+# 测试' 'tests row present'
echo 'PASS review-map derives levels from archives, fan-in and tests'
