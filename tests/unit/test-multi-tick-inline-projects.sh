#!/bin/bash
# test-multi-tick-inline-projects.sh — Verify dispatcher-multi-tick.sh
# handles inline metadata blocks for remote projects (PR-9, #62 axis 2)
# while preserving PR-8's path-string behavior for local projects.
#
# Strategy: stub dispatcher-tick.sh to record its env (in particular
# REPO, REPO_OWNER, REPO_NAME, EXECUTION_BACKEND, SSM_*) and AUTONOMOUS_CONF.
# Run multi-tick against various PROJECTS shapes.
#
# Run: bash tests/unit/test-multi-tick-inline-projects.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER_SRC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-multi-tick.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected_rc=$expected actual_rc=$actual"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="$TMPROOT/scripts"
mkdir -p "$SANDBOX"
cp "$WRAPPER_SRC" "$SANDBOX/dispatcher-multi-tick.sh"

# Stub dispatcher-tick.sh records relevant env to a sentinel file. For
# local projects, we source AUTONOMOUS_CONF first to mirror what the real
# dispatcher-tick.sh does via lib-config.sh — without that, the stub would
# see REPO=<unset> for local entries and the test wouldn't reflect real flow.
cat > "$SANDBOX/dispatcher-tick.sh" <<'EOF'
#!/bin/bash
# Mirror lib-config.sh::load_autonomous_conf priority-1 behavior.
if [[ -n "${AUTONOMOUS_CONF:-}" ]] && [[ -f "$AUTONOMOUS_CONF" ]]; then
  # shellcheck disable=SC1090
  source "$AUTONOMOUS_CONF"
fi
{
  printf 'AUTONOMOUS_CONF=%s\n' "${AUTONOMOUS_CONF:-<unset>}"
  printf 'REPO=%s\n' "${REPO:-<unset>}"
  printf 'REPO_OWNER=%s\n' "${REPO_OWNER:-<unset>}"
  printf 'REPO_NAME=%s\n' "${REPO_NAME:-<unset>}"
  printf 'PROJECT_ID=%s\n' "${PROJECT_ID:-<unset>}"
  printf 'EXECUTION_BACKEND=%s\n' "${EXECUTION_BACKEND:-<unset>}"
  printf 'SSM_INSTANCE_ID=%s\n' "${SSM_INSTANCE_ID:-<unset>}"
  printf 'SSM_REMOTE_PROJECT_DIR=%s\n' "${SSM_REMOTE_PROJECT_DIR:-<unset>}"
  printf 'ISSUE_FILTER=%s\n' "${ISSUE_FILTER:-<unset>}"
  printf 'ISSUE_SCAN_LIMIT=%s\n' "${ISSUE_SCAN_LIMIT:-<unset>}"
  printf 'HUMAN_ESCALATION_LOGIN=%s\n' "${HUMAN_ESCALATION_LOGIN:-<unset>}"
  printf 'DEV_BOT_LOGIN=%s\n' "${DEV_BOT_LOGIN:-<unset>}"
  printf '%s\n' '---'
} >> "$TICK_RECORD_FILE"
exit 0
EOF
chmod +x "$SANDBOX/dispatcher-tick.sh"

# AUTONOMOUS_TRUST_CONF=1 because /tmp is mode 1777 (PR-8 trust gate)
export AUTONOMOUS_TRUST_CONF=1

# ---------------------------------------------------------------------------
echo "=== TC-EB-013/014: inline block — REPO_OWNER/_NAME auto-derived ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-013.conf"
RECORD="$TMPROOT/record-013"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projB
REPO=myorg/projB
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-0abc123
SSM_REMOTE_PROJECT_DIR=/data/git/projB
SSM_REMOTE_PROJECT_ID=projB
' )
EOF

DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "rc=0 for happy-path inline project" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "REPO propagated" "REPO=myorg/projB" "$record"
assert_contains "REPO_OWNER auto-derived" "REPO_OWNER=myorg" "$record"
assert_contains "REPO_NAME auto-derived" "REPO_NAME=projB" "$record"
assert_contains "PROJECT_ID propagated" "PROJECT_ID=projB" "$record"
assert_contains "EXECUTION_BACKEND propagated" "EXECUTION_BACKEND=remote-aws-ssm" "$record"
assert_contains "SSM_INSTANCE_ID propagated" "SSM_INSTANCE_ID=i-0abc123" "$record"
assert_contains "AUTONOMOUS_CONF unset for inline" "AUTONOMOUS_CONF=<unset>" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-015: inline block with non-assignment line is rejected ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-015.conf"
RECORD="$TMPROOT/record-015"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=mal
REPO=evil/repo
rm -rf /
' )
EOF
stderr_log="$TMPROOT/stderr-015"
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
rc=$?
assert_rc "rc=0 (per-project failure isolation)" 0 "$rc"
case "$(cat "$stderr_log")" in
  *"non-assignment lines"*)
    echo -e "  ${GREEN}PASS${NC}: stderr explains the validator rejection"
    PASS=$((PASS + 1)) ;;
  *)
    echo -e "  ${RED}FAIL${NC}: expected 'non-assignment lines' in stderr"
    FAIL=$((FAIL + 1)) ;;
esac
# Stub should NOT have been invoked (validator caught the bad block)
[ ! -s "$RECORD" ] && {
  echo -e "  ${GREEN}PASS${NC}: stub was NOT invoked for malformed block"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: stub was invoked despite malformed block"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-015b: Q PR-80 — value-side metachars rejected (CWE-95) ==="
# ---------------------------------------------------------------------------
# Q's finding: pre-fix, validator only checked LHS, so values like
# `REPO=$(rm -rf /)` would pass validation and execute on eval.
for badval in \
  'REPO=$(echo PWNED)' \
  'REPO=`echo PWNED`' \
  'REPO=foo;rm -rf /' \
  'REPO=foo&&evil' \
  'REPO=foo|evil' \
  'REPO=foo$VAR' \
  'REPO=foo\nnewlinetrick' ; do
  CONF="$TMPROOT/disp-015b.conf"
  RECORD="$TMPROOT/record-015b"
  : > "$RECORD"
  printf 'PROJECTS=()\nPROJECTS+=( '\''\nPROJECT_ID=test\n%s\nEXECUTION_BACKEND=remote-aws-ssm\nSSM_INSTANCE_ID=i-x\nSSM_REMOTE_PROJECT_DIR=/data/test\nSSM_REMOTE_PROJECT_ID=test\n'\'' )\n' "$badval" > "$CONF"
  stderr_log="$TMPROOT/stderr-015b"
  DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
    bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
  rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$RECORD" ]; then
    echo -e "  ${GREEN}PASS${NC}: rejected metachar value: $badval"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: did NOT reject: $badval (rc=$rc, record=$(wc -l <"$RECORD"))"
    FAIL=$((FAIL + 1))
  fi
done

# Sanity: a legitimate value WITHOUT metachars must still pass.
CONF="$TMPROOT/disp-015c.conf"
RECORD="$TMPROOT/record-015c"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projB
REPO=myorg/projB
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-0abc123
SSM_REMOTE_PROJECT_DIR=/data/git/projB
SSM_REMOTE_PROJECT_ID=projB
' )
EOF
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
[ -s "$RECORD" ] && {
  echo -e "  ${GREEN}PASS${NC}: legitimate metachar-free values still accepted"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: legitimate values were rejected — validator too strict"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-016: inline block missing REPO → warn-and-skip ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-016.conf"
RECORD="$TMPROOT/record-016"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projX
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-empty
SSM_REMOTE_PROJECT_DIR=/data/git/projX
SSM_REMOTE_PROJECT_ID=projX
' )
EOF
stderr_log="$TMPROOT/stderr-016"
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
rc=$?
assert_rc "rc=0 even with missing-REPO inline project" 0 "$rc"
[ ! -s "$RECORD" ] && {
  echo -e "  ${GREEN}PASS${NC}: stub NOT invoked for missing-REPO project"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: stub was invoked despite missing REPO"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-017: mixed local + remote projects in one PROJECTS array ==="
# ---------------------------------------------------------------------------
LOCAL_CONF="$TMPROOT/local-autoconf.conf"
cat > "$LOCAL_CONF" <<'EOF'
REPO=myorg/local-proj
REPO_OWNER=myorg
REPO_NAME=local-proj
PROJECT_ID=local-proj
PROJECT_DIR=/tmp/local-proj
EOF

CONF="$TMPROOT/disp-017.conf"
RECORD="$TMPROOT/record-017"
: > "$RECORD"
{
  echo 'PROJECTS=()'
  printf 'PROJECTS+=( %q )\n' "$LOCAL_CONF"
  echo "PROJECTS+=( '"
  echo 'PROJECT_ID=remote-proj'
  echo 'REPO=myorg/remote-proj'
  echo 'EXECUTION_BACKEND=remote-aws-ssm'
  echo 'SSM_INSTANCE_ID=i-mix'
  echo 'SSM_REMOTE_PROJECT_DIR=/data/git/remote-proj'
  echo 'SSM_REMOTE_PROJECT_ID=remote-proj'
  echo "' )"
} > "$CONF"

DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "rc=0 for mixed projects" 0 "$rc"
record=$(cat "$RECORD")
# Two ticks recorded — separated by '---'.
tick_count=$(grep -c '^---$' "$RECORD")
[ "$tick_count" = "2" ] && {
  echo -e "  ${GREEN}PASS${NC}: both projects ticked (count=$tick_count)"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: expected 2 ticks, got $tick_count"
  FAIL=$((FAIL + 1))
}
# Local project tick records AUTONOMOUS_CONF=$LOCAL_CONF
assert_contains "local project: AUTONOMOUS_CONF set to autonomous.conf path" "AUTONOMOUS_CONF=$LOCAL_CONF" "$record"
# Remote project records inline metadata + AUTONOMOUS_CONF=<unset>
assert_contains "remote project: REPO=myorg/remote-proj propagated" "REPO=myorg/remote-proj" "$record"
assert_contains "remote project: AUTONOMOUS_CONF unset" "AUTONOMOUS_CONF=<unset>" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-018: backwards compat — pure-path PROJECTS still works ==="
# ---------------------------------------------------------------------------
LOCAL_ONLY_CONF="$TMPROOT/disp-018.conf"
RECORD="$TMPROOT/record-018"
: > "$RECORD"
{
  echo 'PROJECTS=()'
  printf 'PROJECTS+=( %q )\n' "$LOCAL_CONF"
} > "$LOCAL_ONLY_CONF"

DISPATCHER_CONF="$LOCAL_ONLY_CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
assert_rc "rc=0 for PR-8-shape pure-path PROJECTS" 0 "$?"
record=$(cat "$RECORD")
assert_contains "PR-8 path entry: AUTONOMOUS_CONF set" "AUTONOMOUS_CONF=$LOCAL_CONF" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-120: ISSUE_FILTER/ISSUE_SCAN_LIMIT export into inline project subshell ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-ifilt-120.conf"
RECORD="$TMPROOT/record-ifilt-120"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projFiltered
REPO=myorg/projFiltered
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-filt
SSM_REMOTE_PROJECT_DIR=/data/git/projFiltered
SSM_REMOTE_PROJECT_ID=projFiltered
ISSUE_FILTER=label:box-a
ISSUE_SCAN_LIMIT=200
' )
EOF
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "rc=0 for ISSUE_FILTER inline project" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "TC-IFILT-120 ISSUE_FILTER propagated" "ISSUE_FILTER=label:box-a" "$record"
assert_contains "TC-IFILT-120 ISSUE_SCAN_LIMIT propagated" "ISSUE_SCAN_LIMIT=200" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-121: project without ISSUE_FILTER/ISSUE_SCAN_LIMIT stays unfiltered at default ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-ifilt-121.conf"
RECORD="$TMPROOT/record-ifilt-121"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projUnfiltered
REPO=myorg/projUnfiltered
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-unfilt
SSM_REMOTE_PROJECT_DIR=/data/git/projUnfiltered
SSM_REMOTE_PROJECT_ID=projUnfiltered
' )
EOF
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "rc=0 for project without ISSUE_FILTER" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "TC-IFILT-121 ISSUE_FILTER stays unset (unfiltered)" "ISSUE_FILTER=<unset>" "$record"
assert_contains "TC-IFILT-121 ISSUE_SCAN_LIMIT stays unset (default 100 applies downstream)" "ISSUE_SCAN_LIMIT=<unset>" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-122: inline ISSUE_FILTER with a rejected metachar fails block validation loudly ==="
# ---------------------------------------------------------------------------
for badval in \
  'ISSUE_FILTER=label:$(evil)' \
  'ISSUE_FILTER=label:`evil`' \
  'ISSUE_FILTER=label:a;evil' \
  'ISSUE_FILTER=label:a&evil' \
  'ISSUE_FILTER=label:a|evil' ; do
  CONF="$TMPROOT/disp-ifilt-122.conf"
  RECORD="$TMPROOT/record-ifilt-122"
  : > "$RECORD"
  printf 'PROJECTS=()\nPROJECTS+=( '\''\nPROJECT_ID=test\nREPO=myorg/test\n%s\nEXECUTION_BACKEND=remote-aws-ssm\nSSM_INSTANCE_ID=i-x\nSSM_REMOTE_PROJECT_DIR=/data/test\nSSM_REMOTE_PROJECT_ID=test\n'\'' )\n' "$badval" > "$CONF"
  stderr_log="$TMPROOT/stderr-ifilt-122"
  DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
    bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
  rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$RECORD" ]; then
    echo -e "  ${GREEN}PASS${NC}: rejected metachar ISSUE_FILTER value: $badval"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: did NOT reject: $badval (rc=$rc, record=$(wc -l <"$RECORD"))"
    FAIL=$((FAIL + 1))
  fi
  case "$(cat "$stderr_log")" in
    *"non-assignment lines"*)
      echo -e "  ${GREEN}PASS${NC}: stderr explains the validator rejection for: $badval"
      PASS=$((PASS + 1)) ;;
    *)
      echo -e "  ${RED}FAIL${NC}: expected 'non-assignment lines' in stderr for: $badval"
      FAIL=$((FAIL + 1)) ;;
  esac
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-123: path-entry project (autonomous.conf file) has NO charset restriction ==="
# ---------------------------------------------------------------------------
PATH_CONF="$TMPROOT/path-autoconf-ifilt.conf"
cat > "$PATH_CONF" <<'EOF'
REPO=myorg/path-proj
REPO_OWNER=myorg
REPO_NAME=path-proj
PROJECT_ID=path-proj
PROJECT_DIR=/tmp/path-proj
ISSUE_FILTER='label:box-a and not label:$special'
EOF
CONF="$TMPROOT/disp-ifilt-123.conf"
RECORD="$TMPROOT/record-ifilt-123"
: > "$RECORD"
{
  echo 'PROJECTS=()'
  printf 'PROJECTS+=( %q )\n' "$PATH_CONF"
} > "$CONF"
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
assert_rc "rc=0 for path-entry project with a metachar in ISSUE_FILTER" 0 "$?"
record=$(cat "$RECORD")
assert_contains "TC-IFILT-123 path-entry ISSUE_FILTER sourced verbatim (no charset gate)" 'ISSUE_FILTER=label:box-a and not label:$special' "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IFILT-124: ambient ISSUE_FILTER/ISSUE_SCAN_LIMIT does NOT leak into an inline project that omits both ==="
# ---------------------------------------------------------------------------
# Regression for the codex review finding on PR #438: tick_inline_project's
# subshell only ever ADDED the export when the block declared the key; it
# never cleared an ambient value the fork already inherited (e.g. exported by
# dispatcher.conf itself, or by the parent process env). Simulate that by
# exporting a stale ISSUE_FILTER/ISSUE_SCAN_LIMIT into the multi-tick
# process's OWN environment before it forks the per-project subshells, then
# assert a project whose inline block omits both keys still lands on the
# documented unfiltered/default-100 path (AC-B8), not the ambient value.
CONF="$TMPROOT/disp-ifilt-124.conf"
RECORD="$TMPROOT/record-ifilt-124"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projNoFilterAttr
REPO=myorg/projNoFilterAttr
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-nofilt
SSM_REMOTE_PROJECT_DIR=/data/git/projNoFilterAttr
SSM_REMOTE_PROJECT_ID=projNoFilterAttr
' )
EOF
ISSUE_FILTER="label:stale-ambient" ISSUE_SCAN_LIMIT="999" \
  DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "TC-IFILT-124 rc=0 despite ambient ISSUE_FILTER/ISSUE_SCAN_LIMIT" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "TC-IFILT-124 ambient ISSUE_FILTER does NOT leak into omitting project" "ISSUE_FILTER=<unset>" "$record"
assert_contains "TC-IFILT-124 ambient ISSUE_SCAN_LIMIT does NOT leak into omitting project" "ISSUE_SCAN_LIMIT=<unset>" "$record"
assert_not_contains "TC-IFILT-124 stale ambient filter value absent from record" "label:stale-ambient" "$record"
assert_not_contains "TC-IFILT-124 stale ambient scan limit absent from record" "ISSUE_SCAN_LIMIT=999" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PAEM-130: HUMAN_ESCALATION_LOGIN/DEV_BOT_LOGIN export into inline project subshell (#495 review finding #2) ==="
# ---------------------------------------------------------------------------
# Without this export, an inline (remote-aws-ssm) project's dispatcher-tick.sh
# process never sees an operator-set HUMAN_ESCALATION_LOGIN/DEV_BOT_LOGIN —
# every dispatcher-side escalation fallback on that project silently reverts
# to REPO_OWNER (the exact GitLab group-blast problem issue #495 exists to
# fix), even though the SAME conf keys work correctly for a local (path-entry)
# project whose autonomous.conf is sourced directly.
CONF="$TMPROOT/disp-paem-130.conf"
RECORD="$TMPROOT/record-paem-130"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projEscalation
REPO=myorg/projEscalation
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-esc
SSM_REMOTE_PROJECT_DIR=/data/git/projEscalation
SSM_REMOTE_PROJECT_ID=projEscalation
HUMAN_ESCALATION_LOGIN=maintainer1
DEV_BOT_LOGIN=my-org-ci-bot
' )
EOF
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "TC-PAEM-130 rc=0 for HUMAN_ESCALATION_LOGIN/DEV_BOT_LOGIN inline project" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "TC-PAEM-130 HUMAN_ESCALATION_LOGIN propagated" "HUMAN_ESCALATION_LOGIN=maintainer1" "$record"
assert_contains "TC-PAEM-130 DEV_BOT_LOGIN propagated" "DEV_BOT_LOGIN=my-org-ci-bot" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PAEM-131: project without HUMAN_ESCALATION_LOGIN/DEV_BOT_LOGIN stays unset (byte-identical default) ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-paem-131.conf"
RECORD="$TMPROOT/record-paem-131"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projNoEscalation
REPO=myorg/projNoEscalation
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-noesc
SSM_REMOTE_PROJECT_DIR=/data/git/projNoEscalation
SSM_REMOTE_PROJECT_ID=projNoEscalation
' )
EOF
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "TC-PAEM-131 rc=0 for project without HUMAN_ESCALATION_LOGIN/DEV_BOT_LOGIN" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "TC-PAEM-131 HUMAN_ESCALATION_LOGIN stays unset" "HUMAN_ESCALATION_LOGIN=<unset>" "$record"
assert_contains "TC-PAEM-131 DEV_BOT_LOGIN stays unset" "DEV_BOT_LOGIN=<unset>" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PAEM-132: ambient HUMAN_ESCALATION_LOGIN/DEV_BOT_LOGIN does NOT leak into an inline project that omits both (review round 2) ==="
# ---------------------------------------------------------------------------
# Mirrors TC-IFILT-124's threat model exactly: a stale value exported into the
# process that launches dispatcher-multi-tick.sh (a cron environment, a
# dispatcher.conf-level top-level assignment sourced directly into THIS
# process, or a leftover operator shell export) must NOT leak into an inline
# project whose own block omits both keys — otherwise that project silently
# mentions the wrong maintainer / misclassifies a login as the dev bot on
# someone else's PR, exactly the class of bug #495 exists to eliminate.
CONF="$TMPROOT/disp-paem-132.conf"
RECORD="$TMPROOT/record-paem-132"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projNoEscalationAttr
REPO=myorg/projNoEscalationAttr
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-noescattr
SSM_REMOTE_PROJECT_DIR=/data/git/projNoEscalationAttr
SSM_REMOTE_PROJECT_ID=projNoEscalationAttr
' )
EOF
HUMAN_ESCALATION_LOGIN="stale-ambient-maintainer" DEV_BOT_LOGIN="stale-ambient-bot" \
  DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "TC-PAEM-132 rc=0 despite ambient HUMAN_ESCALATION_LOGIN/DEV_BOT_LOGIN" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "TC-PAEM-132 ambient HUMAN_ESCALATION_LOGIN does NOT leak into omitting project" "HUMAN_ESCALATION_LOGIN=<unset>" "$record"
assert_contains "TC-PAEM-132 ambient DEV_BOT_LOGIN does NOT leak into omitting project" "DEV_BOT_LOGIN=<unset>" "$record"
assert_not_contains "TC-PAEM-132 stale ambient maintainer login absent from record" "stale-ambient-maintainer" "$record"
assert_not_contains "TC-PAEM-132 stale ambient bot login absent from record" "stale-ambient-bot" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
