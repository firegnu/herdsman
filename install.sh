#!/usr/bin/env bash
# 全局安装（只需一次，所有项目共用）
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${HOME}/.local/bin"
CFG="${HOME}/.config/review"

echo "从 ${SRC} 安装"

mkdir -p "${BIN}" "${CFG}"

install -m 0755 "${SRC}/bin/request-review" "${BIN}/request-review"
install -m 0755 "${SRC}/bin/review-archive" "${BIN}/review-archive"
echo "  ✓ ${BIN}/request-review"
echo "  ✓ ${BIN}/review-archive"

if [ -f "${CFG}/rubric.md" ]; then
  if cmp -s "${SRC}/config/rubric.md" "${CFG}/rubric.md"; then
    echo "  = ${CFG}/rubric.md（无变化）"
  else
    cp "${CFG}/rubric.md" "${CFG}/rubric.md.bak.$(date +%Y%m%d%H%M%S)"
    install -m 0644 "${SRC}/config/rubric.md" "${CFG}/rubric.md"
    echo "  ✓ ${CFG}/rubric.md（旧版已备份为 .bak.*）"
  fi
else
  install -m 0644 "${SRC}/config/rubric.md" "${CFG}/rubric.md"
  echo "  ✓ ${CFG}/rubric.md"
fi

echo
missing=0
for c in jq herdr git; do
  command -v "$c" >/dev/null || { echo "  ✗ 缺少 ${c}"; missing=1; }
done
case ":${PATH}:" in
  *":${BIN}:"*) ;;
  *) echo "  ✗ ${BIN} 不在 PATH 中，请加进 ~/.zshrc"; missing=1;;
esac
[ "${missing}" -eq 0 ] && echo "  ✓ 依赖检查通过"

echo
echo "下一步：在项目目录里运行  herdsman-init <短名>"
install -m 0755 "${SRC}/bin/herdsman-init" "${BIN}/herdsman-init" 2>/dev/null && echo "  ✓ ${BIN}/herdsman-init"
