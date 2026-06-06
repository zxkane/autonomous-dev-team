#!/bin/bash
# test-lib-review-codex.sh — Unit tests for the codex review auto-resume loop
# (INV-51, issue #189).
#
# The codex member of a multi-agent review fleet was dropped as `unavailable`
# on large diffs because `codex exec` runs ONE agentic turn consumed by
# context-gathering (git diff, file reads) before posting a verdict. This lib
# adds a codex-specific review path that watches codex's JSONL event stream and
# auto-resumes the SAME thread while turns end gather-only, bounded by a max
# resume count AND a wall-clock deadline.
#
# Tests:
#   - _codex_log_has_verdict_message: detects whether codex's LAST completed
#     turn contained a verdict-posting agent_message
#   - _codex_review_deadline_seconds: parses AGENT_REVIEW_TIMEOUT to seconds
#     (1h default, never unbounded)
#   - _run_codex_review_with_resume: the bounded resume-loop controller
#
# Strategy: stub run_agent / resume_agent so each APPENDS scripted JSONL turns
# to the per-agent log and records its call count + argv; stub the clock so the
# wall-clock bound is deterministic.
#
# Run: bash tests/unit/test-lib-review-codex.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-codex.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
CI="$PROJECT_ROOT/.github/workflows/ci.yml"

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
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
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
    echo "      haystack='${haystack:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

[[ -f "$LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $LIB not found — implementation step required first"
  echo "  PASS: $PASS"
  echo "  FAIL: $((FAIL + 1))"
  exit 1
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-codex.sh
source "$LIB"

# Scripted JSONL turn fragments -----------------------------------------------
GATHER_TURN='{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i0","type":"reasoning","text":"thinking"}}
{"type":"item.completed","item":{"id":"i1","type":"tool_call","name":"shell"}}
{"type":"turn.completed","usage":{"input_tokens":55000,"output_tokens":3}}'

VERDICT_TURN='{"type":"turn.started"}
{"type":"item.completed","item":{"id":"i2","type":"tool_call","name":"shell"}}
{"type":"item.completed","item":{"id":"i3","type":"agent_message","text":"Review PASSED"}}
{"type":"turn.completed","usage":{"input_tokens":1000,"output_tokens":900}}'

# ---------------------------------------------------------------------------
echo "=== TC-CXR-DET: _codex_log_has_verdict_message ==="
# ---------------------------------------------------------------------------
TMPLOG=$(mktemp)
trap 'rm -f "$TMPLOG"' EXIT

# TC-CXR-DET-01 — last turn has an agent_message
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$VERDICT_TURN"; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-01 verdict message in only turn → rc 0" 0 "$?"

# TC-CXR-DET-02 — only turn is gather-only
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$GATHER_TURN"; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-02 gather-only turn → rc 1" 1 "$?"

# TC-CXR-DET-03 — turn 1 gather-only, turn 2 has agent_message (last turn decides)
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$GATHER_TURN"; echo "$VERDICT_TURN"; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-03 last turn has verdict msg → rc 0" 0 "$?"

# TC-CXR-DET-04 — turn 1 had agent_message, turn 2 gather-only (last turn decides)
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$VERDICT_TURN"; echo "$GATHER_TURN"; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-04 last turn gather-only → rc 1" 1 "$?"

# TC-CXR-DET-05 — empty / missing log never crashes
: > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-05 empty log → rc 1" 1 "$?"
_codex_log_has_verdict_message "/nonexistent/path/$$"; assert_eq "TC-CXR-DET-05b missing log → rc 1" 1 "$?"

# TC-CXR-DET-06 — agent_message present but NO trailing turn.completed (turn mid-flight)
{ echo '{"type":"thread.started","thread_id":"aaaa"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.completed","item":{"type":"agent_message","text":"partial"}}'; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-06 no completed turn yet → rc 1" 1 "$?"

# TC-CXR-DET-07 — a turn emits agent_message but is KILLED before turn.completed
# (per-turn cap fired mid-stream), then a later GATHER-ONLY turn completes. The
# stale agent_message flag must NOT leak across the turn boundary — the LAST
# COMPLETED turn is gather-only. Regression for the cur_msg-not-reset bug.
{ echo '{"type":"thread.started","thread_id":"aaaa"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.completed","item":{"type":"agent_message","text":"partial verdict"}}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.completed","item":{"type":"tool_call","name":"shell"}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":50000}}'; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-07 killed-mid-msg then gather-only completed → rc 1" 1 "$?"

# TC-CXR-DET-08 — a tool_call turn whose OUTPUT text contains the literal
# substring "type":"agent_message" (e.g. codex grepping its own JSONL log) must
# NOT be mis-detected as a verdict turn. The narrowed regex requires the
# agent_message type INSIDE the item object (`"item":{...}`), not anywhere on
# the line. Regression for the substring false-positive (#189 review finding 2).
{ echo '{"type":"thread.started","thread_id":"aaaa"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.completed","item":{"type":"tool_call","name":"shell","output":"grep hit: \"type\":\"agent_message\" in transcript"}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":5000}}'; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-08 tool-output substring not a false verdict → rc 1" 1 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXR-DL: _codex_review_deadline_seconds ==="
# ---------------------------------------------------------------------------
assert_eq "TC-CXR-DL-01 1h → 3600"   3600  "$(AGENT_REVIEW_TIMEOUT=1h   _codex_review_deadline_seconds)"
assert_eq "TC-CXR-DL-02 90m → 5400"  5400  "$(AGENT_REVIEW_TIMEOUT=90m  _codex_review_deadline_seconds)"
assert_eq "TC-CXR-DL-03 120s → 120"  120   "$(AGENT_REVIEW_TIMEOUT=120s _codex_review_deadline_seconds)"
assert_eq "TC-CXR-DL-04 1d → 86400"  86400 "$(AGENT_REVIEW_TIMEOUT=1d   _codex_review_deadline_seconds)"
assert_eq "TC-CXR-DL-05 3600 bare → 3600" 3600 "$(AGENT_REVIEW_TIMEOUT=3600 _codex_review_deadline_seconds)"
assert_eq "TC-CXR-DL-06a unset → 3600 default" 3600 "$(unset AGENT_REVIEW_TIMEOUT; _codex_review_deadline_seconds)"
assert_eq "TC-CXR-DL-06b garbage → 3600 default" 3600 "$(AGENT_REVIEW_TIMEOUT=notaduration _codex_review_deadline_seconds)"
assert_eq "TC-CXR-DL-06c empty → 3600 default" 3600 "$(AGENT_REVIEW_TIMEOUT='' _codex_review_deadline_seconds)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXR-CTL: _run_codex_review_with_resume controller ==="
# ---------------------------------------------------------------------------
# Build a sandbox: a per-test temp dir with a recorder for run_agent /
# resume_agent calls and a scripted JSONL feed. We stub run_agent /
# resume_agent and the clock helper _codex_now_seconds so behavior is
# deterministic. The controller writes the per-agent log to the path given by
# the CODEX_REVIEW_LOG env var (the wrapper points this at $_agent_log).

# run_codex_controller_case <feed-spec> <max-resumes> <now-script>
#   feed-spec : newline-separated tokens, one per invocation: "gather" | "verdict"
#               run_agent consumes token 1, each resume_agent consumes the next.
#   now-script: newline-separated integers, one per _codex_now_seconds call.
# Echoes "<rc>|<run_calls>|<resume_calls>" and writes resume argv recorder to
# $REC_RESUME_ARGV.
run_codex_controller_case() {
  local feed="$1" max="$2" nowscript="$3"
  local sandbox; sandbox=$(mktemp -d)
  local log="$sandbox/agent.log"
  printf '%s\n' "$feed"      > "$sandbox/feed"
  printf '%s\n' "$nowscript" > "$sandbox/now"
  : > "$sandbox/run_calls"; : > "$sandbox/resume_calls"; : > "$sandbox/resume_argv"

  (
    source "$LIB"

    _feed_next() {
      local tok; tok=$(head -n1 "$sandbox/feed")
      sed -i '1d' "$sandbox/feed" 2>/dev/null || true
      if [[ "$tok" == "verdict" ]]; then
        printf '%s\n' "$VERDICT_TURN" >> "$log"
      else
        printf '%s\n' "$GATHER_TURN" >> "$log"
      fi
    }

    # Stub the agent primitives. We record ONE marker line per call (the
    # session_id is the 1st positional arg) so the call count is a clean line
    # count — the prompt ($2) is multiline, so it goes to a separate recorder.
    run_agent() {
      echo "run sid=$1" >> "$sandbox/run_calls"
      _feed_next
    }
    resume_agent() {
      echo "resume sid=$1" >> "$sandbox/resume_calls"
      printf '%s\n---END---\n' "$2" >> "$sandbox/resume_argv"   # $2 == prompt
      _feed_next
    }
    # Deterministic clock: pop one integer per call; reuse last when exhausted.
    _codex_now_seconds() {
      local n; n=$(head -n1 "$sandbox/now")
      [[ $(wc -l < "$sandbox/now") -gt 1 ]] && sed -i '1d' "$sandbox/now"
      printf '%s\n' "$n"
    }

    CODEX_REVIEW_MAX_RESUMES="$max" CODEX_REVIEW_LOG="$log" AGENT_REVIEW_TIMEOUT=1h \
      _run_codex_review_with_resume "sid-123" "review prompt" "model-x" "sess-name"
    rc=$?
    # Count marker lines only ('run sid=' / 'resume sid='). grep -c exits 1 on
    # no match (returns 0), so avoid bare grep which breaks under set -e.
    runs=$(grep -c '^run sid=' "$sandbox/run_calls" 2>/dev/null) || runs=0
    resumes=$(grep -c '^resume sid=' "$sandbox/resume_calls" 2>/dev/null) || resumes=0
    cp "$sandbox/resume_argv" "$REC_RESUME_ARGV" 2>/dev/null || true
    cp "$sandbox/resume_calls" "$REC_RESUME_CALLS" 2>/dev/null || true
    echo "${rc}|${runs}|${resumes}"
  )
  rm -rf "$sandbox"
}

REC_RESUME_ARGV=$(mktemp)
REC_RESUME_CALLS=$(mktemp)
trap 'rm -f "$TMPLOG" "$REC_RESUME_ARGV" "$REC_RESUME_CALLS"' EXIT

# TC-CXR-CTL-01 — turn 1 gather, turn 2 (resume) posts verdict → exactly 1 resume
out=$(run_codex_controller_case $'gather\nverdict' 3 $'0\n10\n20\n30')
assert_eq "TC-CXR-CTL-01 one gather then verdict → 1 run, 1 resume, rc 0" "0|1|1" "$out"

# TC-CXR-CTL-02 — turn 1 already verdict (small-diff happy path) → zero resumes
out=$(run_codex_controller_case $'verdict' 3 $'0\n10')
assert_eq "TC-CXR-CTL-02 immediate verdict → 1 run, 0 resume, rc 0" "0|1|0" "$out"

# TC-CXR-CTL-03 — every turn gather-only, max=3 → exactly 3 resumes then stop
out=$(run_codex_controller_case $'gather\ngather\ngather\ngather' 3 $'0\n5\n10\n15\n20')
assert_eq "TC-CXR-CTL-03 never converges, max=3 → 1 run, 3 resume (bounded)" "0|1|3" "$out"

# TC-CXR-CTL-04 — deadline already passed before round 1 → zero resumes
# now-script: first call (deadline base) 0, then a huge value so now >= deadline.
out=$(run_codex_controller_case $'gather\ngather' 3 $'0\n999999')
assert_eq "TC-CXR-CTL-04 wall-clock exceeded → 1 run, 0 resume (deadline guard)" "0|1|0" "$out"

# TC-CXR-CTL-05 — resume prompt content
run_codex_controller_case $'gather\nverdict' 3 $'0\n10\n20\n30' >/dev/null
resume_prompt=$(cat "$REC_RESUME_ARGV")
assert_contains "TC-CXR-CTL-05a resume prompt says NOT to re-run git diff" \
  "NOT re-run \`git diff\`" "$resume_prompt"
assert_contains "TC-CXR-CTL-05b resume prompt tells codex to post the verdict" \
  "verdict" "$resume_prompt"

# TC-CXR-CTL-06 — resume reuses the SAME dispatcher session_id
run_codex_controller_case $'gather\nverdict' 3 $'0\n10\n20\n30' >/dev/null
resume_call=$(cat "$REC_RESUME_CALLS")
assert_contains "TC-CXR-CTL-06 resume_agent called with the same session_id sid-123" \
  "sid-123" "$resume_call"

# TC-CXR-CTL-07 — rc propagation: the controller returns the rc of the LAST
# invocation. run_agent returns 9 (no resume fires on an immediate verdict).
ctl07=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); log="$sandbox/agent.log"
  run_agent() { printf '%s\n' "$VERDICT_TURN" >> "$log"; return 9; }
  resume_agent() { return 0; }
  CODEX_REVIEW_LOG="$log" CODEX_REVIEW_MAX_RESUMES=3 AGENT_REVIEW_TIMEOUT=1h \
    _run_codex_review_with_resume sid p m n
  echo "$?"
  rm -rf "$sandbox"
)
assert_eq "TC-CXR-CTL-07 returns last invocation rc (run_agent=9, no resume)" 9 "$ctl07"

# TC-CXR-CTL-08 — max=0 disables the loop entirely
out=$(run_codex_controller_case $'gather\ngather' 0 $'0\n5')
assert_eq "TC-CXR-CTL-08 max=0 → 1 run, 0 resume" "0|1|0" "$out"

# TC-CXR-CTL-09 — a non-numeric CODEX_REVIEW_MAX_RESUMES must NOT crash the
# subshell under set -euo pipefail (degrade-don't-crash, mirroring the deadline
# parser). Regression for the "stale typo strands the issue in reviewing"
# failure mode: turn 1 is GATHER-ONLY so the `(( resumes >= max ))` bound check
# IS reached — under set -u, evaluating arithmetic against a non-numeric `max`
# would abort the subshell (unbound variable) before the marker line below.
# The garbage value must safely default so the loop runs its bound and returns.
ctl09=$(
  set -euo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); log="$sandbox/agent.log"
  run_agent()    { printf '%s\n' "$GATHER_TURN" >> "$log"; return 0; }   # never converges
  resume_agent() { printf '%s\n' "$GATHER_TURN" >> "$log"; return 0; }
  CODEX_REVIEW_LOG="$log" CODEX_REVIEW_MAX_RESUMES="three" AGENT_REVIEW_TIMEOUT=1h \
    _run_codex_review_with_resume sid p m n
  echo "rc=$?"   # only printed if the bound check did NOT abort the subshell
  rm -rf "$sandbox"
) 2>/dev/null
assert_eq "TC-CXR-CTL-09 non-numeric max degrades (bound reached), no crash" "rc=0" "$ctl09"

# TC-CXR-CTL-10 — turn-1 rc 124 + clean resume + bound-exhaustion → controller returns 124
# (regression test for timeout rc lost across resumes).
ctl10=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); log="$sandbox/agent.log"
  run_agent()    { printf '%s\n' "$GATHER_TURN" >> "$log"; return 124; }
  resume_agent() { printf '%s\n' "$GATHER_TURN" >> "$log"; return 0; }
  CODEX_REVIEW_LOG="$log" CODEX_REVIEW_MAX_RESUMES=2 AGENT_REVIEW_TIMEOUT=1h \
    _run_codex_review_with_resume sid p m n
  echo "$?"
  rm -rf "$sandbox"
)
assert_eq "TC-CXR-CTL-10 turn-1 rc 124 + clean resume + bound-exhaustion → returns 124" 124 "$ctl10"

# TC-CXR-CTL-11 — non-timeout launch failure (rc=1) → returns 1 immediately, no resumes
ctl11=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); log="$sandbox/agent.log"
  run_calls=0; resume_calls=0
  run_agent()    { run_calls=$((run_calls + 1)); return 1; }
  resume_agent() { resume_calls=$((resume_calls + 1)); return 0; }
  CODEX_REVIEW_LOG="$log" CODEX_REVIEW_MAX_RESUMES=3 AGENT_REVIEW_TIMEOUT=1h \
    _run_codex_review_with_resume sid p m n
  echo "$?|${run_calls}|${resume_calls}"
  rm -rf "$sandbox"
)
assert_eq "TC-CXR-CTL-11 non-timeout launch failure returns early with no resumes" "1|1|0" "$ctl11"

# TC-CXR-CTL-12 — a timeout on a RESUME turn (not just turn 1) is sticky through a
# later clean resume + bound-exhaustion: turn-1 rc 0, resume-1 rc 124, resume-2
# rc 0, max=2 → controller returns 124. Pins the sticky rule for a mid-loop
# timeout, the stronger half of #189 review finding 1 (the INV-48 veto must not be
# reset by a subsequent clean-but-no-verdict resume).
ctl12=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); log="$sandbox/agent.log"
  ri=0
  run_agent()    { printf '%s\n' "$GATHER_TURN" >> "$log"; return 0; }
  resume_agent() {
    ri=$((ri + 1))
    printf '%s\n' "$GATHER_TURN" >> "$log"
    [[ $ri -eq 1 ]] && return 124 || return 0
  }
  CODEX_REVIEW_LOG="$log" CODEX_REVIEW_MAX_RESUMES=2 AGENT_REVIEW_TIMEOUT=1h \
    _run_codex_review_with_resume sid p m n
  echo "$?"
  rm -rf "$sandbox"
)
assert_eq "TC-CXR-CTL-12 mid-loop resume timeout sticky through clean resume → returns 124" 124 "$ctl12"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXR-ISO: isolation + wrapper wiring (source-of-truth) ==="
# ---------------------------------------------------------------------------
# TC-CXR-ISO-02 — fan-out routes codex through the resume controller, guarded.
assert_grep "TC-CXR-ISO-02a wrapper calls _run_codex_review_with_resume" \
  '_run_codex_review_with_resume' "$WRAPPER"
assert_grep "TC-CXR-ISO-02b codex routing is guarded on the per-agent CMD == codex" \
  '(AGENT_CMD|_agent).*=.*codex' "$WRAPPER"
# TC-CXR-ISO-03 — non-codex still routes through bare run_agent.
assert_grep "TC-CXR-ISO-03 bare run_agent retained for non-codex agents" \
  'run_agent "\$_agent_session_id"' "$WRAPPER"
# TC-CXR-ISO-04 — wrapper sources the new lib.
assert_grep "TC-CXR-ISO-04 wrapper sources lib-review-codex.sh" \
  'source "\$\{SCRIPT_DIR\}/lib-review-codex.sh"' "$WRAPPER"
# TC-CXR-ISO-06 — CI shellcheck job lists the new lib.
assert_grep "TC-CXR-ISO-06 CI shellcheck includes lib-review-codex.sh" \
  'lib-review-codex.sh' "$CI"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
