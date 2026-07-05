#!/bin/bash
# test-chp-commit-file.sh — #330: chp_commit_file whole-op CHP write verb.
#
# Proves the largest single #296 migration is a zero-behavior-change GitHub
# refactor: the 8 raw git-Data-API `gh api` calls in upload-screenshot.sh move
# BEHIND one whole-op verb `chp_commit_file REPO BRANCH FILE_PATH CONTENT_BASE64
# MESSAGE` (GitHub leaf chp_github_commit_file), the caller keeping the local
# file-read + base64 encode + the fail-on-empty-SHA glue (provider-spec.md §3.2,
# [INV-95]).
#
#   1. GOLDEN whole-op (AC1) — a STATEFUL gh stub emitting realistic per-endpoint
#      JSON (the leaf PIPES `gh api | jq -r '.ref // empty'` + `.sha` — a pure
#      argv-recorder writes nothing to stdout and would break the orchestration,
#      [P3 F2]). Covers branch-absent (create path), branch-present (update path),
#      new-file (create), and the fail paths (leaf returns non-zero → caller fail).
#   2. Trap-hazard regression (AC2) — the leaf uses a function-scoped, SELF-
#      DISARMING `trap '…; trap - RETURN' RETURN` (NOT `… EXIT`, which clobbers
#      the caller's trap; a BARE `… RETURN` with no self-disarm PERSISTS and
#      re-fires on the chp_commit_file shim's own return with the leaf's locals
#      out of scope → `unbound variable` under set -u, reproduced on-box). The
#      self-disarm keeps the RETURN-trap contract (AC2) while firing exactly
#      once per invocation; a caller's OWN EXIT trap is NOT clobbered + its temp
#      survives to fire at caller-exit (the on-box repro, pinned, driven THROUGH
#      the shim, across repeated calls).
#   3. REPO threaded from $1 (AC3) — a different global $REPO does NOT win.
#   4. SOURCE-SHAPE (AC4) — zero raw `gh api …git/…`/`…contents/…` in
#      upload-screenshot.sh; the `command -v gh` guard stays; new leaf+shim
#      present; the verb call present; baseline −8 (7 sigs) reconciled; the
#      cutover guard passes.
#   5. Lib resolution + self-guarding shim (leaf-absent → WARN + return 1).
#
# Run: env -u PROJECT_DIR bash tests/unit/test-chp-commit-file.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
REVIEW_SCRIPTS="$PROJECT_ROOT/skills/autonomous-review/scripts"
CHP_LIB="$SCRIPTS/lib-code-host.sh"
CHP_GITHUB="$SCRIPTS/providers/chp-github.sh"
UPLOAD="$REVIEW_SCRIPTS/upload-screenshot.sh"
BASELINE="$SCRIPTS/providers/cutover-baseline.json"
FAKE_PROVIDER="$SCRIPT_DIR/fixtures/provider-degraded"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle: |$needle|"; echo "      hay:    |$hay|"
    FAIL=$((FAIL + 1))
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      unexpected needle: |$needle|"; echo "      hay: |$hay|"
    FAIL=$((FAIL + 1))
  fi
}
pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

export REPO=zxkane/autonomous-dev-team

# ===========================================================================
# STATEFUL gh stub generator. Emits a `gh()` shell function (as a string) that
# dispatches on the git-Data-API endpoint and serves realistic JSON, honoring an
# in-argv `--jq <filter>` (steps blobs/trees/commits) and writing the put-contents
# response to the `--input … >file` path the caller redirects. Driven by env knobs:
#   STUB_BRANCH_PRESENT=1   get-ref returns a ref (update path) else empty (create path)
#   STUB_FILE_PRESENT=1     get-contents returns a sha (update) else empty (new file)
#   STUB_PUT_FAILS=1        put-contents response carries no .content.sha (fail path)
#   STUB_CREATE_FAILS=1     branch-create chain breaks (re-get-ref still empty)
#   STUB_ARGV_FILE          append each call's joined argv (one call per line) here
# The stub serves create-blob/tree/commit SHAs so the create path completes.
# ===========================================================================
_stub_gh='
gh() {
  # record argv (space-joined) for path/REPO assertions
  if [ -n "${STUB_ARGV_FILE:-}" ]; then printf "%s\n" "$*" >> "$STUB_ARGV_FILE"; fi
  # find the endpoint (first non-flag positional after the `api` subcommand) and any --jq filter
  local endpoint="" jqf="" i a
  for ((i=1;i<=$#;i++)); do
    a="${!i}"
    if [ "$a" = "api" ]; then continue; fi
    if [ "$a" = "--jq" ]; then local n=$((i+1)); jqf="${!n}"; fi
    if [ -z "$endpoint" ] && [ "${a:0:1}" != "-" ] && [ "$a" != "PUT" ]; then endpoint="$a"; fi
  done
  local json="{}"
  case "$endpoint" in
    *git/ref/heads/*)
      # branch-create chain: on the create path the SECOND get-ref (verify) only
      # succeeds if the create did not fail. The leaf runs each get-ref inside a
      # `$(gh … | jq …)` command-sub SUBSHELL, so the "seen-once" state can NOT be
      # an in-process variable (it would not survive the subshell) — persist it in
      # a FILE keyed by STUB_REF_STATE so the re-verify get-ref sees the first one.
      if [ "${STUB_BRANCH_PRESENT:-0}" = "1" ]; then json="{\"ref\":\"refs/heads/screenshots\"}"
      else
        local seen=0
        if [ -n "${STUB_REF_STATE:-}" ] && [ -f "$STUB_REF_STATE" ]; then seen=1; fi
        if [ "$seen" = "1" ] && [ "${STUB_CREATE_FAILS:-0}" != "1" ]; then
          json="{\"ref\":\"refs/heads/screenshots\"}"
        else
          json="{}"
        fi
        [ -n "${STUB_REF_STATE:-}" ] && : > "$STUB_REF_STATE"   # mark first get-ref seen
      fi
      ;;
    *git/blobs*)    json="{\"sha\":\"blobsha111\"}";;
    *git/trees*)    json="{\"sha\":\"treesha222\"}";;
    *git/commits*)  json="{\"sha\":\"commitsha333\"}";;
    *git/refs*)     json="{\"ref\":\"refs/heads/screenshots\"}";;
    *contents/*\?ref=*|*contents/*ref=*)
      # get-contents (existing-file SHA for update)
      if [ "${STUB_FILE_PRESENT:-0}" = "1" ]; then json="{\"sha\":\"existingfilesha444\"}"; else json="{}"; fi
      ;;
    *contents/*)
      # put-contents (the PUT upload). Response carries .content.sha unless fail.
      if [ "${STUB_PUT_FAILS:-0}" = "1" ]; then json="{}"; else json="{\"content\":{\"sha\":\"uploadedsha555\"}}"; fi
      ;;
  esac
  if [ -n "$jqf" ]; then printf "%s" "$json" | jq -r "$jqf"; else printf "%s" "$json"; fi
  return 0
}
'

# run_commit — source the GitHub leaf with the stateful stub and invoke
# chp_github_commit_file; echo "SHA=<stdout> RC=<rc>".
run_commit() {
  # env knobs are passed through from the caller's environment
  bash -c '
    set -uo pipefail
    '"$_stub_gh"'
    # source ONLY the github leaf (it is self-contained; REPO from $1)
    source "'"$CHP_GITHUB"'" 2>/dev/null
    out="$(chp_github_commit_file "$@")"; rc=$?
    printf "SHA=%s RC=%s" "$out" "$rc"
  ' _ "$@"
}

# ===========================================================================
# 1. GOLDEN whole-op (AC1)
# ===========================================================================
echo "=== AC1: golden whole-op (stateful gh stub, per-endpoint JSON) ==="

# TC-CCF-001 — orphan branch ABSENT → create-blob→tree→commit→ref→verify→put.
# STUB_REF_STATE points at a fresh path that does NOT exist yet (first get-ref →
# empty/create path); the stub creates it so the re-verify get-ref succeeds.
argv1="$(mktemp)"; refstate1="$(mktemp)"; rm -f "$refstate1"
res=$(STUB_BRANCH_PRESENT=0 STUB_FILE_PRESENT=0 STUB_PUT_FAILS=0 STUB_CREATE_FAILS=0 \
  STUB_ARGV_FILE="$argv1" STUB_REF_STATE="$refstate1" \
  run_commit "$REPO" screenshots "pr-7/TC-1.png" "BASE64CONTENT" "screenshot: PR #7 TC-1")
rm -f "$refstate1"
assert_eq "TC-CCF-001 branch-absent create path echoes put-contents sha, rc 0" "SHA=uploadedsha555 RC=0" "$res"
calls="$(tr '\n' '|' < "$argv1")"
assert_contains "TC-CCF-001 create path hits git/blobs"   "git/blobs"   "$calls"
assert_contains "TC-CCF-001 create path hits git/trees"   "git/trees"   "$calls"
assert_contains "TC-CCF-001 create path hits git/commits" "git/commits" "$calls"
assert_contains "TC-CCF-001 create path hits git/refs"    "git/refs"    "$calls"
assert_contains "TC-CCF-001 create path PUTs the file"    "contents/pr-7/TC-1.png" "$calls"
rm -f "$argv1"

# TC-CCF-002 — branch PRESENT → SKIP create, get-contents (existing) → put (update).
argv2="$(mktemp)"
res=$(STUB_BRANCH_PRESENT=1 STUB_FILE_PRESENT=1 STUB_PUT_FAILS=0 STUB_ARGV_FILE="$argv2" \
  run_commit "$REPO" screenshots "pr-7/TC-1.png" "BASE64CONTENT" "screenshot: PR #7 TC-1")
assert_eq "TC-CCF-002 branch-present update path echoes sha, rc 0" "SHA=uploadedsha555 RC=0" "$res"
calls="$(tr '\n' '|' < "$argv2")"
assert_not_contains "TC-CCF-002 branch-present SKIPS git/blobs (no create chain)" "git/blobs" "$calls"
assert_contains "TC-CCF-002 branch-present reads get-contents for the update sha" "contents/pr-7/TC-1.png?ref=screenshots" "$calls"
rm -f "$argv2"

# TC-CCF-003 — put-contents fails (empty .content.sha) → leaf returns non-zero.
res=$(STUB_BRANCH_PRESENT=1 STUB_FILE_PRESENT=1 STUB_PUT_FAILS=1 \
  run_commit "$REPO" screenshots "pr-7/TC-1.png" "BASE64CONTENT" "screenshot: PR #7 TC-1")
assert_contains "TC-CCF-003 put-contents failure → leaf rc != 0 (caller fail triggers)" "RC=1" "$res"

# TC-CCF-004 — branch-create fails (re-verify get-ref still empty) → non-zero.
refstate4="$(mktemp)"; rm -f "$refstate4"
res=$(STUB_BRANCH_PRESENT=0 STUB_CREATE_FAILS=1 STUB_FILE_PRESENT=0 STUB_PUT_FAILS=0 \
  STUB_REF_STATE="$refstate4" \
  run_commit "$REPO" screenshots "pr-7/TC-1.png" "BASE64CONTENT" "screenshot: PR #7 TC-1")
rm -f "$refstate4"
assert_contains "TC-CCF-004 branch-create failure → leaf rc != 0" "RC=1" "$res"

# TC-CCF-005 — new file on existing branch (get-contents empty) → PUT without sha.
argv5="$(mktemp)"
res=$(STUB_BRANCH_PRESENT=1 STUB_FILE_PRESENT=0 STUB_PUT_FAILS=0 STUB_ARGV_FILE="$argv5" \
  run_commit "$REPO" screenshots "pr-9/TC-NEW.png" "BASE64CONTENT" "screenshot: PR #9 TC-NEW")
assert_eq "TC-CCF-005 new-file create-on-branch echoes sha, rc 0" "SHA=uploadedsha555 RC=0" "$res"
rm -f "$argv5"

# ===========================================================================
# 2. Trap-hazard regression (AC2 — the load-bearing fix)
# ===========================================================================
echo "=== AC2: leaf uses a SELF-DISARMING function-scoped trap … RETURN (no EXIT clobber, no persistent re-fire); caller EXIT trap untouched, no unbound-var crash ==="

# TC-CCF-010 — SOURCE-SHAPE: chp_github_commit_file uses a function-scoped
# `trap … RETURN` (AC2's literal contract) that DISARMS itself in its own body
# (`trap - RETURN`) — never a bare `trap … EXIT` (which clobbers the caller's
# EXIT trap) and never a bare/non-self-disarming `trap … RETURN` (which is NOT
# cleared at leaf return and fires AGAIN when the chp_commit_file shim itself
# returns, by then the leaf's `local` temps are gone → `unbound variable` under
# set -u). Extract the function body, STRIP comment lines (a comment mentioning
# "trap" is prose, not a call site), then grep the CODE.
fn_code=$(awk '/^chp_github_commit_file\(\)/{f=1} f{print} /^}/{if(f) exit}' "$CHP_GITHUB" \
          | grep -vE '^[[:space:]]*#')
if grep -qE "trap[[:space:]]+'[^']*'[[:space:]]+RETURN" <<<"$fn_code"; then
  pass "TC-CCF-010 chp_github_commit_file installs a function-scoped trap … RETURN (AC2 literal contract)"
else
  fail "TC-CCF-010 chp_github_commit_file does NOT install a function-scoped trap … RETURN"
fi
if grep -qE '\btrap\b.*\bEXIT\b' <<<"$fn_code"; then
  fail "TC-CCF-010a chp_github_commit_file MUST NOT install a trap … EXIT (clobbers the caller's own EXIT trap)"
else
  pass "TC-CCF-010a chp_github_commit_file installs no trap … EXIT"
fi
if grep -qE "trap[[:space:]]+'[^']*trap - RETURN[^']*'[[:space:]]+RETURN" <<<"$fn_code"; then
  pass "TC-CCF-010b the RETURN trap SELF-DISARMS ('trap - RETURN' is its own last action)"
else
  fail "TC-CCF-010b the RETURN trap does NOT self-disarm — it will persist and re-fire on the shim's return"
fi
if grep -qE "trap[[:space:]]+'rm -f \"\\\$json_tmpfile\" \"\\\$upload_response_file\"" <<<"$fn_code"; then
  pass "TC-CCF-010c the RETURN trap body cleans json_tmpfile + upload_response_file"
else
  fail "TC-CCF-010c the RETURN trap body does NOT clean the expected temps"
fi

# TC-CCF-011 — BEHAVIORAL on-box repro, the PRODUCTION crash path: a CALLER under
# `set -euo pipefail` (upload-screenshot.sh's shell options) with its OWN
# `trap … EXIT` sources the FULL lib-code-host.sh and calls the verb TWICE
# THROUGH the `chp_commit_file` SHIM (NOT the leaf directly — the shim→leaf
# return is exactly what makes a NON-self-disarming RETURN trap re-fire with the
# leaf's locals out of scope; calling twice additionally proves the self-disarm
# doesn't leave the trap dead for the SECOND invocation either — each call
# re-installs its own trap fresh). After both verb calls return, the caller must
# reach PRE_EXIT_OK (no crash) AND on exit its OWN EXIT trap must fire (not
# clobbered) AND there must be NO `unbound variable`. This is the bug the
# issue's P3 fix (as amended for AC2) exists to prevent.
caller_marker="$(mktemp)"; rm -f "$caller_marker"      # path the caller's EXIT trap creates
caller_tmp_probe="$(mktemp)"; rm -f "$caller_tmp_probe" # caller records its own temp path here
trap_out=$(
  CALLER_MARKER="$caller_marker" CALLER_TMP_PROBE="$caller_tmp_probe" REPO="$REPO" \
  bash -c '
    set -euo pipefail
    '"$_stub_gh"'
    CALLER_TMP="$(mktemp)"
    printf "%s" "$CALLER_TMP" > "$CALLER_TMP_PROBE"
    # the caller installs its OWN EXIT trap BEFORE sourcing/calling the verb
    trap '\''printf done > "$CALLER_MARKER"; rm -f "$CALLER_TMP"'\'' EXIT
    source "'"$CHP_LIB"'" 2>/dev/null
    # call THROUGH the shim (the production path) TWICE — both branch-present
    # (update) and the put-success path so the verb returns 0 each time and the
    # shim returns into the caller each time (the re-fire hazard site).
    sha1=$(STUB_BRANCH_PRESENT=1 STUB_FILE_PRESENT=1 \
            chp_commit_file "$REPO" screenshots "pr-1/T.png" "B64" "msg") || true
    echo "VERB_SHA_1=$sha1"
    sha2=$(STUB_BRANCH_PRESENT=1 STUB_FILE_PRESENT=1 \
            chp_commit_file "$REPO" screenshots "pr-2/T.png" "B64" "msg2") || true
    echo "VERB_SHA_2=$sha2"
    echo "PRE_EXIT_OK"
  ' 2>&1
)
assert_contains "TC-CCF-011 verb-through-shim ran to completion TWICE (no crash before caller exit)" "PRE_EXIT_OK" "$trap_out"
assert_contains "TC-CCF-011b first shim call returned the SHA" "VERB_SHA_1=uploadedsha555" "$trap_out"
assert_contains "TC-CCF-011b2 SECOND shim call ALSO returned the SHA (self-disarm didn't kill the trap for call #2)" "VERB_SHA_2=uploadedsha555" "$trap_out"
assert_not_contains "TC-CCF-011c NO 'unbound variable' (self-disarming RETURN trap never re-fires stale)" "unbound variable" "$trap_out"
# the caller's OWN EXIT trap fired → not clobbered by the leaf
if [[ -f "$caller_marker" && "$(cat "$caller_marker")" == "done" ]]; then
  pass "TC-CCF-011d caller's own EXIT trap STILL fires (leaf installed no EXIT trap)"
else
  fail "TC-CCF-011d caller EXIT trap did NOT fire (leaf clobbered it)"
fi
# the caller's temp was removed by its (surviving) EXIT trap
caller_tmp_path="$(cat "$caller_tmp_probe" 2>/dev/null || true)"
if [[ -n "$caller_tmp_path" && ! -e "$caller_tmp_path" ]]; then
  pass "TC-CCF-011e caller temp cleaned by its surviving EXIT trap"
else
  fail "TC-CCF-011e caller temp NOT cleaned (path=$caller_tmp_path)"
fi
rm -f "$caller_marker" "$caller_tmp_probe"

# ===========================================================================
# 3. REPO threaded from $1, not a global (AC3 — the #324 lesson)
# ===========================================================================
echo "=== AC3: REPO threaded from arg, not global ==="
argvR="$(mktemp)"
# Export a DIFFERENT global REPO; pass the CORRECT one as $1. Every path must use $1.
res=$(REPO="zxkane/WRONG-GLOBAL" STUB_BRANCH_PRESENT=1 STUB_FILE_PRESENT=1 STUB_ARGV_FILE="$argvR" \
  run_commit "zxkane/correct-arg-repo" screenshots "pr-3/T.png" "B64" "msg")
callsR="$(tr '\n' '|' < "$argvR")"
assert_contains "TC-CCF-020 leaf paths use the arg REPO (repos/zxkane/correct-arg-repo/…)" "repos/zxkane/correct-arg-repo/" "$callsR"
assert_not_contains "TC-CCF-020b leaf paths NEVER use the global REPO" "WRONG-GLOBAL" "$callsR"
rm -f "$argvR"

# ===========================================================================
# 4. SOURCE-SHAPE (AC4)
# ===========================================================================
echo "=== AC4: source-shape (zero raw gh api git/contents; guard stays; leaf+shim+verb; baseline) ==="

# TC-CCF-030 — zero raw `gh api …git/…`/`…contents/…` in upload-screenshot.sh
# (strip comment lines first; we only care about executable call sites).
raw_git=$(grep -vE '^[[:space:]]*#' "$UPLOAD" | grep -cE 'gh api "?repos/[^"]*/(git/|contents/)' || true)
assert_eq "TC-CCF-030 zero raw gh-api git/contents calls in upload-screenshot.sh" "0" "$raw_git"

# TC-CCF-031 — the `command -v gh` presence guard STAYS (residue).
if grep -qE 'command -v gh' "$UPLOAD"; then
  pass "TC-CCF-031 command -v gh presence guard stays"
else
  fail "TC-CCF-031 command -v gh guard was removed (it must stay)"
fi

# TC-CCF-032 — new leaf chp_github_commit_file present.
if grep -qE '^chp_github_commit_file\(\)' "$CHP_GITHUB"; then
  pass "TC-CCF-032 chp_github_commit_file leaf present in providers/chp-github.sh"
else
  fail "TC-CCF-032 chp_github_commit_file leaf MISSING"
fi

# TC-CCF-033 — new shim chp_commit_file present + self-guarding.
shim_defined=$(env -u CODE_HOST bash -c 'source "'"$CHP_LIB"'" 2>/dev/null; declare -F chp_commit_file >/dev/null && echo yes || echo no')
assert_eq "TC-CCF-033 chp_commit_file shim defined by lib-code-host.sh" "yes" "$shim_defined"
if grep -qE 'chp_commit_file\(\)' "$CHP_LIB" && grep -qE 'no chp_\$\{CODE_HOST\}_commit_file leaf' "$CHP_LIB"; then
  pass "TC-CCF-033b chp_commit_file shim is self-guarding (WARN on absent leaf)"
else
  fail "TC-CCF-033b chp_commit_file shim not self-guarding"
fi

# TC-CCF-035 — upload-screenshot.sh routes through chp_commit_file.
if grep -qE 'chp_commit_file' "$UPLOAD"; then
  pass "TC-CCF-035 upload-screenshot.sh invokes chp_commit_file"
else
  fail "TC-CCF-035 upload-screenshot.sh does NOT invoke chp_commit_file"
fi

# TC-CCF-034 — baseline shrank: no upload-screenshot.sh git/contents sigs remain.
# The `command -v gh` presence guard was this issue's premise for #344 (#296 FINAL
# batch) to allowlist the whole file — once landed, upload-screenshot.sh carries
# ZERO baseline signatures at all (allowlisted files are excluded from the scan
# entirely, not baselined survivors). TC-CCF-034b now asserts that end state.
n_us_gitcontents=$(jq -r '[.surviving_sites[] | select(.file=="upload-screenshot.sh") | select(.content|test("git/|contents/"))] | length' "$BASELINE" 2>/dev/null || echo ERR)
assert_eq "TC-CCF-034 baseline has zero upload-screenshot.sh git/contents sigs" "0" "$n_us_gitcontents"
n_us_any=$(jq -r '[.surviving_sites[] | select(.file=="upload-screenshot.sh")] | length' "$BASELINE" 2>/dev/null || echo ERR)
assert_eq "TC-CCF-034b upload-screenshot.sh is allowlisted (#344) — zero baseline sigs of any kind" "0" "$n_us_any"

# The cutover guard (INV-91) PASSES against the real repo (Check 1 reconciles the
# tree to the shrunk baseline). Run it like test-provider-cutover.sh does.
CUTOVER="$SCRIPTS/check-provider-cutover.sh"
if bash "$CUTOVER" >/dev/null 2>&1; then
  pass "TC-CCF-034c check-provider-cutover.sh PASSES (tree reconciles with shrunk baseline)"
else
  fail "TC-CCF-034c check-provider-cutover.sh FAILED (baseline/tree mismatch)"
fi

# ===========================================================================
# 5. Lib resolution + self-guarding shim
# ===========================================================================
echo "=== Lib resolution (skill-tree readlink -f) + self-guarding shim ==="

# TC-CCF-040 — upload-screenshot.sh resolves lib-code-host.sh via the readlink -f
# skill-tree idiom (NOT $_SCRIPT_DIR), mirroring mark-issue-checkbox.sh.
if grep -qE 'readlink -f' "$UPLOAD" && grep -qE 'autonomous-dispatcher/scripts/lib-code-host.sh' "$UPLOAD"; then
  pass "TC-CCF-040 upload-screenshot.sh resolves lib-code-host.sh via readlink -f skill tree"
else
  fail "TC-CCF-040 upload-screenshot.sh does NOT resolve lib-code-host.sh via the skill-tree idiom"
fi

# TC-CCF-041 — self-guarding shim: leaf-absent → chp_commit_file returns
# non-zero + WARN, does NOT command-not-found-abort.
# [#419 P3-4 review-r4] The degraded fixture now defines chp_degraded_commit_file
# so the conformance runner can assert coverage. To keep this test's semantic
# (shim degrades cleanly when the leaf is genuinely absent), we pivot to an
# empty provider dir + a synthetic CODE_HOST name — the shim's self-guard
# path is what matters, and it's now isolated from future fixture-leaf additions.
EMPTY_PROV_DIR="$(mktemp -d)"
guard_out=$(
  env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      CODE_HOST=emptyprov AUTONOMOUS_PROVIDERS_DIR="$EMPTY_PROV_DIR" \
  bash -c '
    set -uo pipefail
    source "'"$CHP_LIB"'" 2>/dev/null
    chp_commit_file o/r screenshots p/x.png B64 msg 2>&1
    echo "RC=$?"
  '
)
rm -rf "$EMPTY_PROV_DIR"
assert_contains "TC-CCF-041 leaf-absent backend: chp_commit_file WARNs leaf-absent" "no chp_emptyprov_commit_file leaf" "$guard_out"
assert_contains "TC-CCF-041b leaf-absent backend: chp_commit_file returns non-zero" "RC=1" "$guard_out"

# ===========================================================================
echo ""
echo "=================================================="
echo "test-chp-commit-file.sh: $PASS passed, $FAIL failed"
echo "=================================================="
[[ "$FAIL" -eq 0 ]]
