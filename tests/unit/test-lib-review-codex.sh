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
FIXTURES="$SCRIPT_DIR/fixtures"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should NOT contain='$needle'"
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

# A turn that emits agent_message items that are PROGRESS NARRATION only — no
# verdict trailer (`Review PASSED` / `Review findings:` / `Review Agent: codex`).
# This is the #198 root-cause-2 shape: the pre-fix detector (which matched ANY
# agent_message) false-converged on this; the verdict-trailer detector must treat
# it as gather-only (rc 1) so the loop RESUMES.
NARRATION_TURN='{"type":"turn.started"}
{"type":"item.completed","item":{"id":"n0","type":"command_execution","command":"gh pr view 197 --json mergeable","aggregated_output":"MERGEABLE"}}
{"type":"item.completed","item":{"id":"n1","type":"agent_message","text":"Next I'\''m reading the workflow instructions to understand the checklist."}}
{"type":"item.completed","item":{"id":"n2","type":"agent_message","text":"I'\''ll verify the PR reflects both changes."}}
{"type":"turn.completed","usage":{"input_tokens":138668,"output_tokens":746}}'

# A FAIL verdict turn: agent_message text begins with the fail-side trailer.
FAIL_VERDICT_TURN='{"type":"turn.started"}
{"type":"item.completed","item":{"id":"f0","type":"tool_call","name":"shell"}}
{"type":"item.completed","item":{"id":"f1","type":"agent_message","text":"Review findings:\n1. [BLOCKING] missing test coverage.\nReview Agent: codex"}}
{"type":"turn.completed","usage":{"input_tokens":2000,"output_tokens":400}}'

# A turn whose only verdict signal is the `Review Agent: codex` discriminator
# trailer (the resume prompt forces codex to emit this) — must converge.
AGENT_TRAILER_TURN='{"type":"turn.started"}
{"type":"item.completed","item":{"id":"a0","type":"agent_message","text":"Review PASS - looks good.\nReview Session: `sid`\nReview Agent: codex"}}
{"type":"turn.completed","usage":{"input_tokens":3000,"output_tokens":120}}'

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

# TC-CXR-DET-09 — #198 ROOT CAUSE 2: the last completed turn emits agent_message
# items that are PURE PROGRESS NARRATION (no verdict trailer). Convergence must
# mean "codex posted the VERDICT", NOT "codex emitted any assistant message" —
# so this is gather-only (rc 1) and the loop RESUMES. The pre-fix detector
# (any-agent_message) returned rc 0 here and false-converged → no resume → the
# poller found no verdict → codex dropped `unavailable`.
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$NARRATION_TURN"; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-09 narration-only turn (no verdict trailer) → rc 1 (resumes)" 1 "$?"

# TC-CXR-DET-09b — the SAME shape from a captured real-world review-193 fixture
# (sanitized; the issue mandates a committed fixture, not a /tmp log).
_codex_log_has_verdict_message "$FIXTURES/codex-gather-only-turn.jsonl"
assert_eq "TC-CXR-DET-09b review-193 gather-only fixture → rc 1 (resumes)" 1 "$?"

# TC-CXR-DET-10 — a PASS verdict trailer in the last turn → converged (rc 0).
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$VERDICT_TURN"; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-10 Review PASSED trailer → rc 0 (converged)" 0 "$?"

# TC-CXR-DET-10b — a committed PASS-verdict fixture (Review PASSED + Review Agent: codex).
_codex_log_has_verdict_message "$FIXTURES/codex-verdict-turn.jsonl"
assert_eq "TC-CXR-DET-10b verdict fixture → rc 0 (converged)" 0 "$?"

# TC-CXR-DET-11 — a FAIL verdict trailer (`Review findings:`) → converged (rc 0).
# A failing verdict is still a verdict — codex posted its decision, do not resume.
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$FAIL_VERDICT_TURN"; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-11 Review findings: (FAIL verdict) → rc 0 (converged)" 0 "$?"

# TC-CXR-DET-12 — the `Review Agent: codex` discriminator trailer alone → converged.
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$AGENT_TRAILER_TURN"; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-12 Review Agent: codex trailer → rc 0 (converged)" 0 "$?"

# TC-CXR-DET-13 — last-turn-decides for the verdict-trailer rule: a verdict in an
# EARLIER turn followed by a narration-only LAST turn must NOT count (rc 1). Pins
# that the per-turn reset still applies to the new trailer match.
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$VERDICT_TURN"; echo "$NARRATION_TURN"; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-13 verdict then narration-only last turn → rc 1" 1 "$?"

# TC-CXR-DET-14 — tool-output containing a verdict PHRASE (e.g. codex catting
# SKILL.md / the prompt, whose text literally contains "Review PASSED") must NOT
# be a false verdict — the phrase must be inside an agent_message item, not a
# command_execution aggregated_output. Strengthens TC-CXR-DET-08 for the new
# text-based match.
{ echo '{"type":"thread.started","thread_id":"aaaa"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.completed","item":{"type":"command_execution","command":"cat SKILL.md","aggregated_output":"... post a comment with Review PASSED on the first line ..."}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":5000}}'; } > "$TMPLOG"
_codex_log_has_verdict_message "$TMPLOG"; assert_eq "TC-CXR-DET-14 verdict phrase in tool output not a false verdict → rc 1" 1 "$?"

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

# TC-CXR-CTL-05 — resume prompt content (via the controller)
run_codex_controller_case $'gather\nverdict' 3 $'0\n10\n20\n30' >/dev/null
resume_prompt=$(cat "$REC_RESUME_ARGV")
assert_contains "TC-CXR-CTL-05a resume prompt tells codex to reuse already-loaded context" \
  "ALREADY loaded" "$resume_prompt"
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
echo "=== TC-CXR-RP: _codex_resume_prompt content (context-compaction safety) ==="
# ---------------------------------------------------------------------------
# #198 follow-up: the original resume prompt said "do NOT re-run git diff and do
# NOT re-read files you already read" — an ABSOLUTE instruction. When codex's own
# context is compacted between turns (the diff is no longer in its working
# context), that absolute bar left codex unable to substantiate a verdict, so it
# defensively posted a [BLOCKING] "review context unavailable" FAIL instead of a
# real verdict (observed on the codex lane reviewing PR #199 itself). The prompt
# must instead PREFER reusing already-loaded context but ALLOW re-reading the
# minimum needed when that context is gone — and must NEVER tell codex to refuse a
# verdict for lack of context.
rp=$(_codex_resume_prompt "sess-uuid-xyz")

# TC-CXR-RP-01 — the prompt no longer contains the ABSOLUTE "do NOT re-read files"
# bar (the instruction that stranded a compacted turn).
if [[ "$rp" == *"do NOT re-read"* || "$rp" == *"do not re-read"* ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-CXR-RP-01 prompt must not contain an absolute 'do NOT re-read' bar"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CXR-RP-01 no absolute 'do NOT re-read' bar"
  PASS=$((PASS + 1))
fi

# TC-CXR-RP-02 — the prompt explicitly ALLOWS re-reading when context is gone.
assert_contains "TC-CXR-RP-02 prompt allows re-reading when context is unavailable" \
  "re-read" "$rp"

# TC-CXR-RP-03 — the prompt still prefers reusing already-loaded context (avoid
# gratuitous re-gather on the common path).
assert_contains "TC-CXR-RP-03 prompt prefers already-loaded context" \
  "ALREADY loaded" "$rp"

# TC-CXR-RP-04 — the prompt instructs codex to ISSUE a verdict, not to refuse one
# for lack of context (the defensive-bail the codex lane produced).
assert_contains "TC-CXR-RP-04a prompt tells codex to post a verdict" \
  "post your verdict" "$rp"
assert_contains "TC-CXR-RP-04b prompt names the never-refuse rule" \
  "do NOT refuse" "$rp"

# TC-CXR-RP-05 — the attribution trailers (INV-40/INV-20) are still present.
assert_contains "TC-CXR-RP-05a prompt carries the Review Agent discriminator" \
  "Review Agent: codex" "$rp"
assert_contains "TC-CXR-RP-05b prompt carries the session uuid" \
  "sess-uuid-xyz" "$rp"

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

# ===========================================================================
# INV-59 (#209): codex transient stream-error retry + drop reason
# ===========================================================================
# A codex review member whose model stream dies with an upstream 5xx exhausts
# its 5/5 SSE reconnects and emits turn.failed. Pre-#209 the wrapper dropped it
# as an opaque `unavailable` with no reason, and a launch-level turn.failed
# early-returned from the resume loop so a brief blip was never ridden out.
# These tests pin the codex-shaped drop-reason classifier (mirroring agy's
# INV-58) + the resume-loop's transient-stream-error retry.

# Scripted JSONL turn fragments for the stream-error path -----------------
# A turn.failed preceded by the full Reconnecting... N/5 ladder (the live
# repro: codex's CLI retries the SSE stream 5 times then fails the turn).
STREAM_ERROR_TURN='{"type":"turn.started"}
{"type":"item.completed","item":{"id":"s0","type":"command_execution","command":"gh pr view 209 --json mergeable","aggregated_output":"MERGEABLE"}}
{"type":"error","message":"Reconnecting... 1/5 (stream disconnected before completion: The server had an error while processing your request. Sorry about that!)"}
{"type":"error","message":"Reconnecting... 5/5 (stream disconnected before completion: The server had an error while processing your request. Sorry about that!)"}
{"type":"turn.failed","error":{"message":"stream disconnected before completion: The server had an error while processing your request. Sorry about that!"}}'

# A turn.failed with the stream-error message but NO Reconnecting ladder
# visible (e.g. the ladder rolled off / a single-shot failure).
STREAM_FAIL_NO_LADDER='{"type":"turn.started"}
{"type":"item.completed","item":{"id":"sf0","type":"reasoning","text":"loading diff"}}
{"type":"turn.failed","error":{"message":"stream disconnected before completion: The server had an error while processing your request."}}'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CODEX-DROP-DET: _codex_log_has_stream_error ==="
# ---------------------------------------------------------------------------
DLOG=$(mktemp)
trap 'rm -f "$TMPLOG" "$REC_RESUME_ARGV" "$REC_RESUME_CALLS" "$DLOG"' EXIT

# TC-CODEX-DROP-DET-01 — full Reconnecting ladder + turn.failed → stream error
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$STREAM_ERROR_TURN"; } > "$DLOG"
_codex_log_has_stream_error "$DLOG"; assert_eq "TC-CODEX-DROP-DET-01 ladder + turn.failed → rc 0 (stream error)" 0 "$?"

# TC-CODEX-DROP-DET-02 — a clean gather/narration turn (#198 case) → NO stream error
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$NARRATION_TURN"; } > "$DLOG"
_codex_log_has_stream_error "$DLOG"; assert_eq "TC-CODEX-DROP-DET-02 clean no-verdict turn → rc 1 (no over-claim)" 1 "$?"

# TC-CODEX-DROP-DET-03 — a clean verdict turn → NO stream error
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$VERDICT_TURN"; } > "$DLOG"
_codex_log_has_stream_error "$DLOG"; assert_eq "TC-CODEX-DROP-DET-03 verdict turn → rc 1 (no stream error)" 1 "$?"

# TC-CODEX-DROP-DET-04 — turn.failed stream error, no ladder → stream error
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$STREAM_FAIL_NO_LADDER"; } > "$DLOG"
_codex_log_has_stream_error "$DLOG"; assert_eq "TC-CODEX-DROP-DET-04 turn.failed (no ladder) → rc 0" 0 "$?"

# TC-CODEX-DROP-DET-05 — empty / missing / empty-arg log → rc 1, no crash
: > "$DLOG"
_codex_log_has_stream_error "$DLOG"; assert_eq "TC-CODEX-DROP-DET-05a empty log → rc 1" 1 "$?"
_codex_log_has_stream_error "/nonexistent/path/$$"; assert_eq "TC-CODEX-DROP-DET-05b missing log → rc 1" 1 "$?"
_codex_log_has_stream_error ""; assert_eq "TC-CODEX-DROP-DET-05c empty arg → rc 1" 1 "$?"

# TC-CODEX-DROP-DET-06 — a tool-output line whose text merely contains the
# literal substring "turn.failed" (codex grepping its own JSONL log) must NOT be
# mis-detected. The detector keys on the EVENT type, not any substring on the
# line. Mirrors TC-CXR-DET-08 for the verdict detector.
{ echo '{"type":"thread.started","thread_id":"aaaa"}'
  echo '{"type":"turn.started"}'
  echo '{"type":"item.completed","item":{"type":"tool_call","name":"shell","output":"grep hit: \"type\":\"turn.failed\" in transcript"}}'
  echo '{"type":"turn.completed","usage":{"input_tokens":5000}}'; } > "$DLOG"
_codex_log_has_stream_error "$DLOG"; assert_eq "TC-CODEX-DROP-DET-06 tool-output substring not a false stream error → rc 1" 1 "$?"

# TC-CODEX-DROP-DET-07 — committed fixture (sanitized real codex stream-error log).
_codex_log_has_stream_error "$FIXTURES/codex-stream-error-turn.jsonl"
assert_eq "TC-CODEX-DROP-DET-07 committed stream-error fixture → rc 0" 0 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CODEX-DROP-CLS: _classify_codex_drop_reason ==="
# ---------------------------------------------------------------------------
# TC-CODEX-DROP-CLS-01 — ladder + turn.failed → stream-error:5/5 (ladder depth)
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$STREAM_ERROR_TURN"; } > "$DLOG"
assert_eq "TC-CODEX-DROP-CLS-01 ladder + turn.failed → stream-error:5/5" \
  "stream-error:5/5" "$(_classify_codex_drop_reason "$DLOG")"

# TC-CODEX-DROP-CLS-02 — turn.failed, no ladder → bare stream-error
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$STREAM_FAIL_NO_LADDER"; } > "$DLOG"
assert_eq "TC-CODEX-DROP-CLS-02 turn.failed no ladder → stream-error" \
  "stream-error" "$(_classify_codex_drop_reason "$DLOG")"

# TC-CODEX-DROP-CLS-03 — clean no-verdict turn (#198) → empty (no over-claim)
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$NARRATION_TURN"; } > "$DLOG"
assert_eq "TC-CODEX-DROP-CLS-03 clean no-verdict turn → empty (caller keeps bare unavailable)" \
  "" "$(_classify_codex_drop_reason "$DLOG")"

# TC-CODEX-DROP-CLS-04 — verdict turn → empty
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$VERDICT_TURN"; } > "$DLOG"
assert_eq "TC-CODEX-DROP-CLS-04 verdict turn → empty" \
  "" "$(_classify_codex_drop_reason "$DLOG")"

# TC-CODEX-DROP-CLS-05 — empty / missing / empty-arg → empty, no crash
: > "$DLOG"
assert_eq "TC-CODEX-DROP-CLS-05a empty log → empty" "" "$(_classify_codex_drop_reason "$DLOG")"
assert_eq "TC-CODEX-DROP-CLS-05b missing log → empty" "" "$(_classify_codex_drop_reason "/nonexistent/path/$$")"
assert_eq "TC-CODEX-DROP-CLS-05c empty arg → empty" "" "$(_classify_codex_drop_reason "")"

# TC-CODEX-DROP-CLS-06 — runs cleanly under set -euo pipefail (no abort)
cls06=$(
  set -euo pipefail
  source "$LIB"
  printf '%s\n' "$STREAM_ERROR_TURN" > "$DLOG"
  out=$(_classify_codex_drop_reason "$DLOG")
  echo "rc=$?|$out"
)
assert_eq "TC-CODEX-DROP-CLS-06 no crash under set -euo pipefail" \
  "rc=0|stream-error:5/5" "$cls06"

# TC-CODEX-DROP-CLS-07 — committed fixture → stream-error:5/5
assert_eq "TC-CODEX-DROP-CLS-07 committed fixture → stream-error:5/5" \
  "stream-error:5/5" "$(_classify_codex_drop_reason "$FIXTURES/codex-stream-error-turn.jsonl")"

# TC-CODEX-DROP-CLS-08 — fail-safe contract holds for a BARE call (not in a
# command substitution) under `set -euo pipefail` with a turn.failed stream
# error that carries NO reconnect ladder. This is the path CLS-06 cannot cover:
# CLS-06 calls the classifier inside `out=$(…)`, which suppresses errexit for the
# function body, AND it uses a log WITH a ladder so the inner ladder pipeline
# matches and exits 0 anyway. Only a BARE call + a NO-LADDER log exercises the
# ladder-extraction pipeline's grep-no-match rc 1 under pipefail at the function's
# own errexit scope — the function MUST still reach its `return 0`. A regression
# guard: the helper's docstring promises "rc 0 ALWAYS — fail-safe under
# `set -euo pipefail`", so an unprotected pipeline that aborts before `return 0`
# is a contract violation (codex review finding on PR #211).
cls08=$(
  set -euo pipefail
  source "$LIB"
  printf '%s\n' "$STREAM_FAIL_NO_LADDER" > "$DLOG"
  _classify_codex_drop_reason "$DLOG"   # BARE call — errexit applies to the body
  echo "REACHED_RETURN_0"               # only prints if the function did not abort
)
assert_eq "TC-CODEX-DROP-CLS-08 bare call, no-ladder stream error → no errexit abort" \
  $'stream-error\nREACHED_RETURN_0' "$cls08"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CODEX-DROP-PHR: _codex_drop_reason_phrase ==="
# ---------------------------------------------------------------------------
cphr01=$(_codex_drop_reason_phrase "stream-error:5/5")
assert_contains "TC-CODEX-DROP-PHR-01a phrase names stream-error" "stream-error" "$cphr01"
assert_contains "TC-CODEX-DROP-PHR-01b phrase carries the reconnect ladder depth" "5/5" "$cphr01"
assert_contains "TC-CODEX-DROP-PHR-01c phrase mentions reconnects" "reconnect" "$cphr01"

cphr02=$(_codex_drop_reason_phrase "stream-error")
assert_contains "TC-CODEX-DROP-PHR-02a phrase names stream-error (no depth)" "stream-error" "$cphr02"
assert_not_contains "TC-CODEX-DROP-PHR-02b no spurious '5/5' when no ladder depth" "5/5" "$cphr02"

assert_eq "TC-CODEX-DROP-PHR-03 empty token → empty phrase" "" "$(_codex_drop_reason_phrase "")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CODEX-DROP-RETRY: resume loop rides out a transient stream error ==="
# ---------------------------------------------------------------------------
# The pre-#209 controller early-returns when turn 1's rc is non-zero AND not
# 124/137 — so a launch-level turn.failed stream error never entered the resume
# loop. The fix: a non-zero/non-timeout rc WITH a fresh stream-error signal in
# the log must NOT early-return; it falls through to the bounded resume loop so a
# brief blip is ridden out. A genuine non-stream launch failure still
# early-returns (unchanged). A sustained outage exhausts the bound (graceful).

# TC-CODEX-DROP-RETRY-01 — turn 1 rc 1 WITH a stream error, resume posts verdict
# → enters the loop, ≥1 resume fires, converges to rc 0. run_agent appends a
# stream-error turn and returns 1; resume_agent appends a verdict turn.
retry01=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); log="$sandbox/agent.log"
  rc1=0; res=0
  run_agent()    { printf '%s\n' "$STREAM_ERROR_TURN" >> "$log"; return 1; }
  resume_agent() { res=$((res+1)); printf '%s\n' "$VERDICT_TURN" >> "$log"; return 0; }
  CODEX_REVIEW_LOG="$log" CODEX_REVIEW_MAX_RESUMES=3 AGENT_REVIEW_TIMEOUT=1h \
    _run_codex_review_with_resume sid p m n
  rc=$?
  echo "$rc|$res"
  rm -rf "$sandbox"
)
assert_eq "TC-CODEX-DROP-RETRY-01 turn-1 stream-error rc1 + verdict resume → enters loop, converges (rc 0, ≥1 resume)" "0|1" "$retry01"

# TC-CODEX-DROP-RETRY-02 — turn 1 rc 1 WITHOUT a stream error (genuine launch
# failure) → early-returns rc 1 with 0 resumes (unchanged behavior). run_agent
# writes NOTHING to the log (no stream error) and returns 1.
retry02=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); log="$sandbox/agent.log"; : > "$log"
  run_calls=0; resume_calls=0
  run_agent()    { run_calls=$((run_calls+1)); return 1; }
  resume_agent() { resume_calls=$((resume_calls+1)); return 0; }
  CODEX_REVIEW_LOG="$log" CODEX_REVIEW_MAX_RESUMES=3 AGENT_REVIEW_TIMEOUT=1h \
    _run_codex_review_with_resume sid p m n
  echo "$?|${run_calls}|${resume_calls}"
  rm -rf "$sandbox"
)
assert_eq "TC-CODEX-DROP-RETRY-02 genuine launch failure (no stream error) early-returns, 0 resumes" "1|1|0" "$retry02"

# TC-CODEX-DROP-RETRY-03 — sustained: turn 1 rc 1 with a stream error, EVERY
# resume also fails with a stream error, max=2 → enters the loop, exhausts the
# bound (exactly 2 resumes), then degrades — no infinite retry.
retry03=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); log="$sandbox/agent.log"
  res=0
  run_agent()    { printf '%s\n' "$STREAM_ERROR_TURN" >> "$log"; return 1; }
  resume_agent() { res=$((res+1)); printf '%s\n' "$STREAM_ERROR_TURN" >> "$log"; return 1; }
  CODEX_REVIEW_LOG="$log" CODEX_REVIEW_MAX_RESUMES=2 AGENT_REVIEW_TIMEOUT=1h \
    _run_codex_review_with_resume sid p m n
  rc=$?
  echo "$res"
  rm -rf "$sandbox"
)
assert_eq "TC-CODEX-DROP-RETRY-03 sustained stream error, max=2 → bounded (exactly 2 resumes)" "2" "$retry03"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CODEX-DROP-LOOP: drop-reason augmentation loop (behavioral) ==="
# ---------------------------------------------------------------------------
# Mirror the wrapper's per-agent _dropped_reasons loop body verbatim against the
# real libs (agy + codex). This is the issue's mandatory regression: it FAILS
# before the fix (no codex branch → a stream-error codex reads identically to a
# launch failure; a fan-out dropping BOTH agy and codex lists a reason only for
# agy). Sources lib-review-agy.sh so the both-dropped case exercises both libs.
AGY_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-agy.sh"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-agy.sh
source "$AGY_LIB"

# build_dropped_reasons <agent>:<verdict>:<logfixture> ...
#   Mirrors the wrapper's per-agent loop body verbatim against the real libs:
#   for an `unavailable` agy → agy classifier; for an `unavailable` codex →
#   codex classifier. Echoes the assembled `_dropped_reasons` (trailing `; `
#   trimmed).
build_dropped_reasons() {
  local spec agent verdict logf reasons="" tok
  for spec in "$@"; do
    agent="${spec%%:*}"; spec="${spec#*:}"
    verdict="${spec%%:*}"; logf="${spec#*:}"
    [[ "$verdict" == "unavailable" ]] || continue
    if [[ "$agent" == "agy" ]]; then
      tok=$(_classify_agy_drop_reason "$logf")
      [[ -n "$tok" ]] && reasons+="${agent}: $(_agy_drop_reason_phrase "$tok"); "
    elif [[ "$agent" == "codex" ]]; then
      tok=$(_classify_codex_drop_reason "$logf")
      [[ -n "$tok" ]] && reasons+="${agent}: $(_codex_drop_reason_phrase "$tok"); "
    fi
  done
  printf '%s' "${reasons%; }"
}

# TC-CODEX-DROP-LOOP-01 — codex dropped on a stream-error log → reason names codex + stream-error
loop01=$(build_dropped_reasons "codex:unavailable:$FIXTURES/codex-stream-error-turn.jsonl")
assert_contains "TC-CODEX-DROP-LOOP-01 stream-error loop reason names codex + stream-error" \
  "codex: stream-error" "$loop01"

# TC-CODEX-DROP-LOOP-02 — codex dropped on a generic/no-signal log → empty reason
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$NARRATION_TURN"; } > "$DLOG"
loop02=$(build_dropped_reasons "codex:unavailable:$DLOG")
assert_eq "TC-CODEX-DROP-LOOP-02 generic codex drop → empty reason (bare unavailable)" "" "$loop02"

# TC-CODEX-DROP-LOOP-03 — BOTH agy (quota) AND codex (stream-error) dropped in the
# SAME fan-out → reasons list a DISTINCT clause for each (the AC #2 regression
# guard on the assembly loop only handling agy).
loop03=$(build_dropped_reasons \
  "agy:unavailable:$FIXTURES/agy-quota-exhausted.fixture" \
  "codex:unavailable:$FIXTURES/codex-stream-error-turn.jsonl")
assert_contains "TC-CODEX-DROP-LOOP-03a both-dropped lists the agy quota reason" "agy: quota-exhausted" "$loop03"
assert_contains "TC-CODEX-DROP-LOOP-03b both-dropped lists the codex stream-error reason" "codex: stream-error" "$loop03"

# TC-CODEX-DROP-LOOP-04 — a non-codex/non-agy unavailable agent adds no reason
loop04=$(build_dropped_reasons "kiro:unavailable:$FIXTURES/codex-stream-error-turn.jsonl")
assert_eq "TC-CODEX-DROP-LOOP-04 non-agy/non-codex unavailable agent adds no reason" "" "$loop04"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CODEX-DROP-SRC: wrapper wiring (source-of-truth) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-CODEX-DROP-SRC-01 wrapper captures the per-agent codex log path (AGENT_CODEX_LOGS)" \
  'AGENT_CODEX_LOGS' "$WRAPPER"
assert_grep "TC-CODEX-DROP-SRC-02 wrapper calls _classify_codex_drop_reason" \
  '_classify_codex_drop_reason' "$WRAPPER"
assert_grep "TC-CODEX-DROP-SRC-03 dropped-agent reason assembly interpolates the codex reason phrase" \
  '_codex_drop_reason_phrase' "$WRAPPER"
# TC-CODEX-DROP-SRC-04 — bash -n parses both files
if bash -n "$LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-CODEX-DROP-SRC-04a lib-review-codex.sh parses (bash -n)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CODEX-DROP-SRC-04a lib-review-codex.sh fails bash -n"; FAIL=$((FAIL + 1))
fi
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-CODEX-DROP-SRC-04b autonomous-review.sh parses (bash -n)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CODEX-DROP-SRC-04b autonomous-review.sh fails bash -n"; FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CODEX-DROP-REG: regression ==="
# ---------------------------------------------------------------------------
# TC-CODEX-DROP-REG-01 — a stream-error codex drop classifies DISTINCTLY from a
# generic/no-verdict drop (the core regression: pre-fix both produce no reason).
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$STREAM_ERROR_TURN"; } > "$DLOG"
reg_stream=$(_classify_codex_drop_reason "$DLOG")
{ echo '{"type":"thread.started","thread_id":"aaaa"}'; echo "$NARRATION_TURN"; } > "$DLOG"
reg_generic=$(_classify_codex_drop_reason "$DLOG")
if [[ "$reg_stream" != "$reg_generic" && -n "$reg_stream" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CODEX-DROP-REG-01 stream-error drop classified distinctly from a no-verdict drop"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CODEX-DROP-REG-01 not distinguished (stream='$reg_stream' generic='$reg_generic')"; FAIL=$((FAIL + 1))
fi

# TC-CODEX-DROP-REG-02 — a clean no-verdict turn (#198) is NOT misreported as a
# stream error (no over-claim).
assert_eq "TC-CODEX-DROP-REG-02 clean no-verdict turn not misreported as stream-error" \
  "" "$reg_generic"

# ===========================================================================
# Issue #212: codex resume honors the per-agent AGENT_REVIEW_EXTRA_ARGS override
# ===========================================================================
# `run_agent` (turn 1) reads AGENT_DEV_EXTRA_ARGS; `resume_agent` (subsequent
# turns) reads AGENT_REVIEW_EXTRA_ARGS — two DIFFERENT vars. The codex review
# lane is the one CLI that RESUMES (gather-only turn 1 → resume_agent). Before
# the fix the fan-out subshell aliased the resolved per-agent extra-args onto
# ONLY AGENT_DEV_EXTRA_ARGS, so codex's `exec resume` read the SHARED
# AGENT_REVIEW_EXTRA_ARGS and dropped the per-agent _CODEX override — a shared
# `--trust-all-tools` (set for kiro) crashed `codex exec resume` with exit 2 and
# codex was dropped `unavailable` on every review. The fix aliases the resolved
# value onto BOTH vars inside the subshell.
#
# Strategy: drive the REAL resume_agent codex branch (lib-agent.sh) with a
# stubbed `codex` on PATH that records argv, a pre-seeded thread-id sidecar so
# resume_agent resumes (instead of falling back to a fresh run), and the
# wrapper's per-agent subshell logic (resolve via lib-review-resolve.sh, assign
# both vars) replicated faithfully. We assert the codex `exec resume` argv.
echo ""
echo "=== TC-CXR-XA: codex resume honors per-agent review extra-args (#212) ==="
RESOLVE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-resolve.sh"
AGENT_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"

# Build a sandbox once: a stub `codex` (records argv), a stub `timeout`/`env`,
# a PID dir for the codex thread sidecar.
XA_ROOT=$(mktemp -d)
trap 'rm -f "$TMPLOG" "$REC_RESUME_ARGV" "$REC_RESUME_CALLS" "$DLOG"; rm -rf "$XA_ROOT"' EXIT
XA_BIN="$XA_ROOT/bin"; mkdir -p "$XA_BIN"
XA_PID="$XA_ROOT/pid"; mkdir -p "$XA_PID"; chmod 700 "$XA_PID"

# `codex` stub: record argv, then act as _codex_capture_thread's upstream by
# emitting one thread.started line so the capture filter is happy (its output is
# discarded by the test). The recorder file is given via CODEX_ARGV_FILE.
cat > "$XA_BIN/codex" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "${CODEX_ARGV_FILE}"
echo '{"type":"thread.started","thread_id":"deadbeefdeadbeef"}'
EOF
chmod +x "$XA_BIN/codex"
# `timeout` stub: drop its 3 leading args, exec the rest.
cat > "$XA_BIN/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$XA_BIN/timeout"

XA_SID="abc12345-1111-2222-3333-444444444444"
XA_ARGV="$XA_ROOT/codex-argv"

# run_codex_resume_argv <shared_extra> <per_agent_codex_extra>
#   Replicate the wrapper's per-agent codex subshell: source the resolver,
#   resolve the per-agent extra-args, assign BOTH AGENT_DEV_EXTRA_ARGS and
#   AGENT_REVIEW_EXTRA_ARGS (the fix), seed the thread sidecar so resume fires,
#   then call resume_agent. Echo the recorded `codex exec resume` argv.
run_codex_resume_argv() {
  local shared="$1" per_codex="$2"
  : > "$XA_ARGV"
  PATH="$XA_BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$XA_PID" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$XA_ROOT" \
  AGENT_PERMISSION_MODE=auto \
  CODEX_ARGV_FILE="$XA_ARGV" \
  AGENT_REVIEW_EXTRA_ARGS="$shared" \
  AGENT_REVIEW_EXTRA_ARGS_CODEX="$per_codex" \
  bash -c '
    source "'"$RESOLVE_LIB"'"
    source "'"$AGENT_LIB"'"
    # Seed the codex thread-id sidecar so resume_agent resumes (not fresh).
    tf=$(AGENT_CMD=codex _codex_thread_file "'"$XA_SID"'")
    printf "%s\n" "deadbeefdeadbeef" > "$tf"
    # --- the wrapper per-agent subshell, replicated for codex ---
    (
      AGENT_CMD=codex
      _resolved=$(_resolve_review_agent_extra_args codex)
      AGENT_DEV_EXTRA_ARGS="$_resolved"
      AGENT_REVIEW_EXTRA_ARGS="$_resolved"
      resume_agent "'"$XA_SID"'" "verdict prompt" "model-x" "sess"
    )
  ' >/dev/null 2>&1
  cat "$XA_ARGV"
}

# TC-CXR-XA-01 — per-agent _CODEX value present, shared value absent.
xa01=$(run_codex_resume_argv "--trust-all-tools" "-s danger-full-access")
assert_contains "TC-CXR-XA-01a codex resume argv carries the per-agent -s danger-full-access" \
  "-s danger-full-access" "$xa01"
assert_not_contains "TC-CXR-XA-01b codex resume argv does NOT carry the shared --trust-all-tools" \
  "--trust-all-tools" "$xa01"
assert_contains "TC-CXR-XA-01c codex resume argv keeps structural 'exec resume'" \
  "exec resume" "$xa01"

# TC-CXR-XA-02 — shared only (no per-agent key): the shared value reaches resume.
xa02=$(run_codex_resume_argv "--shared-flag" "")
assert_contains "TC-CXR-XA-02 shared-only: codex resume argv carries --shared-flag (no regression)" \
  "--shared-flag" "$xa02"

# TC-CXR-XA-03 — the #212 regression, exercising the REAL resume_agent codex
# branch (not a replica). This pins the ROOT CAUSE: resume_agent reads
# AGENT_REVIEW_EXTRA_ARGS, NOT AGENT_DEV_EXTRA_ARGS. The pre-fix wrapper aliased
# the resolved per-agent value onto ONLY AGENT_DEV_EXTRA_ARGS — so we drive
# resume_agent with the resolved value on AGENT_DEV only (pre-fix shape) and
# show the per-agent `-s danger-full-access` does NOT reach codex resume, while
# the shared `--trust-all-tools` (set on AGENT_REVIEW) DOES → exactly the exit-2
# drop. Then with the fix's dual assignment the per-agent value reaches resume.
# If anyone reverts resume_agent to read AGENT_DEV_EXTRA_ARGS, the dual-assign
# would be unnecessary — but that is a SEPARATE lib change deliberately out of
# scope; this test documents the contract the wrapper fix depends on.
run_codex_resume_argv_devonly() {
  # Replicate the PRE-FIX wrapper subshell: resolved value on AGENT_DEV only.
  local shared="$1" per_codex="$2"
  : > "$XA_ARGV"
  PATH="$XA_BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$XA_PID" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$XA_ROOT" \
  AGENT_PERMISSION_MODE=auto \
  CODEX_ARGV_FILE="$XA_ARGV" \
  AGENT_REVIEW_EXTRA_ARGS="$shared" \
  AGENT_REVIEW_EXTRA_ARGS_CODEX="$per_codex" \
  bash -c '
    source "'"$RESOLVE_LIB"'"
    source "'"$AGENT_LIB"'"
    tf=$(AGENT_CMD=codex _codex_thread_file "'"$XA_SID"'")
    printf "%s\n" "deadbeefdeadbeef" > "$tf"
    (
      AGENT_CMD=codex
      _resolved=$(_resolve_review_agent_extra_args codex)
      AGENT_DEV_EXTRA_ARGS="$_resolved"   # PRE-FIX: only the dev var
      resume_agent "'"$XA_SID"'" "verdict prompt" "model-x" "sess"
    )
  ' >/dev/null 2>&1
  cat "$XA_ARGV"
}
xa03_prefix=$(run_codex_resume_argv_devonly "--trust-all-tools" "-s danger-full-access")
assert_not_contains "TC-CXR-XA-03a pre-fix shape: per-agent -s danger-full-access does NOT reach codex resume (root cause)" \
  "-s danger-full-access" "$xa03_prefix"
assert_contains "TC-CXR-XA-03b pre-fix shape: codex resume instead carries the rejected shared --trust-all-tools (→ exit 2 drop)" \
  "--trust-all-tools" "$xa03_prefix"
xa03_fixed=$(run_codex_resume_argv "--trust-all-tools" "-s danger-full-access")
assert_not_contains "TC-CXR-XA-03c with the dual-var fix: codex resume no longer inherits the rejected shared --trust-all-tools" \
  "--trust-all-tools" "$xa03_fixed"

# TC-CXR-XA-ISO-01 — sibling isolation. The fix writes AGENT_REVIEW_EXTRA_ARGS,
# a var the PARENT fan-out loop also reads. Assert a codex subshell's assignment
# does NOT leak back into the parent, and a sibling (kiro) subshell resolves only
# its own value. Pure-resolver level (no CLI launch needed).
iso01=$(
  set -uo pipefail
  source "$RESOLVE_LIB"
  AGENT_REVIEW_EXTRA_ARGS="--shared-flag"
  AGENT_REVIEW_EXTRA_ARGS_CODEX="-s danger-full-access"
  unset AGENT_REVIEW_EXTRA_ARGS_KIRO 2>/dev/null || true
  parent_before="$AGENT_REVIEW_EXTRA_ARGS"
  # codex fan-out subshell mutates AGENT_REVIEW_EXTRA_ARGS (the fix).
  ( AGENT_CMD=codex
    _r=$(_resolve_review_agent_extra_args codex)
    AGENT_DEV_EXTRA_ARGS="$_r"; AGENT_REVIEW_EXTRA_ARGS="$_r"
    : )
  parent_after="$AGENT_REVIEW_EXTRA_ARGS"
  # sibling kiro subshell resolves only its own value (falls back to shared).
  kiro_seen=$( AGENT_CMD=kiro
    _r=$(_resolve_review_agent_extra_args kiro)
    AGENT_DEV_EXTRA_ARGS="$_r"; AGENT_REVIEW_EXTRA_ARGS="$_r"
    printf '%s' "$AGENT_REVIEW_EXTRA_ARGS" )
  echo "before=[$parent_before] after=[$parent_after] kiro=[$kiro_seen]"
)
assert_contains "TC-CXR-XA-ISO-01a parent AGENT_REVIEW_EXTRA_ARGS unchanged after codex subshell" \
  "before=[--shared-flag] after=[--shared-flag]" "$iso01"
assert_contains "TC-CXR-XA-ISO-01b sibling kiro subshell sees only its own (shared fallback) value, not codex's _CODEX override" \
  "kiro=[--shared-flag]" "$iso01"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXR-XA-SRC: wrapper aliases resolved extra-args onto BOTH vars (#212) ==="
# ---------------------------------------------------------------------------
# Source-of-truth: the per-agent subshell must assign the resolved review
# extra-args to AGENT_REVIEW_EXTRA_ARGS (read by resume_agent) in ADDITION to
# AGENT_DEV_EXTRA_ARGS (read by run_agent). The TC-PAM-SRC-05 grep in
# test-autonomous-review-per-agent-model.sh covers the AGENT_DEV alias; this
# pins the AGENT_REVIEW alias here too.
assert_grep "TC-CXR-XA-SRC-01 wrapper assigns AGENT_REVIEW_EXTRA_ARGS the resolved per-agent value (resume_agent's var)" \
  'AGENT_REVIEW_EXTRA_ARGS="\$_resolved_review_extra_args"' "$WRAPPER"
# The misleading "the review wrapper never resumes" claim must be gone (codex does).
if grep -qE 'review wrapper never resumes' "$WRAPPER"; then
  echo -e "  ${RED}FAIL${NC}: TC-CXR-XA-SRC-02 stale 'review wrapper never resumes' claim still present in wrapper comment"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CXR-XA-SRC-02 stale 'review wrapper never resumes' claim removed"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
