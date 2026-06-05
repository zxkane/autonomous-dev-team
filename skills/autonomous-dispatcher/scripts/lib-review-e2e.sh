#!/bin/bash
# lib-review-e2e.sh — INV-46 (issue #182): run E2E ONCE in a dedicated lane,
# sequentially, BEFORE the review fan-out — not once per fan-out review agent.
#
# Pre-#182 the E2E execution block was injected into EVERY review agent's prompt
# (build_review_prompt), so AGENT_REVIEW_AGENTS with N CLIs ran the full E2E N
# times: N× E2E_COMMAND_PRE_HOOKS (e.g. a container build), N× E2E_COMMAND, N×
# evidence generation — racing each other on shared stage state. The INV-43
# "duplicated pre-hook shrink" was best-effort (a prompt re-check all N agents
# could race past). This lib lands the strong guarantee: the wrapper runs the
# E2E lane once, computes a hard gate from its result, and only fans out the
# PURE code-review agents on a gate pass.
#
# This lib holds the PURE / testable pieces so they can be unit-tested in
# isolation (mirrors lib-review-aggregate.sh / lib-review-resolve.sh /
# lib-review-poll.sh) without spawning the wrapper:
#   - _classify_e2e_gate        — the dual-signal pass/fail decision (pure)
#   - _fetch_sha_evidence       — re-fetch a SHA-matching evidence comment
#   - _run_command_e2e_lane     — the command-mode shell lane (setsid+timeout)
#   - build_browser_e2e_prompt  — the single browser-mode LLM lane prompt
#
# The wrapper (autonomous-review.sh) owns the orchestration: its Phase-A block
# dispatches command→_run_command_e2e_lane / browser→one run_agent lane, reads
# the .rc sidecar, computes the gate via _classify_e2e_gate, and branches.

# ---------------------------------------------------------------------------
# _classify_e2e_gate <rc> <evidence_present>
#
# The E2E hard gate — a mechanical DUAL-SIGNAL decision (issue #182). Echoes one
# of: `pass` | `fail` | `block-nonsubstantive`. Pure: no I/O, no side effects.
#
# Two independent signals, AND-ed:
#   (a) rc == 0                — the lane's composite result: pre-hooks=0 AND
#                                verify ∈ {0, 124-recovered} AND parser=0 AND
#                                comment-post ok. The lane normalizes a
#                                124-with-recovered-artifact to rc=0 BEFORE
#                                calling the gate, so only a literal `0` here is
#                                the pass precondition.
#   (b) evidence_present == 1  — a re-fetch of the PR found a SHA-matching
#                                evidence comment for the CAPTURED PR_HEAD_SHA.
#
# Truth table:
#   rc=0  + evidence      → pass
#   rc=0  + no evidence   → block-nonsubstantive  (crash between parser-ok and
#                           comment-post, OR transient GitHub on the re-fetch —
#                           fail CLOSED: re-queue for re-review, NOT a
#                           substantive dev bounce, since the code may be fine
#                           and only the evidence post / re-fetch is missing)
#   rc!=0 + evidence      → fail  (verify/pre-hook genuinely failed; a
#                           stale-but-present evidence comment must NOT rescue a
#                           failed run)
#   rc!=0 + no evidence   → fail
#   non-numeric rc        → fail  (defensive — only a literal `0` rc can pass)
#
# Why `block-nonsubstantive` for rc=0+no-evidence (not `fail`): the lane ran
# clean (verify passed, parser produced a block) but the evidence comment is not
# visible on re-fetch. That is overwhelmingly a transient GitHub propagation /
# post hiccup, not a code defect — re-queuing for re-review (the next tick
# re-checks) is the right recovery, mirroring INV-44's mergeable-UNKNOWN routing.
# A genuine verify failure is rc!=0 → `fail` → substantive dev bounce.
_classify_e2e_gate() {
  local rc="$1" evidence_present="$2"

  # Only a literal `0` rc is the pass precondition. Non-numeric / non-zero → fail.
  if ! [[ "$rc" =~ ^[0-9]+$ ]] || [[ "$rc" -ne 0 ]]; then
    printf 'fail\n'
    return 0
  fi

  if [[ "$evidence_present" == "1" ]]; then
    printf 'pass\n'
  else
    # rc==0 but no SHA-matching evidence visible — fail closed, but as a
    # non-substantive re-queue (transient), not a dev bounce.
    printf 'block-nonsubstantive\n'
  fi
}

# ---------------------------------------------------------------------------
# _fetch_sha_evidence — echo the full body of a PR comment whose marker contains
# exactly `e2e-evidence: complete sha="${PR_HEAD_SHA}"` for the CURRENT HEAD, or
# empty if none. Bounded retry (transient GitHub) controlled by the two optional
# args.
#
# Args:
#   $1 retries   — number of attempts (default 1, no extra wait). The gate
#                  re-fetch passes a small budget so a just-posted comment that
#                  hasn't propagated yet still resolves.
#   $2 interval  — seconds between attempts (default 0). Tests pass 0 so the
#                  bounded-retry-then-empty path doesn't sleep.
#
# Reads PR_NUMBER / REPO / PR_HEAD_SHA from the environment. The SHA binding is
# load-bearing: a plain marker (no sha=) must NOT match (stale evidence from a
# prior commit would otherwise pass a re-review of newer code).
_fetch_sha_evidence() {
  local retries="${1:-1}" interval="${2:-0}"
  local _attempt _body
  [[ "$retries" =~ ^[0-9]+$ ]] && [[ "$retries" -ge 1 ]] || retries=1
  for (( _attempt=1; _attempt<=retries; _attempt++ )); do
    # `last`: take the most recent SHA-matching comment, full body (NOT
    # head -1 — a multiline evidence block must survive intact for the reuse
    # path). select-into-array + last avoids truncating a multi-line body.
    _body=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json comments \
      --jq "[.comments[] | select(.body | contains(\"e2e-evidence: complete sha=\\\"${PR_HEAD_SHA}\\\"\")) | .body] | last // empty" 2>/dev/null \
      || true)
    if [[ -n "$_body" ]]; then
      printf '%s\n' "$_body"
      return 0
    fi
    [[ "$_attempt" -lt "$retries" ]] && [[ "$interval" -gt 0 ]] && sleep "$interval"
  done
  # Still empty after the budget.
  return 0
}

# ---------------------------------------------------------------------------
# _run_command_e2e_lane <rc_file>
#
# The command-mode E2E lane (issue #182): a pure SHELL subshell — NOT an LLM
# agent. Runs ONCE, before the fan-out. Writes its composite result to <rc_file>
# (the `.rc` sidecar) under STRICT set -e discipline: every fallible step is
# guarded `|| rc=$?` so a failing step (e.g. a non-zero pre-hook) can never abort
# the function before the sidecar is written — a missing sidecar would otherwise
# read as a launch failure and the gate would still fail closed, but writing it
# explicitly keeps the rc forensically accurate.
#
# Reads (rendered by the wrapper):
#   E2E_COMMAND_RENDERED, E2E_COMMAND_PRE_HOOKS_RENDERED,
#   E2E_COMMAND_EVIDENCE_PARSER_RENDERED, E2E_COMMAND_TIMEOUT_SECONDS,
#   PR_NUMBER, REPO, PR_HEAD_SHA.
#
# Exit-code semantics (unchanged from references/e2e-command-mode.md):
#   verify 0   → run parser → post evidence → rc 0
#   verify 124 → run parser on PARTIAL log; if it produces a valid SHA-marked
#                block, post it and recover to rc 0; else rc 124
#   verify !=0,!=124 → SKIP parser (log is malformed) → post a log-tail → rc=that
#
# Idempotency: if a SHA-matching evidence comment already exists for the current
# HEAD (a prior tick validated this exact commit), reuse it — no pre-hook, no
# verify, rc 0.
#
# setsid + timeout: the verify command is wrapped so its child subtree shares a
# new process group reachable for reaping. The lane's own PGID is exposed to the
# wrapper via _E2E_LANE_PGID (the wrapper passes it to _reap_fanout_processes,
# same as a fan-out agent's PGID; the wrapper's SIGTERM trap also reaches the
# setsid child during Phase A via its `pkill -P $$` fallback).
_E2E_LANE_PGID=""
_run_command_e2e_lane() {
  local rc_file="$1"
  local rc=0
  local log="/tmp/e2e-${PR_NUMBER}.log"

  # Idempotency: a SHA-matching evidence comment for THIS HEAD already exists.
  local existing
  existing=$(_fetch_sha_evidence 1 0)
  if [[ -n "$existing" ]]; then
    log "INV-46: SHA-matching E2E evidence already present for HEAD ${PR_HEAD_SHA:0:7} — reusing, skipping pre-hook + verify."
    printf '0\n' > "$rc_file"
    return 0
  fi

  # Step 1: pre-hooks (if configured). Failure aborts the lane → rc != 0.
  if [[ -n "${E2E_COMMAND_PRE_HOOKS_RENDERED:-}" ]]; then
    log "INV-46: running E2E pre-hooks (once, before fan-out): ${E2E_COMMAND_PRE_HOOKS_RENDERED}"
    bash -c "${E2E_COMMAND_PRE_HOOKS_RENDERED}" >>"$log" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      log "INV-46: E2E pre-hooks FAILED (rc=${rc}) — skipping verify + parser."
      gh pr comment "$PR_NUMBER" --repo "$REPO" \
        --body "## E2E Failure (pre-hooks exited ${rc})

Pre-hook command: \`${E2E_COMMAND_PRE_HOOKS_RENDERED}\`

Last 50 lines of ${log}:
\`\`\`
$(tail -50 "$log" 2>/dev/null)
\`\`\`" 2>/dev/null || true
      printf '%s\n' "$rc" > "$rc_file"
      return 0
    fi
  fi

  # Step 2: verify command under setsid + timeout so the subtree is reapable.
  local verify_rc=0
  log "INV-46: running E2E verify (once, before fan-out): ${E2E_COMMAND_RENDERED}"
  _run_command_e2e_verify >>"$log" 2>&1 || verify_rc=$?

  # Step 3/4: interpret the exit code.
  if [[ "$verify_rc" -eq 0 || "$verify_rc" -eq 124 ]]; then
    # Run the parser on the (possibly partial) log.
    local evidence=""
    evidence=$(bash -c "${E2E_COMMAND_EVIDENCE_PARSER_RENDERED} '${log}'" 2>/dev/null) || true
    if [[ -n "$evidence" ]] && printf '%s' "$evidence" | grep -qF "e2e-evidence: complete sha=\"${PR_HEAD_SHA}\""; then
      # Step 5: post the evidence block as a PR comment.
      # rc stays at its initialized 0 here — it is NEVER set to verify_rc on this
      # branch, so a verify_rc=124 with a recovered, SHA-marked artifact passes
      # (the artifact-recovery exception) and verify_rc=0 passes. Only a failed
      # comment-post (the `|| rc=$?` below) can make this branch non-zero.
      gh pr comment "$PR_NUMBER" --repo "$REPO" --body "$evidence" 2>/dev/null || rc=$?
    else
      # Parser produced no SHA-marked block (malformed log, or timeout with no
      # recoverable artifact) → fail.
      log "INV-46: evidence parser produced no SHA-marked block (verify_rc=${verify_rc}) — E2E FAIL."
      rc="${verify_rc:-1}"
      [[ "$rc" -eq 0 ]] && rc=1
      gh pr comment "$PR_NUMBER" --repo "$REPO" \
        --body "## E2E Failure (evidence block missing/malformed, verify exit ${verify_rc})

Command: \`${E2E_COMMAND_RENDERED}\`

Last 50 lines of ${log}:
\`\`\`
$(tail -50 "$log" 2>/dev/null)
\`\`\`" 2>/dev/null || true
    fi
  else
    # Step 5 (hard failure): SKIP the parser (its input log is malformed). Post a
    # log-tail comment instead.
    log "INV-46: E2E verify hard-failed (rc=${verify_rc}) — skipping parser, posting log tail."
    rc="$verify_rc"
    gh pr comment "$PR_NUMBER" --repo "$REPO" \
      --body "## E2E Failure (verify command exit code: ${verify_rc})

Command: \`${E2E_COMMAND_RENDERED}\`

Last 50 lines of ${log}:
\`\`\`
$(tail -50 "$log" 2>/dev/null)
\`\`\`" 2>/dev/null || true
  fi

  printf '%s\n' "$rc" > "$rc_file"
  return 0
}

# _run_command_e2e_verify — runs E2E_COMMAND_RENDERED under setsid + timeout so
# the verify subtree shares a new process group (reapable on wrapper SIGTERM,
# INV-23 PGID semantics). Captures the session-leader PID into _E2E_LANE_PGID so
# the wrapper can add it to the trap kill-set + _reap_fanout_processes. The
# `timeout --kill-after=… --signal=TERM` wrapper bounds the verify to
# E2E_COMMAND_TIMEOUT_SECONDS and surfaces 124 on expiry. Split out so the
# command-mode lane body stays readable and the setsid/timeout wiring is greppable.
_run_command_e2e_verify() {
  local timeout_secs="${E2E_COMMAND_TIMEOUT_SECONDS:-3600}"
  local _to_cmd=()
  if command -v timeout >/dev/null 2>&1; then
    _to_cmd=(timeout --kill-after=30s --signal=TERM "${timeout_secs}")
  elif command -v gtimeout >/dev/null 2>&1; then
    _to_cmd=(gtimeout --kill-after=30s --signal=TERM "${timeout_secs}")
  fi
  local _setsid=()
  command -v setsid >/dev/null 2>&1 && _setsid=(setsid)

  "${_setsid[@]}" "${_to_cmd[@]}" bash -c "${E2E_COMMAND_RENDERED}" &
  _E2E_LANE_PGID=$!
  wait "$_E2E_LANE_PGID"
}

# ---------------------------------------------------------------------------
# _stamp_browser_evidence_marker — stamp the SHA marker ONTO the browser lane's
# posted E2E report comment (issue #182, codex review fix).
#
# The browser lane LLM posts a `## E2E Verification Report` PR comment (tables,
# screenshots, AC results). This helper finds THAT report comment and edits it
# in place to append the SHA-bound marker
# `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->`. It MUST NOT post a
# standalone marker-only comment: `_fetch_sha_evidence` selects the latest
# comment containing the marker, so a marker-only comment would let the gate pass
# AND would hand the review agents a comment with NO actual evidence (no tables,
# no screenshots, no AC coverage). Stamping the marker onto the report keeps the
# report + marker in ONE comment, so the gate's evidence-present signal and the
# review agents' evidence-read both resolve to the real report.
#
# Report-comment match (mirrors the INV-20 verdict binding): the LATEST PR
# comment authored by BOT_LOGIN (when set), created at/after WRAPPER_START_TS,
# whose body contains `## E2E Verification Report`. When BOT_LOGIN is unset
# (gh api user 403 in app mode — the documented fallback), the actor predicate is
# dropped and the time-window + report-header predicates narrow it.
#
# Returns 0 on a successful stamp (or when the report is ALREADY stamped —
# idempotent). Returns 1 when NO report comment is found or the edit fails — the
# caller (wrapper) treats a non-zero return as "no usable evidence" so the gate
# fails closed instead of passing on a fabricated marker.
#
# Reads PR_NUMBER / REPO_OWNER / REPO_NAME / PR_HEAD_SHA / BOT_LOGIN /
# WRAPPER_START_TS from the environment (all set by the wrapper before the lane).
_stamp_browser_evidence_marker() {
  local marker="<!-- e2e-evidence: complete sha=\"${PR_HEAD_SHA}\" -->"
  # Author predicate: bind to BOT_LOGIN when available, else drop it (the same
  # fallback INV-20 uses when `gh api user` can't introspect the bot identity).
  local _author_jq=""
  if [[ -n "${BOT_LOGIN:-}" ]]; then
    _author_jq="(.user.login == \"${BOT_LOGIN}\") and "
  fi
  # Find the latest report comment's numeric REST id. PR comments are issue
  # comments for this endpoint. `last` → most recent matching report.
  #
  # `gh api --paginate` applies --jq PER PAGE and concatenates, so on a PR with
  # >100 comments spread across pages this can emit one id per page. `tail -n1`
  # collapses that to the single most-recent id (pages arrive in ascending order,
  # so the last line is the newest) — the numeric guard below would otherwise
  # reject a multi-line value and fail closed, harmlessly but with a spurious
  # re-queue on very long PRs.
  local _comment_id
  _comment_id=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/${PR_NUMBER}/comments" --paginate \
    --jq "[.[] | select(${_author_jq}(.created_at >= \"${WRAPPER_START_TS}\") and (.body | contains(\"## E2E Verification Report\")))] | last | .id" \
    2>/dev/null | tail -n1 || true)

  if ! [[ "$_comment_id" =~ ^[0-9]+$ ]]; then
    log "INV-46: browser lane posted NO '## E2E Verification Report' comment to stamp — gate fails closed (no marker-only fabrication)."
    return 1
  fi

  # Fetch the current body so we can append the marker (idempotent: skip if the
  # SHA marker is already present, e.g. a re-run against the same comment).
  local _body
  _body=$(gh api "repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${_comment_id}" \
    --jq '.body' 2>/dev/null || true)
  if [[ -z "$_body" ]]; then
    log "INV-46: could not read the report comment body (id=${_comment_id}) — gate fails closed."
    return 1
  fi
  if printf '%s' "$_body" | grep -qF "e2e-evidence: complete sha=\"${PR_HEAD_SHA}\""; then
    log "INV-46: report comment (id=${_comment_id}) already carries the SHA marker — idempotent skip."
    return 0
  fi

  # PATCH the report comment, appending the marker on its own line. -f body=…
  # sends the field as a string; the literal newline is embedded via $'...'.
  if gh api -X PATCH "repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${_comment_id}" \
      -f body="${_body}"$'\n\n'"${marker}" >/dev/null 2>&1; then
    log "INV-46: stamped SHA marker onto the browser E2E report comment (id=${_comment_id})."
    return 0
  fi
  log "INV-46: failed to stamp the SHA marker onto the report comment (id=${_comment_id}) — gate fails closed."
  return 1
}

# ---------------------------------------------------------------------------
# build_browser_e2e_prompt — the ONE browser-mode E2E lane prompt (issue #182).
#
# E2E_MODE=browser needs an LLM to drive Chrome DevTools MCP, so it stays an
# LLM-driven lane — but a SINGLE lane, run once before the review fan-out, NOT
# replicated across the N review agents. The LLM performs the smoke test, builds
# the structured E2E report, and posts it as a PR comment. The LLM does NOT have
# to emit the SHA marker — the WRAPPER mechanically stamps
# `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` onto the posted report
# after the lane succeeds, so the gate anchor is deterministic in both modes.
#
# Echoes the prompt on stdout. Reads PR_NUMBER / ISSUE_NUMBER / REPO /
# PREVIEW_URL / SCREENSHOT_UPLOAD_AVAILABLE from the environment (set by the
# wrapper, same as the legacy inline block did).
build_browser_e2e_prompt() {
  cat <<E2E_BROWSER_LANE
You are the E2E verification lane for PR #${PR_NUMBER} (issue #${ISSUE_NUMBER}) in
the ${REPO} project. You are NOT the code reviewer — your ONLY job is to run the
browser E2E smoke test via Chrome DevTools MCP and post a structured E2E report
as a PR comment. The wrapper runs you ONCE, before the code-review agents fan out
(INV-46), so the review agents can read your posted report as input.

## E2E Verification via Chrome DevTools MCP — MANDATORY

Preview URL: ${PREVIEW_URL:-NOT_FOUND}
Test user email: available via \$E2E_TEST_USER_EMAIL environment variable
Test user password: available via \$E2E_TEST_USER_PASSWORD environment variable
Screenshot upload available: ${SCREENSHOT_UPLOAD_AVAILABLE}

NOTE: E2E credentials are passed as environment variables for security.
Read them at runtime: \$(printenv E2E_TEST_USER_EMAIL) and \$(printenv E2E_TEST_USER_PASSWORD)

### Step 1: Verify preview URL availability
- If the preview URL above is "NOT_FOUND" or empty, post a PR comment that the
  E2E could not run (preview URL not found; the deploy-preview job must post the
  URL before E2E can proceed) and exit non-zero.

### Step 2: Navigate to preview URL
- Use Chrome DevTools MCP \`new_page\` to open a new browser page
- Use \`navigate_page\` to go to the preview URL
- Use \`wait_for\` to confirm the page loads
- Use \`take_screenshot\` to capture the landing page

### Step 3: Login with test user
- Navigate to login / sign-in, \`fill\` the test email + password, submit
- \`wait_for\` successful auth, \`take_screenshot\` the authenticated state

### Screenshot upload — MANDATORY after every take_screenshot
\`\`\`bash
SCREENSHOT_URL=\$(bash scripts/upload-screenshot.sh "<screenshot-file-path>" ${PR_NUMBER} "<TC-ID>")
echo "Uploaded: \$SCREENSHOT_URL"
\`\`\`
- On success use the blob URL as a clickable link: \`[TC-ID](\$SCREENSHOT_URL)\`
- On "UPLOAD_FAILED", describe the visual state in text instead.

### Step 4–6: Execute happy-path + feature test cases + regression checks
- Pick relevant happy-path cases from the PR diff; run at least ONE.
- Read \`docs/test-cases/\` for feature cases; skip duplicates.
- Regression: auth login/logout, main navigation, no console errors
  (\`list_console_messages\`).
- \`take_screenshot\` at each verification point and upload immediately.

### Step 7: Post the E2E report as a PR comment
Post a structured comment on PR #${PR_NUMBER} (NOT the issue) with this format
(the WRAPPER will append the SHA evidence marker — you do NOT add it):

\`\`\`markdown
## E2E Verification Report

### Summary
| Total | Passed | Failed | Skipped |
|-------|--------|--------|--------|
| N     | X      | Y      | Z       |

### Happy Path Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-HP-001 | ... | PASS/FAIL | [TC-HP-001](url) or description |

### Feature Test Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-XXX-001 | Description | PASS/FAIL | [TC-XXX-001](url) or description |

### Regression Tests
| Test | Status |
|------|--------|
| Auth login/logout | PASS/FAIL |
| Navigation | PASS/FAIL |
| Console errors | PASS/FAIL |
\`\`\`

If ALL E2E checks pass, exit 0 after posting the report. If ANY check fails,
post the report with the failures recorded and exit non-zero — the wrapper's
E2E hard gate will then FAIL the review WITHOUT fanning out the code reviewers.

IMPORTANT: Work autonomously. Do NOT review code — only run the browser E2E and
post the report.
E2E_BROWSER_LANE
}
