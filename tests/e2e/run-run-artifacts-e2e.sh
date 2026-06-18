#!/bin/bash
# run-run-artifacts-e2e.sh — E2E for the per-run artifact dir + run-id threading
# + status.sh inspector (issue #235, INV-80). Test IDs: TC-RUN-ARTIFACTS-080..085.
#
# Drives a STUB dev + review cycle through the REAL lib-run-artifacts.sh
# (init → finalize → footer → drop), then runs the REAL status.sh against a stub
# `gh`, and finally simulates a reboot (clear /tmp, keep the XDG state root) to
# prove the artifacts are durable. No real CLIs / network / credentials — part of
# the always-on hermetic tier.
#
# Run:  bash tests/e2e/run-run-artifacts-e2e.sh
# CI:   invoked directly by ci.yml AND by the test-*.sh loop via a thin unit
#       wrapper (tests/unit/test-run-artifacts-e2e.sh).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-run-artifacts.sh"
STATUS_SH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/status.sh"

PASS=0; FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; echo "      $2"; FAIL=$((FAIL + 1)); }
expect()     { [[ "$3" == *"$2"* ]] && ok "$1" || bad "$1" "needle='$2'"; }
expect_not() { [[ "$3" != *"$2"* ]] && ok "$1" || bad "$1" "unexpected='$2'"; }
expect_file(){ [[ -f "$2" ]] && ok "$1" || bad "$1" "missing file: $2"; }

# Isolate everything under one temp root: a fake /tmp, the XDG state root, the
# stub gh, and the stub PID dir.
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE_TMP="$TMP/tmp"; mkdir -p "$FAKE_TMP"
STATE_ROOT="$TMP/xdg-state"; mkdir -p "$STATE_ROOT"
PID_DIR="$TMP/piddir"; mkdir -p "$PID_DIR"
BIN="$TMP/bin"; mkdir -p "$BIN"

export PROJECT_ID="e2e-proj"
export XDG_STATE_HOME="$STATE_ROOT"      # durable base; survives a /tmp wipe

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-run-artifacts.sh
source "$LIB"

# ---------------------------------------------------------------------------
# TC-080: stub DEV run — init → finalize rc 0 → footer
# ---------------------------------------------------------------------------
echo "== TC-080 stub dev run =="
unset RUN_ID RUN_DIR
export MODE="new" AGENT_CMD="claude" GH_AUTH_MODE="token"
export LOG_FILE="$FAKE_TMP/agent-e2e-proj-issue-700.log"
echo "dev log line 1" > "$LOG_FILE"
run_artifacts_init dev 700 || true
DEV_RUN_ID="$RUN_ID"; DEV_RUN_DIR="$RUN_DIR"
echo "dev wrapper output captured" >> "$DEV_RUN_DIR/run.log"   # simulate the tee
run_artifacts_finalize "$DEV_RUN_DIR" 0 || true
DEV_FOOTER="$(run_footer)"

expect_file "TC-080a dev meta.json present" "$DEV_RUN_DIR/meta.json"
expect_file "TC-080b dev run.log present"   "$DEV_RUN_DIR/run.log"
expect "TC-080c dev meta rc=0" "0" "$(jq -r '.rc' "$DEV_RUN_DIR/meta.json")"
expect "TC-080d dev side=dev"  "dev" "$(jq -r '.side' "$DEV_RUN_DIR/meta.json")"
expect "TC-082a dev footer carries run-id" "run-id: $DEV_RUN_ID" "$DEV_FOOTER"
expect "TC-082b dev footer carries artifacts dir" "artifacts: $DEV_RUN_DIR" "$DEV_FOOTER"

# ---------------------------------------------------------------------------
# TC-081: stub REVIEW run — init → record a drop → finalize → footer
# ---------------------------------------------------------------------------
echo "== TC-081 stub review run =="
unset RUN_ID RUN_DIR
export AGENT_CMD="codex"
export LOG_FILE="$FAKE_TMP/agent-e2e-proj-review-700.log"
run_artifacts_init review 700 || true
REVIEW_RUN_ID="$RUN_ID"; REVIEW_RUN_DIR="$RUN_DIR"
run_artifacts_record_drop "$REVIEW_RUN_DIR" "agy" "agent-unavailable:quota" || true
run_artifacts_finalize "$REVIEW_RUN_DIR" 0 || true
REVIEW_FOOTER="$(run_footer)"

expect_file "TC-081a review drops.jsonl present" "$REVIEW_RUN_DIR/drops.jsonl"
expect "TC-081b drop agent recorded" "agy" "$(jq -r '.agent' "$REVIEW_RUN_DIR/drops.jsonl")"
expect "TC-081c drop reason recorded" "agent-unavailable:quota" "$(jq -r '.reason' "$REVIEW_RUN_DIR/drops.jsonl")"
expect "TC-082c review footer carries run-id" "run-id: $REVIEW_RUN_ID" "$REVIEW_FOOTER"

# ---------------------------------------------------------------------------
# status.sh against a stub gh (TC-083) — needs a real gh on PATH.
# ---------------------------------------------------------------------------
echo "== TC-083 status.sh snapshot =="
cat > "$BIN/gh" <<'GH'
#!/bin/bash
args=("$@"); want=""; q=""
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    issue) [[ "${args[$((i+1))]:-}" == "view" ]] && want="issue" ;;
    pr)    [[ "${args[$((i+1))]:-}" == "list" ]] && want="pr" ;;
    -q)    q="${args[$((i+1))]:-}" ;;
  esac
done
case "$want" in
  issue) echo '{"state":"OPEN","title":"e2e issue","labels":[{"name":"autonomous"},{"name":"pending-review"}]}' ;;
  pr)    echo "" ;;   # no PR
  *)     echo "" ;;
esac
GH
chmod +x "$BIN/gh"

STATUS_OUT="$(
  PATH="$BIN:$PATH" \
  REPO="zxkane/e2e" REPO_OWNER="zxkane" PROJECT_ID="e2e-proj" \
  MAX_RETRIES=3 MAX_CONCURRENT=5 \
  AUTONOMOUS_PID_DIR="$PID_DIR" AUTONOMOUS_RUN_DIR_BASE="$STATE_ROOT/autonomous-e2e-proj" \
  AUTONOMOUS_CONF="/dev/null" \
    bash "$STATUS_SH" 700 2>&1
)"
expect "TC-083a status shows labels" "pending-review" "$STATUS_OUT"
expect "TC-083b status shows the dev run-id" "$DEV_RUN_ID" "$STATUS_OUT"
expect "TC-083c status shows the review run-id" "$REVIEW_RUN_ID" "$STATUS_OUT"
expect "TC-083d status shows last drop reason" "agy: agent-unavailable:quota" "$STATUS_OUT"
expect "TC-083e status shows next-tick action" "next dispatcher tick" "$STATUS_OUT"
expect "TC-083f next action = dispatch review (pending-review)" "Step 3" "$STATUS_OUT"

# ---------------------------------------------------------------------------
# TC-084 / TC-085: reboot simulation — wipe /tmp, keep XDG state root.
# ---------------------------------------------------------------------------
echo "== TC-084 reboot simulation (/tmp wiped) =="
rm -rf "$FAKE_TMP"   # the legacy /tmp/agent-*.log files evaporate on reboot
expect "TC-084a /tmp wiped" "GONE" "$([[ -d "$FAKE_TMP" ]] && echo PRESENT || echo GONE)"
expect_file "TC-084b dev meta.json SURVIVES under XDG state" "$DEV_RUN_DIR/meta.json"
expect_file "TC-084c dev run.log SURVIVES under XDG state"   "$DEV_RUN_DIR/run.log"
expect_file "TC-084d review drops.jsonl SURVIVES under XDG state" "$REVIEW_RUN_DIR/drops.jsonl"

# TC-085: the FAIL-comment footer round-trip (AC1) — given ONLY the footer
# string, the referenced artifact dir exists and contains the raw evidence.
echo "== TC-085 footer → dir round trip (AC1) =="
FOOTER_DIR="$(printf '%s' "$DEV_FOOTER" | sed -n 's/.*artifacts: \(.*\)/\1/p' | tr -d ' ')"
expect "TC-085a footer's dir is the dev run dir" "$DEV_RUN_DIR" "$FOOTER_DIR"
expect_file "TC-085b footer's dir has raw evidence (meta.json)" "$FOOTER_DIR/meta.json"
expect_file "TC-085c footer's dir has raw evidence (run.log)"   "$FOOTER_DIR/run.log"
expect "TC-085d run.log has the durable wrapper output" "dev wrapper output captured" "$(cat "$FOOTER_DIR/run.log")"

# ---------------------------------------------------------------------------
# TC-086: wrapper-owned verdict comment carries the run footer (AC1, #235
# review [P1]). The two wrapper-owned post-verdict.sh call sites
# (codex stdout-fallback + INV-78 aggregate) must append the run footer to the
# body file so a PASS/FAIL verdict comment leads to the durable run dir. We
# exercise the REAL helper `_append_run_footer_to_file` extracted from
# autonomous-review.sh against the real run_footer.
# ---------------------------------------------------------------------------
echo "== TC-086 wrapper-owned verdict comment footer =="
REVIEW_SH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

# Source ONLY the helper definition (awk: from its `_append_run_footer_to_file() {`
# line through the matching closing `}` at column 0) so we don't run the whole
# wrapper. The helper depends only on run_footer (already sourced) + RUN_ID/RUN_DIR.
HELPER_SRC="$(awk '/^_append_run_footer_to_file\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$REVIEW_SH")"
if [[ -n "$HELPER_SRC" ]]; then
  eval "$HELPER_SRC"
  if declare -F _append_run_footer_to_file >/dev/null 2>&1; then
    ok "TC-086a helper extracted + defined"
    # Footer appended when a run is active (use the dev run from TC-080).
    export RUN_ID="$DEV_RUN_ID" RUN_DIR="$DEV_RUN_DIR"
    VERDICT_BODY_FILE="$TMP/verdict-body.md"
    printf 'Review PASSED\n\nAll acceptance criteria met.' > "$VERDICT_BODY_FILE"
    _append_run_footer_to_file "$VERDICT_BODY_FILE"
    BODY_AFTER="$(cat "$VERDICT_BODY_FILE")"
    expect "TC-086b verdict body keeps its original content" "All acceptance criteria met." "$BODY_AFTER"
    expect "TC-086c verdict body gains run-id footer" "run-id: $DEV_RUN_ID" "$BODY_AFTER"
    expect "TC-086d verdict body gains artifacts pointer" "artifacts: $DEV_RUN_DIR" "$BODY_AFTER"
    # No-op (observe-only) when RUN_ID is unset — a verdict comment is never broken.
    unset RUN_ID RUN_DIR
    NOFOOTER_FILE="$TMP/verdict-nofooter.md"
    printf 'Review findings:\n\n1. [BLOCKING] something' > "$NOFOOTER_FILE"
    BEFORE="$(cat "$NOFOOTER_FILE")"
    _append_run_footer_to_file "$NOFOOTER_FILE"
    expect "TC-086e no-op when RUN_ID unset (body unchanged)" "$BEFORE" "$(cat "$NOFOOTER_FILE")"
  else
    bad "TC-086a helper extracted + defined" "eval did not define _append_run_footer_to_file"
  fi
else
  bad "TC-086a helper extracted + defined" "could not extract _append_run_footer_to_file from $REVIEW_SH"
fi

# TC-086f/g: both wrapper-owned post-verdict.sh call sites append the footer FIRST
# (grep-assert against the wrapper source — the codex stdout-fallback + the INV-78
# aggregate post). Guards against a future edit dropping the footer on a verdict.
REVIEW_SRC="$(cat "$REVIEW_SH")"
expect "TC-086f wrapper sources call _append_run_footer_to_file" "_append_run_footer_to_file" "$REVIEW_SRC"
# Each `post-verdict.sh` wrapper-owned invocation must be preceded by a footer
# append within a small window — assert there are at least two append call sites.
APPEND_COUNT="$(grep -c '_append_run_footer_to_file "' "$REVIEW_SH")"
expect "TC-086g >=2 footer-append call sites (codex-fallback + aggregate)" "yes" "$([[ "$APPEND_COUNT" -ge 2 ]] && echo yes || echo "no($APPEND_COUNT)")"

echo ""
echo "RUN-ARTIFACTS-E2E-SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
