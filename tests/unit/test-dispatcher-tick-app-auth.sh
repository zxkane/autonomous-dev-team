#!/bin/bash
# test-dispatcher-tick-app-auth.sh — Verify dispatcher-tick.sh generates
# a GitHub App installation token before any `gh` call when GH_AUTH_MODE=app.
# Closes #91 (dispatcher fell back to user `gh auth login` token, so
# dispatcher-side issue comments + label changes appeared as the user
# instead of the bot app).
#
# Strategy: sandbox the dispatcher script tree so the test can substitute
# every external dependency (gh-app-token.sh, lib-dispatch.sh, gh CLI) with
# a recording stub. Exercise the auth block under several configurations
# and assert which stubs got which calls.
#
# Run: bash tests/unit/test-dispatcher-tick-app-auth.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TICK_SRC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
LIB_CONFIG_SRC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-config.sh"
LIB_REVIEW_BOTS_SRC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-bots.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should NOT contain: '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

SANDBOX="$TMPROOT/scripts"
mkdir -p "$SANDBOX"

# Real script under test.
cp "$TICK_SRC" "$SANDBOX/dispatcher-tick.sh"
cp "$LIB_CONFIG_SRC" "$SANDBOX/lib-config.sh"
cp "$LIB_REVIEW_BOTS_SRC" "$SANDBOX/lib-review-bots.sh"

# Stub lib-dispatch.sh: provide every helper dispatcher-tick.sh expects, but
# return empty/no-op so the tick exercises only the upfront validation +
# auth block. count_active=0 ensures the concurrency gate doesn't bail.
cat > "$SANDBOX/lib-dispatch.sh" <<'EOF'
#!/bin/bash
: "${REPO:?REPO must be set in autonomous.conf}"
: "${REPO_OWNER:?REPO_OWNER must be set in autonomous.conf}"
: "${PROJECT_ID:?PROJECT_ID must be set in autonomous.conf}"
MAX_RETRIES="${MAX_RETRIES:-3}"
MAX_CONCURRENT="${MAX_CONCURRENT:-5}"

count_active() { echo 0; }
list_new_issues() { echo '[]'; }
list_pending_review() { echo '[]'; }
list_pending_dev() { echo '[]'; }
list_stale_candidates() { echo '[]'; }
check_deps_resolved() { return 0; }
count_retries() { echo 0; }
mark_stalled() { :; }
extract_dev_session_id() { echo ""; }
is_session_completed() { return 1; }
fetch_pr_for_issue() { echo ""; }
ci_is_green() { return 1; }
pr_idle_seconds() { echo ""; }
last_reviewed_head() { echo ""; }
pid_alive() { return 1; }
get_pid() { echo ""; }
label_swap() { :; }
was_just_dispatched() { return 1; }
EOF

# Stub gh-app-token.sh: record the call, return a sentinel token. The token
# value AND the GH_TOKEN observed by the gh stub is asserted by each case.
# Cases override the function body via a per-case override file.
cat > "$SANDBOX/gh-app-token.sh" <<'EOF'
#!/bin/bash
get_gh_app_token() {
  echo "GH_APP_TOKEN_CALL app_id=$1 pem=$2 owner=$3 name=$4" >> "$AUTH_RECORD"
  if [[ -n "${GH_APP_TOKEN_OVERRIDE:-}" ]]; then
    # Source the override which redefines get_gh_app_token's body via env.
    case "$GH_APP_TOKEN_OVERRIDE" in
      fail) return 1 ;;
      empty) echo "" ;;
      *) echo "$GH_APP_TOKEN_OVERRIDE" ;;
    esac
  else
    echo "sentinel-token-abc123"
  fi
}
EOF

# Stub gh CLI on PATH. Records every invocation AND the GH_TOKEN it sees,
# so we can assert the token was set before the first gh call.
GH_STUB_DIR="$TMPROOT/bin"
mkdir -p "$GH_STUB_DIR"
cat > "$GH_STUB_DIR/gh" <<'EOF'
#!/bin/bash
echo "GH_CALL token=${GH_TOKEN:-<unset>} args=$*" >> "$GH_RECORD"
# Mimic enough of gh's interface so callers can pipe through jq.
case "$1" in
  issue)
    case "$2" in
      list) echo '[]' ;;
      view) echo '{"comments":[]}' ;;
      *) echo "" ;;
    esac
    ;;
  pr)
    case "$2" in
      list|checks) echo '[]' ;;
      *) echo "" ;;
    esac
    ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$GH_STUB_DIR/gh"

# Stub dispatch-local.sh under PROJECT_DIR/scripts/ so the tick's
# dispatch() helper can spawn a no-op when a list_*() stub returns a
# real issue (TC-001 needs this so a `gh issue comment` actually fires
# through our PATH stub, otherwise the auth-block-runs-before-gh
# invariant is asserted vacuously).
FAKE_PROJECT_DIR="$TMPROOT/proj"
mkdir -p "$FAKE_PROJECT_DIR/scripts"
cat > "$FAKE_PROJECT_DIR/scripts/dispatch-local.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_PROJECT_DIR/scripts/dispatch-local.sh"

# Common autonomous.conf for tests. Each case overrides selected vars
# via env. PROJECT_DIR points to the fake dir created above.
COMMON_CONF="$TMPROOT/autonomous.conf"
cat > "$COMMON_CONF" <<EOF
REPO=myorg/myrepo
REPO_OWNER=myorg
REPO_NAME=myrepo
PROJECT_ID=test-proj
PROJECT_DIR=$FAKE_PROJECT_DIR
MAX_CONCURRENT=5
MAX_RETRIES=3
REVIEW_BOTS=""
EOF

# Helper to run dispatcher-tick.sh under the sandbox.
# Args: $1=case_label (used to scope record files)
# Env  : GH_AUTH_MODE, DISPATCHER_APP_ID, DISPATCHER_APP_PEM,
#        GH_APP_TOKEN_OVERRIDE
run_tick() {
  local label="$1"
  local auth_record="$TMPROOT/auth-${label}.log"
  local gh_record="$TMPROOT/gh-${label}.log"
  local stderr_log="$TMPROOT/stderr-${label}.log"
  : > "$auth_record"
  : > "$gh_record"
  : > "$stderr_log"

  AUTH_RECORD="$auth_record" \
  GH_RECORD="$gh_record" \
  GH_APP_TOKEN_OVERRIDE="${GH_APP_TOKEN_OVERRIDE:-}" \
  AUTONOMOUS_CONF="$COMMON_CONF" \
  GH_AUTH_MODE="${GH_AUTH_MODE:-token}" \
  DISPATCHER_APP_ID="${DISPATCHER_APP_ID:-}" \
  DISPATCHER_APP_PEM="${DISPATCHER_APP_PEM:-}" \
  PATH="$GH_STUB_DIR:$PATH" \
  bash "$SANDBOX/dispatcher-tick.sh" >/dev/null 2>"$stderr_log"
  RC=$?
  AUTH_LOG=$(cat "$auth_record")
  GH_LOG=$(cat "$gh_record")
  STDERR_LOG=$(cat "$stderr_log")
}

# Need a fake PEM file so `[[ ! -f "$pem_file" ]]` checks in the real code
# would pass — but we stub gh-app-token.sh so the validation never runs.
# Still create one for realism in the happy-path case.
FAKE_PEM="$TMPROOT/fake.pem"
echo "-----BEGIN RSA PRIVATE KEY-----" > "$FAKE_PEM"

# ---------------------------------------------------------------------------
echo "=== TC-DISP-AUTH-001: GH_AUTH_MODE=app + valid id/pem → token generated, exported, observed by first gh call ==="
# ---------------------------------------------------------------------------
# Override list_new_issues so Step 2 actually fires `gh issue comment`
# through the PATH stub. Without a non-empty issue list, GH_RECORD stays
# empty and the "token observed by gh" assertion is vacuous.
ORIG_LIB_DISPATCH=$(cat "$SANDBOX/lib-dispatch.sh")
{
  echo "$ORIG_LIB_DISPATCH"
  echo 'list_new_issues() { echo '\''[{"number":42,"labels":[],"title":"t"}]'\''; }'
} > "$SANDBOX/lib-dispatch.sh"

GH_AUTH_MODE=app \
DISPATCHER_APP_ID=12345 \
DISPATCHER_APP_PEM="$FAKE_PEM" \
GH_APP_TOKEN_OVERRIDE="" \
  run_tick "001"

# Restore the empty-issue stub for subsequent cases.
echo "$ORIG_LIB_DISPATCH" > "$SANDBOX/lib-dispatch.sh"

assert_eq "tick exits 0" 0 "$RC"
assert_contains "get_gh_app_token called once with correct args" \
  "GH_APP_TOKEN_CALL app_id=12345 pem=$FAKE_PEM owner=myorg name=myrepo" "$AUTH_LOG"
# Real assertion: at least one gh call DID fire and it carried the
# sentinel token (proves the auth block ran before the first gh call).
assert_contains "gh call observed sentinel token" \
  "token=sentinel-token-abc123" "$GH_LOG"
assert_not_contains "no gh call observed token=<unset>" \
  "token=<unset>" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DISP-AUTH-002: GH_AUTH_MODE=app + missing DISPATCHER_APP_ID → FATAL exit ==="
# ---------------------------------------------------------------------------
GH_AUTH_MODE=app \
DISPATCHER_APP_ID="" \
DISPATCHER_APP_PEM="$FAKE_PEM" \
GH_APP_TOKEN_OVERRIDE="" \
  run_tick "002"

assert_eq "tick exits 1" 1 "$RC"
assert_contains "FATAL message mentions DISPATCHER_APP_ID" \
  "DISPATCHER_APP_ID" "$STDERR_LOG"
assert_eq "get_gh_app_token NOT invoked" "" "$AUTH_LOG"
assert_eq "no gh calls made" "" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DISP-AUTH-003: GH_AUTH_MODE=app + missing DISPATCHER_APP_PEM → FATAL exit ==="
# ---------------------------------------------------------------------------
GH_AUTH_MODE=app \
DISPATCHER_APP_ID=12345 \
DISPATCHER_APP_PEM="" \
GH_APP_TOKEN_OVERRIDE="" \
  run_tick "003"

assert_eq "tick exits 1" 1 "$RC"
assert_contains "FATAL message mentions DISPATCHER_APP_PEM" \
  "DISPATCHER_APP_PEM" "$STDERR_LOG"
assert_eq "get_gh_app_token NOT invoked" "" "$AUTH_LOG"
assert_eq "no gh calls made" "" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DISP-AUTH-004: GH_AUTH_MODE=app + get_gh_app_token rc=1 → FATAL exit ==="
# ---------------------------------------------------------------------------
GH_AUTH_MODE=app \
DISPATCHER_APP_ID=12345 \
DISPATCHER_APP_PEM="$FAKE_PEM" \
GH_APP_TOKEN_OVERRIDE=fail \
  run_tick "004"

assert_eq "tick exits 1" 1 "$RC"
assert_contains "FATAL message references token generation" \
  "GitHub App token" "$STDERR_LOG"
assert_eq "no gh calls made after token failure" "" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DISP-AUTH-005: GH_AUTH_MODE=app + token empty → FATAL exit ==="
# ---------------------------------------------------------------------------
GH_AUTH_MODE=app \
DISPATCHER_APP_ID=12345 \
DISPATCHER_APP_PEM="$FAKE_PEM" \
GH_APP_TOKEN_OVERRIDE=empty \
  run_tick "005"

assert_eq "tick exits 1" 1 "$RC"
assert_contains "FATAL message mentions empty token" \
  "empty" "$STDERR_LOG"
assert_eq "no gh calls made after empty token" "" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DISP-AUTH-006: GH_AUTH_MODE=token (default) → no App-token codepath ==="
# ---------------------------------------------------------------------------
unset DISPATCHER_APP_ID
unset DISPATCHER_APP_PEM
unset GH_APP_TOKEN_OVERRIDE
GH_AUTH_MODE=token \
  run_tick "006"

assert_eq "tick exits 0" 0 "$RC"
assert_eq "get_gh_app_token NOT invoked in token mode" "" "$AUTH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DISP-AUTH-007: GH_AUTH_MODE unset → no App-token codepath ==="
# ---------------------------------------------------------------------------
unset GH_AUTH_MODE DISPATCHER_APP_ID DISPATCHER_APP_PEM GH_APP_TOKEN_OVERRIDE
run_tick "007"

assert_eq "tick exits 0 with GH_AUTH_MODE unset" 0 "$RC"
assert_eq "get_gh_app_token NOT invoked when GH_AUTH_MODE unset" "" "$AUTH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-DISP-AUTH-008: REPO_NAME missing in conf → auto-derived from REPO ==="
# ---------------------------------------------------------------------------
# Older path-entry autonomous.conf may set REPO=owner/name without REPO_NAME.
# The auth block must auto-derive REPO_NAME so set -u doesn't trip.
NO_REPO_NAME_CONF="$TMPROOT/autonomous-no-name.conf"
cat > "$NO_REPO_NAME_CONF" <<EOF
REPO=acme/widget
REPO_OWNER=acme
PROJECT_ID=test-proj
PROJECT_DIR=$FAKE_PROJECT_DIR
MAX_CONCURRENT=5
MAX_RETRIES=3
REVIEW_BOTS=""
EOF

auth_record="$TMPROOT/auth-008.log"
gh_record="$TMPROOT/gh-008.log"
stderr_log="$TMPROOT/stderr-008.log"
: > "$auth_record"
: > "$gh_record"
: > "$stderr_log"

AUTH_RECORD="$auth_record" GH_RECORD="$gh_record" \
AUTONOMOUS_CONF="$NO_REPO_NAME_CONF" \
GH_AUTH_MODE=app DISPATCHER_APP_ID=99 DISPATCHER_APP_PEM="$FAKE_PEM" \
GH_APP_TOKEN_OVERRIDE="" \
PATH="$GH_STUB_DIR:$PATH" \
  bash "$SANDBOX/dispatcher-tick.sh" >/dev/null 2>"$stderr_log"
RC=$?
AUTH_LOG=$(cat "$auth_record")
STDERR_LOG=$(cat "$stderr_log")

assert_eq "tick exits 0 (no unbound-var error from set -u)" 0 "$RC"
assert_contains "REPO_NAME auto-derived from REPO=acme/widget" \
  "owner=acme name=widget" "$AUTH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
