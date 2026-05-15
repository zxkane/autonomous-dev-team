#!/bin/bash
# test-dispatch-local-pgrep-type-scope.sh — Unit tests for issue #126.
#
# `dispatch-local.sh::kill_stale_wrapper`'s pgrep fallback must scope its
# match to `${PROJECT_DIR}/scripts/autonomous-<type>.sh --issue <N>` so that:
#   1. dev-resume for issue N never SIGTERMs autonomous-review.sh for N
#      (and vice versa) — issue #126's primary bug.
#   2. project A's dispatch never touches project B's wrappers, even when
#      both projects share an issue number — multi-project amplification
#      flagged by the operator (TC-PGREP-005).
#
# Test plan: docs/test-cases/dispatcher-stale-wrapper-cross-type.md
# Design:    docs/designs/dispatch-local-pgrep-type-scope.md
# Invariant: INV-28
#
# Run: bash tests/unit/test-dispatch-local-pgrep-type-scope.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCH_LOCAL="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatch-local.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to contain '$needle')"
    FAIL=$((FAIL+1))
  fi
}

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# Spawn a sleep with a wrapper-shaped argv0. The trampoline lives at
# ${proj_dir}/scripts/<script_name> so /proc/<pid>/cmdline (which pgrep -f
# reads) shows the path mirrored from production.
spawn_decoy() {
  local proj_dir="$1"; shift
  local script_name="$1"; shift
  local issue_num="$1"; shift
  local extra_args=("$@")

  mkdir -p "${proj_dir}/scripts"
  local trampoline="${proj_dir}/scripts/${script_name}"
  # NB: do NOT `exec sleep` — exec replaces argv on /proc/<pid>/cmdline
  # with bare `sleep`, defeating pgrep -f. Sleep in-process so the
  # wrapper-shaped argv stays visible.
  cat >"$trampoline" <<'EOF'
#!/bin/bash
sleep 30
EOF
  chmod +x "$trampoline"
  # Use setsid so the decoy is its own session/PG leader (mirrors how the
  # real wrapper runs under setsid in lib-agent.sh::_run_with_timeout —
  # group-kill semantics depend on this).
  setsid "$trampoline" --issue "$issue_num" "${extra_args[@]}" >/dev/null 2>&1 &
  local pid=$!
  # Tiny settle so /proc/<pid>/cmdline is populated before pgrep runs.
  sleep 0.1
  printf '%s' "$pid"
}

_DECOY_PIDS=()
_track_decoy() { _DECOY_PIDS+=("$1"); }
_reap_decoys() {
  local p
  for p in "${_DECOY_PIDS[@]:-}"; do
    [[ -z "$p" ]] && continue
    kill -9 -- "-${p}" 2>/dev/null || true
    kill -9 "$p" 2>/dev/null || true
  done
  _DECOY_PIDS=()
}

TMPDIR_T=$(mktemp -d)
PROJ_A="${TMPDIR_T}/proj-a"
PROJ_B="${TMPDIR_T}/proj-b"
PID_DIR_A="${TMPDIR_T}/pidfiles-a"
mkdir -p "$PROJ_A" "$PROJ_B" "$PID_DIR_A"
trap '_reap_decoys; rm -rf "$TMPDIR_T"' EXIT

# ---------------------------------------------------------------------------
# Source `kill_stale_wrapper` from dispatch-local.sh into a sub-test shell.
# ---------------------------------------------------------------------------

extract_kill_stale_wrapper() {
  awk '
    /^kill_stale_wrapper\(\) \{$/ { flag=1 }
    flag { print }
    flag && /^\}$/ { flag=0 }
  ' "$DISPATCH_LOCAL"
}

# Driver shim: sets PROJECT_DIR/TYPE/ISSUE_NUM/KILL_STALE_PGREP_FALLBACK,
# computes script_re per the implementation contract, then invokes
# kill_stale_wrapper. Uses the regex-escape sed pattern from the design canvas.
run_kill_stale() {
  local proj_dir="$1" type_val="$2" issue_num="$3" pid_file="$4"
  local fallback_env="${5:-true}"

  PROJECT_DIR="$proj_dir" \
  ISSUE_NUM="$issue_num" \
  TYPE="$type_val" \
  KILL_STALE_PGREP_FALLBACK="$fallback_env" \
  bash -c '
    set -uo pipefail
    project_re=$(printf "%s" "${PROJECT_DIR}/scripts/" | sed "s|[][\\.*^\$+?(){}|]|\\\\&|g")
    case "$TYPE" in
      dev-new|dev-resume) script_re="${project_re}autonomous-dev\\.sh" ;;
      review)             script_re="${project_re}autonomous-review\\.sh" ;;
      *)                  script_re="${project_re}autonomous-(dev|review)\\.sh" ;;
    esac
    '"$(extract_kill_stale_wrapper)"'
    kill_stale_wrapper "$1"
  ' _ "$pid_file"
}

# Helper: emit script_re for a given (PROJECT_DIR, TYPE) — used by TC-REGEX-*.
emit_script_re() {
  local proj_dir="$1" type_val="$2"
  PROJECT_DIR="$proj_dir" TYPE="$type_val" bash -c '
    project_re=$(printf "%s" "${PROJECT_DIR}/scripts/" | sed "s|[][\\.*^\$+?(){}|]|\\\\&|g")
    case "$TYPE" in
      dev-new|dev-resume) script_re="${project_re}autonomous-dev\\.sh" ;;
      review)             script_re="${project_re}autonomous-review\\.sh" ;;
      *)                  script_re="${project_re}autonomous-(dev|review)\\.sh" ;;
    esac
    printf "%s" "$script_re"
  '
}

# ---------------------------------------------------------------------------
# Static / regex-shape assertions
# ---------------------------------------------------------------------------

echo ""
echo "=== Regex-shape assertions ==="

src=$(extract_kill_stale_wrapper)

# TC-REGEX-001..004: regex shape per TYPE.
re_dev_new=$(emit_script_re "/var/lib/proj-a" dev-new)
re_dev_resume=$(emit_script_re "/var/lib/proj-a" dev-resume)
re_review=$(emit_script_re "/var/lib/proj-a" review)
re_default=$(emit_script_re "/var/lib/proj-a" _unused_)

assert_contains "TC-REGEX-001 dev-new contains project path anchor" \
  '/var/lib/proj-a/scripts/' "$re_dev_new"
assert_contains "TC-REGEX-001 dev-new contains autonomous-dev.sh" \
  'autonomous-dev\.sh' "$re_dev_new"
[[ "$re_dev_new" != *autonomous-review* ]] \
  && { echo -e "  ${GREEN}PASS${NC}: TC-REGEX-001 dev-new excludes review wrapper"; PASS=$((PASS+1)); } \
  || { echo -e "  ${RED}FAIL${NC}: TC-REGEX-001 dev-new should not include 'autonomous-review'"; FAIL=$((FAIL+1)); }

assert_contains "TC-REGEX-002 dev-resume contains autonomous-dev.sh" \
  'autonomous-dev\.sh' "$re_dev_resume"
assert_contains "TC-REGEX-003 review contains autonomous-review.sh" \
  'autonomous-review\.sh' "$re_review"
[[ "$re_review" != *autonomous-dev\\.sh* ]] \
  && { echo -e "  ${GREEN}PASS${NC}: TC-REGEX-003 review excludes dev wrapper"; PASS=$((PASS+1)); } \
  || { echo -e "  ${RED}FAIL${NC}: TC-REGEX-003 review should not include 'autonomous-dev.sh'"; FAIL=$((FAIL+1)); }
assert_contains "TC-REGEX-004 default catch-all matches both wrappers under project" \
  'autonomous-(dev|review)\.sh' "$re_default"
assert_contains "TC-REGEX-004 default still anchors on project path" \
  '/var/lib/proj-a/scripts/' "$re_default"

# TC-REGEX-005: regex-quoting for dotted PROJECT_DIR.
re_dotted=$(emit_script_re "/home/x/.local/foo" dev-new)
assert_contains "TC-REGEX-005 dotted PROJECT_DIR is regex-escaped (\\.local)" \
  '\.local' "$re_dotted"
# A path-traversal sanity check: the dotted regex MUST NOT also match the
# undotted variant (which it would if '.' stayed unescaped).
[[ "/home/xX.local/foo/scripts/autonomous-dev.sh" =~ ^${re_dotted}$ ]] \
  && { echo -e "  ${RED}FAIL${NC}: TC-REGEX-005 unescaped dot wildcards across paths"; FAIL=$((FAIL+1)); } \
  || { echo -e "  ${GREEN}PASS${NC}: TC-REGEX-005 escaped dot does not wildcard"; PASS=$((PASS+1)); }

# TC-STATIC-001: dispatch-local.sh source declares the same shape.
assert_contains "TC-STATIC-001 source declares script_re= for dev-new|dev-resume" \
  'dev-new|dev-resume) script_re=' "$src"
assert_contains "TC-STATIC-001 source declares script_re= for review" \
  'review)             script_re=' "$src"
assert_contains "TC-STATIC-001 pgrep regex ANDs script_re with --issue matcher" \
  'pgrep -f "${script_re}.*[-]-issue ${ISSUE_NUM}\b"' "$src"
assert_contains "TC-STATIC-001 source includes project path anchor (PROJECT_DIR/scripts/)" \
  '${PROJECT_DIR}/scripts/' "$src"

# TC-STATIC-002: INV-28 reference in source comment.
assert_contains "TC-STATIC-002 source references INV-28" \
  'INV-28' "$src"

# ---------------------------------------------------------------------------
# Behavioral assertions — fixture processes vs the live function body.
# ---------------------------------------------------------------------------

echo ""
echo "=== Behavioral pgrep-fallback assertions ==="

# TC-PGREP-001 — dev-resume must NOT kill autonomous-review.sh decoy of same project.
echo ""
echo "--- TC-PGREP-001 dev-resume MUST NOT kill review wrapper for same issue/project ---"
review_pid=$(spawn_decoy "$PROJ_A" "autonomous-review.sh" 998877 --some-flag x)
_track_decoy "$review_pid"
if ! kill -0 "$review_pid" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-PGREP-001 setup — decoy did not start"
  FAIL=$((FAIL+1))
else
  run_kill_stale "$PROJ_A" dev-resume 998877 "$PID_DIR_A/issue-998877.pid" >/dev/null 2>&1 || true
  if kill -0 "$review_pid" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-PGREP-001 review decoy survived dev-resume kill_stale_wrapper"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PGREP-001 review decoy was killed by dev-resume (regression for #126)"
    FAIL=$((FAIL+1))
  fi
fi
_reap_decoys

# TC-PGREP-002 — review must NOT kill autonomous-dev.sh decoy of same project.
echo ""
echo "--- TC-PGREP-002 review MUST NOT kill dev wrapper for same issue/project ---"
dev_pid=$(spawn_decoy "$PROJ_A" "autonomous-dev.sh" 998877 --mode resume)
_track_decoy "$dev_pid"
if ! kill -0 "$dev_pid" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-PGREP-002 setup — decoy did not start"
  FAIL=$((FAIL+1))
else
  run_kill_stale "$PROJ_A" review 998877 "$PID_DIR_A/review-998877.pid" >/dev/null 2>&1 || true
  if kill -0 "$dev_pid" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-PGREP-002 dev decoy survived review kill_stale_wrapper"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PGREP-002 dev decoy was killed by review (regression for #126)"
    FAIL=$((FAIL+1))
  fi
fi
_reap_decoys

# TC-PGREP-003 — same-type orphan in same project IS group-killed.
echo ""
echo "--- TC-PGREP-003 dev-resume DOES kill autonomous-dev.sh orphan for same issue/project ---"
dev_pid=$(spawn_decoy "$PROJ_A" "autonomous-dev.sh" 998877 --mode resume)
_track_decoy "$dev_pid"
if ! kill -0 "$dev_pid" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-PGREP-003 setup — decoy did not start"
  FAIL=$((FAIL+1))
else
  run_kill_stale "$PROJ_A" dev-resume 998877 "$PID_DIR_A/issue-998877.pid" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    kill -0 "$dev_pid" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "$dev_pid" 2>/dev/null; then
    echo -e "  ${RED}FAIL${NC}: TC-PGREP-003 same-type same-project orphan survived (fallback regression)"
    FAIL=$((FAIL+1))
  else
    echo -e "  ${GREEN}PASS${NC}: TC-PGREP-003 same-type same-project orphan was reaped"
    PASS=$((PASS+1))
  fi
fi
_reap_decoys

# TC-PGREP-004 — issue 9 dispatch must NOT kill issue 99 wrapper (word boundary).
echo ""
echo "--- TC-PGREP-004 word-boundary preserved (issue 9 vs 99) ---"
dev_pid=$(spawn_decoy "$PROJ_A" "autonomous-dev.sh" 99 --mode resume)
_track_decoy "$dev_pid"
if ! kill -0 "$dev_pid" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-PGREP-004 setup — decoy did not start"
  FAIL=$((FAIL+1))
else
  run_kill_stale "$PROJ_A" dev-resume 9 "$PID_DIR_A/issue-9.pid" >/dev/null 2>&1 || true
  if kill -0 "$dev_pid" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-PGREP-004 issue 99 decoy survived issue 9 dispatch"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PGREP-004 issue 99 decoy killed by issue 9 dispatch (word-boundary regression)"
    FAIL=$((FAIL+1))
  fi
fi
_reap_decoys

# TC-PGREP-005 — cross-project isolation. The decoy is in PROJ_B; dispatch
# is for PROJ_A, same issue number. Decoy must survive.
echo ""
echo "--- TC-PGREP-005 cross-project isolation (proj-A dispatch must NOT kill proj-B wrapper) ---"
projb_pid=$(spawn_decoy "$PROJ_B" "autonomous-dev.sh" 998877 --mode resume)
_track_decoy "$projb_pid"
if ! kill -0 "$projb_pid" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-PGREP-005 setup — decoy did not start"
  FAIL=$((FAIL+1))
else
  run_kill_stale "$PROJ_A" dev-resume 998877 "$PID_DIR_A/issue-998877.pid" >/dev/null 2>&1 || true
  if kill -0 "$projb_pid" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-PGREP-005 proj-B decoy survived proj-A dispatch"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-PGREP-005 proj-B decoy was killed by proj-A dispatch (cross-project regression)"
    FAIL=$((FAIL+1))
  fi
fi
_reap_decoys

# TC-DISABLE-001 — KILL_STALE_PGREP_FALLBACK=false short-circuits.
echo ""
echo "--- TC-DISABLE-001 KILL_STALE_PGREP_FALLBACK=false skips fallback ---"
dev_pid=$(spawn_decoy "$PROJ_A" "autonomous-dev.sh" 998877 --mode resume)
_track_decoy "$dev_pid"
if ! kill -0 "$dev_pid" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-DISABLE-001 setup — decoy did not start"
  FAIL=$((FAIL+1))
else
  run_kill_stale "$PROJ_A" dev-resume 998877 "$PID_DIR_A/issue-998877.pid" false >/dev/null 2>&1 || true
  if kill -0 "$dev_pid" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: TC-DISABLE-001 fallback was skipped, decoy alive"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-DISABLE-001 decoy was killed (disable knob ignored)"
    FAIL=$((FAIL+1))
  fi
fi
_reap_decoys

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -eq 0 ]]; then
  exit 0
else
  exit 1
fi
