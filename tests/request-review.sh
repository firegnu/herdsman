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

case "$1 $2" in
  'agent list')
    case "${MOCK_SCENARIO}" in
      new|live|lost-once|lost|stalled-working)
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
      HERDR_PANE_ID=writer-pane \
      "${REQUEST_REVIEW}"
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

# With REVIEW_PLAN_PATHS set, round 1 refuses a diff that does not match the declared kind.
mkdir -p "${REPO}/docs/plans" "${REPO}/src"
printf 'plan\n' > "${REPO}/docs/plans/p.md"
printf 'code\n' > "${REPO}/src/a.txt"
git -C "${REPO}" add docs/plans/p.md src/a.txt
git -C "${REPO}" commit -qm mixed
printf 'REVIEW_PLAN_PATHS="docs/plans/*"\n' >> "${REPO}/.review.conf"
write_request code "${BASE}" 1/3
run_review none
assert_rejected 'mixed code request' 'docs/plans/p.md'
write_request plan "${BASE}" 1/3
run_review none
assert_rejected 'mixed plan request' 'src/a.txt'
# Round 2+ is frozen scope: the same diff is not re-checked.
write_request code "${BASE}" 2/3
run_review new
assert_eq "${RUN_STATUS}" 3 'mixed diff round 2 status'
rm -f "${REVIEW_DIR}"/.r*.sent "${PANE_CACHE}"
echo 'PASS REVIEW_PLAN_PATHS refuses a round-1 diff that contradicts kind'

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
