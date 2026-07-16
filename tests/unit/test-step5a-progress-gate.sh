#!/bin/bash
# test-step5a-progress-gate.sh — Unit tests for the progress-gated Step 5a
# SIGTERM decision (issue #485, [INV-137], consumer half of #493's
# agent-progress lease).
#
# Covers docs/test-cases/step5a-progress-gate.md:
#   - Snapshot probe (dev_progress_snapshot, local backend): FRESH/STALE
#     boundary math, the full UNKNOWN taxonomy, prior-run lease exclusion.
#   - Snapshot probe (remote backend): the real
#     agent-progress-snapshot-remote-aws-ssm.sh driver, driven end-to-end
#     against a stubbed `aws` CLI (same technique as
#     test-agent-progress-lease.sh's TC-LEASE-013 — the stub decodes and
#     executes the driver's own base64-encoded inner shell snippet locally,
#     so a regression in the driver's real logic fails this test).
#   - Step 5a decision matrix: the REAL Step 5 loop body extracted from
#     dispatcher-tick.sh (same awk-range technique as
#     test-lane-gc-p6-gate.sh's STEP5_BODY) driven behaviorally in an
#     isolated harness with every dependent function stubbed.
#
# Run: bash tests/unit/test-step5a-progress-gate.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DISPATCH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
REMOTE_DRIVER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/agent-progress-snapshot-remote-aws-ssm.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then ok "$desc"; else
    bad "$desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$desc"; else
    bad "$desc"
    echo "      needle='$needle'"
    echo "      haystack[0..300]='${haystack:0:300}'"
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# ===========================================================================
echo "=== Snapshot probe (dev_progress_snapshot, local backend) ==="
# ===========================================================================

PID_DIR="$TMPROOT/pid"
mkdir -p "$PID_DIR"
chmod 700 "$PID_DIR"

# Frozen clock: dev_progress_snapshot's own `date -u +%s` call computes
# `now` internally, so real elapsed wall-clock time between writing a
# fixture and invoking the function would make an exact-boundary case
# (TC-DPS-003, age==1800) flaky under load. Shadow `date` on PATH with a
# fake binary pinned to NOW (same technique as
# test-agent-progress-lease.sh's TC-LEASE-002 frozen-clock stub) so every
# snapshot call in this block sees the SAME "now" regardless of real time.
NOW=$(date -u +%s)
FAKE_DATE_BIN="$TMPROOT/fake-date-bin"
mkdir -p "$FAKE_DATE_BIN"
cat > "$FAKE_DATE_BIN/date" <<EOF
#!/bin/bash
if [[ "\$1" == "-u" && "\$2" == "+%s" ]]; then
  echo "$NOW"
else
  exec /usr/bin/date "\$@"
fi
EOF
chmod +x "$FAKE_DATE_BIN/date"

_snap() {
  local issue="$1"
  ( set +e
    export PATH="$FAKE_DATE_BIN:$PATH"
    export AUTONOMOUS_PID_DIR="$PID_DIR"
    export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=step5a-test MAX_RETRIES=3 MAX_CONCURRENT=5
    # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
    source "$LIB_DISPATCH" 2>/dev/null
    dev_progress_snapshot "$issue"
  )
}

_write_lease() {
  local issue="$1" pid="$2" run_id="$3" epoch="$4"
  echo "$pid" > "$PID_DIR/issue-${issue}.pid"
  chmod 600 "$PID_DIR/issue-${issue}.pid"
  echo "$run_id" > "$PID_DIR/issue-${issue}.run-id"
  chmod 600 "$PID_DIR/issue-${issue}.run-id"
  printf '{"schema_version":1,"run_id":"%s","pid":%s,"updated_at_epoch":%s}\n' "$run_id" "$pid" "$epoch" > "$PID_DIR/issue-${issue}.progress.json"
  chmod 600 "$PID_DIR/issue-${issue}.progress.json"
}

_state_of() { jq -r '.state // "PARSE-ERROR"' <<<"$1" 2>/dev/null; }
_reason_of() { jq -r '.reason // ""' <<<"$1" 2>/dev/null; }

# TC-DPS-001: age 0 -> FRESH
_write_lease 101 111 run-a "$NOW"
out=$(_snap 101)
assert_eq "TC-DPS-001: age=0 -> FRESH" "FRESH" "$(_state_of "$out")"

# TC-DPS-002: age 1799 -> FRESH
_write_lease 102 111 run-a "$((NOW - 1799))"
out=$(_snap 102)
assert_eq "TC-DPS-002: age=1799 -> FRESH" "FRESH" "$(_state_of "$out")"

# TC-DPS-003: age exactly 1800 -> FRESH (inclusive boundary)
_write_lease 103 111 run-a "$((NOW - 1800))"
out=$(_snap 103)
assert_eq "TC-DPS-003: age=1800 -> FRESH (boundary)" "FRESH" "$(_state_of "$out")"

# TC-DPS-004: age 1801 -> STALE, pid/run_id populated
_write_lease 104 111 run-a "$((NOW - 1801))"
out=$(_snap 104)
assert_eq "TC-DPS-004: age=1801 -> STALE" "STALE" "$(_state_of "$out")"
assert_eq "TC-DPS-004: pid populated" "111" "$(jq -r '.pid' <<<"$out")"
assert_eq "TC-DPS-004: run_id populated" "run-a" "$(jq -r '.run_id' <<<"$out")"

# TC-DPS-005: progress.json missing -> UNKNOWN
_write_lease 105 111 run-a "$NOW"
rm -f "$PID_DIR/issue-105.progress.json"
out=$(_snap 105)
assert_eq "TC-DPS-005: missing progress.json -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"
assert_contains "TC-DPS-005: reason token shape" "" "$(_reason_of "$out")" # non-empty checked below
if [[ -n "$(_reason_of "$out")" ]]; then ok "TC-DPS-005: reason is non-empty"; else bad "TC-DPS-005: reason is non-empty"; fi

# TC-DPS-006: run-id missing -> UNKNOWN
_write_lease 106 111 run-a "$NOW"
rm -f "$PID_DIR/issue-106.run-id"
out=$(_snap 106)
assert_eq "TC-DPS-006: missing run-id -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-007: progress.json is a symlink -> UNKNOWN
_write_lease 107 111 run-a "$NOW"
mv "$PID_DIR/issue-107.progress.json" "$TMPROOT/evil-107.json"
ln -sf "$TMPROOT/evil-107.json" "$PID_DIR/issue-107.progress.json"
out=$(_snap 107)
assert_eq "TC-DPS-007: symlinked progress.json -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"
rm -f "$PID_DIR/issue-107.progress.json"

# TC-DPS-008: bad mode 0644 -> UNKNOWN
_write_lease 108 111 run-a "$NOW"
chmod 644 "$PID_DIR/issue-108.progress.json"
out=$(_snap 108)
assert_eq "TC-DPS-008: mode 0644 -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-009: malformed JSON -> UNKNOWN
_write_lease 109 111 run-a "$NOW"
echo "not json" > "$PID_DIR/issue-109.progress.json"
chmod 600 "$PID_DIR/issue-109.progress.json"
out=$(_snap 109)
assert_eq "TC-DPS-009: malformed JSON -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-010: missing required field -> UNKNOWN
_write_lease 110 111 run-a "$NOW"
printf '{"schema_version":1,"pid":111,"updated_at_epoch":%s}\n' "$NOW" > "$PID_DIR/issue-110.progress.json"
chmod 600 "$PID_DIR/issue-110.progress.json"
out=$(_snap 110)
assert_eq "TC-DPS-010: missing run_id field -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-011: schema_version != 1 -> UNKNOWN
_write_lease 111 111 run-a "$NOW"
printf '{"schema_version":2,"run_id":"run-a","pid":111,"updated_at_epoch":%s}\n' "$NOW" > "$PID_DIR/issue-111.progress.json"
chmod 600 "$PID_DIR/issue-111.progress.json"
out=$(_snap 111)
assert_eq "TC-DPS-011: schema_version=2 -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-012: pid non-numeric -> UNKNOWN
_write_lease 112 111 run-a "$NOW"
printf '{"schema_version":1,"run_id":"run-a","pid":"abc","updated_at_epoch":%s}\n' "$NOW" > "$PID_DIR/issue-112.progress.json"
chmod 600 "$PID_DIR/issue-112.progress.json"
out=$(_snap 112)
assert_eq "TC-DPS-012: non-numeric pid -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-013: updated_at_epoch non-numeric -> UNKNOWN
_write_lease 113 111 run-a "$NOW"
printf '{"schema_version":1,"run_id":"run-a","pid":111,"updated_at_epoch":"abc"}\n' > "$PID_DIR/issue-113.progress.json"
chmod 600 "$PID_DIR/issue-113.progress.json"
out=$(_snap 113)
assert_eq "TC-DPS-013: non-numeric updated_at_epoch -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-014: updated_at_epoch negative -> UNKNOWN
_write_lease 114 111 run-a "$NOW"
printf '{"schema_version":1,"run_id":"run-a","pid":111,"updated_at_epoch":-5}\n' > "$PID_DIR/issue-114.progress.json"
chmod 600 "$PID_DIR/issue-114.progress.json"
out=$(_snap 114)
assert_eq "TC-DPS-014: negative updated_at_epoch -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-015: updated_at_epoch in the future -> UNKNOWN
_write_lease 115 111 run-a "$((NOW + 1000))"
out=$(_snap 115)
assert_eq "TC-DPS-015: future updated_at_epoch -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-016: lease pid != current issue-N.pid -> UNKNOWN
_write_lease 116 111 run-a "$NOW"
echo "999" > "$PID_DIR/issue-116.pid"
chmod 600 "$PID_DIR/issue-116.pid"
out=$(_snap 116)
assert_eq "TC-DPS-016: pid mismatch -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-017: lease run_id != current run-id (prior-run lease) -> UNKNOWN, never FRESH
_write_lease 117 111 run-a "$NOW"
echo "run-PRIOR" > "$PID_DIR/issue-117.run-id"
chmod 600 "$PID_DIR/issue-117.run-id"
out=$(_snap 117)
assert_eq "TC-DPS-017: prior-run lease (run_id mismatch) -> UNKNOWN, never FRESH" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-018: run-id is a symlink -> UNKNOWN
_write_lease 118 111 run-a "$NOW"
mv "$PID_DIR/issue-118.run-id" "$TMPROOT/evil-118.run-id"
ln -sf "$TMPROOT/evil-118.run-id" "$PID_DIR/issue-118.run-id"
out=$(_snap 118)
assert_eq "TC-DPS-018: symlinked run-id -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"
rm -f "$PID_DIR/issue-118.run-id"

# TC-DPS-019: pid_dir_for_project fails -> UNKNOWN, no crash
out=$(
  ( set +e
    unset AUTONOMOUS_PID_DIR XDG_RUNTIME_DIR
    export HOME="$TMPROOT/no-such-home-$$"
    export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=step5a-test MAX_RETRIES=3 MAX_CONCURRENT=5
    source "$LIB_DISPATCH" 2>/dev/null
    dev_progress_snapshot 119
  )
)
assert_eq "TC-DPS-019: pid_dir_for_project unavailable -> UNKNOWN (no crash)" "UNKNOWN" "$(_state_of "$out")"

# ===========================================================================
echo ""
echo "=== Snapshot probe (remote backend) — real driver, stubbed aws ==="
# ===========================================================================

# _make_replay_aws_stub <stub_bin> <real_output> <xdg_dir> [inner_path]
#
# Writes an `aws` stub into <stub_bin> that replays the driver's OWN
# base64-encoded inner shell snippet locally (same technique as
# test-agent-progress-lease.sh's TC-LEASE-013), routing its stdout to
# <real_output> under XDG_RUNTIME_DIR=<xdg_dir>. Shared by the --snapshot
# and --compare-and-signal runners below; the ONLY difference between those
# paths is the driver invocation each makes afterward.
#
# Optional <inner_path>: when set, the replayed inner snippet runs with
# PATH pinned to that value, simulating a genuinely separate remote host
# whose shell cannot reach the controller's PATH. Used by the skewed-clock
# test (TC-DPS-034) to force PATH=/usr/bin:/bin for the inner invocation
# only; left empty everywhere else so the inner snippet inherits the
# ambient PATH (including any frozen-clock shadow the caller prepended).
_make_replay_aws_stub() {
  local stub_bin="$1" real_output="$2" xdg_dir="$3" inner_path="${4:-}"
  local inner_path_prefix=""
  [[ -n "$inner_path" ]] && inner_path_prefix="PATH=\"$inner_path\" "
  cat > "$stub_bin/aws" <<STUBEOF
#!/bin/bash
case "\$*" in
  *send-command*)
    prev=""
    params_json=""
    for arg in "\$@"; do
      [[ "\$prev" == "--parameters" ]] && params_json="\$arg"
      prev="\$arg"
    done
    full_cmd=\$(printf '%s' "\$params_json" | jq -r '.commands[0]')
    b64=\$(printf '%s' "\$full_cmd" | grep -oE 'printf %s [A-Za-z0-9+/=]+ \\| base64 -d' | sed -E 's/^printf %s //; s/ \\| base64 -d\$//')
    inner_cmd=\$(printf '%s' "\$b64" | base64 -d)
    XDG_RUNTIME_DIR="$xdg_dir" ${inner_path_prefix}bash -c "\$inner_cmd" > "$real_output" 2>/dev/null || true
    echo '{"Command":{"CommandId":"stub-1","Status":"Pending"}}'
    ;;
  *get-command-invocation*)
    out=\$(cat "$real_output" 2>/dev/null || true)
    jq -n --arg out "\$out" '{"Status":"Success","StandardOutputContent":\$out,"StandardErrorContent":""}'
    ;;
esac
STUBEOF
  chmod +x "$stub_bin/aws"
}

# _run_remote_snapshot <project_id> <issue> <xdg_dir> [frozen]
#
# `frozen=1` prepends FAKE_DATE_BIN (the SAME frozen-`date` stub the local
# snapshot block above uses, pinned to $NOW) ahead of the stub `aws` on
# PATH. The remote inner shell's own `date -u +%s` call resolves PATH at
# the time it runs inside the stub's `bash -c "$inner_cmd"` replay, so this
# freezes the remote-side clock too — verified empirically that the
# shadow reaches through the stub's own subshell layer. Round-2 review
# finding #3: TC-DPS-030 only exercised age=0 and age=1801 against the
# REAL wall clock, never the FRESH/STALE boundary (1799/1800 inclusive,
# 1801 strict) the local probe's TC-DPS-002/003/004 already pin — a
# regression in the remote driver's OWN copy of the boundary comparison
# could pass TC-DPS-030 (nowhere near the boundary) while failing at
# exactly 1800.
_run_remote_snapshot() {
  local remote_project_id="$1" issue="$2" xdg_dir="$3" frozen="${4:-0}"
  local stub_bin="$TMPROOT/remote-stub-bin-$$-$RANDOM"
  mkdir -p "$stub_bin"
  local real_output="$TMPROOT/remote-real-output-$$-$RANDOM.txt"
  _make_replay_aws_stub "$stub_bin" "$real_output" "$xdg_dir"
  local path_prefix="$stub_bin"
  [[ "$frozen" == "1" ]] && path_prefix="$FAKE_DATE_BIN:$stub_bin"
  PATH="$path_prefix:$PATH" \
  SSM_INSTANCE_ID="i-test" \
  SSM_REMOTE_PROJECT_ID="$remote_project_id" \
  SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  SSM_REGION="ap-southeast-1" \
  bash "$REMOTE_DRIVER" --snapshot "$issue"
}

_run_remote_cas() {
  local remote_project_id="$1" issue="$2" xdg_dir="$3" exp_pid="$4" exp_run_id="$5"
  local stub_bin="$TMPROOT/remote-stub-bin-cas-$$-$RANDOM"
  mkdir -p "$stub_bin"
  local real_output="$TMPROOT/remote-real-output-cas-$$-$RANDOM.txt"
  _make_replay_aws_stub "$stub_bin" "$real_output" "$xdg_dir"
  PATH="$stub_bin:$PATH" \
  SSM_INSTANCE_ID="i-test" \
  SSM_REMOTE_PROJECT_ID="$remote_project_id" \
  SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  SSM_REGION="ap-southeast-1" \
  bash "$REMOTE_DRIVER" --compare-and-signal "$issue" "$exp_pid" "$exp_run_id"
}

REMOTE_XDG="$TMPROOT/remote-xdg"
REMOTE_PROJECT="rprog$$"
mkdir -p "$REMOTE_XDG/autonomous-${REMOTE_PROJECT}"

_write_remote_lease() {
  local issue="$1" pid="$2" run_id="$3" epoch="$4"
  local dir="$REMOTE_XDG/autonomous-${REMOTE_PROJECT}"
  echo "$pid" > "$dir/issue-${issue}.pid"
  chmod 600 "$dir/issue-${issue}.pid"
  echo "$run_id" > "$dir/issue-${issue}.run-id"
  chmod 600 "$dir/issue-${issue}.run-id"
  printf '{"schema_version":1,"run_id":"%s","pid":%s,"updated_at_epoch":%s}\n' "$run_id" "$pid" "$epoch" > "$dir/issue-${issue}.progress.json"
  chmod 600 "$dir/issue-${issue}.progress.json"
}

# TC-DPS-030: same fixtures as local, run through the remote driver -> identical state
_write_remote_lease 201 111 run-a "$NOW"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 201 "$REMOTE_XDG")
assert_eq "TC-DPS-030a: remote FRESH (age=0) matches local" "FRESH" "$(_state_of "$out")"

_write_remote_lease 202 111 run-a "$((NOW - 1801))"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 202 "$REMOTE_XDG")
assert_eq "TC-DPS-030b: remote STALE (age=1801) matches local" "STALE" "$(_state_of "$out")"

# TC-DPS-049..051: remote FRESH/STALE boundary at exactly 1799/1800/1801,
# under the FROZEN clock (see _run_remote_snapshot's docstring) so the
# assertion is exact rather than a wall-clock-drift-tolerant range — the
# same boundary local TC-DPS-002/003/004 already pin, run through the REAL
# remote driver instead of the local dev_progress_snapshot.
_write_remote_lease 234 111 run-a "$((NOW - 1799))"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 234 "$REMOTE_XDG" 1)
assert_eq "TC-DPS-049: remote age=1799 -> FRESH (frozen clock)" "FRESH" "$(_state_of "$out")"

_write_remote_lease 235 111 run-a "$((NOW - 1800))"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 235 "$REMOTE_XDG" 1)
assert_eq "TC-DPS-050: remote age=1800 -> FRESH (inclusive boundary, frozen clock)" "FRESH" "$(_state_of "$out")"

_write_remote_lease 236 111 run-a "$((NOW - 1801))"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 236 "$REMOTE_XDG" 1)
assert_eq "TC-DPS-051: remote age=1801 -> STALE (strict boundary, frozen clock)" "STALE" "$(_state_of "$out")"

# TC-DPS-035..048: remote UNKNOWN-family parity. Same fixture families as
# the local probe's TC-DPS-005..018, run through the REAL remote driver
# (stubbed aws/SSM transport, real remote shell snippet executed locally)
# — a divergence in the duplicated remote classifier (agent-progress-
# snapshot-remote-aws-ssm.sh's own copy of the snapshot logic) must fail
# one of these, not just the FRESH/STALE-only TC-DPS-030 pair above.
_remote_dir() { echo "$REMOTE_XDG/autonomous-${REMOTE_PROJECT}"; }

# TC-DPS-035: progress.json missing -> UNKNOWN
_write_remote_lease 220 111 run-a "$NOW"
rm -f "$(_remote_dir)/issue-220.progress.json"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 220 "$REMOTE_XDG")
assert_eq "TC-DPS-035: remote missing progress.json -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-036: run-id missing -> UNKNOWN
_write_remote_lease 221 111 run-a "$NOW"
rm -f "$(_remote_dir)/issue-221.run-id"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 221 "$REMOTE_XDG")
assert_eq "TC-DPS-036: remote missing run-id -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-037: progress.json is a symlink -> UNKNOWN
_write_remote_lease 222 111 run-a "$NOW"
mv "$(_remote_dir)/issue-222.progress.json" "$TMPROOT/evil-remote-222.json"
ln -sf "$TMPROOT/evil-remote-222.json" "$(_remote_dir)/issue-222.progress.json"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 222 "$REMOTE_XDG")
assert_eq "TC-DPS-037: remote symlinked progress.json -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"
rm -f "$(_remote_dir)/issue-222.progress.json"

# TC-DPS-038: bad mode 0644 -> UNKNOWN
_write_remote_lease 223 111 run-a "$NOW"
chmod 644 "$(_remote_dir)/issue-223.progress.json"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 223 "$REMOTE_XDG")
assert_eq "TC-DPS-038: remote mode 0644 -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-039: malformed JSON -> UNKNOWN
_write_remote_lease 224 111 run-a "$NOW"
echo "not json" > "$(_remote_dir)/issue-224.progress.json"
chmod 600 "$(_remote_dir)/issue-224.progress.json"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 224 "$REMOTE_XDG")
assert_eq "TC-DPS-039: remote malformed JSON -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-040: missing required field -> UNKNOWN
_write_remote_lease 225 111 run-a "$NOW"
printf '{"schema_version":1,"pid":111,"updated_at_epoch":%s}\n' "$NOW" > "$(_remote_dir)/issue-225.progress.json"
chmod 600 "$(_remote_dir)/issue-225.progress.json"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 225 "$REMOTE_XDG")
assert_eq "TC-DPS-040: remote missing run_id field -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-041: schema_version != 1 -> UNKNOWN
_write_remote_lease 226 111 run-a "$NOW"
printf '{"schema_version":2,"run_id":"run-a","pid":111,"updated_at_epoch":%s}\n' "$NOW" > "$(_remote_dir)/issue-226.progress.json"
chmod 600 "$(_remote_dir)/issue-226.progress.json"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 226 "$REMOTE_XDG")
assert_eq "TC-DPS-041: remote schema_version=2 -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-042: pid non-numeric -> UNKNOWN
_write_remote_lease 227 111 run-a "$NOW"
printf '{"schema_version":1,"run_id":"run-a","pid":"abc","updated_at_epoch":%s}\n' "$NOW" > "$(_remote_dir)/issue-227.progress.json"
chmod 600 "$(_remote_dir)/issue-227.progress.json"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 227 "$REMOTE_XDG")
assert_eq "TC-DPS-042: remote non-numeric pid -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-043: updated_at_epoch non-numeric -> UNKNOWN
_write_remote_lease 228 111 run-a "$NOW"
printf '{"schema_version":1,"run_id":"run-a","pid":111,"updated_at_epoch":"abc"}\n' > "$(_remote_dir)/issue-228.progress.json"
chmod 600 "$(_remote_dir)/issue-228.progress.json"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 228 "$REMOTE_XDG")
assert_eq "TC-DPS-043: remote non-numeric updated_at_epoch -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-044: updated_at_epoch negative -> UNKNOWN
_write_remote_lease 229 111 run-a "$NOW"
printf '{"schema_version":1,"run_id":"run-a","pid":111,"updated_at_epoch":-5}\n' > "$(_remote_dir)/issue-229.progress.json"
chmod 600 "$(_remote_dir)/issue-229.progress.json"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 229 "$REMOTE_XDG")
assert_eq "TC-DPS-044: remote negative updated_at_epoch -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-045: updated_at_epoch in the future -> UNKNOWN
_write_remote_lease 230 111 run-a "$((NOW + 1000))"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 230 "$REMOTE_XDG")
assert_eq "TC-DPS-045: remote future updated_at_epoch -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-046: lease pid != current issue-N.pid -> UNKNOWN
_write_remote_lease 231 111 run-a "$NOW"
echo "999" > "$(_remote_dir)/issue-231.pid"
chmod 600 "$(_remote_dir)/issue-231.pid"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 231 "$REMOTE_XDG")
assert_eq "TC-DPS-046: remote pid mismatch -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-047: lease run_id != current run-id (prior-run lease) -> UNKNOWN, never FRESH
_write_remote_lease 232 111 run-a "$NOW"
echo "run-PRIOR" > "$(_remote_dir)/issue-232.run-id"
chmod 600 "$(_remote_dir)/issue-232.run-id"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 232 "$REMOTE_XDG")
assert_eq "TC-DPS-047: remote prior-run lease (run_id mismatch) -> UNKNOWN, never FRESH" "UNKNOWN" "$(_state_of "$out")"

# TC-DPS-048: run-id is a symlink -> UNKNOWN
_write_remote_lease 233 111 run-a "$NOW"
mv "$(_remote_dir)/issue-233.run-id" "$TMPROOT/evil-remote-233.run-id"
ln -sf "$TMPROOT/evil-remote-233.run-id" "$(_remote_dir)/issue-233.run-id"
out=$(_run_remote_snapshot "$REMOTE_PROJECT" 233 "$REMOTE_XDG")
assert_eq "TC-DPS-048: remote symlinked run-id -> UNKNOWN" "UNKNOWN" "$(_state_of "$out")"
rm -f "$(_remote_dir)/issue-233.run-id"

# TC-DPS-031: SSM send-command failure -> UNKNOWN, never STALE
out=$(
  stub_bin="$TMPROOT/fail-stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*) echo "stub aws: send-command failure" >&2; exit 1 ;;
esac
EOF
  chmod +x "$stub_bin/aws"
  PATH="$stub_bin:$PATH" \
  SSM_INSTANCE_ID="i-test" SSM_REMOTE_PROJECT_ID="$REMOTE_PROJECT" SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  bash "$REMOTE_DRIVER" --snapshot 203 2>/dev/null
)
rc_check=$(
  stub_bin="$TMPROOT/fail-stub-bin2"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*) echo "stub aws: send-command failure" >&2; exit 1 ;;
esac
EOF
  chmod +x "$stub_bin/aws"
  PATH="$stub_bin:$PATH" \
  SSM_INSTANCE_ID="i-test" SSM_REMOTE_PROJECT_ID="$REMOTE_PROJECT" SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  bash "$REMOTE_DRIVER" --snapshot 203 >/dev/null 2>&1
  echo $?
)
assert_eq "TC-DPS-031: transport failure -> driver rc=2 (indeterminate, never STALE)" "2" "$rc_check"

# TC-DPS-032: SSM poll-deadline timeout (get-command-invocation stays
# InProgress forever) -> UNKNOWN/rc=2, never STALE. Uses a short
# REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS so the test doesn't wait the real
# (default 8s) poll cap.
rc_timeout=$(
  stub_bin="$TMPROOT/timeout-stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*) echo '{"Command":{"CommandId":"x","Status":"Pending"}}' ;;
  *get-command-invocation*) echo '{"Status":"InProgress","StandardOutputContent":"","StandardErrorContent":""}' ;;
esac
EOF
  chmod +x "$stub_bin/aws"
  PATH="$stub_bin:$PATH" \
  SSM_INSTANCE_ID="i-test" SSM_REMOTE_PROJECT_ID="$REMOTE_PROJECT" SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS="1" \
  bash "$REMOTE_DRIVER" --snapshot 209 >/dev/null 2>&1
  echo $?
)
assert_eq "TC-DPS-032: poll-deadline timeout -> driver rc=2 (indeterminate, never STALE)" "2" "$rc_timeout"

# TC-DPS-033: remote stdout not valid JSON matching any shape -> rc=2
out_rc=$(
  stub_bin="$TMPROOT/garbage-stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*) echo '{"Command":{"CommandId":"x","Status":"Pending"}}' ;;
  *get-command-invocation*) echo '{"Status":"Success","StandardOutputContent":"garbage not json","StandardErrorContent":""}' ;;
esac
EOF
  chmod +x "$stub_bin/aws"
  PATH="$stub_bin:$PATH" \
  SSM_INSTANCE_ID="i-test" SSM_REMOTE_PROJECT_ID="$REMOTE_PROJECT" SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  bash "$REMOTE_DRIVER" --snapshot 204 >/dev/null 2>&1
  echo $?
)
assert_eq "TC-DPS-033: malformed remote stdout -> rc=2 (indeterminate, never STALE)" "2" "$out_rc"

# TC-DPS-034: remote age is computed on the REMOTE host's clock, not the
# controller's — proven with a genuinely SKEWED controller clock (round-2
# review finding #4: the original version read the real host clock for
# BOTH fixture setup and assertion, so it would still pass even if the
# driver regressed to computing age from the CONTROLLER's clock, since
# both clocks were, in fact, the same clock).
#
# Setup: the OUTER PATH (the "controller") is shadowed with a `date` stub
# skewed 500000s into the future — far outside any plausible tolerance
# window. If the driver's remote snippet's `NOW=$(date -u +%s)` resolved
# this skewed controller `date` (the regression this test exists to
# catch), the resulting age would be ~500000s too large, nowhere near the
# expected ~1801. The `aws` stub's replay of the remote inner script
# forces PATH=/usr/bin:/bin for that inner invocation ONLY — simulating a
# genuinely separate remote host whose clock the skewed controller PATH
# cannot reach — so a CORRECT driver still reports age~1801 despite the
# hostile outer PATH.
SKEW_DATE_BIN="$TMPROOT/skew-date-bin"
mkdir -p "$SKEW_DATE_BIN"
_real_now_probe=$(date -u +%s)
_skew_now=$((_real_now_probe + 500000))
cat > "$SKEW_DATE_BIN/date" <<EOF
#!/bin/bash
if [[ "\$1" == "-u" && "\$2" == "+%s" ]]; then
  echo "$_skew_now"
else
  exec /usr/bin/date "\$@"
fi
EOF
chmod +x "$SKEW_DATE_BIN/date"

_run_remote_snapshot_skew_controller_clock() {
  local remote_project_id="$1" issue="$2" xdg_dir="$3"
  local stub_bin="$TMPROOT/remote-stub-bin-skew-$$-$RANDOM"
  mkdir -p "$stub_bin"
  local real_output="$TMPROOT/remote-real-output-skew-$$-$RANDOM.txt"
  # Pin the replayed inner snippet's PATH to /usr/bin:/bin so it CANNOT
  # reach $SKEW_DATE_BIN on the outer (controller) PATH — a correct driver
  # must then compute age from the real remote-host clock, not the skew.
  _make_replay_aws_stub "$stub_bin" "$real_output" "$xdg_dir" "/usr/bin:/bin"
  PATH="$SKEW_DATE_BIN:$stub_bin:$PATH" \
  SSM_INSTANCE_ID="i-test" \
  SSM_REMOTE_PROJECT_ID="$remote_project_id" \
  SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  SSM_REGION="ap-southeast-1" \
  bash "$REMOTE_DRIVER" --snapshot "$issue"
}

_write_remote_lease 205 111 run-a "$((_real_now_probe - 1801))"
out=$(_run_remote_snapshot_skew_controller_clock "$REMOTE_PROJECT" 205 "$REMOTE_XDG")
remote_age=$(jq -r '.age' <<<"$out" 2>/dev/null)
# Tolerance window computed from the REAL wall clock at assertion time
# (not a fixed constant) — this block runs after an increasing number of
# earlier fixture/driver invocations elsewhere in this file, so a fixed
# "< N seconds since script start" window would grow flaky as this file
# gains more test cases ahead of it. Critically, the ceiling stays anchored
# to the small real-time delta, NOT to the 500000s skew — a regression that
# leaked the skewed controller clock into the remote age computation would
# blow past this ceiling by ~500000s and fail loudly.
_expected_age_ceiling=$(( $(date -u +%s) - _real_now_probe + 1801 + 5 ))
if [[ "$remote_age" -ge 1801 ]] && [[ "$remote_age" -le "$_expected_age_ceiling" ]]; then
  ok "TC-DPS-034: remote age computed independently of a skewed controller clock (age=${remote_age}, expected ~1801)"
else
  bad "TC-DPS-034: remote age computed independently of a skewed controller clock (got age=${remote_age}, expected <= ${_expected_age_ceiling})"
fi

# Spawns a real, killable process that blocks on a FIFO it opens for both
# read AND write (so there's no writer/EOF race to depend on) — never a
# `sleep N`. Round-2 review finding #4: a `sleep 60 &` "real background
# process" plus a bounded poll loop for its death is still a wall-clock
# dependency in spirit, and this codebase already has a no-sleep idiom for
# "spawn a real victim process" (test-lane-gc-p1-source-hygiene.sh's
# `mkfifo` + blocking-open technique). The victim blocks in the kernel on
# the `exec 3<>fifo` open / the subsequent read, not on a timer, so its
# liveness is a pure kill/wait fact rather than a timing guess.
#
# Spawned INLINE (not via a helper called through `$(...)`) for two
# reasons: (1) command substitution runs in its own subshell, so a
# background job started inside one is never a child of THIS shell and
# `wait` on it fails with "not a child of this shell"; (2) the FIFO
# reader's stdout would otherwise inherit the substitution's capture pipe,
# which never sees EOF while the child is alive, hanging the substitution
# itself. `>/dev/null 2>&1` keeps the victim's stdio detached from
# anything this script reads.

# Compare-and-signal: SIGNALED path against a real background process.
VICTIM_FIFO_206="$TMPROOT/victim-206.fifo"
mkfifo "$VICTIM_FIFO_206"
( exec 3<>"$VICTIM_FIFO_206"; cat <&3 ) >/dev/null 2>&1 &
REAL_PID=$!
_write_remote_lease 206 "$REAL_PID" run-sig "$((NOW - 1801))"
out=$(_run_remote_cas "$REMOTE_PROJECT" 206 "$REMOTE_XDG" "$REAL_PID" "run-sig")
assert_eq "TC-S5A-031 (remote CAS): matching pid/run_id -> SIGNALED" "SIGNALED" "$out"
# `wait` blocks until the process is actually reaped — no poll loop, no
# fixed sleep, no timing guess: SIGNALED already means the driver's remote
# shell delivered kill -TERM before returning, so the signal has already
# been sent by the time we get here; `wait` just observes the outcome.
wait "$REAL_PID" 2>/dev/null
if kill -0 "$REAL_PID" 2>/dev/null; then
  bad "TC-S5A-031 (remote CAS): process actually terminated"
  kill "$REAL_PID" 2>/dev/null
else
  ok "TC-S5A-031 (remote CAS): process actually terminated"
fi

# Compare-and-signal: ABORTED on run_id mismatch — process must survive.
VICTIM_FIFO_207="$TMPROOT/victim-207.fifo"
mkfifo "$VICTIM_FIFO_207"
( exec 3<>"$VICTIM_FIFO_207"; cat <&3 ) >/dev/null 2>&1 &
REAL_PID2=$!
_write_remote_lease 207 "$REAL_PID2" run-sig "$((NOW - 1801))"
out=$(_run_remote_cas "$REMOTE_PROJECT" 207 "$REMOTE_XDG" "$REAL_PID2" "WRONG-RUN-ID")
assert_eq "TC-S5A-032 (remote CAS): run_id mismatch -> ABORTED" "ABORTED:run-id-changed" "$out"
# No signal was ever sent on this path (ABORTED short-circuits before
# `kill -TERM`), so there is no async-delivery race to wait out here —
# check liveness immediately.
if kill -0 "$REAL_PID2" 2>/dev/null; then
  ok "TC-S5A-032 (remote CAS): process survives an aborted signal"
else
  bad "TC-S5A-032 (remote CAS): process survives an aborted signal"
fi
kill "$REAL_PID2" 2>/dev/null
wait "$REAL_PID2" 2>/dev/null

# TC-S5A-033: compare-and-signal SSM transport failure -> ABORTED sentinel, never SIGNALED
out_cas_fail=$(
  stub_bin="$TMPROOT/cas-fail-stub"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*) exit 1 ;;
esac
EOF
  chmod +x "$stub_bin/aws"
  PATH="$stub_bin:$PATH" \
  SSM_INSTANCE_ID="i-test" SSM_REMOTE_PROJECT_ID="$REMOTE_PROJECT" SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  bash "$REMOTE_DRIVER" --compare-and-signal 208 111 run-a 2>/dev/null
)
out_cas_fail_rc=$(
  stub_bin="$TMPROOT/cas-fail-stub2"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*) exit 1 ;;
esac
EOF
  chmod +x "$stub_bin/aws"
  PATH="$stub_bin:$PATH" \
  SSM_INSTANCE_ID="i-test" SSM_REMOTE_PROJECT_ID="$REMOTE_PROJECT" SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  bash "$REMOTE_DRIVER" --compare-and-signal 208 111 run-a >/dev/null 2>&1
  echo $?
)
assert_eq "TC-S5A-033: compare-and-signal transport failure -> rc=2" "2" "$out_cas_fail_rc"

# ===========================================================================
echo ""
echo "=== Step 5a decision matrix (real extracted control-flow block) ==="
# ===========================================================================

STEP5_BODY=$(awk '/^for i in \$\(seq 0 \$\(\(cand_count - 1\)\)\); do$/{f=1} f{print} f && /^done$/{exit}' "$TICK")

if [[ -n "$STEP5_BODY" ]] && grep -q 'INV-137' <<<"$STEP5_BODY"; then
  ok "Extraction control: Step 5 loop body extracted and contains the INV-137 marker"
else
  bad "Extraction control: Step 5 loop body extraction is empty OR missing the INV-137 marker — the awk range no longer matches dispatcher-tick.sh's structure; every assertion below is UNRELIABLE until fixed"
fi

# _build_harness <harness> <backend> <initial_state> <initial_age>
#   <recheck_state> <recheck_run_id> [recheck_kill0_rc] [get_pid_after_dispatch]
#   [kill_term_rc] [pr_idle]
#
# Builds a harness script with every Step 5a dependency stubbed. Common
# fixture: PR #77, updatedAt far in the past (pr_idle_seconds stubbed
# directly so we don't need real date math — default "301", parameterized
# via the 10th arg for TC-S5A-004's boundary case), CI green, dev PID alive
# (the OUTER pid_alive gate is ALWAYS true — a dead wrapper never reaches
# Step 5a at all; that's Step 5b's branch, tested elsewhere). `dev_progress_snapshot`
# is called TWICE by the real control flow (initial + final recheck) — a
# per-harness COUNTER FILE (not a subshell-local var, which would reset to 0
# on every `$(...)` call under `dev_progress_snapshot`) tracks which call this
# is. `recheck_kill0_rc` controls the FINAL PRE-KILL `kill -0 "$pid"` recheck
# specifically (TC-S5A-009) — separate from the always-true outer pid_alive gate.
_build_harness() {
  local harness="$1" backend="$2" initial_state="$3" initial_age="$4" \
        recheck_state="$5" recheck_run_id="$6" recheck_kill0_rc="${7:-0}" \
        get_pid_after_dispatch="${8:-12345}" kill_term_rc="${9:-0}" \
        pr_idle="${10:-301}"
  local counter_file="${harness}.dps-count"
  : > "$counter_file"
  {
    echo '#!/bin/bash'
    echo 'set -u'
    echo "EXECUTION_BACKEND='${backend}'"
    echo "COUNTER_FILE='${counter_file}'"
    echo 'POSTED=0'
    echo 'POSTED_BODY=""'
    echo 'LABEL_SWAPS=0'
    echo 'KILL_TERM_CALLS=0'
    echo 'log() { :; }'
    echo 'was_just_dispatched() { return 1; }'
    echo 'is_within_grace_period() { return 1; }'
    echo 'itp_post_comment() { POSTED=$((POSTED + 1)); POSTED_BODY="$2"; }'
    echo 'label_swap() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); }'
    echo 'pid_alive() { return 0; }'
    echo "get_pid() { echo '${get_pid_after_dispatch}'; }"
    echo 'fetch_pr_for_issue() { echo "{\"number\":77,\"updatedAt\":\"2020-01-01T00:00:00Z\"}"; }'
    echo 'ci_is_green() { return 0; }'
    echo "pr_idle_seconds() { echo '${pr_idle}'; }"
    echo 'dev_near_success() { return 1; }'
    echo 'review_near_success() { return 1; }'
    echo 'recent_error_envelope() { echo ""; }'
    echo 'last_reviewed_head() { echo ""; }'
    echo 'declare -F metrics_emit >/dev/null 2>&1 || metrics_emit() { :; }'
    echo "dev_progress_snapshot() {
      local n
      n=\$(cat \"\$COUNTER_FILE\" 2>/dev/null || echo 0)
      n=\$((n + 1))
      echo \"\$n\" > \"\$COUNTER_FILE\"
      if [ \"\$n\" -eq 1 ]; then
        echo '{\"state\":\"${initial_state}\",\"age\":${initial_age},\"pid\":12345,\"run_id\":\"run-initial\"}'
      else
        echo '{\"state\":\"${recheck_state}\",\"age\":${initial_age},\"pid\":12345,\"run_id\":\"${recheck_run_id}\"}'
      fi
    }"
    echo "_remote_dev_progress_snapshot_query() { echo '{\"state\":\"${initial_state}\",\"age\":${initial_age},\"pid\":12345,\"run_id\":\"run-initial\"}'; }"
    echo "kill() {
      if [ \"\$1\" = \"-0\" ]; then return ${recheck_kill0_rc}; fi
      KILL_TERM_CALLS=\$((KILL_TERM_CALLS + 1))
      return ${kill_term_rc}
    }"
    echo 'candidates='"'"'[{"number":9999,"labels":["autonomous","in-progress"]}]'"'"''
    echo 'cand_count=1'
    echo "$STEP5_BODY"
    echo 'echo "POSTED=$POSTED"'
    echo 'echo "POSTED_BODY=[$POSTED_BODY]"'
    echo 'echo "LABEL_SWAPS=$LABEL_SWAPS"'
    echo 'echo "KILL_TERM_CALLS=$KILL_TERM_CALLS"'
  } > "$harness"
}

_build_harness_remote_cas() {
  local harness="$1" initial_state="$2" initial_age="$3" cas_result="$4"
  {
    echo '#!/bin/bash'
    echo 'set -u'
    echo "EXECUTION_BACKEND='remote-aws-ssm'"
    echo 'POSTED=0'
    echo 'POSTED_BODY=""'
    echo 'LABEL_SWAPS=0'
    echo 'log() { :; }'
    echo 'was_just_dispatched() { return 1; }'
    echo 'is_within_grace_period() { return 1; }'
    echo 'itp_post_comment() { POSTED=$((POSTED + 1)); POSTED_BODY="$2"; }'
    echo 'label_swap() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); }'
    echo 'pid_alive() { return 0; }'
    echo 'get_pid() { echo ""; }'
    echo 'fetch_pr_for_issue() { echo "{\"number\":77,\"updatedAt\":\"2020-01-01T00:00:00Z\"}"; }'
    echo 'ci_is_green() { return 0; }'
    echo 'pr_idle_seconds() { echo "301"; }'
    echo 'dev_near_success() { return 1; }'
    echo 'review_near_success() { return 1; }'
    echo 'recent_error_envelope() { echo ""; }'
    echo 'last_reviewed_head() { echo ""; }'
    echo 'declare -F metrics_emit >/dev/null 2>&1 || metrics_emit() { :; }'
    echo "_remote_dev_progress_snapshot_query() { echo '{\"state\":\"${initial_state}\",\"age\":${initial_age},\"pid\":12345,\"run_id\":\"run-initial\"}'; }"
    echo "_remote_dev_progress_compare_and_signal() { echo '${cas_result}'; }"
    echo 'kill() { return 0; }'
    echo 'candidates='"'"'[{"number":9999,"labels":["autonomous","in-progress"]}]'"'"''
    echo 'cand_count=1'
    echo "$STEP5_BODY"
    echo 'echo "POSTED=$POSTED"'
    echo 'echo "POSTED_BODY=[$POSTED_BODY]"'
    echo 'echo "LABEL_SWAPS=$LABEL_SWAPS"'
  } > "$harness"
}

H="$TMPROOT/h.sh"

# TC-S5A-001: progress age=0 (FRESH) -> no action
_build_harness "$H" local FRESH 0 FRESH run-initial
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-001: FRESH progress -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-001: FRESH progress -> no label change" "LABEL_SWAPS=0" "$out"

# TC-S5A-002: progress age=1800 (FRESH boundary) -> no action
_build_harness "$H" local FRESH 1800 FRESH run-initial
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-002: FRESH boundary (age=1800) -> no comment" "POSTED=0" "$out"

# TC-S5A-003: progress age=1801 (STALE), recheck also STALE same run_id -> SIGTERM + comment + swap
_build_harness "$H" local STALE 1801 STALE run-initial
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-003: STALE + passing recheck -> comment posted" "POSTED=1" "$out"
assert_contains "TC-S5A-003: STALE + passing recheck -> label swapped" "LABEL_SWAPS=1" "$out"
assert_contains "TC-S5A-003: STALE + passing recheck -> SIGTERM sent" "KILL_TERM_CALLS=1" "$out"
assert_contains "TC-S5A-003: comment mentions PR inactivity AND progress staleness" "PR inactive 301s" "$out"
assert_contains "TC-S5A-003: comment mentions progress age" "no agent progress for 1801s" "$out"

# TC-S5A-004: pr_idle EXACTLY 300 (INV-10 strict >, not >=) + progress STALE
# -> no action. Pins the pre-existing idle boundary is UNCHANGED by this PR —
# a regression that loosened `-le 300` to `-lt 300` in dispatcher-tick.sh
# would pass every other test in this file (they all use pr_idle=301) but
# fail this one.
_build_harness "$H" local STALE 1801 STALE run-initial 0 12345 0 300
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-004: pr_idle=300 (INV-10 boundary) -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-004: pr_idle=300 (INV-10 boundary) -> no label change" "LABEL_SWAPS=0" "$out"
assert_contains "TC-S5A-004: pr_idle=300 (INV-10 boundary) -> no SIGTERM" "KILL_TERM_CALLS=0" "$out"

# TC-S5A-005: UNKNOWN snapshot -> no action + WARN
_build_harness "$H" local UNKNOWN 0 UNKNOWN run-initial
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-005: UNKNOWN snapshot -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-005: UNKNOWN snapshot -> no label change" "LABEL_SWAPS=0" "$out"

# TC-S5A-006: initial STALE, final recheck FRESH -> abort
_build_harness "$H" local STALE 1801 FRESH run-initial
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-006: recheck flips to FRESH -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-006: recheck flips to FRESH -> no label change" "LABEL_SWAPS=0" "$out"
assert_contains "TC-S5A-006: recheck flips to FRESH -> no SIGTERM" "KILL_TERM_CALLS=0" "$out"

# TC-S5A-007: PID changed between checks -> abort
_build_harness "$H" local STALE 1801 STALE run-initial 0 99999
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-007: PID changed on recheck -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-007: PID changed on recheck -> no label change" "LABEL_SWAPS=0" "$out"

# TC-S5A-008: recheck STALE but different run_id -> abort
_build_harness "$H" local STALE 1801 STALE run-DIFFERENT
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-008: run_id changed on recheck -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-008: run_id changed on recheck -> no label change" "LABEL_SWAPS=0" "$out"

# TC-S5A-009: kill -0 fails on final recheck (process exited) -> abort
_build_harness "$H" local STALE 1801 STALE run-initial 1
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-009: process gone before final recheck -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-009: process gone before final recheck -> no label change" "LABEL_SWAPS=0" "$out"

# TC-S5A-010: kill itself fails at signal time -> no comment, no transition
_build_harness "$H" local STALE 1801 STALE run-initial 0 12345 1
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-010: signal fails at kill time -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-010: signal fails at kill time -> no label change" "LABEL_SWAPS=0" "$out"

# TC-S5A-011: the pre-existing PR-exists / CI-green / idle<=300 short-circuits
# still fire BEFORE the new snapshot gate — even with a snapshot that WOULD
# be STALE, none of these three should ever reach dev_progress_snapshot (a
# regression that reordered the gates, or made the snapshot check run first,
# would flip these to SIGTERM+comment instead of a clean no-op). Each variant
# builds its own minimal harness (not `_build_harness`, since that always
# supplies a PR + green CI) with a `dev_progress_snapshot` stub that records
# whether it was ever CALLED — the assertion is on that call count, not just
# on the absence of a comment.
_build_gate_order_harness() {
  local harness="$1" pr_body="$2" ci_rc="$3" idle="$4"
  local dps_calls_file="${harness}.dps-calls"
  : > "$dps_calls_file"
  {
    echo '#!/bin/bash'
    echo 'set -u'
    echo "DPS_CALLS_FILE='${dps_calls_file}'"
    echo 'POSTED=0'
    echo 'LABEL_SWAPS=0'
    echo 'log() { :; }'
    echo 'was_just_dispatched() { return 1; }'
    echo 'is_within_grace_period() { return 1; }'
    echo 'itp_post_comment() { POSTED=$((POSTED + 1)); }'
    echo 'label_swap() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); }'
    echo 'pid_alive() { return 0; }'
    echo 'get_pid() { echo "12345"; }'
    echo "fetch_pr_for_issue() { echo '${pr_body}'; }"
    echo "ci_is_green() { return ${ci_rc}; }"
    echo "pr_idle_seconds() { echo '${idle}'; }"
    echo 'dev_near_success() { return 1; }'
    echo 'review_near_success() { return 1; }'
    echo 'recent_error_envelope() { echo ""; }'
    echo 'last_reviewed_head() { echo ""; }'
    echo 'declare -F metrics_emit >/dev/null 2>&1 || metrics_emit() { :; }'
    # dev_progress_snapshot runs via `$(...)` in the real Step 5a code — a
    # subshell — so a plain variable increment here would never be visible
    # to the parent; record calls in a file instead (same technique as
    # _build_harness's own counter_file above).
    echo 'dev_progress_snapshot() { echo x >> "$DPS_CALLS_FILE"; echo "{\"state\":\"STALE\",\"age\":1801,\"pid\":12345,\"run_id\":\"run-initial\"}"; }'
    echo 'kill() { return 0; }'
    echo 'candidates='"'"'[{"number":9999,"labels":["autonomous","in-progress"]}]'"'"''
    echo 'cand_count=1'
    echo "$STEP5_BODY"
    echo 'echo "POSTED=$POSTED"'
    echo 'echo "LABEL_SWAPS=$LABEL_SWAPS"'
  } > "$harness"
}

_build_gate_order_harness "$H" "" 0 301
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-011a: no PR -> no comment (short-circuits before snapshot)" "POSTED=0" "$out"
assert_eq "TC-S5A-011a: no PR -> dev_progress_snapshot never called" "0" "$(wc -l < "${H}.dps-calls" | tr -d ' ')"

_build_gate_order_harness "$H" '{"number":77,"updatedAt":"2020-01-01T00:00:00Z"}' 1 301
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-011b: CI not green -> no comment (short-circuits before snapshot)" "POSTED=0" "$out"
assert_eq "TC-S5A-011b: CI not green -> dev_progress_snapshot never called" "0" "$(wc -l < "${H}.dps-calls" | tr -d ' ')"

_build_gate_order_harness "$H" '{"number":77,"updatedAt":"2020-01-01T00:00:00Z"}' 0 300
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-011c: idle<=300 -> no comment (short-circuits before snapshot)" "POSTED=0" "$out"
assert_eq "TC-S5A-011c: idle<=300 -> dev_progress_snapshot never called" "0" "$(wc -l < "${H}.dps-calls" | tr -d ' ')"

# ===========================================================================
echo ""
echo "=== TC-S5A-020: automated regression pin against the PRE-FIX ALIVE branch ==="
# ===========================================================================
# The headline regression this issue closes: under the OLD idle-only gate, a
# FRESH-progress agent (actively working locally, no push in 5+ min) with
# pr_idle=301 and green CI gets SIGTERMed anyway. Pinned as a frozen literal
# snippet (byte-for-byte captured from dispatcher-tick.sh at commit 55c0c82,
# the tip of main immediately before this fix) rather than a dynamic `git
# show <sha>` — GitHub Actions checkouts are shallow/single-ref, so a
# commit-SHA lookup can 404 there even when the pinned content is correct
# (same rationale test-lane-gc-p1-source-hygiene.sh's TC-LGC1-040 documents
# for its own frozen-copy pin). This is deliberately NOT re-run against the
# live pre-fix tree — it exists once, here, as a permanent regression fence:
# if a future edit reintroduces this exact shape elsewhere, this test still
# proves what "old behavior" looked like and that new behavior differs.
PRE_FIX_ALIVE_BRANCH=$(cat <<'PREFIXEOF'
  if pid_alive "$kind" "$issue_num"; then
    if [ "$kind" != "issue" ]; then
      continue
    fi

    pid=$(get_pid "$kind" "$issue_num")

    pr_info=$(fetch_pr_for_issue "$issue_num" "number,body,updatedAt")
    if [ -z "$pr_info" ]; then
      continue
    fi

    pr_num=$(jq -r '.number // empty' <<<"$pr_info")
    pr_updated_at=$(jq -r '.updatedAt // empty' <<<"$pr_info")

    if ! [[ "$pr_num" =~ ^[0-9]+$ ]] || [ -z "$pr_updated_at" ]; then
      echo "WARN: malformed PR info for issue ${issue_num} (PR_NUM='$pr_num', PR_UPDATED_AT='$pr_updated_at'); leaving as-is" >&2
      continue
    fi

    if ! ci_is_green "$pr_num"; then
      continue
    fi

    idle_seconds=$(pr_idle_seconds "$pr_updated_at")
    if [ -z "$idle_seconds" ]; then
      echo "WARN: cannot parse PR.updatedAt='${pr_updated_at}' for issue ${issue_num}; leaving as-is" >&2
      continue
    fi

    if [ "$idle_seconds" -le 300 ]; then
      continue
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
      echo "INFO: wrapper PID ${pid} for issue ${issue_num} exited between checks; deferring to next cycle" >&2
      continue
    fi

    if kill "$pid" 2>/dev/null; then
      kill_note="Sent SIGTERM to PID ${pid}"
    else
      kill_note="PID ${pid} already gone"
    fi
    itp_post_comment "$issue_num" \
      "Dev process still alive but PR #${pr_num} is ready (all CI checks passed, idle ${idle_seconds}s). ${kill_note}. Moving to pending-review."
    label_swap "$issue_num" "in-progress" "pending-review"
  else
    :
  fi
PREFIXEOF
)

_build_prefix_regression_harness() {
  local harness="$1"
  {
    echo '#!/bin/bash'
    echo 'set -u'
    echo 'POSTED=0'
    echo 'LABEL_SWAPS=0'
    echo 'KILL_TERM_CALLS=0'
    echo 'log() { :; }'
    echo 'was_just_dispatched() { return 1; }'
    echo 'is_within_grace_period() { return 1; }'
    echo 'itp_post_comment() { POSTED=$((POSTED + 1)); }'
    echo 'label_swap() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); }'
    echo 'pid_alive() { return 0; }'
    echo 'get_pid() { echo "12345"; }'
    echo 'fetch_pr_for_issue() { echo "{\"number\":77,\"updatedAt\":\"2020-01-01T00:00:00Z\"}"; }'
    echo 'ci_is_green() { return 0; }'
    echo 'pr_idle_seconds() { echo "301"; }'
    echo 'kill() {
      if [ "$1" = "-0" ]; then return 0; fi
      KILL_TERM_CALLS=$((KILL_TERM_CALLS + 1))
      return 0
    }'
    echo 'issue_num=9999'
    echo 'kind="issue"'
    echo "$PRE_FIX_ALIVE_BRANCH"
    echo 'echo "POSTED=$POSTED"'
    echo 'echo "LABEL_SWAPS=$LABEL_SWAPS"'
    echo 'echo "KILL_TERM_CALLS=$KILL_TERM_CALLS"'
  } > "$harness"
}

PREFIX_H="$TMPROOT/prefix-regression.sh"
_build_prefix_regression_harness "$PREFIX_H"
prefix_out=$(bash "$PREFIX_H" 2>&1)
assert_contains "TC-S5A-020: pre-fix ALIVE branch SIGTERMs a FRESH-progress agent (pr_idle=301, CI green) — the headline regression" "KILL_TERM_CALLS=1" "$prefix_out"
assert_contains "TC-S5A-020: pre-fix ALIVE branch posts the crash-cycle comment" "POSTED=1" "$prefix_out"
assert_contains "TC-S5A-020: pre-fix ALIVE branch swaps the label" "LABEL_SWAPS=1" "$prefix_out"

# Counter-proof: the SAME inputs (pr_idle=301, CI green, FRESH progress —
# irrelevant to the pre-fix snippet, which never reads it) through the REAL
# (post-fix) Step 5a block do NOT fire, closing the regression.
_build_harness "$H" local FRESH 5 FRESH run-initial
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-020 counter-proof: post-fix Step 5a does NOT SIGTERM the same FRESH-progress agent" "KILL_TERM_CALLS=0" "$out"
assert_contains "TC-S5A-020 counter-proof: post-fix Step 5a posts no comment" "POSTED=0" "$out"

# TC-S5A-030: local backend valid-stale path (same as 003, re-asserted via the backend switch explicitly)
_build_harness "$H" local STALE 1801 STALE run-initial
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-030: local backend valid-stale path -> comment+swap+signal" "POSTED=1" "$out"

# TC-S5A-031: remote backend, all gates pass -> SIGTERM + comment + swap
_build_harness_remote_cas "$H" STALE 1801 SIGNALED
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-031: remote backend SIGNALED -> comment posted" "POSTED=1" "$out"
assert_contains "TC-S5A-031: remote backend SIGNALED -> label swapped" "LABEL_SWAPS=1" "$out"
assert_contains "TC-S5A-031: remote comment mentions PR + progress inactivity" "PR inactive 301s" "$out"

# TC-S5A-032: remote backend, compare-and-signal ABORTED -> no comment, no transition
_build_harness_remote_cas "$H" STALE 1801 "ABORTED:pid-changed"
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-032: remote backend ABORTED -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-032: remote backend ABORTED -> no label change" "LABEL_SWAPS=0" "$out"

# TC-S5A-033: remote backend, transport failure sentinel -> no comment, no transition
_build_harness_remote_cas "$H" STALE 1801 "ABORTED:remote-transport-failure"
out=$(bash "$H" 2>&1)
assert_contains "TC-S5A-033: remote transport failure -> no comment" "POSTED=0" "$out"
assert_contains "TC-S5A-033: remote transport failure -> no label change" "LABEL_SWAPS=0" "$out"

# ===========================================================================
echo ""
echo "=== Wording / retry-regex exclusion ==="
# ===========================================================================

_build_harness "$H" local STALE 1801 STALE run-initial
out=$(bash "$H" 2>&1)
new_wording=$(sed -n 's/^POSTED_BODY=\[\(.*\)\]$/\1/p' <<<"$out")

if [[ -f "$LIB_DISPATCH" ]]; then
  count_result=$(
    ( set +e
      export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=step5a-wording MAX_RETRIES=3 MAX_CONCURRENT=5
      # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
      source "$LIB_DISPATCH" 2>/dev/null
      itp_list_comments() { jq -n --arg b "$new_wording" '[{"body":$b,"createdAt":"2020-01-01T00:00:00Z","authorKind":"bot"}]'; }
      count_agent_failures 12345
    )
  )
  assert_eq "TC-S5A-040: new comment does not count toward count_agent_failures" "0" "$count_result"
else
  bad "TC-S5A-040: lib-dispatch.sh not found"
fi

if [[ "$new_wording" != "Dev process exited"* ]]; then
  ok "TC-S5A-041: new wording does not collide with the 'Dev process exited' (Step 5b) prefix"
else
  bad "TC-S5A-041: new wording collides with 'Dev process exited' prefix"
fi

# ----------------------------------------------------------------------------
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo ""

[[ $FAIL -gt 0 ]] && exit 1
exit 0
