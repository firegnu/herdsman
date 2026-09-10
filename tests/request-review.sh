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
REVIEW_BOARD=
REVIEW_BRIEF=
EOF
# write_request <kind> <base> <round>; artifact/target are fixed to the fixture and HEAD.
write_request() {
  cat > "${REVIEW_DIR}/request.md" <<EOF
artifact: fixture
kind: $1
base sha: $2
target sha: $(git -C "${REPO}" rev-parse HEAD)
round: $3
EOF
}
write_request code "$(git -C "${REPO}" rev-parse HEAD)" 1/3

cat > "${MOCK_BIN}/herdr" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${MOCK_LOG}"

reviewer() {
  local pane="$1" status="$2" session="${3:-session-review}"
  printf '{"agent":"claude","agent_status":"%s","pane_id":"%s","terminal_id":"term-review","cwd":"%s","foreground_cwd":"/Users/firegnu/.local/share/blender_mcp/mcp","interactive_ready":true,"agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"%s"}}' \
    "${status}" "${pane}" "${MOCK_REVIEW_WT}" "${session}"
}

planner() {
  local pane="$1" status="$2"
  printf '{"agent":"claude","agent_status":"%s","pane_id":"%s","terminal_id":"term-plan","name":"pl-repo-","cwd":"%s","foreground_cwd":"%s","interactive_ready":true,"agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"session-plan"}}' \
    "${status}" "${pane}" "${MOCK_REPO}" "${MOCK_REPO}"
}
writer() {  # 写手和规划者同目录、没有名字：按目录找会撞上它
  printf '{"agent":"codex","agent_status":"working","pane_id":"writer-pane","terminal_id":"term-writer","cwd":"%s","foreground_cwd":"%s","interactive_ready":true}' "${MOCK_REPO}" "${MOCK_REPO}"
}
writer_at() {  # $1=状态 $2=terminal_id（省略即 term-writer）
  printf '{"agent":"codex","agent_status":"%s","pane_id":"writer-pane","terminal_id":"%s","cwd":"%s","foreground_cwd":"%s","interactive_ready":true}' \
    "$1" "${2:-term-writer}" "${MOCK_REPO}" "${MOCK_REPO}"
}

case "$1 $2" in
  'agent list')
    case "${MOCK_SCENARIO}" in
      new|live|lost-once|lost|stalled-working)
        printf '{"result":{"agents":['; reviewer reviewer-pane working; printf ']}}\n';;
      plan-new)
        printf '{"result":{"agents":['; writer; printf ']}}\n';;
      plan-live)
        printf '{"result":{"agents":['; writer; printf ','; planner new-pane working; printf ']}}\n';;
      plan-idle)
        printf '{"result":{"agents":['; writer; printf ','; planner new-pane idle; printf ']}}\n';;
      changed)
        printf '{"result":{"agents":[{"agent":"codex","agent_status":"working","pane_id":"reviewer-pane","terminal_id":"term-review","cwd":"/other","foreground_cwd":"%s","interactive_ready":true}]}}\n' "${MOCK_REVIEW_WT}";;
      session-changed)
        printf '{"result":{"agents":['; reviewer reviewer-pane working session-other; printf ']}}\n';;
      *) printf '{"result":{"agents":[]}}\n';;
    esac
    ;;
  'agent get')
    case "${MOCK_SCENARIO}:$3" in
      new:reviewer-pane|live:reviewer-pane|lost-once:reviewer-pane|lost:reviewer-pane)
        printf '{"result":{"agent":'; reviewer reviewer-pane idle; printf '}}\n';;
      stalled-working:reviewer-pane)
        # idle until a prompt has been sent, then working even though herdr said stalled
        if [ "$(grep -c '^agent prompt ' "${MOCK_LOG}")" -eq 0 ]; then
          printf '{"result":{"agent":'; reviewer reviewer-pane idle; printf '}}\n'
        else
          printf '{"result":{"agent":'; reviewer reviewer-pane working; printf '}}\n'
        fi;;
      stale:old-pane)
        printf '{"result":{"agent":{"agent":"claude","agent_status":"working","pane_id":"old-pane","terminal_id":"term-other","cwd":"/Users/firegnu/.local/share/blender_mcp/mcp","foreground_cwd":"/Users/firegnu/.local/share/blender_mcp/mcp","interactive_ready":true}}}\n';;
      stale:new-pane)
        printf '{"result":{"agent":'; reviewer new-pane idle; printf '}}\n';;
      plan-new:new-pane|plan-idle:new-pane)
        if [ "$(grep -c '^agent prompt ' "${MOCK_LOG}")" -eq 0 ]; then
          printf '{"result":{"agent":'; planner new-pane idle; printf '}}\n'
        else
          printf '{"result":{"agent":'; planner new-pane working; printf '}}\n'
        fi;;
      plan-live:new-pane)
        printf '{"result":{"agent":'; planner new-pane working; printf '}}\n';;
      wake:writer-pane)        # 写手闲着，可以叫醒
        printf '{"result":{"agent":'; writer_at idle; printf '}}\n';;
      wake-drift:writer-pane)  # pane 还在，但已换了别的 terminal
        printf '{"result":{"agent":'; writer_at idle term-other; printf '}}\n';;
      wake:reviewer-pane|wake-drift:reviewer-pane)
        printf '{"result":{"agent":'; reviewer reviewer-pane idle; printf '}}\n';;
      *:writer-pane)
        printf '{"result":{"agent":'; writer; printf '}}\n';;
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
    # lost-once: the first prompt lands in the agent's startup window and never registers;
    # lost: no prompt ever registers. herdr reports both as agent_prompt_stalled.
    if [ "${MOCK_SCENARIO}" = lost ] || [ "${MOCK_SCENARIO}" = stalled-working ] \
      || { [ "${MOCK_SCENARIO}" = lost-once ] && [ "$(grep -c '^agent prompt ' "${MOCK_LOG}")" -eq 1 ]; }; then
      printf '{"error":{"code":"agent_prompt_stalled"}}\n' >&2; exit 1
    fi
    case "${MOCK_SCENARIO}" in
      plan-*) printf '{"result":{"agent":'; planner "$3" working; printf '}}\n';;
      *) printf '{"result":{"agent":'; reviewer "$3" working; printf '}}\n';;
    esac;;
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
  local scenario="$1"; shift
  : > "${MOCK_LOG}"
  set +e
  (
    cd "${REPO}"
    PATH="${MOCK_BIN}:${PATH}" \
      MOCK_LOG="${MOCK_LOG}" MOCK_SCENARIO="${scenario}" MOCK_REVIEW_WT="${REVIEW_WT}" MOCK_REPO="$(cd "${REPO}" && pwd -P)" \
      HERDR_PANE_ID=writer-pane \
      "${REQUEST_REVIEW}" "$@"
  ) > "${TMP}/stdout" 2> "${TMP}/stderr"
  RUN_STATUS=$?
  set -e
}

SENT="${REVIEW_DIR}/.r1.sent"
PANE_CACHE="${REVIEW_DIR}/.pane"
SELF_CLOSED="${REPO}/docs/reviews/self-closed.md"
TRIAGE_OUT="${REVIEW_DIR}/triage.md"

commit_file() {   # <path> <message>
  mkdir -p "$(dirname "${REPO}/$1")"; printf '%s\n' "$2" > "${REPO}/$1"
  git -C "${REPO}" add "$1"; git -C "${REPO}" commit -qm "$2"
}

# ---- Routing: without a request for HEAD the script triages the commit itself. ----

# A text-only commit is skipped mechanically, without asking the reviewer.
rm -f "${REVIEW_DIR}/request.md"
commit_file notes.md 'notes only'
run_review new
assert_eq "${RUN_STATUS}" 0 'text-only status'
grep -q '^SKIP:' "${TMP}/stdout" || fail 'text-only stdout lacks SKIP'
assert_eq "$(call_count '^agent ')" 0 'text-only agent call count'
grep -q "$(git -C "${REPO}" rev-parse --short HEAD)" "${SELF_CLOSED}" || fail 'text-only not logged in self-closed.md'
echo 'PASS text-only commit is skipped without the reviewer'

# A code commit is triaged by the reviewer; the verdict is cached per HEAD.
commit_file src/x.py 'code change'
run_review new
assert_eq "${RUN_STATUS}" 3 'triage dispatch status'
assert_eq "$(call_count '^agent prompt reviewer-pane Triage request')" 1 'triage prompt count'
run_review live
assert_eq "${RUN_STATUS}" 3 'triage continuation status'
assert_eq "$(call_count '^agent prompt ')" 0 'triage continuation prompt count'
printf 'SKIP\nsmall isolated change with a test\nTRIAGE-COMPLETE\n' > "${TRIAGE_OUT}"
run_review live
assert_eq "${RUN_STATUS}" 0 'triage SKIP status'
grep -q '^SKIP: small isolated' "${TMP}/stdout" || fail 'triage SKIP stdout'
grep -q "$(git -C "${REPO}" rev-parse --short HEAD) | triage" "${SELF_CLOSED}" || fail 'triage SKIP not logged'
run_review new
assert_eq "${RUN_STATUS}" 0 'cached SKIP status'
assert_eq "$(call_count '^agent ')" 0 'cached SKIP agent call count'
echo 'PASS code commit is triaged and a SKIP verdict is cached'

# A REVIEW verdict exits 6 until a request for HEAD exists, then reviews normally.
commit_file src/y.py 'another code change'
run_review new
assert_eq "${RUN_STATUS}" 3 'second triage dispatch status'
printf 'REVIEW\ntouches a core path\nTRIAGE-COMPLETE\n' > "${TRIAGE_OUT}"
run_review live
assert_eq "${RUN_STATUS}" 6 'triage REVIEW status'
grep -q '^REVIEW: touches a core path' "${TMP}/stdout" || fail 'triage REVIEW stdout'
run_review new
assert_eq "${RUN_STATUS}" 6 'cached REVIEW status'
assert_eq "$(call_count '^agent ')" 0 'cached REVIEW agent call count'
write_request code "$(git -C "${REPO}" rev-parse HEAD~1)" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'review after REVIEW verdict status'
assert_eq "$(call_count '^agent prompt reviewer-pane Review request')" 1 'review prompt count'
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
echo 'PASS REVIEW verdict gates the review on a request for HEAD'

# Plan paths are routed to review mechanically, even when text-only.
printf 'REVIEW_PLAN_PATHS="docs/plans/*"\n' >> "${REPO}/.review.conf"
commit_file docs/plans/q.md 'plan doc'
rm -f "${REVIEW_DIR}/request.md"
run_review new
assert_eq "${RUN_STATUS}" 6 'plan path status'
assert_eq "$(call_count '^agent ')" 0 'plan path agent call count'
grep -q '^REVIEW:' "${TMP}/stdout" || fail 'plan path stdout'
grep -v '^REVIEW_PLAN_PATHS=' "${REPO}/.review.conf" > "${TMP}/conf" && mv "${TMP}/conf" "${REPO}/.review.conf"
echo 'PASS plan paths route to review without triage'

# A request for HEAD is an explicit review: no triage happens.
commit_file src/z.py 'third code change'
write_request code "$(git -C "${REPO}" rev-parse HEAD~1)" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'explicit request status'
assert_eq "$(call_count '^agent prompt reviewer-pane Review request')" 1 'explicit request review prompt'
assert_eq "$(call_count '^agent prompt reviewer-pane Triage request')" 0 'explicit request triage prompt'
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
echo 'PASS request for HEAD skips triage'

BASE=$(git -C "${REPO}" rev-parse HEAD)

# Every unit-boundary rejection exits 2 before touching the reviewer or any state file.
assert_rejected() {
  assert_eq "${RUN_STATUS}" 2 "$1 status"
  assert_eq "$(call_count '^agent ')" 0 "$1 agent call count"
  [ ! -f "${SENT}" ] || fail "$1 wrote a sent marker"
  grep -q "$2" "${TMP}/stdout" || fail "$1: stdout lacks '$2'"
}

# A request without a valid kind is refused; the reviewer must know which contract applies.
grep -v '^kind:' "${REVIEW_DIR}/request.md" > "${TMP}/req" && mv "${TMP}/req" "${REVIEW_DIR}/request.md"
run_review none
assert_rejected 'missing kind' '缺 kind'
# Every run leaves its exit code and output in the handoff dir for the board.
assert_eq "$(cut -d' ' -f1 "${REVIEW_DIR}/.last")" 2 'last exit code recorded'
grep -q '缺 kind' "${REVIEW_DIR}/.last.out" || fail 'last output not recorded'
write_request docs "${BASE}" 1/3
run_review none
assert_rejected 'invalid kind' '只能是 code 或 plan'
echo 'PASS request without a valid kind is refused'

# base sha must be a real commit that is an ancestor of HEAD.
write_request code 0123456789abcdef0123456789abcdef01234567 1/3
run_review none
assert_rejected 'unknown base' '不是本仓库的提交'
git -C "${REVIEW_WT}" commit -q --allow-empty -m side
write_request code "$(git -C "${REVIEW_WT}" rev-parse HEAD)" 1/3
run_review none
assert_rejected 'non-ancestor base' '不是 HEAD 的祖先'
echo 'PASS base sha must be an ancestor of HEAD'

# A human-requested review of a mixed diff is accepted as whatever kind the human declares: the script no
# longer judges purity, it only makes a routed kind stick (tested with the risk map below).
mkdir -p "${REPO}/docs/plans" "${REPO}/src"
printf 'plan\n' > "${REPO}/docs/plans/p.md"
printf 'code\n' > "${REPO}/src/a.txt"
git -C "${REPO}" add docs/plans/p.md src/a.txt
git -C "${REPO}" commit -qm mixed
printf 'REVIEW_PLAN_PATHS="docs/plans/*"\n' >> "${REPO}/.review.conf"
write_request code "${BASE}" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'mixed code request status'
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
write_request plan "${BASE}" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'mixed plan request status'
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
write_request code "${BASE}" 2/3
run_review new
assert_eq "${RUN_STATUS}" 3 'mixed diff round 2 status'
rm -f "${REVIEW_DIR}"/.r*.sent "${PANE_CACHE}"
echo 'PASS a human-requested review is not judged for purity'

# A pure plan diff passes as kind: plan, and an unset REVIEW_PLAN_PATHS never gates.
printf 'plan2\n' >> "${REPO}/docs/plans/p.md"
git -C "${REPO}" commit -qam plan-only
write_request plan "$(git -C "${REPO}" rev-parse HEAD~1)" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'plan-only request status'
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
grep -v '^REVIEW_PLAN_PATHS=' "${REPO}/.review.conf" > "${TMP}/conf" && mv "${TMP}/conf" "${REPO}/.review.conf"
write_request code "${BASE}" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'ungated mixed request status'
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
echo 'PASS plan-only diff passes and unset REVIEW_PLAN_PATHS does not gate'

write_request code "$(git -C "${REPO}" rev-parse HEAD)" 1/3

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

# Delivery is confirmed by the reviewer's state change, not by the prompt command's exit
# status: a prompt swallowed in the agent's startup window is resent once.
cp "${SENT}" "${TMP}/sent-keep"; rm -f "${SENT}"
run_review lost-once
assert_eq "${RUN_STATUS}" 3 'lost-once status'
assert_eq "$(call_count '^agent prompt reviewer-pane ')" 2 'lost-once prompt count'
[ -f "${SENT}" ] || fail 'lost-once did not record the confirmed delivery'
echo 'PASS swallowed prompt is resent once and confirmed'

# When no prompt registers the script fails closed: no sent marker, human looks at the pane.
rm -f "${SENT}"
run_review lost
assert_eq "${RUN_STATUS}" 4 'lost status'
assert_eq "$(call_count '^agent prompt reviewer-pane ')" 2 'lost prompt count'
[ ! -f "${SENT}" ] || fail 'lost wrote a sent marker without delivery'
grep -q 'STOP: .*送达' "${TMP}/stdout" "${TMP}/stderr" || fail 'lost stdout lacks delivery STOP'
echo 'PASS undelivered prompt fails closed without a sent marker'

# herdr's stalled report is not trusted over the reviewer's own state: already working
# means delivered, so nothing is resent.
run_review stalled-working
assert_eq "${RUN_STATUS}" 3 'stalled-working status'
assert_eq "$(call_count '^agent prompt reviewer-pane ')" 1 'stalled-working prompt count'
[ -f "${SENT}" ] || fail 'stalled-working did not record delivery'
cp "${TMP}/sent-keep" "${SENT}"
echo 'PASS stalled report with a working reviewer counts as delivered'

# While waiting, a reviewer that has gone idle without writing the sentinel has ended its
# turn without delivering: stop for the human instead of waiting out REVIEW_WAIT. One idle
# poll is tolerated; a working reviewer keeps the wait alive until the timeout.
cp "${REPO}/.review.conf" "${TMP}/conf-keep"
printf 'REVIEW_WAIT=20\nREVIEW_POLL=1\n' >> "${REPO}/.review.conf"
rm -f "${SENT}"
run_review new
assert_eq "${RUN_STATUS}" 4 'idle reviewer status'
grep -q 'STOP: 评审方已空闲' "${TMP}/stdout" || fail 'idle reviewer stdout lacks the idle STOP'
[ -f "${SENT}" ] || fail 'idle reviewer lost the sent marker'
run_review new
assert_eq "${RUN_STATUS}" 4 'idle reviewer continuation status'
assert_eq "$(call_count '^agent prompt ')" 0 'idle reviewer continuation prompt count'
printf 'REVIEW_WAIT=3\n' >> "${REPO}/.review.conf"
rm -f "${SENT}"
run_review stalled-working
assert_eq "${RUN_STATUS}" 3 'working reviewer status'
cp "${TMP}/conf-keep" "${REPO}/.review.conf"
cp "${TMP}/sent-keep" "${SENT}"
echo 'PASS idle reviewer without sentinel stops for the human'

# A sent round resumes the saved reviewer and never discovers, creates, or prompts again.
printf 'partial findings\n' > "${REVIEW_DIR}/r1-findings.md"
run_review live
assert_eq "${RUN_STATUS}" 3 'continuation status'
assert_eq "$(call_count '^pane split ')" 0 'continuation split count'
assert_eq "$(call_count '^agent start ')" 0 'continuation start count'
assert_eq "$(call_count '^agent prompt ')" 0 'continuation prompt count'
[ -f "${SENT}" ] || fail 'continuation archived its sent marker'
echo 'PASS sent round reuses saved reviewer without redispatch'

# Continuation never needs a clean tree: the target is pinned in the sent marker,
# and the script itself dirties the tree (archive, timing, precision).
printf 'dirty\n' >> "${REPO}/fixture.txt"
run_review live
assert_eq "${RUN_STATUS}" 3 'dirty continuation status'
assert_eq "$(call_count '^agent prompt ')" 0 'dirty continuation prompt count'
git -C "${REPO}" checkout -q -- fixture.txt
echo 'PASS sent round continues on a dirty tree'

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
# The reviewer is split off the writer's own pane, never the UI-focused one.
assert_eq "$(call_count '^pane split --current ')" 1 'stale cache split targets calling pane'
assert_eq "$(call_count '^agent start .*--pane new-pane ')" 1 'stale cache start count'
assert_eq "$(call_count '^agent prompt new-pane ')" 1 'stale cache prompt count'
assert_eq "$(call_count '^agent \(start\|prompt\).*old-pane')" 0 'stale occupant action count'
assert_eq "$(cat "${PANE_CACHE}")" new-pane 'stale cache replacement'
echo 'PASS unsent stale cache creates one new reviewer without touching old occupant'

# defer is allowed on should/nit and never on blocking; a deferred blocking stops for the human.
rm -f "${REVIEW_DIR}"/.r*.sent
printf 'F1 | blocking\nclaim: x\nF2 | should\nclaim: y\nREVIEW-COMPLETE\n' > "${REVIEW_DIR}/r1-findings.md"
printf 'F1 defer — later\nF2 accept — fixed\n' > "${REVIEW_DIR}/r1-responses.md"
write_request code "$(git -C "${REPO}" rev-parse HEAD)" 2/3
run_review new
assert_eq "${RUN_STATUS}" 5 'deferred blocking status'
assert_eq "$(call_count '^agent prompt ')" 0 'deferred blocking prompt count'
grep -q 'F1' "${TMP}/stdout" || fail 'deferred blocking: stdout does not name F1'
printf 'F1 accept — fixed\nF2 defer — later\n' > "${REVIEW_DIR}/r1-responses.md"
run_review new
assert_eq "${RUN_STATUS}" 3 'deferred should status'
assert_eq "$(call_count '^agent prompt ')" 1 'deferred should prompt count'
echo 'PASS defer stops on blocking and passes on should'

# A reject stops for the human. Once the human's ruling is recorded in r<n>-decision.md
# for every rejected (or blocking-deferred) id, the next round proceeds on the same cycle:
# findings and responses stay, no round is consumed, the reviewer is told where the ruling is.
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/r*-decision.md
printf 'F1 | blocking\nclaim: x\nF2 | nit\nclaim: y\nREVIEW-COMPLETE\n' > "${REVIEW_DIR}/r1-findings.md"
printf 'F1 accept — fixed\nF2 reject — by design\n' > "${REVIEW_DIR}/r1-responses.md"
run_review new
assert_eq "${RUN_STATUS}" 5 'reject without decision status'
grep -q 'r1-decision.md' "${TMP}/stdout" || fail 'reject stop does not name the decision file'
printf 'F9 uphold — wrong id\n' > "${REVIEW_DIR}/r1-decision.md"
run_review new
assert_eq "${RUN_STATUS}" 5 'reject with incomplete decision status'
grep -q 'F2' "${TMP}/stdout" || fail 'incomplete decision: stdout does not name F2'
printf 'F2 uphold — 同意，继续吧\n' > "${REVIEW_DIR}/r1-decision.md"
run_review new
assert_eq "${RUN_STATUS}" 3 'reject with decision status'
assert_eq "$(call_count '^agent prompt ')" 1 'reject with decision prompt count'
grep -q "^Previous decisions: ${REVIEW_DIR}/r1-decision.md" "${MOCK_LOG}" || fail 'decision path not in prompt'
[ -f "${REVIEW_DIR}/r1-findings.md" ] && [ -f "${REVIEW_DIR}/r1-responses.md" ] || fail 'decision run lost round-1 files'
grep -q '^round: *2/3' "${REVIEW_DIR}/request.md" || fail 'decision run changed the round'
# The same ruling file covers a deferred blocking.
rm -f "${REVIEW_DIR}"/.r*.sent
printf 'F1 defer — later\nF2 accept — fixed\n' > "${REVIEW_DIR}/r1-responses.md"
printf 'F1 uphold — 允许推迟\n' > "${REVIEW_DIR}/r1-decision.md"
run_review new
assert_eq "${RUN_STATUS}" 3 'deferred blocking with decision status'
rm -f "${REVIEW_DIR}"/r*-decision.md
echo 'PASS human decision file unblocks reject and blocking defer'

# A response line the parser cannot read (`- F1 reject`, `**F1** reject`, `F1: reject`) would
# hide a reject and let the round proceed, so any such line stops with exit 2; so does an id
# answered twice. Skipping an already-resolved id is allowed.
rm -f "${REVIEW_DIR}"/.r*.sent
printf 'F1 | blocking\nclaim: x\nF2 | nit\nclaim: y\nF3 | nit\nclaim: z\nREVIEW-COMPLETE\n' > "${REVIEW_DIR}/r1-findings.md"
for bad in '- F2 reject — by design' '**F2** reject — by design' 'F2: reject — by design' '## F2 accept'; do
  printf 'F1 accept — fixed\n%s\nF3 accept — ok\n' "${bad}" > "${REVIEW_DIR}/r1-responses.md"
  run_review new
  assert_eq "${RUN_STATUS}" 2 "drifted response status (${bad})"
  grep -qF -e "${bad}" "${TMP}/stdout" || fail "drifted response: stdout does not quote the line (${bad})"
  assert_eq "$(call_count '^agent prompt ')" 0 "drifted response prompt count (${bad})"
done
printf 'F1 accept — fixed\nF2 accept — ok\nF2 defer — twice\nF3 accept — ok\n' > "${REVIEW_DIR}/r1-responses.md"
run_review new
assert_eq "${RUN_STATUS}" 2 'duplicate response status'
grep -q '重复编号：F2' "${TMP}/stdout" || fail 'duplicate response: stdout does not list F2'
printf 'F1 accept — fixed\nF3 accept — 同 F2 的 reject 理由不适用\n' > "${REVIEW_DIR}/r1-responses.md"
run_review new
assert_eq "${RUN_STATUS}" 3 'well-formed partial response status'
assert_eq "$(call_count '^agent prompt ')" 1 'well-formed partial response prompt count'
echo 'PASS malformed or duplicated response lines stop before the next round'

# Archiving never overwrites an existing file: a hand-written or committed
# archive under the same sha gets a suffixed sibling instead.
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/r*-responses.md
printf 'F1 | should\nREVIEW-COMPLETE\n' > "${REVIEW_DIR}/r1-findings.md"
printf 'abc1234\n' > "${REVIEW_DIR}/.cycle"
printf 'hand-written\n' > "${REPO}/docs/reviews/abc1234.md"
write_request code "$(git -C "${REPO}" rev-parse HEAD)" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'archive-collision dispatch status'
assert_eq "$(cat "${REPO}/docs/reviews/abc1234.md")" hand-written 'existing archive untouched'
[ -f "${REPO}/docs/reviews/abc1234-2.md" ] || fail 'suffixed archive not written'
grep -q 'F1 | should' "${REPO}/docs/reviews/abc1234-2.md" || fail 'suffixed archive lacks findings'
echo 'PASS archive never overwrites an existing file'

# A completed review that has no responses yet is delivered even after HEAD moved,
# instead of being archived unread and re-dispatched (round 1) or refused (round 2+).
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/r*-findings.md "${REVIEW_DIR}"/r*-responses.md "${REVIEW_DIR}"/.cycle*
OLD_HEAD=$(git -C "${REPO}" rev-parse HEAD)
rm -f "${REPO}/docs/reviews/${OLD_HEAD:0:7}"*.md   # archives left by earlier cases
printf 'F1 | should\nREVIEW-COMPLETE\n' > "${REVIEW_DIR}/r1-findings.md"
printf '%s\n%s\nreviewer-pane\nterm-review\n{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-review"}\n' \
  "$(date +%s)" "${OLD_HEAD}" > "${SENT}"
git -C "${REPO}" commit -q --allow-empty -m unrelated
write_request code "${OLD_HEAD}" 1/3
run_review new
assert_eq "${RUN_STATUS}" 0 'unclaimed review after HEAD moved status'
assert_eq "$(cat "${TMP}/stdout")" "${REVIEW_DIR}/r1-findings.md" 'unclaimed review prints findings path'
assert_eq "$(call_count '^agent prompt ')" 0 'unclaimed review prompt count'
[ ! -f "${REPO}/docs/reviews/${OLD_HEAD:0:7}.md" ] || fail 'unclaimed review was archived'
grep -q "| ${OLD_HEAD:0:7} | round 1/3 |" "${REPO}/docs/reviews/timing.md" || fail 'timing not recorded under sent target'
echo 'PASS unclaimed completed review is delivered after HEAD moved'

# Once responses exist the same state is a finished round: round 1 starts a new cycle.
printf 'F1 defer — later\n' > "${REVIEW_DIR}/r1-responses.md"
run_review new
assert_eq "${RUN_STATUS}" 3 'claimed review new cycle status'
assert_eq "$(call_count '^agent prompt ')" 1 'claimed review new cycle prompt count'
[ -f "${REPO}/docs/reviews/${OLD_HEAD:0:7}.md" ] || [ -f "${REPO}/docs/reviews/unknown.md" ] || fail 'previous cycle not archived'
echo 'PASS claimed review lets round 1 start a new cycle'

# A finished round 2+ (findings claimed by responses) is a closed cycle: the stale
# request.md must not make the next commit look like a continuation. It is triaged.
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/r*-findings.md "${REVIEW_DIR}"/r*-responses.md "${REVIEW_DIR}"/.cycle* "${REVIEW_DIR}"/.triage*
OLD_HEAD=$(git -C "${REPO}" rev-parse HEAD)
write_request code "${OLD_HEAD}" 2/3
printf 'F1 | should\nREVIEW-COMPLETE\n' > "${REVIEW_DIR}/r2-findings.md"
printf 'F1 defer — later\n' > "${REVIEW_DIR}/r2-responses.md"
printf '%s\n%s\nreviewer-pane\nterm-review\n{"agent":"claude","kind":"id","source":"herdr:claude","value":"session-review"}\n' \
  "$(date +%s)" "${OLD_HEAD}" > "${REVIEW_DIR}/.r2.sent"
commit_file notes2.md 'status record after closed cycle'
run_review new
assert_eq "${RUN_STATUS}" 0 'closed round-2 cycle then text commit status'
grep -q '^SKIP:' "${TMP}/stdout" || fail 'closed round-2 cycle text commit not skipped'
commit_file src/w.py 'code after closed cycle'
run_review new
assert_eq "${RUN_STATUS}" 3 'closed round-2 cycle then code commit status'
assert_eq "$(call_count '^agent prompt reviewer-pane Triage request')" 1 'closed round-2 cycle triage prompt count'
echo 'PASS closed round-2 cycle does not block triage of later commits'

# ---- Brief gate: the reviewer reads the brief every round, so a missing or stale brief stops dispatch. ----
rm -f "${REVIEW_DIR}/request.md" "${REVIEW_DIR}/.triage" "${REVIEW_DIR}/.triage.sent" "${REVIEW_DIR}/triage.md"
grep -v '^REVIEW_BRIEF=' "${REPO}/.review.conf" > "${TMP}/conf" && mv "${TMP}/conf" "${REPO}/.review.conf"
printf 'REVIEW_BRIEF_MAX_COMMITS=2\n' >> "${REPO}/.review.conf"
mkdir -p "${REPO}/docs"
# No brief at all: a fresh repo is asked to write one before anything is routed.
commit_file src/b0.py 'c0'
run_review new
assert_eq "${RUN_STATUS}" 7 'missing brief status'
grep -q '还没有 docs/reviewer-brief.md' "${TMP}/stdout" || fail 'missing brief stdout'
assert_eq "$(call_count '^agent ')" 0 'missing brief agent calls'
V=$(git -C "${REPO}" rev-parse HEAD)
printf '<!-- verified at: %s -->\n# brief\n' "${V}" > "${REPO}/docs/reviewer-brief.md"
git -C "${REPO}" add docs/reviewer-brief.md; git -C "${REPO}" commit -qm 'brief'
# The commit that writes the brief is let through and routed as a plan review (rule path).
run_review new
assert_eq "${RUN_STATUS}" 6 'brief commit status'
grep -q '规则文档' "${TMP}/stdout" || fail 'brief commit is not routed as plan/rule'
assert_eq "$(call_count '^agent ')" 0 'brief commit agent calls'
# Three commits past verified-at with a cap of 2: routing and an explicit round-1 request both stop with 7.
commit_file src/b1.py 'c1'; commit_file src/b2.py 'c2'
run_review new
assert_eq "${RUN_STATUS}" 7 'stale brief routing status'
grep -q '简报过期' "${TMP}/stdout" || fail 'stale brief stdout'
grep -q 'brief-prompt.md' "${TMP}/stdout" || fail 'stale brief stdout lacks the rewrite hint'
assert_eq "$(call_count '^agent ')" 0 'stale brief agent calls'
write_request code "$(git -C "${REPO}" rev-parse HEAD~1)" 1/3
run_review new
assert_eq "${RUN_STATUS}" 7 'stale brief explicit round-1 status'
[ ! -f "${SENT}" ] || fail 'stale brief dispatched anyway'
rm -f "${REVIEW_DIR}/request.md"
# Rewriting the brief at HEAD lifts the gate; the next code commit is triaged normally.
printf '<!-- verified at: %s -->\n# brief v2\n' "$(git -C "${REPO}" rev-parse HEAD)" > "${REPO}/docs/reviewer-brief.md"
git -C "${REPO}" commit -qam 'brief rewrite'
run_review new
assert_eq "${RUN_STATUS}" 6 'brief rewrite status'
commit_file src/b3.py 'c3'
run_review new
assert_eq "${RUN_STATUS}" 3 'fresh brief routing status'
assert_eq "$(call_count '^agent prompt reviewer-pane Triage request')" 1 'fresh brief triage prompt'
# A commit bundling the brief with code routes as plan (rule file), and a kind: code request against it is refused.
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/request.md"
printf '<!-- verified at: %s -->\n# brief v3\n' "$(git -C "${REPO}" rev-parse HEAD)" > "${REPO}/docs/reviewer-brief.md"
commit_file src/b4.py 'code with brief'
git -C "${REPO}" add docs/reviewer-brief.md; git -C "${REPO}" commit -q --amend --no-edit
run_review new
assert_eq "${RUN_STATUS}" 6 'brief with code routing status'
grep -q '^kind: plan' "${TMP}/stdout" || fail 'brief with code should route as plan'
write_request code "$(git -C "${REPO}" rev-parse HEAD~1)" 1/3
run_review none
assert_rejected 'brief mixed into code' '照抄 request-review 的输出'
rm -f "${REVIEW_DIR}/request.md" "${REVIEW_DIR}"/.triage*
# A verified-at that is not in HEAD's history is stale too.
printf '<!-- verified at: 0123456789abcdef0123456789abcdef01234567 -->\n' > "${REPO}/docs/reviewer-brief.md"
git -C "${REPO}" commit -qam 'brief bad base'
commit_file src/b5.py 'c5'
run_review new
assert_eq "${RUN_STATUS}" 7 'non-ancestor brief status'
grep -q '不在 HEAD 的历史里' "${TMP}/stdout" || fail 'non-ancestor brief stdout'
# REVIEW_BRIEF= disables the gate.
printf 'REVIEW_BRIEF=\n' >> "${REPO}/.review.conf"
run_review new
assert_eq "${RUN_STATUS}" 3 'brief gate disabled status'
echo 'PASS stale reviewer brief stops dispatch until it is rewritten'

# ---- Risk map and accumulated ranges ----
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/triage.md" "${REVIEW_DIR}/request.md" "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/r*-findings.md "${REVIEW_DIR}"/r*-responses.md
grep -v '^REVIEW_PLAN_PATHS=' "${REPO}/.review.conf" > "${TMP}/conf" && mv "${TMP}/conf" "${REPO}/.review.conf"
printf 'REVIEW_PLAN_PATHS="docs/plans/*"\n' >> "${REPO}/.review.conf"
cat > "${REPO}/.review-map" <<'MAP'
# pattern   level   # reason
src/core/**   deep    # core
src/util/**   light   # helpers
docs/**       skip    # notes
MAP
git -C "${REPO}" add .review-map; git -C "${REPO}" commit -qm 'risk map'
# 把"上次代码评审"和"上次计划评审"都钉在这里，后面的范围从这个提交起算（引入 .review-map 的提交视为已审）
printf '2026-09-01 | %s | round 1/3 | 60s | code\n2026-09-01 | %s | round 1/2 | 30s | plan\n' "$(git -C "${REPO}" rev-parse --short HEAD)" "$(git -C "${REPO}" rev-parse --short HEAD)" > "${REPO}/docs/reviews/timing.md"
# A mapped deep path is routed without the reviewer, with kind / level / base printed for the writer.
commit_file src/core/a.py 'core change'
run_review new
assert_eq "${RUN_STATUS}" 6 'mapped deep status'
assert_eq "$(call_count '^agent ')" 0 'mapped deep agent calls'
grep -q '^REVIEW: .*最高等级 deep' "${TMP}/stdout" || fail 'mapped deep stdout'
grep -q '^kind: code' "${TMP}/stdout" || fail 'mapped deep kind line'
grep -q '^level: deep' "${TMP}/stdout" || fail 'mapped deep level line'
grep -q "^base sha: $(git -C "${REPO}" rev-parse HEAD~1)" "${TMP}/stdout" || fail 'mapped deep base line'
run_review new
grep -q '^level: deep' "${TMP}/stdout" || fail 'cached verdict lost the level'
# Once that review is on record, a mapped skip-only change is closed by the map.
printf '2026-09-01 | %s | round 1/3 | 60s | code\n' "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
printf '{}\n' > "${REPO}/docs/n.json"; git -C "${REPO}" add docs/n.json; git -C "${REPO}" commit -qm 'notes json'
run_review new
assert_eq "${RUN_STATUS}" 0 'mapped skip status'
grep -q '^SKIP: .*全为 skip' "${TMP}/stdout" || fail 'mapped skip stdout'
# An unmapped path goes to the reviewer with the range and the unmapped list; its level and map hint are honoured.
commit_file src/new/z.py 'unmapped change'
run_review new
assert_eq "${RUN_STATUS}" 3 'unmapped triage status'
assert_eq "$(call_count '^agent prompt reviewer-pane Triage request')" 1 'unmapped triage prompt'
grep -q '^Range: ' "${MOCK_LOG}" || fail 'triage prompt lacks Range'
grep -q '^Unmapped paths.*src/new/z.py' "${MOCK_LOG}" || fail 'triage prompt lacks unmapped list'
printf 'REVIEW deep\ntouches an unmapped module\nmap: src/new/** deep\nTRIAGE-COMPLETE\n' > "${TRIAGE_OUT}"
run_review live
assert_eq "${RUN_STATUS}" 6 'unmapped verdict status'
grep -q '^level: deep' "${TMP}/stdout" || fail 'reviewer level not honoured'
grep -q '建议加进风险图：src/new/\*\* deep' "${TMP}/stderr" || fail 'map hint not surfaced'
echo 'PASS risk map routes mapped paths and asks the reviewer only for unmapped ones'

# Map semantics found by the first live map review: plan rows route as plan even when absent from
# .review.conf; `*` does not cross directories; a text file counts only when the map says deep/review.
printf '2026-09-01 | %s | round 1/3 | 60s | code\n2026-09-01 | %s | round 1/2 | 30s | plan\n' "$(git -C "${REPO}" rev-parse --short HEAD)" "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
cat > "${REPO}/.review-map" <<'MAP'
src/core/**    deep    # core
src/util/*     light   # top-level helpers only
docs/specs/**  plan    # specs are plans, not in .review.conf
docs/**        skip    # notes
README.md      review  # pointers that were wrong before
MAP
git -C "${REPO}" add .review-map; git -C "${REPO}" commit -qm 'map v2'
printf '2026-09-01 | %s | round 1/2 | 30s | plan\n' "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/triage.md"
commit_file docs/specs/s.md 'spec'
run_review new
assert_eq "${RUN_STATUS}" 6 'map plan row status'
grep -q '^kind: plan' "${TMP}/stdout" || fail 'map plan row not routed as plan'
printf '2026-09-01 | %s | round 1/2 | 30s | plan\n' "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
commit_file src/util/sub/deep.py 'new subpackage'
run_review new
assert_eq "${RUN_STATUS}" 3 'single-star subdir status'
grep -q '^Unmapped paths.*src/util/sub/deep.py' "${MOCK_LOG}" || fail 'single star crossed a directory'
printf 'SKIP\nfine\nTRIAGE-COMPLETE\n' > "${TRIAGE_OUT}"; run_review live
printf '2026-09-01 | %s | round 1/3 | 60s | code\n' "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/triage.md"
commit_file README.md 'readme pointer'
run_review new
assert_eq "${RUN_STATUS}" 6 'mapped text file status'
grep -q '^level: review' "${TMP}/stdout" || fail 'README review row ignored'
printf '2026-09-01 | %s | round 1/3 | 60s | code\n' "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/triage.md"
commit_file docs/x.md 'plain note'
run_review new
assert_eq "${RUN_STATUS}" 0 'unmapped-text status'
grep -q '^SKIP: .*只改了 .md' "${TMP}/stdout" || fail 'plain note not skipped'
git -C "${REPO}" checkout -q HEAD~5 -- .review-map 2>/dev/null || true
cat > "${REPO}/.review-map" <<'MAP'
# pattern   level   # reason
src/core/**   deep    # core
src/util/**   light   # helpers
docs/**       skip    # notes
MAP
git -C "${REPO}" commit -qam 'map back'
printf '2026-09-01 | %s | round 1/2 | 30s | plan\n2026-09-01 | %s | round 1/3 | 60s | code\n' "$(git -C "${REPO}" rev-parse --short HEAD)" "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
echo 'PASS map plan rows route, single star stays in its directory, mapped text files count'

# With a completed code review on record, routing looks at the whole range since its target.
A=$(git -C "${REPO}" rev-parse HEAD)
printf '2026-09-01 | %s | round 1/3 | 60s | code\n' "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/triage.md"
commit_file src/new/b.py 'b'
run_review new
printf 'SKIP\nsmall\nTRIAGE-COMPLETE\n' > "${TRIAGE_OUT}"
run_review live
assert_eq "${RUN_STATUS}" 0 'range skip status'
# A text-only commit after a SKIP carries the verdict over without asking again.
commit_file docs/note.md 'note'
run_review new
assert_eq "${RUN_STATUS}" 0 'carry-over status'
grep -q '^SKIP: .*沿用' "${TMP}/stdout" || fail 'carry-over stdout'
assert_eq "$(call_count '^agent ')" 0 'carry-over agent calls'
# A commit the human skipped with SKIP_REVIEW stays out of the range: the next text-only commit is still a carry-over.
commit_file src/other/h.py 'human-skipped'
( cd "${REPO}" && PATH="${MOCK_BIN}:${PATH}" MOCK_LOG="${MOCK_LOG}" MOCK_SCENARIO=new MOCK_REVIEW_WT="${REVIEW_WT}" SKIP_REVIEW=1 "${REQUEST_REVIEW}" "deploy" >/dev/null )
commit_file src/other/h2.py 'human-skipped again'
( cd "${REPO}" && PATH="${MOCK_BIN}:${PATH}" MOCK_LOG="${MOCK_LOG}" MOCK_SCENARIO=new MOCK_REVIEW_WT="${REVIEW_WT}" SKIP_REVIEW=1 "${REQUEST_REVIEW}" "deploy2" >/dev/null )
commit_file docs/note2.md 'note2'
run_review new
assert_eq "${RUN_STATUS}" 0 'skipped commit excluded status'
grep -q '^SKIP: .*沿用' "${TMP}/stdout" || fail 'skipped commit not excluded from range'
# The next code commit is triaged over the accumulated range: 3 unskipped commits since A.
commit_file src/new/d.py 'd'
run_review new
assert_eq "${RUN_STATUS}" 3 'range triage status'
grep -q "^Range: ${A}\.\..* (6 commits" "${MOCK_LOG}" || fail 'range prompt lacks the accumulated range'
assert_eq "$(grep -c '^  [0-9a-f]\{7\} ' "${MOCK_LOG}")" 6 'range prompt commit list'
grep -q '^Unmapped paths.*src/new/d.py' "${MOCK_LOG}" || fail 'unmapped list lacks d.py'
grep -q '^Unmapped paths.*src/other/h' "${MOCK_LOG}" && fail 'human-skipped file leaked into the unmapped list'
# Past the accumulation cap the script reviews without asking.
printf 'REVIEW_ACCUM_COMMITS=2\n' >> "${REPO}/.review.conf"
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/triage.md"
run_review new
assert_eq "${RUN_STATUS}" 6 'accumulation cap status'
grep -q '^REVIEW: .*累积 6 个提交.*超过上限' "${TMP}/stdout" || fail 'accumulation cap stdout'
assert_eq "$(call_count '^agent ')" 0 'accumulation cap agent calls'
grep -q "^base sha: ${A}" "${TMP}/stdout" || fail 'accumulation cap base is the last code review'
grep -v '^REVIEW_ACCUM_COMMITS=' "${REPO}/.review.conf" > "${TMP}/conf" && mv "${TMP}/conf" "${REPO}/.review.conf"
echo 'PASS routing accumulates commits since the last code review'

# Plan paths accumulate from the last plan review, independently of code reviews.
P=$(git -C "${REPO}" rev-parse HEAD)
printf '2026-09-02 | %s | round 1/2 | 30s | plan\n' "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/triage.md"
commit_file docs/plans/q.md 'plan edit'
run_review new
assert_eq "${RUN_STATUS}" 6 'plan range status'
grep -q '^kind: plan' "${TMP}/stdout" || fail 'plan range kind'
grep -q "^base sha: ${P}" "${TMP}/stdout" || fail 'plan range base is the last plan review'
echo 'PASS plan paths accumulate from the last plan review'

# Round 1 checks the target commit for purity and kind; older commits in the range are history.
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/triage.md" "${REVIEW_DIR}"/.r*.sent
B=$(git -C "${REPO}" rev-parse HEAD)
commit_file src/core/c2.py 'code after plan'
write_request code "${P}" 1/3            # range P..HEAD = plan commit + code commit → ok
run_review new
assert_eq "${RUN_STATUS}" 3 'pure mixed-range status'
grep -q '^Level: deep' "${MOCK_LOG}" || fail 'review prompt lacks the derived level'
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
# A mixed commit earlier in the range does not block; the same mix as the target does.
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
printf 'p\n' >> "${REPO}/docs/plans/q.md"; printf 'r\n' >> "${REPO}/README.md"
git -C "${REPO}" add docs/plans/q.md README.md; git -C "${REPO}" commit -qm 'historical mixed status commit'
commit_file src/core/c3.py 'code after mixed history'
write_request code "${P}" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'mixed history in range status'
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
# A target commit mixing plan and code is not rejected: the plan range and the code range are reviewed separately.
printf 'p2\n' >> "${REPO}/docs/plans/q.md"; printf 'x\n' > "${REPO}/src/core/c4.py"
git -C "${REPO}" add docs/plans/q.md src/core/c4.py; git -C "${REPO}" commit -qm 'mixed target'
write_request code "${P}" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'mixed target status'
rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
git -C "${REPO}" reset -q --hard HEAD~1
# When the script routed this HEAD, the request's kind must copy the verdict; a human-requested review is free.
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/request.md"
run_review new
assert_eq "${RUN_STATUS}" 6 'routing before kind check status'
grep -q '^kind: plan' "${TMP}/stdout" || fail 'expected the plan range to route first'
write_request code "${P}" 1/3
run_review none
assert_rejected 'kind vs routed verdict' '照抄 request-review 的输出'
rm -f "${REVIEW_DIR}"/.triage*
write_request code "${P}" 1/3
sed -i '' 's|^round:|level: huge\nround:|' "${REVIEW_DIR}/request.md"
run_review none
assert_rejected 'bad level' 'level 只能是'
sed -i '' 's|^level: huge|level: light|' "${REVIEW_DIR}/request.md"
run_review new
assert_eq "${RUN_STATUS}" 3 'explicit level status'
grep -q '^Level: light' "${MOCK_LOG}" || fail 'explicit level not passed to the reviewer'
echo 'PASS round 1 makes kind follow the routed verdict and honours an explicit level'

# When findings land, a blocking on a path below deep upgrades the map automatically and timing.md records the kind.
printf 'F1 | blocking\nclaim:    boom\nevidence: src/util/u.py:3\nREVIEW-COMPLETE\n' > "${REVIEW_DIR}/r1-findings.md"
mkdir -p "${REPO}/src/util"; printf 'x\n' > "${REPO}/src/util/u.py"
run_review live
assert_eq "${RUN_STATUS}" 0 'findings delivered status'
grep -q '^src/util/u.py *deep *# 自动升级' "${REPO}/.review-map" || fail 'map not auto-upgraded'
grep -q '升级 src/util/u.py → deep' "${TMP}/stderr" || fail 'upgrade note missing'
tail -1 "${REPO}/docs/reviews/timing.md" | grep -q '| code$' || fail 'timing row lacks kind'
# Running again before responses are written re-delivers the path without a second row.
n_timing=$(grep -c . "${REPO}/docs/reviews/timing.md"); n_prec=$(grep -c . "${REPO}/docs/reviews/precision.md")
run_review live
assert_eq "${RUN_STATUS}" 0 'redelivery status'
assert_eq "$(cat "${TMP}/stdout")" "${REVIEW_DIR}/r1-findings.md" 'redelivery prints the findings path'
assert_eq "$(grep -c . "${REPO}/docs/reviews/timing.md")" "${n_timing}" 'redelivery duplicated a timing row'
assert_eq "$(grep -c . "${REPO}/docs/reviews/precision.md")" "${n_prec}" 'redelivery duplicated a precision row'
rm -f "${REPO}/src/util/u.py"
echo 'PASS a blocking finding upgrades its path in the map'

# ---- Script-written files never block, route, or count as a mix ----
# The tree now carries the round's timing/precision rows and the map upgrade line, uncommitted.
# A new code commit that leaves them behind is still dispatchable: they are the script's, not the writer's.
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/triage.md" "${REVIEW_DIR}/request.md" "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
git -C "${REPO}" status --porcelain -- docs/reviews | grep -q . || fail "fixture: docs/reviews should be dirty: $(git -C "${REPO}" status --porcelain)"
git -C "${REPO}" status --porcelain | grep -q '^ M .review-map' || fail 'fixture: .review-map should be dirty'
commit_file src/core/c5.py 'code with records left behind'
run_review new
assert_eq "${RUN_STATUS}" 6 'dirty records routing status'
grep -q '未提交' "${TMP}/stdout" && fail 'script-written files counted as a dirty tree'
# A commit that only carries the records and the upgrade line is not routed and leaves no trace.
printf '2026-09-03 | %s | round 1/3 | 1s | code\n2026-09-03 | %s | round 1/2 | 1s | plan\n' "$(git -C "${REPO}" rev-parse --short HEAD)" "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
rm -f "${REVIEW_DIR}"/.triage*
n_closed=$(grep -c . "${SELF_CLOSED}")
git -C "${REPO}" add -A docs/reviews .review-map; git -C "${REPO}" commit -qm 'records only'
run_review new
assert_eq "${RUN_STATUS}" 0 'records-only status'
grep -q '无需路由' "${TMP}/stdout" || fail 'records-only commit was routed'
assert_eq "$(grep -c . "${SELF_CLOSED}")" "${n_closed}" 'records-only commit left a self-closed row'
[ -f "${REVIEW_DIR}/.triage" ] && fail 'records-only commit left a triage cache'
assert_eq "$(call_count '^agent ')" 0 'records-only agent calls'
# A records-only commit after a real SKIP verdict reuses that verdict instead of writing another row.
commit_file docs/note3.md 'status note'
run_review new
assert_eq "${RUN_STATUS}" 0 'text commit after records status'
n_closed=$(grep -c . "${SELF_CLOSED}")
printf '2026-09-03 | x | blocking 0 | 误报 ?\n' >> "${REPO}/docs/reviews/precision.md"
git -C "${REPO}" add docs/reviews/precision.md; git -C "${REPO}" commit -qm 'records after skip'
run_review new
assert_eq "${RUN_STATUS}" 0 'records after skip status'
assert_eq "$(grep -c . "${SELF_CLOSED}")" "${n_closed}" 'records after skip wrote another self-closed row'
grep -q '已记录' "${TMP}/stdout" || fail 'records after skip should reuse the cached verdict'
# A REVIEW verdict is not reused across a records-only commit: once reviewed, routing must start over.
commit_file src/core/c6.py 'core again'
run_review new
assert_eq "${RUN_STATUS}" 6 'review before records status'
printf '2026-09-03 | %s | round 1/3 | 1s | code\n' "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
git -C "${REPO}" add docs/reviews/timing.md; git -C "${REPO}" commit -qm 'records after review'
run_review new
assert_eq "${RUN_STATUS}" 0 'records after review status'
grep -q '无需路由' "${TMP}/stdout" || fail 'records after a completed review should not re-request it'
# A plan commit with records and an upgrade line riding along is still a pure plan commit.
printf 'p3\n' >> "${REPO}/docs/plans/q.md"
printf '2026-09-03 | x | blocking 0 | 误报 ?\n' >> "${REPO}/docs/reviews/precision.md"
printf '%-40s deep    # 自动升级：abc1234 第 1 轮出阻断（原 light）\n' src/util/v.py >> "${REPO}/.review-map"
git -C "${REPO}" add docs/plans/q.md docs/reviews/precision.md .review-map; git -C "${REPO}" commit -qm 'plan with records riding along'
run_review new
assert_eq "${RUN_STATUS}" 6 'plan with records routing status'
grep -q '^kind: plan' "${TMP}/stdout" || fail 'plan with records kind'
base=$(sed -n 's/^base sha: \([0-9a-f]*\).*/\1/p' "${TMP}/stdout")
write_request plan "${base}" 1/2
run_review new
assert_eq "${RUN_STATUS}" 3 'plan with records dispatch status'
# A human edit to the map is still a rule change and routes as plan.
rm -f "${REVIEW_DIR}"/.triage* "${REVIEW_DIR}/request.md" "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/.cycle* "${PANE_CACHE}"
printf '2026-09-04 | %s | round 1/2 | 1s | plan\n' "$(git -C "${REPO}" rev-parse --short HEAD)" >> "${REPO}/docs/reviews/timing.md"
printf 'src/legacy/**   skip   # human decision\n' >> "${REPO}/.review-map"
git -C "${REPO}" add -A docs/reviews .review-map; git -C "${REPO}" commit -qm 'human map edit'
run_review new
assert_eq "${RUN_STATUS}" 6 'human map edit status'
grep -q '^kind: plan' "${TMP}/stdout" || fail 'human map edit should route as plan'
echo 'PASS script-written records and map upgrades never block, route, or mix'

# ---- Planner: request-review plan ----
# Not configured → exit 2 and the writer plans on its own.
run_review none plan
assert_rejected 'planner unconfigured' '未配置规划者'
printf 'PLAN_KIND=claude\nPLAN_AGENT_ARGS="--model claude-opus-5"\n' >> "${REPO}/.review.conf"
run_review none plan
assert_rejected 'planner without request' 'plan-request.md'
printf 'task: 做 M5\nconstraints: 不改 WorldProposal\n' > "${REVIEW_DIR}/plan-request.md"
# A stale brief stops the request before the planner is even spawned: the writer rewrites it first (exit 7).
grep -v '^REVIEW_BRIEF=' "${REPO}/.review.conf" > "${TMP}/conf" && mv "${TMP}/conf" "${REPO}/.review.conf"
run_review none plan
assert_eq "${RUN_STATUS}" 7 'planner behind a stale brief status'
assert_eq "$(call_count '^agent ')" 0 'stale brief must not spawn the planner'
printf 'REVIEW_BRIEF=\n' >> "${REPO}/.review.conf"
printf 'wip\n' > "${REPO}/src/wip.py"; git -C "${REPO}" add src/wip.py
run_review none plan
assert_rejected 'planner on a dirty tree' '工作区未提交'
git -C "${REPO}" reset -q src/wip.py; rm -f "${REPO}/src/wip.py"
# The writer sits in the repo dir with no name; the planner is spawned there by name with its args.
run_review plan-new plan
assert_eq "${RUN_STATUS}" 3 'planner dispatch status'
assert_eq "$(call_count '^pane split ')" 1 'planner split count'
grep -q '^agent start pl-repo- --kind claude --pane new-pane --timeout [0-9]* -- --model claude-opus-5$' "${MOCK_LOG}" || fail 'planner start line'
assert_eq "$(call_count '^agent prompt new-pane Plan request for repo')" 1 'planner prompt count'
grep -q 'planner-prompt.md' "${MOCK_LOG}" || fail 'planner prompt lacks the planner rules path'
[ -f "${REVIEW_DIR}/.plan.sent" ] || fail 'plan sent marker missing'
assert_eq "$(sed -n '3p' "${REVIEW_DIR}/.plan.sent")" new-pane 'plan sent pane'
# Waiting on the planner never overwrites .last (that belongs to the planner's own request-review runs).
[ -f "${REVIEW_DIR}/.last-plan.out" ] || fail 'plan mode should log to .last-plan.out'
[ "$(cut -d' ' -f1 "${REVIEW_DIR}/.last")" != 3 ] || fail 'plan wait wrote exit 3 into .last'
# Continuation reuses the saved planner and never re-prompts.
run_review plan-live plan
assert_eq "${RUN_STATUS}" 3 'planner continuation status'
assert_eq "$(call_count '^agent prompt ')" 0 'planner continuation prompt count'
assert_eq "$(call_count '^pane split ')" 0 'planner continuation split count'
# Delivery: plan.md complete, the tree clean, and the planner's commits touch only plan paths → exit 0.
assert_eq "$(sed -n '6p' "${REVIEW_DIR}/.plan.sent")" "$(git -C "${REPO}" rev-parse HEAD)" 'dispatch HEAD recorded'
commit_file docs/plans/M5.md 'docs: plan M5'
printf 'PLAN: docs/plans/M5.md\n边界：不改 WorldProposal。\nPLAN-COMPLETE\n' > "${REVIEW_DIR}/plan.md"
run_review plan-live plan
assert_eq "${RUN_STATUS}" 0 'planner delivery status'
assert_eq "$(cat "${TMP}/stdout")" "${REVIEW_DIR}/plan.md" 'planner delivery prints plan.md'
# The planner committed code alongside the plan → exit 4, even with a clean tree.
commit_file src/sneaky.py 'planner touched code'
run_review plan-live plan
assert_eq "${RUN_STATUS}" 4 'planner touched code status'
grep -q '改了计划以外的文件：src/sneaky.py' "${TMP}/stdout" || fail 'stray file not named'
git -C "${REPO}" reset -q --hard HEAD~1
# Delivered but the planner left uncommitted work → exit 4.
printf 'x\n' > "${REPO}/src/left.py"; git -C "${REPO}" add src/left.py
run_review plan-live plan
assert_eq "${RUN_STATUS}" 4 'planner left dirty tree status'
grep -q '未提交的改动' "${TMP}/stdout" || fail 'dirty delivery message'
git -C "${REPO}" reset -q src/left.py; rm -f "${REPO}/src/left.py"
# A STOP answer → exit 4.
printf 'STOP: 任务和 M4 计划冲突\nPLAN-COMPLETE\n' > "${REVIEW_DIR}/plan.md"
run_review plan-live plan
assert_eq "${RUN_STATUS}" 4 'planner stop status'
grep -q '规划者停下了' "${TMP}/stdout" || fail 'planner stop message'
assert_eq "$(cut -d' ' -f1 "${REVIEW_DIR}/.last")" 4 'planner stop recorded in .last'
grep -q '规划者停下了' "${REVIEW_DIR}/.last.out" || fail 'planner stop output not copied to .last.out'
# A changed request supersedes the old answer and is dispatched afresh to the existing planner.
printf 'task: 做 M6\n' > "${REVIEW_DIR}/plan-request.md"
run_review plan-idle plan
assert_eq "${RUN_STATUS}" 3 'planner new request status'
assert_eq "$(call_count '^agent prompt new-pane Plan request')" 1 'planner new request prompt count'
assert_eq "$(call_count '^agent start ')" 0 'planner new request reuses the pane'
[ -f "${REVIEW_DIR}/plan.md" ] && fail 'old plan.md should be discarded'
# The review path is untouched by planner state: a plain run still routes.
rm -f "${REVIEW_DIR}/request.md" "${REVIEW_DIR}"/.triage*
run_review new
[ "${RUN_STATUS}" -ne 2 ] || fail "review path broken by planner files: $(cat "${TMP}/stdout")"
echo 'PASS request-review plan dispatches, waits, delivers and stops like a review'

# ---- SKIP_REVIEW takes a commit range: one call registers every commit in it. ----
rm -f "${REVIEW_DIR}/request.md" "${REVIEW_DIR}"/.triage* "${TRIAGE_OUT}"
B=$(git -C "${REPO}" rev-parse HEAD)
SB=$(git -C "${REPO}" rev-parse --short HEAD)
printf '2026-09-10 | %s | round 1/2 | 30s | plan\n2026-09-10 | %s | round 1/3 | 60s | code\n' "${SB}" "${SB}" >> "${REPO}/docs/reviews/timing.md"
commit_file src/core/x1.py 'waived 1'
commit_file src/core/x2.py 'waived 2'
commit_file src/core/x3.py 'waived 3'
W=$(git -C "${REPO}" rev-parse HEAD)
( cd "${REPO}" && PATH="${MOCK_BIN}:${PATH}" MOCK_LOG="${MOCK_LOG}" MOCK_SCENARIO=new MOCK_REVIEW_WT="${REVIEW_WT}" \
    SKIP_REVIEW="${B}..${W}" "${REQUEST_REVIEW}" "range waiver" ) > "${TMP}/stdout" 2> "${TMP}/stderr" \
  || fail 'range waiver should exit 0'
for c in $(git -C "${REPO}" rev-list "${B}..${W}"); do
  grep -q " $(git -C "${REPO}" rev-parse --short "${c}") " "${REPO}/docs/reviews/skipped.md" \
    || fail "range waiver did not register $(git -C "${REPO}" rev-parse --short "${c}")"
done
assert_eq "$(grep -c 'range waiver' "${REPO}/docs/reviews/skipped.md")" 3 'range waiver row count'
grep -q "^${B}\b" "${REPO}/docs/reviews/skipped.md" && fail 'range waiver must not register the base itself'
# The waived commits no longer push the range into review.
commit_file docs/note9.md 'note after waiver'
run_review new
assert_eq "${RUN_STATUS}" 0 'waived range routing status'
assert_eq "$(call_count '^agent ')" 0 'waived range must not wake the reviewer'
echo 'PASS SKIP_REVIEW registers a whole commit range in one call'

# ---- A fully waived prefix is named when the base is printed, so the human can advance it. ----
rm -f "${REVIEW_DIR}"/.triage* "${TRIAGE_OUT}"
commit_file src/core/y.py 'new work after the waived range'
run_review new
assert_eq "${RUN_STATUS}" 6 'post-waiver review status'
grep -q "^base sha: ${B}" "${TMP}/stdout" || fail 'routed base should stay at the last real review'
grep -q "NOTE: base 之后.*豁免.*$(git -C "${REPO}" rev-parse --short "${W}")" "${TMP}/stderr" \
  || fail 'no NOTE naming the waived prefix and the base it suggests'
echo 'PASS a fully waived prefix is flagged when the base is printed'

# ---- 唤醒模式：派发完就把回合交回给人，由一个只盯这次的进程叫醒写手。----
printf 'REVIEW_WAKE=1\nREVIEW_WAKE_FORK=0\n' >> "${REPO}/.review.conf"
clear_cycle() { rm -f "${REVIEW_DIR}"/.r*.sent "${REVIEW_DIR}"/r*-findings.md \
  "${REVIEW_DIR}"/r*-responses.md "${REVIEW_DIR}/.wake"; }

clear_cycle
write_request code "${B}" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'wake dispatch status'
grep -q '已派发' "${TMP}/stdout" || fail 'wake dispatch should tell the writer to stop, not to re-run'
[ -f "${REVIEW_DIR}/.wake" ] || fail 'wake marker not written'
assert_eq "$(sed -n '2p' "${REVIEW_DIR}/.wake")" REVIEW-COMPLETE 'wake marker sentinel word'
assert_eq "$(sed -n '3p' "${REVIEW_DIR}/.wake")" reviewer-pane 'wake marker watched pane'
assert_eq "$(sed -n '4p' "${REVIEW_DIR}/.wake")" writer-pane 'wake marker writer pane'
assert_eq "$(sed -n '5p' "${REVIEW_DIR}/.wake")" term-writer 'wake marker writer terminal'
assert_eq "$(call_count '^agent prompt reviewer-pane')" 1 'wake dispatch still sends the review prompt'
echo 'PASS wake mode dispatches then hands the turn back'

# Outside herdr nobody can wake the writer, so it must keep waiting in the foreground.
clear_cycle
write_request code "${B}" 1/3
set +e
( cd "${REPO}" && PATH="${MOCK_BIN}:${PATH}" MOCK_LOG="${MOCK_LOG}" MOCK_SCENARIO=new \
    MOCK_REVIEW_WT="${REVIEW_WT}" MOCK_REPO="$(cd "${REPO}" && pwd -P)" "${REQUEST_REVIEW}" \
) > "${TMP}/stdout" 2> "${TMP}/stderr"
NOPANE_STATUS=$?
set -e
assert_eq "${NOPANE_STATUS}" 3 'no-pane fallback status'
[ -f "${REVIEW_DIR}/.wake" ] && fail 'without HERDR_PANE_ID no waker may be armed'
grep -q '再次运行' "${TMP}/stdout" || fail 'no-pane fallback should keep the old PENDING message'
echo 'PASS without a pane of its own the script still waits in the foreground'

# The waker itself: sentinel is in, writer is idle → prompt it once and clear the marker.
arm_wake() {   # $1=writer terminal
  printf 'REVIEW-COMPLETE\n' > "${REVIEW_DIR}/r1-findings.md"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "${REVIEW_DIR}/r1-findings.md" REVIEW-COMPLETE \
    reviewer-pane writer-pane "$1" '' '评审已完成，再次运行 request-review 领取结果。' 0 \
    > "${REVIEW_DIR}/.wake"
  : > "${MOCK_LOG}"
}
run_wake() {   # $1=scenario
  set +e
  ( cd "${REPO}" && PATH="${MOCK_BIN}:${PATH}" MOCK_LOG="${MOCK_LOG}" MOCK_SCENARIO="$1" \
      MOCK_REVIEW_WT="${REVIEW_WT}" MOCK_REPO="$(cd "${REPO}" && pwd -P)" \
      "${REQUEST_REVIEW}" --wake "${REVIEW_DIR}/.wake" ) > "${TMP}/stdout" 2> "${TMP}/stderr"
  set -e
}
arm_wake term-writer
run_wake wake
assert_eq "$(call_count '^agent prompt writer-pane')" 1 'waker should wake the writer exactly once'
[ -f "${REVIEW_DIR}/.wake" ] && fail 'waker should clear its marker after waking'
echo 'PASS the waker wakes an idle writer and clears its marker'

# The pane still exists but now hosts a different terminal → never type into it.
arm_wake term-writer
run_wake wake-drift
assert_eq "$(call_count '^agent prompt ')" 0 'waker must not type into a drifted pane'
[ -f "${REVIEW_DIR}/.wake" ] || fail 'a drifted wake should leave its marker for the human'
echo 'PASS the waker fails closed when the writer pane drifted'

# A real fork must leave the writer's .last / .last.out alone — the board reads those.
clear_cycle
grep -v '^REVIEW_WAKE_FORK=' "${REPO}/.review.conf" > "${TMP}/conf" && mv "${TMP}/conf" "${REPO}/.review.conf"
write_request code "${B}" 1/3
run_review new
assert_eq "${RUN_STATUS}" 3 'real fork status'
WPID=$(sed -n '8p' "${REVIEW_DIR}/.wake")
case "${WPID}" in [1-9]*) ;; *) fail "real fork should record a pid, got '${WPID}'";; esac
grep -q '已派发' "${REVIEW_DIR}/.last.out" || fail 'the waker clobbered the writer .last.out'
assert_eq "$(cut -d' ' -f1 "${REVIEW_DIR}/.last")" 3 'the waker clobbered the writer .last'
kill "${WPID}" 2>/dev/null || true
echo 'PASS a real fork leaves the writer records the board reads untouched'

# The waker must never type into the agent it is watching — only into the writer.
printf 'REVIEW_WAKE_FORK=0\n' >> "${REPO}/.review.conf"
arm_wake term-writer
run_wake wake
assert_eq "$(call_count '^agent prompt reviewer-pane')" 0 'waker must never prompt the watched agent'
assert_eq "$(call_count '^agent prompt writer-pane')" 1 'waker still wakes the writer'
echo 'PASS the waker never confuses the watched agent with the writer'

# Planner and writer share a directory; if discovery ever returned our own pane, refuse to arm.
clear_cycle
write_request code "${B}" 1/3
set +e
( cd "${REPO}" && PATH="${MOCK_BIN}:${PATH}" MOCK_LOG="${MOCK_LOG}" MOCK_SCENARIO=new \
    MOCK_REVIEW_WT="${REVIEW_WT}" MOCK_REPO="$(cd "${REPO}" && pwd -P)" \
    HERDR_PANE_ID=reviewer-pane "${REQUEST_REVIEW}" ) > "${TMP}/stdout" 2> "${TMP}/stderr"
SELFWATCH_STATUS=$?
set -e
assert_eq "${SELFWATCH_STATUS}" 3 'self-watch fallback status'
[ -f "${REVIEW_DIR}/.wake" ] && fail 'must not arm a waker that watches and wakes the same pane'
grep -q '再次运行' "${TMP}/stdout" || fail 'self-watch should fall back to foreground waiting'
echo 'PASS arming is refused when the watched pane is our own'
