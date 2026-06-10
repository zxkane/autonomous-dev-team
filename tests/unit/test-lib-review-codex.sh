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
# _codex_review_argv populates a nameref OUT-ARRAY (no stdout): `_codex_review_argv
# <out> <prompt> <model>`. We assert on the resulting bash array directly so a
# multi-line prompt is verified to stay ONE element (the #218 finding-1 regression).
# A per-element dump (NUL-joined → one line per element via tr) lets us count
# elements and inspect each.
argv_dump() { local -n _d="$1"; printf '%s\0' "${_d[@]}"; }   # NUL-delimited elements

AGENT_DEV_EXTRA_ARGS="" _codex_review_argv argv_basic "my review prompt" ""
# TC-CXRS-LAUNCH-01 — `review` is the subcommand and the prompt is the positional
assert_eq "TC-CXRS-LAUNCH-01a argv[0] is the review subcommand" "review" "${argv_basic[0]}"
assert_eq "TC-CXRS-LAUNCH-01b argv[1] is the prompt (one element)" "my review prompt" "${argv_basic[1]}"
assert_eq "TC-CXRS-LAUNCH-01c no model/extra-args → exactly 2 elements" "2" "${#argv_basic[@]}"

# TC-CXRS-LAUNCH-02/03 — model via -c model="...", NOT -m
AGENT_DEV_EXTRA_ARGS="" _codex_review_argv argv_model "p" "openai.gpt-5.5"
# join elements with a sentinel for substring/flag assertions
argv_model_joined=$(IFS='|'; echo "${argv_model[*]}")
assert_contains "TC-CXRS-LAUNCH-02 model passed via -c model=\"...\"" 'model="openai.gpt-5.5"' "$argv_model_joined"
# the -c flag is its own element immediately before the model config element
_mi=-1; for _k in "${!argv_model[@]}"; do [[ "${argv_model[$_k]}" == 'model="openai.gpt-5.5"' ]] && _mi=$_k; done
if [[ "$_mi" -gt 0 && "${argv_model[$((_mi-1))]}" == "-c" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-LAUNCH-02b the -c flag element precedes the model config element"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-LAUNCH-02b -c does not precede model config (idx=$_mi)"; FAIL=$((FAIL + 1))
fi
# TC-CXRS-LAUNCH-03 — NO -m element (codex review rejects it)
_has_m=0; for _e in "${argv_model[@]}"; do [[ "$_e" == "-m" ]] && _has_m=1; done
assert_eq "TC-CXRS-LAUNCH-03 argv has no bare -m element" "0" "$_has_m"
# TC-CXRS-LAUNCH-04 — NO --base
assert_not_contains "TC-CXRS-LAUNCH-04 argv has no --base" "--base" "$argv_model_joined"
# TC-CXRS-LAUNCH-05 — NO --json
assert_not_contains "TC-CXRS-LAUNCH-05 argv has no --json" "--json" "$argv_model_joined"
# also no `exec` element (that is the DEV path)
_has_exec=0; for _e in "${argv_model[@]}"; do [[ "$_e" == "exec" ]] && _has_exec=1; done
assert_eq "TC-CXRS-LAUNCH-05b review argv has no 'exec' element" "0" "$_has_exec"

# TC-CXRS-LAUNCH-06 — extra-args appended as DISTINCT elements (uses the real
# _parse_extra_args via lib-agent.sh). `-s danger-full-access` → two elements.
(
  source "$AGENT_LIB" 2>/dev/null
  source "$LIB"
  AGENT_DEV_EXTRA_ARGS="-s danger-full-access" _codex_review_argv argv_xa "p" "m"
  printf '%s\0' "${argv_xa[@]}"
) > "$TMP/argv_xa.nul"
# count elements + assert -s and its value are SEPARATE elements
argv_xa_count=$(tr -cd '\0' < "$TMP/argv_xa.nul" | wc -c | tr -d ' ')
if grep -qzF -- '-s' "$TMP/argv_xa.nul" && grep -qzF -- 'danger-full-access' "$TMP/argv_xa.nul"; then
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-LAUNCH-06 extra-args appended as distinct elements (-s + value)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-LAUNCH-06 extra-args not present as distinct elements"; FAIL=$((FAIL + 1))
fi

# TC-CXRS-LAUNCH-08 — #218 FINDING 1 REGRESSION: a MULTI-LINE prompt (the real
# build_review_prompt heredoc shape) must remain a SINGLE argv element. The pre-fix
# newline-serialized round-trip split it at every `\n` into many positionals →
# codex review got bogus args and failed before reviewing. The nameref array MUST
# keep it intact: argv[1] equals the full multi-line prompt, and the total element
# count is unaffected by how many lines the prompt has.
multiline_prompt=$'You are reviewing PR #219.\n\n## Step 0\nCheck mergeable.\n\n## Decision\nPost via post-verdict.sh.\nLine with "quotes" and $(subshell) and `backtick`.'
AGENT_DEV_EXTRA_ARGS="" _codex_review_argv argv_ml "$multiline_prompt" "sonnet"
assert_eq "TC-CXRS-LAUNCH-08a multi-line prompt stays ONE argv element" "$multiline_prompt" "${argv_ml[1]}"
# review + prompt + (-c + model) = exactly 4 elements regardless of prompt newlines
assert_eq "TC-CXRS-LAUNCH-08b multi-line prompt does not inflate the element count" "4" "${#argv_ml[@]}"
# and argv[0] is still exactly `review`, argv[2]/[3] the model flag (prompt did not bleed)
assert_eq "TC-CXRS-LAUNCH-08c argv[0] still 'review' after a multi-line prompt" "review" "${argv_ml[0]}"
assert_eq "TC-CXRS-LAUNCH-08d argv[2] is '-c' (prompt did not split into positionals)" "-c" "${argv_ml[2]}"

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

# TC-CXRS-RUN-07 — #218 review finding 4: a wall-clock-cap kill (124/137) STOPS the
# loop IMMEDIATELY and returns the sticky veto rc with ZERO re-runs. The re-run loop
# exists for transient stream errors, NOT for the per-run timeout cap — re-running a
# capped run is pointless (the cap refires) and risks the duplicate-verdict /
# partial-review hazard (each clean re-run is a fresh `codex review` that may
# self-post). So a turn-1 124 → 1 run, 0 re-runs, returns 124 (INV-48 veto).
# The pre-fix code keyed the loop break on the STICKY final_rc, so a 124 then a clean
# re-run kept final_rc==124, never broke, and looped to MAX_RERUNS — exactly the
# bug. This test now asserts the RUN COUNT (not just the return value) so the
# loop-until-bound regression cannot return.
run07=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); : > "$sandbox/runs"
  _run_with_timeout() { echo run >> "$sandbox/runs"; echo x; return 124; }
  _codex_now_seconds() { printf '%s\n' 0; }
  CODEX_REVIEW_MAX_RERUNS=3 AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review p m "$sandbox/cap.txt"; rc=$?
  runs=$(grep -c '^run$' "$sandbox/runs" 2>/dev/null) || runs=0
  echo "rc=${rc}|runs=${runs}"
  rm -rf "$sandbox"
)
assert_eq "TC-CXRS-RUN-07 turn-1 timeout (124) → breaks immediately, 1 run, returns 124 (INV-48 veto)" \
  "rc=124|runs=1" "$run07"

# TC-CXRS-RUN-07b — the bug scenario directly: turn-1 124, then (had the loop
# continued) a CLEAN run. The loop MUST NOT issue that clean re-run — a 124
# terminates the loop. Stub: run 1 → 124, any subsequent run → 0. Correct behavior
# is exactly ONE run (the 124), so the clean rc-0 path is never reached → no extra
# `codex review` invocation that could self-post a duplicate verdict.
run07b=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); ri=0; : > "$sandbox/runs"
  _run_with_timeout() { ri=$((ri+1)); echo run >> "$sandbox/runs"; echo x; [[ $ri -eq 1 ]] && return 124 || return 0; }
  _codex_now_seconds() { printf '%s\n' 0; }
  CODEX_REVIEW_MAX_RERUNS=3 AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review p m "$sandbox/cap.txt"; rc=$?
  runs=$(grep -c '^run$' "$sandbox/runs" 2>/dev/null) || runs=0
  echo "rc=${rc}|runs=${runs}"
  rm -rf "$sandbox"
)
assert_eq "TC-CXRS-RUN-07b timeout-then-(would-be-clean) → NO extra re-run; 1 run, rc 124 (no duplicate-verdict path)" \
  "rc=124|runs=1" "$run07b"

# TC-CXRS-RUN-07c — a 137 (--kill-after SIGKILL) timeout also breaks immediately.
run07c=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); : > "$sandbox/runs"
  _run_with_timeout() { echo run >> "$sandbox/runs"; echo x; return 137; }
  _codex_now_seconds() { printf '%s\n' 0; }
  CODEX_REVIEW_MAX_RERUNS=3 AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review p m "$sandbox/cap.txt"; rc=$?
  runs=$(grep -c '^run$' "$sandbox/runs" 2>/dev/null) || runs=0
  echo "rc=${rc}|runs=${runs}"
  rm -rf "$sandbox"
)
assert_eq "TC-CXRS-RUN-07c turn-1 137 → breaks immediately, 1 run, returns 137 (INV-48 veto)" \
  "rc=137|runs=1" "$run07c"

# TC-CXRS-RUN-07d — a re-run that ITSELF times out still stops + returns the veto:
# turn-1 rc 1 (stream error) → re-run 1 rc 124 → break (timeout), 2 runs, rc 124.
# Confirms a timeout occurring DURING the re-run loop terminates it (not only a
# turn-1 timeout) and feeds the veto.
run07d=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d); ri=0; : > "$sandbox/runs"
  _run_with_timeout() { ri=$((ri+1)); echo run >> "$sandbox/runs"; echo x; [[ $ri -eq 1 ]] && return 1 || return 124; }
  _codex_now_seconds() { printf '%s\n' 0; }
  CODEX_REVIEW_MAX_RERUNS=3 AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review p m "$sandbox/cap.txt"; rc=$?
  runs=$(grep -c '^run$' "$sandbox/runs" 2>/dev/null) || runs=0
  echo "rc=${rc}|runs=${runs}"
  rm -rf "$sandbox"
)
assert_eq "TC-CXRS-RUN-07d stream-error then re-run TIMES OUT → stops at the timeout, 2 runs, rc 124" \
  "rc=124|runs=2" "$run07d"

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
# TC-CXRS-WIRE-10 — #218 finding 2 source-of-truth: the REAL wrapper's stdout
# fallback gates on a clean (rc 0) codex review exit. The INT-07..09 behavioral
# tests exercise a COPY of the fallback block; these greps pin the gate in the
# actual autonomous-review.sh so it can't silently regress (a non-zero exit must
# never post a fabricated verdict). The gate reads the launch rc from
# AGENT_LAUNCH_RC and admits ONLY rc 0 (a completed review).
assert_grep "TC-CXRS-WIRE-10a wrapper reads the codex launch rc from AGENT_LAUNCH_RC (#218 finding 2)" \
  '_cx_launch_rc="\$\{AGENT_LAUNCH_RC\[' "$WRAPPER"
assert_grep "TC-CXRS-WIRE-10b wrapper stdout-fallback admits ONLY rc 0 (#218 finding 2)" \
  '\[\[ "\$_cx_launch_rc" -eq 0 \]\]' "$WRAPPER"
# TC-CXRS-WIRE-11 — the wrapper builds the codex review argv via the nameref
# OUT-ARRAY (#218 finding 1: _run_codex_review must NOT serialize/parse the prompt
# through newlines). Pin that _codex_review_argv is called with an out-array first
# arg in the lib (the production caller).
assert_grep "TC-CXRS-WIRE-11 _run_codex_review builds argv via the nameref out-array (#218 finding 1)" \
  '_codex_review_argv _argv ' "$LIB"

# ===========================================================================
echo ""
echo "=== TC-CXRS-INT: integration — stdout fallback verdict path (behavioral) ==="
# ===========================================================================
# Replicate the wrapper's INV-62 stdout-fallback block against the real lib + a
# stub post-verdict.sh + a stub _fetch_agent_verdict_body / _classify_verdict_body,
# proving: [P1] → FAIL composed + posted; clean → PASS posted; self-posted → no
# double-post; stream-error capture → NOT fabricated into a verdict.

# fallback_case <stdout-fixture> <already-resolved-verdict> <already-self-posted> [fb_lag] [launch_rc]
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
#   - launch_rc      : the codex member's _run_codex_review exit code (default 0).
#                      A non-zero rc means codex review did NOT complete cleanly, so
#                      the rc-0 gate (#218 finding 2) must SKIP the stdout fallback —
#                      a CLI usage/auth error printing `error: …` with no `[P1]` must
#                      NOT be posted as a false PASS.
fallback_case() {
  local fixture="$1" pre_verdict="$2" pre_body="$3" fb_lag="${4:-}" launch_rc="${5:-0}"
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
    declare -A AGENT_LAUNCH_RC=([sid-codex]="$launch_rc")

    # --- the wrapper's INV-62 fallback block, replicated verbatim ---
    for _i in "${!AGENT_NAMES[@]}"; do
      [[ "${AGENT_NAMES[$_i]}" == "codex" ]] || continue
      [[ -n "${AGENT_VERDICTS[$_i]}" ]] && continue
      [[ -n "${AGENT_VERDICT_BODIES[$_i]}" ]] && continue
      # #218 findings 2 + 5: ONLY a clean rc-0 (completed) review is eligible for the
      # stdout fallback. Any non-zero rc (124/137 cap, a usage/auth/config error, or
      # a genuine stream failure which exits non-zero) is left UNRESOLVED for the
      # terminal sweep — never fabricated into a verdict. The rc-0 gate is the SOLE
      # gate: there is NO stream-error skip on the rc-0 path (a real stream failure is
      # non-zero, already filtered; and `_codex_review_has_stream_error` is a broad
      # substring scan that would false-positive on a clean review merely MENTIONING
      # the phrase — #218 finding 5). So an rc-0 review (empty, clean, or text that
      # mentions stream-error strings) always classifies + posts exactly one verdict.
      [[ "${AGENT_LAUNCH_RC[${AGENT_SESSION_IDS[$_i]}]:-1}" -eq 0 ]] || continue
      _cx_stdout="${AGENT_CODEX_LOGS[$_i]:-}"
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

# TC-CXRS-INT-04 — a GENUINE pure stream failure exits NON-ZERO (the CLI exhausts
# its SSE reconnects and `turn.failed`s). With a non-zero launch rc it is dropped by
# the rc-0 gate (→ unresolved → `unavailable` via the sweep + the stream-error
# drop-reason path) — NOT fabricated into a verdict. (#218 finding 5: the realistic
# stream-error case is non-zero rc; the old test used rc 0, which conflated a real
# failure with an rc-0 review that merely MENTIONS the phrase — see INT-04b.)
assert_eq "TC-CXRS-INT-04 genuine stream failure (non-zero rc) → dropped by the rc-0 gate (unresolved)" \
  "NOPOST|-|" "$(fallback_case "$FIXTURES/codex-review-stdout-stream-error.txt" "" "" "" 1)"

# TC-CXRS-INT-04b — #218 finding 5 REGRESSION: an rc-0 COMPLETED review whose capture
# MENTIONS the stream-error phrases (e.g. a clean review of THIS PR's stream-error
# fixtures / the detector) but has no `[P1]` MUST still post the default PASS — NOT
# be dropped by a broad-substring stream-error skip. The fix removed the stream-error
# skip from the rc-0 path; the rc-0 gate is the sole gate. The stream-error fixture
# at rc 0 (a review that talks ABOUT a stream error, not one that suffered it) →
# classifies PASS (no `[P1]`) and posts. Proven to fail against the pre-fix skip
# (which would `continue` → NOPOST → dropped `unavailable`).
assert_eq "TC-CXRS-INT-04b rc-0 review MENTIONING stream-error phrase (no [P1]) → posts PASS (finding 5)" \
  "POST|pass|pass" "$(fallback_case "$FIXTURES/codex-review-stdout-stream-error.txt" "" "" "" 0)"

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

# TC-CXRS-INT-07 — #218 FINDING 2 REGRESSION: a codex review that exited NON-ZERO
# (a CLI usage/auth/config error — here a broken invocation printing `error: …` to
# the capture with NO `[P1]`) must NOT be classified PASS and posted by the wrapper.
# The pre-fix fallback gated only on 124/137, so this `error:` capture (rc 1) would
# read as PASS (no `[P1]`) → a FALSE PASS for a review that never ran. The rc-0 gate
# leaves it UNRESOLVED for the terminal sweep (→ `unavailable`). NOPOST + empty
# resolution. This is the dangerous interaction with finding 1 the reviewer flagged.
assert_eq "TC-CXRS-INT-07 non-zero exit (CLI error, no [P1]) → NOT posted as false PASS (rc-0 gate)" \
  "NOPOST|-|" "$(fallback_case "$FIXTURES/codex-review-stdout-cli-error.txt" "" "" "" 1)"

# TC-CXRS-INT-08 — a non-zero exit even with a [P1] in the capture is still left
# unresolved: a non-completed review is not a trustworthy verdict source regardless
# of what partial text it streamed. (rc 1, stdout has [P1] → still NOPOST.)
assert_eq "TC-CXRS-INT-08 non-zero exit with [P1] in partial stdout → still unresolved (rc-0 gate)" \
  "NOPOST|-|" "$(fallback_case "$FIXTURES/codex-review-stdout-p1.txt" "" "" "" 1)"

# TC-CXRS-INT-09 — the rc-0 happy path is unaffected: an explicit rc 0 with a clean
# review still posts PASS (the gate admits a completed review).
assert_eq "TC-CXRS-INT-09 rc 0 clean review → posts PASS (gate admits completed review)" \
  "POST|pass|pass" "$(fallback_case "$FIXTURES/codex-review-stdout-clean.txt" "" "" "" 0)"

# TC-CXRS-INT-10 — #218 review finding 2: an rc-0 review that did NOT self-post and
# produced an EMPTY capture (the diff had nothing blocking; codex emitted little/no
# text) must STILL post the default PASS — NOT be dropped `unavailable`. An empty
# fixture ("") makes fallback_case write an empty capture (`: > "$cap"`). The pre-fix
# `[[ -n && -s ]] || continue` guard dropped it; the fix posts the composed default
# PASS, upholding INV-62's "exactly one verdict". POST|pass|pass.
assert_eq "TC-CXRS-INT-10 rc 0, empty capture, no self-post → posts default PASS (not dropped unavailable)" \
  "POST|pass|pass" "$(fallback_case "" "" "" "" 0)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXRS-MLP: _run_codex_review passes a MULTI-LINE prompt as ONE arg (#218 finding 1) ==="
# ---------------------------------------------------------------------------
# End-to-end argv guard: drive _run_codex_review with a stub _run_with_timeout that
# records its argv (NUL-delimited) and assert the multi-line prompt arrives as a
# SINGLE positional argument — not split at newlines into many positionals (which
# would make `codex review` fail before reviewing).
mlp_argv=$(
  set -uo pipefail
  source "$LIB"
  sandbox=$(mktemp -d)
  # Record argv NUL-delimited so a multi-line element is preserved intact.
  _run_with_timeout() { shift; printf '%s\0' "$@" > "$sandbox/argv.nul"; echo "review output"; return 0; }
  _codex_now_seconds() { printf '%s\n' 0; }
  prompt=$'You are reviewing PR #219.\n\n## Decision\nPost via post-verdict.sh.'
  CODEX_REVIEW_MAX_RERUNS=3 AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review "$prompt" "sonnet" "$sandbox/cap.txt" >/dev/null 2>&1
  # element count + the prompt element verbatim
  cnt=$(tr -cd '\0' < "$sandbox/argv.nul" | wc -c | tr -d ' ')
  # The prompt is argv element index 1 (after `review`); extract it (2nd NUL field).
  prompt_arg=$(awk 'BEGIN{RS="\0"} NR==2{print; exit}' "$sandbox/argv.nul")
  first_arg=$(awk 'BEGIN{RS="\0"} NR==1{print; exit}' "$sandbox/argv.nul")
  printf 'cnt=%s|first=%s|match=%s' "$cnt" "$first_arg" "$([[ "$prompt_arg" == "$prompt" ]] && echo yes || echo no)"
  rm -rf "$sandbox"
)
# review + prompt + -c + model = 4 elements; first arg is `review`; the multi-line
# prompt element matches verbatim (NOT split into multiple positionals).
assert_eq "TC-CXRS-MLP-01 multi-line prompt reaches codex review as ONE arg" \
  "cnt=4|first=review|match=yes" "$mlp_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXRS-WT: PR-branch worktree for codex review (#218 finding 3) ==="
# ---------------------------------------------------------------------------
# `codex review` auto-scopes its diff against the CURRENT checkout, so the wrapper
# must run it from a PR-branch worktree (not PROJECT_DIR, which is on `main`).
# Build a throwaway git repo with a `main` and a `pr-branch` that diverges, then
# exercise _codex_review_prepare_worktree / _codex_review_cleanup_worktree and the
# _run_codex_review cwd behavior against it.

# Build the fixture repo once.
WT_REPO=$(mktemp -d)
(
  cd "$WT_REPO"
  git init -q -b main
  git config user.email t@t; git config user.name t
  echo base > f.txt; git add f.txt; git commit -qm base
  git checkout -q -b pr-branch
  echo pr-change >> f.txt; git add f.txt; git commit -qm pr-change
  git checkout -q main
) >/dev/null 2>&1

# TC-CXRS-WT-01 — prepare returns rc 0 and the dest is a checkout AT the PR-branch
# tip (the pr-change commit), proving codex review there would diff the PR.
wt01=$(
  set -uo pipefail
  source "$LIB"
  cd "$WT_REPO"
  dest="$WT_REPO/wt-01"
  _codex_review_prepare_worktree "pr-branch" "$dest"; rc=$?
  # HEAD of the worktree must be the pr-branch tip commit (the one that added pr-change).
  head_subj=$(git -C "$dest" log -1 --format=%s 2>/dev/null || echo NONE)
  has_change=$(grep -qF pr-change "$dest/f.txt" 2>/dev/null && echo yes || echo no)
  _codex_review_cleanup_worktree "$dest"
  exists_after=$([[ -d "$dest" ]] && echo yes || echo no)
  echo "rc=${rc}|subj=${head_subj}|change=${has_change}|after=${exists_after}"
)
assert_eq "TC-CXRS-WT-01 prepare checks out the PR-branch tip; cleanup removes it" \
  "rc=0|subj=pr-change|change=yes|after=no" "$wt01"

# TC-CXRS-WT-02 — prepare fails (rc 1) on an empty branch arg / empty dest / not a repo.
wt02=$(
  set -uo pipefail
  source "$LIB"
  cd "$WT_REPO"
  _codex_review_prepare_worktree "" "$WT_REPO/x";    a=$?
  _codex_review_prepare_worktree "pr-branch" "";     b=$?
  nonrepo=$(mktemp -d)
  ( cd "$nonrepo"; source "$LIB"; _codex_review_prepare_worktree "pr-branch" "$nonrepo/y" ); c=$?
  rm -rf "$nonrepo"
  echo "${a}|${b}|${c}"
)
assert_eq "TC-CXRS-WT-02 prepare fails rc1 on empty-branch / empty-dest / non-repo" "1|1|1" "$wt02"

# TC-CXRS-WT-03 — prepare fails (rc 1) for a non-existent branch (no ref resolves).
wt03=$(
  set -uo pipefail
  source "$LIB"
  cd "$WT_REPO"
  _codex_review_prepare_worktree "no-such-branch" "$WT_REPO/wt-03"; echo "rc=$?"
)
assert_eq "TC-CXRS-WT-03 prepare fails rc1 for a non-existent branch" "rc=1" "$wt03"

# --- #218 finding (stale-ref hazard): a clone with a REAL origin -------------
# `git fetch origin <branch>` updates FETCH_HEAD reliably, but it updates the
# remote-tracking ref `origin/<branch>` only when a fetch REFSPEC maps it. With the
# refspec absent (a config the dispatcher box / certain CI checkouts can present),
# `origin/<branch>` stays STALE while FETCH_HEAD is the fresh tip. The pre-fix
# resolver preferred `origin/<branch>` over FETCH_HEAD, so it would check out the
# STALE commit and let `codex review` vote on the wrong diff. Build a bare remote +
# a clone, ADVANCE the remote, and REMOVE the fetch refspec so `origin/pr-branch`
# cannot self-update on fetch — exactly the stale condition.
WT_BARE=$(mktemp -d); WT_CLONE=$(mktemp -d)
(
  src=$(mktemp -d)
  cd "$src"; git init -q -b main; git config user.email t@t; git config user.name t
  echo base > f.txt; git add f.txt; git commit -qm base
  git checkout -q -b pr-branch; echo v1 >> f.txt; git add f.txt; git commit -qm pr-v1
  git checkout -q main
  git clone -q --bare "$src" "$WT_BARE" >/dev/null 2>&1
  # Clone the bare remote → origin/pr-branch == pr-v1.
  git clone -q "$WT_BARE" "$WT_CLONE" >/dev/null 2>&1
  ( cd "$WT_CLONE" && git fetch -q origin pr-branch:refs/remotes/origin/pr-branch 2>/dev/null || true )
  # ADVANCE the remote's pr-branch to pr-v2.
  cd "$src"; git checkout -q pr-branch; echo v2 >> f.txt; git add f.txt; git commit -qm pr-v2
  git push -q "$WT_BARE" pr-branch >/dev/null 2>&1
  # REMOVE the fetch refspec so a subsequent `git fetch origin pr-branch` updates
  # FETCH_HEAD but leaves origin/pr-branch STALE at pr-v1.
  ( cd "$WT_CLONE" && git config --unset-all remote.origin.fetch 2>/dev/null || true )
  rm -rf "$src"
) >/dev/null 2>&1
# Fresh tip = "pr-v2"; the now-unupdatable origin/pr-branch stays "pr-v1".

# TC-CXRS-WT-03b — STALE-REF REGRESSION: with origin/pr-branch pinned stale at pr-v1
# (no refspec) and the remote advanced to pr-v2, prepare MUST check out the FRESH
# tip (pr-v2, via FETCH_HEAD), NOT the stale origin/pr-branch (pr-v1). Pre-fix this
# checked out pr-v1 (it preferred origin/pr-branch) → a vote on the wrong diff.
wt03b=$(
  set -uo pipefail
  source "$LIB"
  cd "$WT_CLONE"
  stale_subj=$(git log -1 --format=%s origin/pr-branch 2>/dev/null || echo NONE)
  dest="$WT_CLONE/wt-03b"
  _codex_review_prepare_worktree "pr-branch" "$dest"; rc=$?
  checked_subj=$(git -C "$dest" log -1 --format=%s 2>/dev/null || echo NONE)
  # Confirm origin/pr-branch STAYED stale at pr-v1 (the fetch did not self-update it).
  after_subj=$(git log -1 --format=%s origin/pr-branch 2>/dev/null || echo NONE)
  _codex_review_cleanup_worktree "$dest"
  echo "rc=${rc}|stale=${stale_subj}|after=${after_subj}|checked=${checked_subj}"
)
assert_eq "TC-CXRS-WT-03b prepare checks out the FRESH tip (pr-v2 via FETCH_HEAD), not the stale origin/pr-branch (pr-v1)" \
  "rc=0|stale=pr-v1|after=pr-v1|checked=pr-v2" "$wt03b"

# TC-CXRS-WT-03c — a FETCH FAILURE with a real origin is a HARD prepare failure
# (rc 1), NOT a fall-through to a possibly-stale local/FETCH_HEAD ref. Simulate by
# pointing origin at a non-existent path so the fetch cannot succeed; even though
# the clone has a (stale) origin/pr-branch + a local FETCH_HEAD, prepare must FAIL.
wt03c=$(
  set -uo pipefail
  source "$LIB"
  cd "$WT_CLONE"
  git remote set-url origin /nonexistent/bare-$$.git 2>/dev/null
  _codex_review_prepare_worktree "pr-branch" "$WT_CLONE/wt-03c"; echo "rc=$?"
)
assert_eq "TC-CXRS-WT-03c origin present but fetch FAILS → hard prepare failure rc1 (no stale fall-through)" \
  "rc=1" "$wt03c"
rm -rf "$WT_BARE" "$WT_CLONE"

# TC-CXRS-WT-04 — cleanup is rc-0-always (no crash) on a missing / empty dest.
wt04=$(
  set -euo pipefail
  source "$LIB"
  cd "$WT_REPO"
  _codex_review_cleanup_worktree "/nonexistent/$$"; a=$?
  _codex_review_cleanup_worktree ""; b=$?
  echo "${a}|${b}"
)
assert_eq "TC-CXRS-WT-04 cleanup rc-0-always on missing/empty dest (no errexit abort)" "0|0" "$wt04"

# TC-CXRS-WT-05 — _run_codex_review runs `codex review` FROM the passed PR-workdir
# (the stub records its cwd, physical path); the wrapper's own cwd is unchanged
# afterward (the cd is in a subshell).
wt05=$(
  set -uo pipefail
  source "$LIB"
  cd "$WT_REPO"
  dest="$WT_REPO/wt-05"; _codex_review_prepare_worktree "pr-branch" "$dest" >/dev/null 2>&1
  dest_p=$(cd "$dest" && pwd -P)
  caller_before=$(pwd -P)
  # Stub records the PHYSICAL cwd `codex review` ran in.
  _run_with_timeout() { pwd -P > "$WT_REPO/ran_cwd.txt"; echo "review output"; return 0; }
  _codex_now_seconds() { printf '%s\n' 0; }
  CODEX_REVIEW_MAX_RERUNS=0 AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review "p" "sonnet" "$WT_REPO/cap.txt" "$dest" >/dev/null 2>&1
  ran_cwd=$(cat "$WT_REPO/ran_cwd.txt" 2>/dev/null)
  caller_after=$(pwd -P)
  _codex_review_cleanup_worktree "$dest"
  ran_in_wt=no; [[ "$ran_cwd" == "$dest_p" ]] && ran_in_wt=yes
  cwd_stable=no; [[ "$caller_before" == "$caller_after" ]] && cwd_stable=yes
  echo "ran_in_wt=${ran_in_wt}|cwd_stable=${cwd_stable}"
)
assert_eq "TC-CXRS-WT-05 codex review runs FROM the PR-branch worktree; wrapper cwd stable" \
  "ran_in_wt=yes|cwd_stable=yes" "$wt05"

# TC-CXRS-WT-06 — with NO pr_workdir, _run_codex_review warns + runs from cwd
# (degraded path, never crashes). The stub records cwd == the caller's cwd.
wt06=$(
  set -uo pipefail
  source "$LIB"
  cd "$WT_REPO"
  _run_with_timeout() { pwd > "$WT_REPO/ran_cwd6.txt"; echo "review output"; return 0; }
  _codex_now_seconds() { printf '%s\n' 0; }
  CODEX_REVIEW_MAX_RERUNS=0 AGENT_REVIEW_TIMEOUT=1h AGENT_CMD=codex \
    _run_codex_review "p" "sonnet" "$WT_REPO/cap6.txt" "" 2> "$WT_REPO/warn6.txt" >/dev/null
  ran_cwd=$(cat "$WT_REPO/ran_cwd6.txt" 2>/dev/null)
  warned=$(grep -qi 'no PR-branch worktree' "$WT_REPO/warn6.txt" && echo yes || echo no)
  echo "ran_in_cwd=$([[ "$(cd "$ran_cwd" && pwd -P)" == "$(cd "$WT_REPO" && pwd -P)" ]] && echo yes || echo no)|warned=${warned}"
)
assert_eq "TC-CXRS-WT-06 empty pr_workdir → runs from cwd + warns (degraded, no crash)" \
  "ran_in_cwd=yes|warned=yes" "$wt06"

rm -rf "$WT_REPO"

# TC-CXRS-WT-SRC — wrapper source-of-truth: the codex branch prepares a PR-branch
# worktree, passes it to _run_codex_review, and cleans it up.
assert_grep "TC-CXRS-WT-SRC-01 wrapper prepares a PR-branch worktree for codex review" \
  '_codex_review_prepare_worktree "\$PR_BRANCH"' "$WRAPPER"
assert_grep "TC-CXRS-WT-SRC-02 wrapper passes the prepared workdir to _run_codex_review (4th arg)" \
  '_run_codex_review "\$_agent_prompt".*"\$_cx_pr_workdir"' "$WRAPPER"
assert_grep "TC-CXRS-WT-SRC-03 wrapper tears the codex worktree down" \
  '_codex_review_cleanup_worktree "\$_cx_pr_workdir"' "$WRAPPER"

# TC-CXRS-WT-SRC-04..06 — #218 review finding 1: the wrapper FAILS CLOSED when the
# PR-branch worktree cannot be prepared. It MUST guard the `_run_codex_review` call
# behind a `_cx_wt_ready == true` gate (never run a vote-producing review without a
# PR-scoped worktree), and on the failure branch set the non-zero sentinel rc
# (CODEX_REVIEW_NO_WORKTREE_RC, default 70) so the agent resolves `unavailable`
# rather than voting on PROJECT_DIR's wrong/empty diff. Pin all three.
assert_grep "TC-CXRS-WT-SRC-04 wrapper gates _run_codex_review behind a worktree-ready flag (fail-closed, finding 1)" \
  '_cx_wt_ready' "$WRAPPER"
assert_grep "TC-CXRS-WT-SRC-05 wrapper runs codex review ONLY when the worktree is ready" \
  '\[\[ "\$_cx_wt_ready" == true \]\]' "$WRAPPER"
assert_grep "TC-CXRS-WT-SRC-06 wrapper sets the non-zero fail-closed sentinel rc on prepare failure (→ unavailable, no vote)" \
  '_rc="\$\{CODEX_REVIEW_NO_WORKTREE_RC:-70\}"' "$WRAPPER"
# And the stale "fails open" wording must be GONE — the prepare-failure path no
# longer runs from PROJECT_DIR.
if grep -qF 'running from PROJECT_DIR (the auto-scoped diff may be wrong)' "$WRAPPER"; then
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-WT-SRC-07 stale fail-open 'running from PROJECT_DIR' path still present in wrapper"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-WT-SRC-07 stale fail-open 'running from PROJECT_DIR' path removed (fails closed now)"
  PASS=$((PASS + 1))
fi

# TC-CXRS-WT-SRC-08 — #218 finding 2 source-of-truth: the LIVE wrapper does NOT drop
# an rc-0 review on a bare `[[ -n "$_cx_stdout" && -s "$_cx_stdout" ]] || continue`
# (which dropped a clean rc-0 empty review `unavailable`). Pin its absence so a
# regression cannot return silently.
if grep -qE '\[\[ -n "\$_cx_stdout" && -s "\$_cx_stdout" \]\][[:space:]]*\|\|[[:space:]]*continue' "$WRAPPER"; then
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-WT-SRC-08 stale '[[ -n && -s ]] || continue' empty-capture drop still present (would drop rc-0 empty review)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-WT-SRC-08 empty-capture drop removed — rc-0 empty capture is no longer dropped (finding 2)"
  PASS=$((PASS + 1))
fi
# TC-CXRS-WT-SRC-09 — #218 finding 5 source-of-truth: the rc-0 gate is the SOLE gate
# on the stdout fallback path — the broad-substring `_codex_review_has_stream_error`
# skip is GONE from the wrapper's fallback (it false-positived on a clean rc-0 review
# that merely MENTIONS the stream-error phrase, dropping it `unavailable`). The
# helper still EXISTS (used by _classify_codex_drop_reason in the lib), and the
# wrapper may still REFERENCE it in an explanatory comment, but it must not CALL it
# (an invocation is `_codex_review_has_stream_error "<arg>`). Assert no invocation —
# a NON-comment line where the helper name is immediately followed by a quoted arg.
if grep -nE '_codex_review_has_stream_error[[:space:]]+"' "$WRAPPER" | grep -vE '^[0-9]+:[[:space:]]*#'; then
  echo -e "  ${RED}FAIL${NC}: TC-CXRS-WT-SRC-09 wrapper still CALLS _codex_review_has_stream_error to gate the rc-0 fallback (false-negative risk, finding 5)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CXRS-WT-SRC-09 stream-error skip removed from the wrapper rc-0 fallback — rc-0 gate is the sole gate (finding 5)"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
