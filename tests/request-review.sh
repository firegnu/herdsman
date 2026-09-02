#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REQUEST_REVIEW=${REQUEST_REVIEW:-${ROOT}/bin/request-review}
TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

REPO="${TMP}/repo"
REVIEW_WT="${TMP}/review-wt"
REVIEW_DIR="${TMP}/review-state"
MOCK_BIN="${TMP}/bin"
MOCK_LOG="${TMP}/herdr.log"
mkdir -p "${REPO}" "${REVIEW_DIR}" "${MOCK_BIN}"

git -C "${REPO}" init -q -b main
git -C "${REPO}" config user.name test
git -C "${REPO}" config user.email test@example.com
printf '.review.conf\n' > "${REPO}/.gitignore"
printf 'fixture\n' > "${REPO}/fixture.txt"
git -C "${REPO}" add .gitignore fixture.txt
git -C "${REPO}" commit -qm fixture
git -C "${REPO}" worktree add -q -b review "${REVIEW_WT}"

cat > "${REPO}/.review.conf" <<EOF
REVIEW_KIND=claude
REVIEW_WT=${REVIEW_WT}
REVIEW_DIR=${REVIEW_DIR}
REVIEW_WAIT=0
REVIEW_START_TIMEOUT=4000
EOF
cat > "${REVIEW_DIR}/request.md" <<EOF
artifact: fixture
base sha: $(git -C "${REPO}" rev-parse HEAD)
target sha: $(git -C "${REPO}" rev-parse HEAD)
round: 1/3
EOF

cat > "${MOCK_BIN}/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${MOCK_LOG}"

reviewer() {
  local pane="$1" status="$2" session="${3:-session-review}"
  printf '{"agent":"claude","agent_status":"%s","pane_id":"%s","terminal_id":"term-review","cwd":"%s","foreground_cwd":"/Users/firegnu/.local/share/blender_mcp/mcp","interactive_ready":true,"agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"%s"}}' \
    "${status}" "${pane}" "${MOCK_REVIEW_WT}" "${session}"
}

case "$1 $2" in
  'agent list')
    case "${MOCK_SCENARIO}" in
      new|live)
        printf '{"result":{"agents":['; reviewer reviewer-pane working; printf ']}}\n';;
      changed)
        printf '{"result":{"agents":[{"agent":"codex","agent_status":"working","pane_id":"reviewer-pane","terminal_id":"term-review","cwd":"/other","foreground_cwd":"%s","interactive_ready":true}]}}\n' "${MOCK_REVIEW_WT}";;
      session-changed)
        printf '{"result":{"agents":['; reviewer reviewer-pane working session-other; printf ']}}\n';;
      *) printf '{"result":{"agents":[]}}\n';;
    esac
    ;;
  'agent get')
    case "${MOCK_SCENARIO}:$3" in
      new:reviewer-pane|live:reviewer-pane)
        printf '{"result":{"agent":'; reviewer reviewer-pane idle; printf '}}\n';;
      stale:old-pane)
        printf '{"result":{"agent":{"agent":"claude","agent_status":"working","pane_id":"old-pane","terminal_id":"term-other","cwd":"/Users/firegnu/.local/share/blender_mcp/mcp","foreground_cwd":"/Users/firegnu/.local/share/blender_mcp/mcp","interactive_ready":true}}}\n';;
      stale:new-pane)
        printf '{"result":{"agent":'; reviewer new-pane idle; printf '}}\n';;
      *)
        printf '{"error":{"code":"agent_not_found"}}\n' >&2
        exit 1;;
    esac
    ;;
  'pane get')
    [ "${MOCK_SCENARIO}:$3" = stale:old-pane ] || exit 1
    printf '{"result":{"pane":{"pane_id":"old-pane"}}}\n'
    ;;
  'pane split') printf '{"result":{"pane":{"pane_id":"new-pane"}}}\n';;
  'pane process-info')
    printf '{"result":{"process_info":{"pane_id":"%s","shell_pid":123,"foreground_process_group_id":123,"foreground_processes":[{"pid":123,"name":"bash"}]}}}\n' "$4";;
  'agent start') exit 0;;
  'agent prompt')
    printf '{"result":{"agent":'; reviewer "$3" working; printf '}}\n';;
  *) echo "unexpected herdr call: $*" >&2; exit 1;;
esac
EOF
chmod +x "${MOCK_BIN}/herdr"

fail() {
  echo "FAIL: $*" >&2
  echo "stdout:" >&2; cat "${TMP}/stdout" >&2 || true
  echo "stderr:" >&2; cat "${TMP}/stderr" >&2 || true
  echo "herdr calls:" >&2; cat "${MOCK_LOG}" >&2 || true
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2', got '$1'"
}

call_count() {
  local pattern="$1" count
  count=$(grep -Ec "${pattern}" "${MOCK_LOG}" || true)
  printf '%s' "${count}"
}

run_review() {
  local scenario="$1"
  : > "${MOCK_LOG}"
  set +e
  (
    cd "${REPO}"
    PATH="${MOCK_BIN}:${PATH}" \
      MOCK_LOG="${MOCK_LOG}" MOCK_SCENARIO="${scenario}" MOCK_REVIEW_WT="${REVIEW_WT}" \
      "${REQUEST_REVIEW}"
  ) > "${TMP}/stdout" 2> "${TMP}/stderr"
  RUN_STATUS=$?
  set -e
}

SENT="${REVIEW_DIR}/.r1.sent"
PANE_CACHE="${REVIEW_DIR}/.pane"

# A new request finds the reviewer by stable cwd even when foreground_cwd is wrong.
run_review new
assert_eq "${RUN_STATUS}" 3 'new dispatch status'
assert_eq "$(call_count '^pane split ')" 0 'new dispatch split count'
assert_eq "$(call_count '^agent start ')" 0 'new dispatch start count'
assert_eq "$(call_count '^agent prompt reviewer-pane ')" 1 'new dispatch prompt count'
assert_eq "$(sed -n '4p' "${SENT}")" term-review 'saved terminal identity'
assert_eq "$(sed -n '5p' "${SENT}")" '{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-review"}' 'saved session identity'
cp "${SENT}" "${TMP}/sent-with-identity"
echo 'PASS new request dispatches once using stable cwd'

# A sent round resumes the saved reviewer and never discovers, creates, or prompts again.
printf 'partial findings\n' > "${REVIEW_DIR}/r1-findings.md"
run_review live
assert_eq "${RUN_STATUS}" 3 'continuation status'
assert_eq "$(call_count '^pane split ')" 0 'continuation split count'
assert_eq "$(call_count '^agent start ')" 0 'continuation start count'
assert_eq "$(call_count '^agent prompt ')" 0 'continuation prompt count'
[ -f "${SENT}" ] || fail 'continuation archived its sent marker'
echo 'PASS sent round reuses saved reviewer without redispatch'

# Existing three-line markers remain resumable, but still validate kind and stable cwd.
sed -n '1,3p' "${SENT}" > "${TMP}/legacy-sent"
mv "${TMP}/legacy-sent" "${SENT}"
run_review live
assert_eq "${RUN_STATUS}" 3 'legacy continuation status'
assert_eq "$(call_count '^pane split ')" 0 'legacy continuation split count'
assert_eq "$(call_count '^agent start ')" 0 'legacy continuation start count'
assert_eq "$(call_count '^agent prompt ')" 0 'legacy continuation prompt count'
cp "${TMP}/sent-with-identity" "${SENT}"
echo 'PASS legacy sent round reuses reviewer by stable cwd without redispatch'

# A missing, replaced, or different-session saved reviewer fails closed.
for scenario in disappeared changed session-changed; do
  run_review "${scenario}"
  assert_eq "${RUN_STATUS}" 4 "${scenario} continuation status"
  assert_eq "$(call_count '^pane split ')" 0 "${scenario} split count"
  assert_eq "$(call_count '^agent start ')" 0 "${scenario} start count"
  assert_eq "$(call_count '^agent prompt ')" 0 "${scenario} prompt count"
  echo "PASS sent round fails closed when reviewer is ${scenario}"
done

# Before dispatch, a genuinely stale cache is still replaced exactly once.
rm -f "${SENT}"
printf 'old-pane' > "${PANE_CACHE}"
run_review stale
assert_eq "${RUN_STATUS}" 3 'stale cache dispatch status'
assert_eq "$(call_count '^pane split ')" 1 'stale cache split count'
assert_eq "$(call_count '^agent start .*--pane new-pane ')" 1 'stale cache start count'
assert_eq "$(call_count '^agent prompt new-pane ')" 1 'stale cache prompt count'
assert_eq "$(call_count '^agent \(start\|prompt\).*old-pane')" 0 'stale occupant action count'
assert_eq "$(cat "${PANE_CACHE}")" new-pane 'stale cache replacement'
echo 'PASS unsent stale cache creates one new reviewer without touching old occupant'
