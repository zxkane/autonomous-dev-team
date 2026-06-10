#!/bin/bash
# test-lib-review-codex.sh — Unit tests for the codex review path that runs the
# purpose-built `codex review "<prompt>"` subcommand (INV-62, issue #218).
#
# This refactor REPLACES the pre-#218 `codex exec` + resume-loop machinery
# (_run_codex_review_with_resume, _codex_log_has_verdict_message, the INV-55
# inline-diff prompt) with `codex review`, which is natively multi-step and
# auto-scopes the diff to the PR's merge target. Verdict capture is double-insured:
# the prompt asks codex to self-post via post-verdict.sh, AND the wrapper parses
# codex review's stdout (`[P1]` → FAIL else PASS) and posts on codex's behalf if it
# did not self-post.
#
# Tests:
#   - _codex_review_classify_stdout: stdout → pass|fail (P1 present/absent/empty)
#   - _codex_review_compose_body: canonical body composition for the fallback post
#   - _codex_review_argv: the `codex review` argv shape (no -m / --base / --json)
#   - _run_codex_review: launch + bounded re-run (subsumes #209) + sticky timeout rc
#   - _codex_review_has_stream_error / _classify_codex_drop_reason /
#     _codex_drop_reason_phrase: stdout-based stream-error drop reason
#   - wrapper-wiring source-of-truth assertions (codex review subcommand routed,
#     resume loop + JSONL parser + inline-diff deleted, dev path unchanged)
#
# Run: bash tests/unit/test-lib-review-codex.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-codex.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
AGENT_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
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

assert_no_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${RED}FAIL${NC}: $desc (should NOT match: $pattern)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
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

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-CXRS-CLS: _codex_review_classify_stdout ==="
# ---------------------------------------------------------------------------
F="$TMP/stdout.txt"

# TC-CXRS-CLS-01 — a [P1] finding → fail
printf '%s\n' '[P1] src/x.ts:1 — silent failure.' > "$F"
assert_eq "TC-CXRS-CLS-01 [P1] present → fail" "fail" "$(_codex_review_classify_stdout "$F")"

# TC-CXRS-CLS-02 — only [P2]/[P3] → pass
printf '%s\n' '[P2] minor nit' '[P3] consider a test' > "$F"
assert_eq "TC-CXRS-CLS-02 only [P2]/[P3] → pass" "pass" "$(_codex_review_classify_stdout "$F")"

# TC-CXRS-CLS-03 — no priority markers at all → pass
printf '%s\n' 'Looks good to merge. No issues.' > "$F"
assert_eq "TC-CXRS-CLS-03 no markers → pass" "pass" "$(_codex_review_classify_stdout "$F")"

# TC-CXRS-CLS-04 — empty stdout → pass (no [P1] ⇒ pass; wrapper still posts)
: > "$F"
assert_eq "TC-CXRS-CLS-04 empty → pass" "pass" "$(_codex_review_classify_stdout "$F")"
# missing / empty-arg → pass, no crash
assert_eq "TC-CXRS-CLS-04b missing file → pass" "pass" "$(_codex_review_classify_stdout "/nonexistent/$$")"
assert_eq "TC-CXRS-CLS-04c empty arg → pass" "pass" "$(_codex_review_classify_stdout "")"

# TC-CXRS-CLS-05 — [P1] mid-line / multiple → fail (any occurrence)
printf '%s\n' 'see [P1] here and another [P1] there' > "$F"
assert_eq "TC-CXRS-CLS-05 multiple/mid-line [P1] → fail" "fail" "$(_codex_review_classify_stdout "$F")"

# TC-CXRS-CLS-06 — [P1] inside a quoted block still counts (conservative)
printf '%s\n' '```' 'the dev wrote: [P1] in a code comment' '```' > "$F"
assert_eq "TC-CXRS-CLS-06 [P1] in quoted block → fail (conservative)" "fail" "$(_codex_review_classify_stdout "$F")"

# TC-CXRS-CLS-07 — runs under set -euo pipefail without aborting (bare call)
cls07=$(
  set -euo pipefail
  source "$LIB"
  printf '%s\n' 'clean review' > "$F"
  out=$(_codex_review_classify_stdout "$F")
  echo "rc=$?|$out"
)
assert_eq "TC-CXRS-CLS-07 no abort under set -euo pipefail" "rc=0|pass" "$cls07"

# fixture-backed
assert_eq "TC-CXRS-CLS-08 p1 fixture → fail" "fail" "$(_codex_review_classify_stdout "$FIXTURES/codex-review-stdout-p1.txt")"
assert_eq "TC-CXRS-CLS-09 clean fixture → pass" "pass" "$(_codex_review_classify_stdout "$FIXTURES/codex-review-stdout-clean.txt")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXRS-BODY: _codex_review_compose_body ==="
# ---------------------------------------------------------------------------
# TC-CXRS-BODY-01 — pass verdict, non-empty stdout → mentions codex review, no findings
printf '%s\n' 'All good, no issues.' > "$F"
body01=$(_codex_review_compose_body pass "$F")
assert_contains "TC-CXRS-BODY-01a pass body mentions codex review" "codex review" "$body01"
assert_contains "TC-CXRS-BODY-01b pass body carries the review output" "All good" "$body01"

# TC-CXRS-BODY-02 — fail verdict, stdout with [P1] → body carries the findings text
cp "$FIXTURES/codex-review-stdout-p1.txt" "$F"
body02=$(_codex_review_compose_body fail "$F")
assert_contains "TC-CXRS-BODY-02a fail body carries the [P1] finding" "[P1]" "$body02"
assert_contains "TC-CXRS-BODY-02b fail body carries the finding text" "silent failure" "$body02"

# TC-CXRS-BODY-03 — empty stdout, pass → non-empty default summary
: > "$F"
body03=$(_codex_review_compose_body pass "$F")
assert_contains "TC-CXRS-BODY-03 empty stdout pass → non-empty default summary" "no blocking" "$body03"
# empty stdout, fail → non-empty default
body03b=$(_codex_review_compose_body fail "$F")
assert_contains "TC-CXRS-BODY-03b empty stdout fail → non-empty default" "blocking" "$body03b"

# TC-CXRS-BODY-04 — very large stdout → truncated under the cap (post-verdict.sh
# rejects > 60000 chars; the helper caps at 50000 + a marker).
head -c 70000 /dev/zero | tr '\0' 'x' > "$F"
body04=$(_codex_review_compose_body fail "$F")
if [[ ${#body04} -le 51000 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-BODY-04a large stdout truncated under cap (len=${#body04})"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-BODY-04a large stdout NOT truncated (len=${#body04})"; FAIL=$((FAIL + 1))
fi
assert_contains "TC-CXRS-BODY-04b truncation marker present" "truncated" "$body04"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXRS-LAUNCH: _codex_review_argv (the codex review invocation shape) ==="
# ---------------------------------------------------------------------------
# Render argv ONE PER LINE so flags with spaces don't split the assertion.
argv_basic=$(AGENT_DEV_EXTRA_ARGS="" _codex_review_argv "my review prompt" "")
# TC-CXRS-LAUNCH-01 — `review` is the subcommand and the prompt is the positional
assert_contains "TC-CXRS-LAUNCH-01a argv starts with the review subcommand" $'review\n' "$argv_basic"$'\n'
assert_contains "TC-CXRS-LAUNCH-01b prompt is the positional argument" "my review prompt" "$argv_basic"

# TC-CXRS-LAUNCH-02/03 — model via -c model="...", NOT -m
argv_model=$(AGENT_DEV_EXTRA_ARGS="" _codex_review_argv "p" "openai.gpt-5.5")
assert_contains "TC-CXRS-LAUNCH-02 model passed via -c model=\"...\"" 'model="openai.gpt-5.5"' "$argv_model"
assert_contains "TC-CXRS-LAUNCH-02b the -c flag precedes the model config" $'-c\nmodel="openai.gpt-5.5"' "$argv_model"
# TC-CXRS-LAUNCH-03 — NO -m (codex review rejects it)
# (assert on a per-line basis: no line is exactly `-m`)
if printf '%s\n' "$argv_model" | grep -qxF -- '-m'; then
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-LAUNCH-03 argv must NOT contain a bare -m flag"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-LAUNCH-03 argv has no -m flag"; PASS=$((PASS + 1))
fi
# TC-CXRS-LAUNCH-04 — NO --base
assert_not_contains "TC-CXRS-LAUNCH-04 argv has no --base" "--base" "$argv_model"
# TC-CXRS-LAUNCH-05 — NO --json
assert_not_contains "TC-CXRS-LAUNCH-05 argv has no --json" "--json" "$argv_model"
# also no `exec` (that is the DEV path)
if printf '%s\n' "$argv_model" | grep -qxF -- 'exec'; then
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-LAUNCH-05b review argv must NOT contain 'exec' (that is the dev path)"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-LAUNCH-05b review argv has no 'exec'"; PASS=$((PASS + 1))
fi

# TC-CXRS-LAUNCH-06 — extra-args appended (uses the real _parse_extra_args via lib-agent.sh)
argv_xa=$(
  source "$AGENT_LIB" 2>/dev/null
  source "$LIB"
  AGENT_DEV_EXTRA_ARGS="-s danger-full-access" _codex_review_argv "p" "m"
)
assert_contains "TC-CXRS-LAUNCH-06a extra-arg flag appended" "-s" "$argv_xa"
assert_contains "TC-CXRS-LAUNCH-06b extra-arg value appended" "danger-full-access" "$argv_xa"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXRS-RUN: _run_codex_review launch + bounded re-run (subsumes #209) ==="
# ---------------------------------------------------------------------------
# Sandbox: stub _run_with_timeout to consume a scripted feed of per-run exit
# codes (one per line) and write scripted stdout to the capture file. Stub the
# clock for the wall-clock deadline.
#
# run_codex_review_case <feed-rc-spec> <max-reruns> <now-script> [stdout-token]
#   feed-rc-spec : newline-separated integers, one rc per invocation.
#   now-script   : newline-separated integers, one per _codex_now_seconds call.
#   stdout-token : "verdict" writes a clean review, "stream" writes a stream error.
# Echoes "<rc>|<run_count>".
run_codex_review_case() {
  local feed="$1" max="$2" nowscript="$3" tok="${4:-verdict}"
  local sandbox; sandbox=$(mktemp -d)
  printf '%s\n' "$feed"      > "$sandbox/feed"
  printf '%s\n' "$nowscript" > "$sandbox/now"
  : > "$sandbox/runs"
  (
    source "$LIB"
    _run_with_timeout() {
      echo "run" >> "$sandbox/runs"
      # the capture file is the LAST positional via `> "$stdout_file"` in
      # _one_codex_review_run; we cannot see it here, so write through the
      # redirection the caller set: our stdout IS that file.
      if [[ "$tok" == "stream" ]]; then
        echo "error: stream disconnected before completion: server error"
      else
        echo "review output line"
      fi
      local rc; rc=$(head -n1 "$sandbox/feed"); sed -i '1d' "$sandbox/feed" 2>/dev/null || true
      return "${rc:-0}"
    }
    _codex_now_seconds() {
      local n; n=$(head -n1 "$sandbox/now")
      [[ $(wc -l < "$sandbox/now") -gt 1 ]] && sed -i '1d' "$sandbox/now"
      printf '%s\n' "$n"
    }
    CODEX_REVIEW_MAX_RERUNS="$max" AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
      _run_codex_review "prompt" "model-x" "$sandbox/cap.txt"
    rc=$?
    runs=$(grep -c '^run$' "$sandbox/runs" 2>/dev/null) || runs=0
    echo "${rc}|${runs}"
  )
  rm -rf "$sandbox"
}

# TC-CXRS-RUN-01 — run 1 clean → 1 run, rc 0
assert_eq "TC-CXRS-RUN-01 clean first run → 1 run, rc 0" "0|1" "$(run_codex_review_case $'0' 3 $'0\n10')"

# TC-CXRS-RUN-02 — run 1 non-zero, re-run clean → 2 runs, rc 0 (transient ridden out, #209)
assert_eq "TC-CXRS-RUN-02 transient non-zero then clean → 2 runs, rc 0 (#209)" "0|2" "$(run_codex_review_case $'1\n0' 3 $'0\n10\n20\n30')"

# TC-CXRS-RUN-03 — every run non-zero, max=3 → 1 + 3 = 4 runs, returns last rc
assert_eq "TC-CXRS-RUN-03 sustained failure max=3 → 4 runs, rc 1 (graceful)" "1|4" "$(run_codex_review_case $'1\n1\n1\n1' 3 $'0\n5\n10\n15\n20')"

# TC-CXRS-RUN-04 — CODEX_REVIEW_MAX_RERUNS=0 disables re-run → 1 run only
assert_eq "TC-CXRS-RUN-04 max=0 → 1 run, no re-run, rc 1" "1|1" "$(run_codex_review_case $'1\n0' 0 $'0\n5')"

# TC-CXRS-RUN-05 — non-numeric max degrades (no unbound-variable crash under set -u)
run05=$(
  set -euo pipefail
  source "$LIB"
  sandbox=$(mktemp -d)
  _run_with_timeout() { echo x; return 1; }   # always fail so the bound is reached
  _codex_now_seconds() { printf '%s\n' 0; }   # deadline never reached (base 0, budget 3600)
  _rc=0
  # `|| _rc=$?` captures the (legitimately non-zero) return without set -e
  # aborting before the echo — the point of this test is that the non-numeric
  # max DEGRADES (the `(( reruns >= max ))` bound is reached) rather than crashing
  # with an `unbound variable` error under set -u.
  CODEX_REVIEW_MAX_RERUNS="three" AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review p m "$sandbox/cap.txt" || _rc=$?
  echo "rc=${_rc}"
  rm -rf "$sandbox"
) 2>/dev/null
assert_eq "TC-CXRS-RUN-05 non-numeric max degrades (bound reached), no crash" "rc=1" "$run05"

# TC-CXRS-RUN-06 — wall-clock deadline already passed before re-run → no re-run
# now-script: base 0, then a huge value so now >= deadline on the first bound check.
assert_eq "TC-CXRS-RUN-06 wall-clock exceeded → 1 run, no re-run" "1|1" "$(run_codex_review_case $'1\n0' 3 $'0\n999999')"

# TC-CXRS-RUN-07 — sticky timeout rc: run 1 rc 124, re-run clean (rc 0), bound
# exhaustion → returns 124 (INV-48 veto, never reset to 0).
run07=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d)
  ri=0
  _run_with_timeout() { ri=$((ri+1)); echo x; [[ $ri -eq 1 ]] && return 124 || return 0; }
  _codex_now_seconds() { printf '%s\n' 0; }
  CODEX_REVIEW_MAX_RERUNS=2 AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review p m "$sandbox/cap.txt"
  echo "$?"
  rm -rf "$sandbox"
)
# run 1 rc 124 → loop: not 0, rerun 1 (rc 0) → final stays 124 (sticky), loop: rc
# is 124 (not 0) → rerun 2 (rc 0) → still 124 → bound exhausted → returns 124.
assert_eq "TC-CXRS-RUN-07 sticky timeout 124 preserved through clean re-runs" "124" "$run07"

# TC-CXRS-RUN-08 — the capture file holds codex review's clean stdout
run08=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d)
  _run_with_timeout() { echo "REVIEW STDOUT MARKER"; return 0; }
  _codex_now_seconds() { printf '%s\n' 0; }
  CODEX_REVIEW_MAX_RERUNS=3 AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review p m "$sandbox/cap.txt"
  cat "$sandbox/cap.txt"
  rm -rf "$sandbox"
)
assert_contains "TC-CXRS-RUN-08 capture file holds codex review stdout" "REVIEW STDOUT MARKER" "$run08"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXRS-DL: _codex_review_deadline_seconds (reused for the re-run bound) ==="
# ---------------------------------------------------------------------------
assert_eq "TC-CXRS-DL-01 1h → 3600"   3600  "$(AGENT_REVIEW_TIMEOUT=1h   _codex_review_deadline_seconds)"
assert_eq "TC-CXRS-DL-02 90m → 5400"  5400  "$(AGENT_REVIEW_TIMEOUT=90m  _codex_review_deadline_seconds)"
assert_eq "TC-CXRS-DL-03 garbage → 3600 default" 3600 "$(AGENT_REVIEW_TIMEOUT=notaduration _codex_review_deadline_seconds)"
assert_eq "TC-CXRS-DL-04 unset → 3600 default" 3600 "$(unset AGENT_REVIEW_TIMEOUT; _codex_review_deadline_seconds)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXRS-DROP: stdout-based stream-error drop reason (re-scoped INV-59) ==="
# ---------------------------------------------------------------------------
DF="$TMP/drop.txt"

# _codex_review_has_stream_error
cp "$FIXTURES/codex-review-stdout-stream-error.txt" "$DF"
_codex_review_has_stream_error "$DF"; assert_eq "TC-CXRS-DROP-01 stream-error capture → rc 0" 0 "$?"
cp "$FIXTURES/codex-review-stdout-clean.txt" "$DF"
_codex_review_has_stream_error "$DF"; assert_eq "TC-CXRS-DROP-02 clean review → rc 1 (no over-claim)" 1 "$?"
cp "$FIXTURES/codex-review-stdout-p1.txt" "$DF"
_codex_review_has_stream_error "$DF"; assert_eq "TC-CXRS-DROP-03 [P1] review → rc 1 (no over-claim)" 1 "$?"
: > "$DF"
_codex_review_has_stream_error "$DF"; assert_eq "TC-CXRS-DROP-04a empty → rc 1" 1 "$?"
_codex_review_has_stream_error "/nonexistent/$$"; assert_eq "TC-CXRS-DROP-04b missing → rc 1" 1 "$?"
_codex_review_has_stream_error ""; assert_eq "TC-CXRS-DROP-04c empty arg → rc 1" 1 "$?"

# _classify_codex_drop_reason
cp "$FIXTURES/codex-review-stdout-stream-error.txt" "$DF"
assert_eq "TC-CXRS-DROP-05 ladder + disconnect → stream-error:5/5" \
  "stream-error:5/5" "$(_classify_codex_drop_reason "$DF")"
# disconnect, no ladder → bare stream-error
printf '%s\n' 'error: stream disconnected before completion: server error' > "$DF"
assert_eq "TC-CXRS-DROP-06 disconnect no ladder → stream-error" \
  "stream-error" "$(_classify_codex_drop_reason "$DF")"
cp "$FIXTURES/codex-review-stdout-clean.txt" "$DF"
assert_eq "TC-CXRS-DROP-07 clean review → empty (caller keeps bare unavailable)" \
  "" "$(_classify_codex_drop_reason "$DF")"
cp "$FIXTURES/codex-review-stdout-p1.txt" "$DF"
assert_eq "TC-CXRS-DROP-08 [P1] review → empty (not a stream error)" \
  "" "$(_classify_codex_drop_reason "$DF")"
assert_eq "TC-CXRS-DROP-09a missing → empty" "" "$(_classify_codex_drop_reason "/nonexistent/$$")"
assert_eq "TC-CXRS-DROP-09b empty arg → empty" "" "$(_classify_codex_drop_reason "")"

# fail-safe under set -euo pipefail with a no-ladder stream error (BARE call)
drop10=$(
  set -euo pipefail
  source "$LIB"
  printf '%s\n' 'error: stream disconnected before completion: server error' > "$DF"
  _classify_codex_drop_reason "$DF"
  echo "REACHED_RETURN_0"
)
assert_eq "TC-CXRS-DROP-10 bare call, no-ladder stream error → no errexit abort" \
  $'stream-error\nREACHED_RETURN_0' "$drop10"

# _codex_drop_reason_phrase
phr1=$(_codex_drop_reason_phrase "stream-error:5/5")
assert_contains "TC-CXRS-DROP-11a phrase names stream-error" "stream-error" "$phr1"
assert_contains "TC-CXRS-DROP-11b phrase carries ladder depth" "5/5" "$phr1"
phr2=$(_codex_drop_reason_phrase "stream-error")
assert_not_contains "TC-CXRS-DROP-12 no spurious depth when no ladder" "5/5" "$phr2"
assert_eq "TC-CXRS-DROP-13 empty token → empty phrase" "" "$(_codex_drop_reason_phrase "")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXRS-DEV: codex DEV path stays on 'codex exec' (byte-for-byte) ==="
# ---------------------------------------------------------------------------
# The dev primitives live in lib-agent.sh and must NOT learn about `codex review`.
assert_grep "TC-CXRS-DEV-01 dev codex branch still emits 'codex exec --json'" \
  '"\$AGENT_CMD" exec --json' "$AGENT_LIB"
assert_no_grep "TC-CXRS-DEV-02 lib-agent.sh has no 'codex review' / review-lib leak" \
  'codex review|_run_codex_review|_codex_review_' "$AGENT_LIB"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXRS-WIRE: wrapper wiring (source-of-truth) ==="
# ---------------------------------------------------------------------------
# TC-CXRS-WIRE-01 — fan-out codex branch calls _run_codex_review
assert_grep "TC-CXRS-WIRE-01 wrapper calls _run_codex_review" \
  '_run_codex_review ' "$WRAPPER"
# TC-CXRS-WIRE-02 — the old resume controller is GONE (lib + wrapper)
assert_no_grep "TC-CXRS-WIRE-02a _run_codex_review_with_resume removed from wrapper" \
  '_run_codex_review_with_resume' "$WRAPPER"
assert_no_grep "TC-CXRS-WIRE-02b _run_codex_review_with_resume removed from lib" \
  '_run_codex_review_with_resume' "$LIB"
# TC-CXRS-WIRE-03 — the JSONL verdict parser is GONE
assert_no_grep "TC-CXRS-WIRE-03a _codex_log_has_verdict_message removed from lib" \
  '_codex_log_has_verdict_message' "$LIB"
assert_no_grep "TC-CXRS-WIRE-03b _codex_log_has_verdict_message removed from wrapper" \
  '_codex_log_has_verdict_message' "$WRAPPER"
# TC-CXRS-WIRE-04 — the INV-55 inline-diff block is GONE from the codex prompt
assert_no_grep "TC-CXRS-WIRE-04a DIFF_START_ inline-diff marker removed" \
  'DIFF_START_' "$WRAPPER"
assert_no_grep "TC-CXRS-WIRE-04b DIFF_END_ inline-diff marker removed" \
  'DIFF_END_' "$WRAPPER"
assert_no_grep "TC-CXRS-WIRE-04c the gh pr diff inline-fetch for codex removed" \
  'CODEX_REVIEW_INLINE_DIFF_MAX_BYTES' "$WRAPPER"
# TC-CXRS-WIRE-05 — non-codex agents still route through bare run_agent
assert_grep "TC-CXRS-WIRE-05 bare run_agent retained for non-codex agents" \
  'run_agent "\$_agent_session_id"' "$WRAPPER"
# TC-CXRS-WIRE-06 — the stdout fallback posts via post-verdict + composes the body
assert_grep "TC-CXRS-WIRE-06a wrapper composes the fallback body" \
  '_codex_review_compose_body' "$WRAPPER"
assert_grep "TC-CXRS-WIRE-06b wrapper classifies codex stdout" \
  '_codex_review_classify_stdout' "$WRAPPER"
assert_grep "TC-CXRS-WIRE-06c fallback posts via post-verdict.sh" \
  'post-verdict.sh' "$WRAPPER"
# TC-CXRS-WIRE-07 — both files parse
if bash -n "$LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-WIRE-07a lib-review-codex.sh parses (bash -n)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-WIRE-07a lib-review-codex.sh fails bash -n"; FAIL=$((FAIL + 1))
fi
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-WIRE-07b autonomous-review.sh parses (bash -n)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-WIRE-07b autonomous-review.sh fails bash -n"; FAIL=$((FAIL + 1))
fi
# TC-CXRS-WIRE-08 — CI shellcheck still lists the lib
assert_grep "TC-CXRS-WIRE-08 CI shellcheck includes lib-review-codex.sh" \
  'lib-review-codex.sh' "$CI"
# TC-CXRS-WIRE-09 — drop-reason loop still wires the codex classifier
assert_grep "TC-CXRS-WIRE-09 wrapper calls _classify_codex_drop_reason" \
  '_classify_codex_drop_reason' "$WRAPPER"

# ===========================================================================
echo ""
echo "=== TC-CXRS-INT: integration — stdout fallback verdict path (behavioral) ==="
# ===========================================================================
# Replicate the wrapper's INV-62 stdout-fallback block against the real lib + a
# stub post-verdict.sh + a stub _fetch_agent_verdict_body / _classify_verdict_body,
# proving: [P1] → FAIL composed + posted; clean → PASS posted; self-posted → no
# double-post; stream-error capture → NOT fabricated into a verdict.

# fallback_case <stdout-fixture> <already-resolved-verdict> <already-self-posted> [fb_lag]
#   Echoes "<posted?>|<verdict-arg>|<resolved-verdict>"
#   - posted?        : "POST" if the stub post-verdict.sh was invoked, else "NOPOST"
#   - verdict-arg    : the pass/fail arg passed to post-verdict.sh (or "-")
#   - resolved       : the AGENT_VERDICTS value after the block
#   - fb_lag         : when "lag", the stub _fetch_agent_verdict_body returns EMPTY
#                      (simulates GitHub comments-API propagation lag: the verdict
#                      comment WAS posted but is not yet visible to the re-fetch).
#                      Exercises the M1 race — a successfully-posted verdict must
#                      NOT be left unresolved (→ dropped `unavailable`) just because
#                      the immediate re-fetch hasn't caught up.
fallback_case() {
  local fixture="$1" pre_verdict="$2" pre_body="$3" fb_lag="${4:-}"
  local sandbox; sandbox=$(mktemp -d)
  local cap="$sandbox/cap.txt"
  [[ -n "$fixture" ]] && cp "$fixture" "$cap" || : > "$cap"
  : > "$sandbox/postlog"
  (
    set -uo pipefail
    source "$LIB"
    # Stubs for the poll helpers the wrapper block uses.
    SCRIPT_DIR="$sandbox"
    ISSUE_NUMBER=999
    _fb_lag="$fb_lag"
    _resolve_review_agent_model() { echo "sonnet"; }
    _fetch_agent_verdict_body() {
      # `lag` → API hasn't surfaced the just-posted comment yet → empty.
      [[ "$_fb_lag" == "lag" ]] && { printf ''; return 0; }
      cat "$sandbox/posted_body" 2>/dev/null || true
    }
    _classify_verdict_body() {
      # FAIL-first, mirrors lib-review-poll.sh.
      if grep -qiE '^[[:space:]]*Review findings:' <<<"${1%%$'\n'*}"; then echo fail; else echo pass; fi
    }
    log() { :; }
    # Stub post-verdict.sh: record the verdict arg, write the composed comment so
    # _fetch_agent_verdict_body returns it (canonical first line prepended).
    cat > "$sandbox/post-verdict.sh" <<PV
#!/bin/bash
echo "POST \$2" >> "$sandbox/postlog"
{ if [[ "\$2" == "fail" ]]; then echo "Review findings:"; else echo "Review PASSED"; fi
  cat "\$3"
  echo "Review Session: \\\`\$5\\\`"
  echo "Review Agent: \$4 (model: \$6)"; } > "$sandbox/posted_body"
exit 0
PV
    chmod +x "$sandbox/post-verdict.sh"

    AGENT_NAMES=(codex)
    AGENT_SESSION_IDS=(sid-codex)
    AGENT_CODEX_LOGS=("$cap")
    AGENT_VERDICTS=("$pre_verdict")
    AGENT_VERDICT_BODIES=("$pre_body")

    # --- the wrapper's INV-62 fallback block, replicated verbatim ---
    for _i in "${!AGENT_NAMES[@]}"; do
      [[ "${AGENT_NAMES[$_i]}" == "codex" ]] || continue
      [[ -n "${AGENT_VERDICTS[$_i]}" ]] && continue
      [[ -n "${AGENT_VERDICT_BODIES[$_i]}" ]] && continue
      _cx_stdout="${AGENT_CODEX_LOGS[$_i]:-}"
      [[ -n "$_cx_stdout" && -s "$_cx_stdout" ]] || continue
      if _codex_review_has_stream_error "$_cx_stdout" \
         && ! grep -qF '[P1]' "$_cx_stdout" 2>/dev/null; then
        continue
      fi
      _cx_verdict=$(_codex_review_classify_stdout "$_cx_stdout")
      _cx_body_file=$(mktemp "$sandbox/body-XXXXXX.md")
      _codex_review_compose_body "$_cx_verdict" "$_cx_stdout" > "$_cx_body_file" 2>/dev/null || true
      _cx_fb_model=$(_resolve_review_agent_model "codex"); _cx_fb_model="${_cx_fb_model:-sonnet}"
      if bash "${SCRIPT_DIR}/post-verdict.sh" "$ISSUE_NUMBER" "$_cx_verdict" "$_cx_body_file" \
           codex "${AGENT_SESSION_IDS[$_i]}" "$_cx_fb_model" >/dev/null 2>&1; then
        _cx_refetched=$(_fetch_agent_verdict_body "codex" "${AGENT_SESSION_IDS[$_i]}")
        if [[ -n "$_cx_refetched" ]]; then
          AGENT_VERDICT_BODIES[$_i]="$_cx_refetched"
          AGENT_VERDICTS[$_i]=$(_classify_verdict_body "$_cx_refetched")
        else
          AGENT_VERDICT_BODIES[$_i]=$(cat "$_cx_body_file" 2>/dev/null || true)
          AGENT_VERDICTS[$_i]="$_cx_verdict"
        fi
      fi
      rm -f "$_cx_body_file" 2>/dev/null || true
    done

    posted="NOPOST"; verdict_arg="-"
    if [[ -s "$sandbox/postlog" ]]; then posted="POST"; verdict_arg=$(awk '{print $2}' "$sandbox/postlog" | head -n1); fi
    echo "${posted}|${verdict_arg}|${AGENT_VERDICTS[0]}"
  )
  rm -rf "$sandbox"
}

# TC-CXRS-INT-01 — [P1] stdout, not self-posted → wrapper posts FAIL, resolves fail
assert_eq "TC-CXRS-INT-01 [P1] not self-posted → wrapper posts FAIL → resolves fail" \
  "POST|fail|fail" "$(fallback_case "$FIXTURES/codex-review-stdout-p1.txt" "" "")"

# TC-CXRS-INT-02 — clean stdout, not self-posted → wrapper posts PASS, resolves pass
assert_eq "TC-CXRS-INT-02 clean not self-posted → wrapper posts PASS → resolves pass" \
  "POST|pass|pass" "$(fallback_case "$FIXTURES/codex-review-stdout-clean.txt" "" "")"

# TC-CXRS-INT-03 — codex self-posted (pre_body set) → NO double-post
assert_eq "TC-CXRS-INT-03 codex self-posted → wrapper does NOT double-post" \
  "NOPOST|-|pass" "$(fallback_case "$FIXTURES/codex-review-stdout-clean.txt" "pass" "Review PASSED ...")"

# TC-CXRS-INT-04 — pure stream-error capture, not self-posted → NOT fabricated
# (left unresolved; the sweep + drop-reason path handle it).
assert_eq "TC-CXRS-INT-04 pure stream-error → not fabricated into a verdict (left unresolved)" \
  "NOPOST|-|" "$(fallback_case "$FIXTURES/codex-review-stdout-stream-error.txt" "" "")"

# TC-CXRS-INT-05 — re-fetch LAGS (comments API hasn't surfaced the just-posted
# verdict yet) on a clean PASS → the agent MUST still resolve `pass` from the
# wrapper's own composed body, NOT be left unresolved (→ spuriously dropped
# `unavailable` by the post-window sweep). Guards the M1 propagation race: the
# wrapper KNOWS the verdict it composed + posted; classifying the posted comment
# is identical (post-verdict.sh prepends `Review PASSED`/`Review findings:`), so a
# lagging API read must never demote a successfully-posted verdict to no-verdict.
assert_eq "TC-CXRS-INT-05 PASS with lagging re-fetch → still resolves pass (not dropped unavailable)" \
  "POST|pass|pass" "$(fallback_case "$FIXTURES/codex-review-stdout-clean.txt" "" "" lag)"

# TC-CXRS-INT-06 — re-fetch LAGS on a [P1] FAIL → still resolves `fail` from the
# wrapper's own composed body (a passing-merge veto must survive the lag too).
assert_eq "TC-CXRS-INT-06 FAIL with lagging re-fetch → still resolves fail (not dropped unavailable)" \
  "POST|fail|fail" "$(fallback_case "$FIXTURES/codex-review-stdout-p1.txt" "" "" lag)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
