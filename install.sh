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
install -m 0755 "${SRC}/bin/herdsman-init" "${BIN}/herdsman-init"
install -m 0755 "${SRC}/bin/review-board" "${BIN}/review-board"
install -m 0755 "${SRC}/bin/review-map" "${BIN}/review-map"
echo "  ✓ ${BIN}/request-review"
echo "  ✓ ${BIN}/review-archive"
echo "  ✓ ${BIN}/herdsman-init"
echo "  ✓ ${BIN}/review-board"
echo "  ✓ ${BIN}/review-map"

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

install -m 0644 "${SRC}/templates/agents-section.md" "${CFG}/agents-section.md"
echo "  ✓ ${CFG}/agents-section.md"
install -m 0644 "${SRC}/templates/brief-prompt.md" "${CFG}/brief-prompt.md"
echo "  ✓ ${CFG}/brief-prompt.md"
install -m 0644 "${SRC}/templates/planner-prompt.md" "${CFG}/planner-prompt.md"
echo "  ✓ ${CFG}/planner-prompt.md"

# 看板定时生成（macOS launchd，每 30 秒）；非 macOS 跳过
if [ "$(uname)" = Darwin ]; then
  AGENTS="${HOME}/Library/LaunchAgents"; PLIST="${AGENTS}/dev.herdsman.review-board.plist"
  mkdir -p "${AGENTS}" "${HOME}/.review"
  sed "s|__HOME__|${HOME}|g" "${SRC}/templates/review-board.plist" > "${PLIST}"
  launchctl bootout "gui/$(id -u)/dev.herdsman.review-board" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$(id -u)" "${PLIST}" 2>/dev/null; then
    echo "  ✓ ${PLIST}（每 30 秒生成 ~/.review/board.html）"
  else
    echo "  ✗ launchctl bootstrap 失败：${PLIST}"
  fi
fi

echo
missing=0
for c in jq herdr git python3; do
  command -v "$c" >/dev/null || { echo "  ✗ 缺少 ${c}"; missing=1; }
done
case ":${PATH}:" in
  *":${BIN}:"*) ;;
  *) echo "  ✗ ${BIN} 不在 PATH 中，请加进 ~/.zshrc"; missing=1;;
esac
[ "${missing}" -eq 0 ] && echo "  ✓ 依赖检查通过"

echo
echo "下一步：在项目目录里运行  herdsman-init <短名>"
