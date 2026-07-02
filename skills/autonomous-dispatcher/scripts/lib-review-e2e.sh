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

# [INV-87]/[INV-46] Issue-Tracker Provider dispatch for the SHA evidence-marker
# stamp. The INV-46 stamp's in-place PATCH leaf routes through itp_edit_comment
# (→ itp_${ISSUE_PROVIDER}_edit_comment) and its edit_comment=0 fallback through
# itp_post_comment + itp_caps. The review wrapper (autonomous-review.sh) does NOT
# source lib-issue-provider.sh, so this lib self-sources it from the REAL skill
# tree via readlink -f of its own BASH_SOURCE (the same idiom lib-dispatch.sh
# uses). Idempotent (the shims + .caps reader guard their own redefinition);
# guarded so a standalone-sourced lib-review-e2e.sh still resolves the verbs.
if ! declare -F itp_edit_comment >/dev/null 2>&1; then
  _lre2e_self="${BASH_SOURCE[0]:-$0}"
  _lre2e_dir="$(cd "$(dirname "$(readlink -f "$_lre2e_self")")" && pwd 2>/dev/null)" || _lre2e_dir=""
  if [ -n "$_lre2e_dir" ] && [ -r "${_lre2e_dir}/lib-issue-provider.sh" ]; then
    # shellcheck source=lib-issue-provider.sh
    source "${_lre2e_dir}/lib-issue-provider.sh"
  fi
  unset _lre2e_self _lre2e_dir
fi

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
# _validate_ac_coverage_json — read a candidate JSON on stdin, echo the
# canonical compact form (jq -c) iff it is a non-empty flat object whose every
# value is exactly "pass" or "fail"; else echo EMPTY. Returns 0 always (fail-
# SAFE). When `jq` is unavailable, echoes EMPTY (the structured double-check is
# an optimization, never a hard dependency). This is the SINGLE source of truth
# for the artifact contract — shared by _extract_ac_coverage_artifact (parse-time)
# and _revalidate_ac_coverage_file (prompt-read TOCTOU re-check, INV-49 sub-rule
# 5) so both apply byte-identical validation + canonicalization.
_validate_ac_coverage_json() {
  command -v jq >/dev/null 2>&1 || return 0
  local compact
  # jq -ce: parse (bad JSON → non-zero, caught by `||`), then require a non-empty
  # object whose every value is "pass"/"fail"; emit compact single-line JSON.
  compact=$(jq -ce '
    if type=="object" and (length > 0)
       and (all(.[]; . == "pass" or . == "fail"))
    then . else empty end
  ' 2>/dev/null) || return 0
  [[ -n "$compact" ]] || return 0
  printf '%s\n' "$compact"
}

# _extract_ac_coverage_artifact <text>
#
# INV-49 (issue #183): extract the OPTIONAL structured AC-coverage artifact a
# command-mode evidence parser MAY embed in its evidence block. Echoes the
# validated, compact JSON object on stdout, or EMPTY when absent/malformed. Pure:
# no I/O beyond a `jq` subprocess. fail-SAFE — any deviation from the contract
# (no fence / not parseable / not an object / a value outside {pass,fail}) yields
# EMPTY so the caller falls back to the #182 free-form double-check. It NEVER
# fails open (a bad artifact never becomes a passing structured map) and NEVER
# aborts the lane (returns 0 in all cases; jq's stderr is swallowed).
#
# Emission contract (parser-side, opt-in): the parser embeds the JSON between an
# HTML-comment fence in its evidence stdout, so the artifact (a) renders
# invisibly in the posted comment and (b) travels into the SHA-bound comment for
# the idempotent reuse path:
#
#   <!-- ac-coverage:begin
#   { "<criterion-id-or-text>": "pass" | "fail", ... }
#   ac-coverage:end -->
#
# Shape: a flat JSON object; every value MUST be exactly "pass" or "fail".
#
# When `jq` is unavailable the function returns EMPTY (fall back) — the structured
# double-check is an optimization, never a hard dependency.
_extract_ac_coverage_artifact() {
  local text="$1"
  # No fence → no artifact (the #182 parser path). Cheap pre-check before awk/jq.
  case "$text" in
    *"ac-coverage:begin"*) : ;;
    *) return 0 ;;
  esac

  # Slice the bytes strictly BETWEEN the FIRST begin/end fence pair (exclusive).
  # `done` latches after the first end so a parser that (incorrectly) emits more
  # than one fence canonicalizes to the first object, never a multi-object stream
  # — the contract is a single flat object. Single-fence output is unchanged.
  local raw
  raw=$(printf '%s\n' "$text" | awk '
    done                { next }
    /ac-coverage:end/   { if (inblk) { done=1 }; inblk=0; next }
    inblk               { print }
    /ac-coverage:begin/ { if (!done) inblk=1 }
  ')
  [[ -n "${raw//[$' \t\n']/}" ]] || return 0   # empty fence body → fail-safe

  printf '%s' "$raw" | _validate_ac_coverage_json
}

# _revalidate_ac_coverage_file
#
# INV-49 (issue #183) sub-rule 5 — TOCTOU defense. Re-validates the sidecar file
# E2E_AC_COVERAGE_FILE at prompt-read time and echoes the canonical compact JSON
# (or EMPTY). The sidecar lives at a predictable, exported /tmp path, and
# PR-controlled command-mode E2E / parser code runs between _write_ac_coverage_
# sidecar's validation and prompt construction, so it could overwrite the file
# AFTER validation — a prompt-injection / fail-open path if the wrapper trusted
# the bytes. By re-running the SAME _validate_ac_coverage_json the wrapper only
# ever interpolates a freshly-re-validated, canonicalized object into the prompt;
# a now-malformed/replaced sidecar falls back to the free-form block. Echoes EMPTY
# when the var is unset/empty, the file is missing/empty, or it fails validation.
# Returns 0 ALWAYS (honors its own contract regardless of call form): the read is
# routed through a brace group with its own stderr discarded — that suppresses a
# redirect-open error on a vanished/unreadable file AND keeps a `cat`/pipefail
# failure from aborting a bare top-level `_ac_map=$(_revalidate_ac_coverage_file)`
# under `set -e` (the trailing `|| true` is the always-0 guarantee).
_revalidate_ac_coverage_file() {
  [[ -n "${E2E_AC_COVERAGE_FILE:-}" ]] || return 0
  [[ -s "${E2E_AC_COVERAGE_FILE}" ]] || return 0
  # Read the CURRENT bytes (not a cached copy) and re-validate; any read failure
  # (file vanished / unreadable between the -s test and the read) → EMPTY.
  { cat "${E2E_AC_COVERAGE_FILE}" | _validate_ac_coverage_json; } 2>/dev/null || true
}

# _write_ac_coverage_sidecar <evidence_text>
#
# INV-49 (issue #183): extract the structured AC-coverage artifact from the given
# evidence text and write the validated compact JSON to E2E_AC_COVERAGE_FILE (the
# sidecar the review fan-out reads). ALWAYS (re)writes the sidecar — truncating it
# to empty when no valid artifact is present — so a prior round's artifact can
# never leak into a round whose parser stopped emitting it (or emitted a malformed
# one). No-op when E2E_AC_COVERAGE_FILE is unset (e.g. browser mode). Logs a
# warning when a fence was present but failed validation (the fail-safe fallback
# path) so an operator can see the parser shipped a bad artifact.
#
# Write-failure = no map (INV-49 sub-rule 3): if the file cannot be made to hold
# EXACTLY this round's validated artifact (non-writable / chmodded / not
# truncatable), `unset E2E_AC_COVERAGE_FILE` for the rest of the run and log —
# so the fan-out reads NO structured map (free-form fallback) rather than a
# possibly-stale prior-round file. The write is no longer swallowed with `|| true`.
_write_ac_coverage_sidecar() {
  local evidence_text="$1"
  [[ -n "${E2E_AC_COVERAGE_FILE:-}" ]] || return 0
  local artifact
  artifact=$(_extract_ac_coverage_artifact "$evidence_text")
  # Same pure-bash fence detection as _extract_ac_coverage_artifact (no forked
  # grep): a present-but-rejected fence means the parser shipped a bad artifact.
  if [[ -z "$artifact" && "$evidence_text" == *"ac-coverage:begin"* ]]; then
    log "INV-49: command-mode evidence carried an ac-coverage fence but it was malformed (invalid JSON / not an object / value not in {pass,fail}) — falling back to the free-form AC double-check (fail-safe)."
  fi
  # Write-or-disarm: an empty artifact writes an empty file (no stale leak); a
  # write failure DISARMS the sidecar (unset) so the fan-out cannot read a
  # possibly-stale prior-round file. The write rc IS checked (no `|| true`). The
  # brace group's `2>/dev/null` also swallows the shell's redirect-OPEN error
  # (`> file` on a non-writable target prints to stderr before a command-level
  # redirect applies) so the INV-49 log line is the single operator-facing signal.
  if ! { printf '%s' "$artifact" > "$E2E_AC_COVERAGE_FILE"; } 2>/dev/null; then
    log "INV-49: could not write the AC-coverage sidecar (${E2E_AC_COVERAGE_FILE}) — disarming it so the review fan-out reads NO structured map (free-form fallback), never a stale prior-round file."
    unset E2E_AC_COVERAGE_FILE
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
    # [INV-87]/[INV-91] (#296 B4, #308) the SHA-evidence read routes through
    # chp_pr_view (the verb prepends `--repo "$REPO"`). Byte-identical to the
    # prior `gh pr view "$PR_NUMBER" --repo "$REPO" --json comments --jq …`. The
    # review wrapper sources lib-code-host.sh before this lib, so chp_pr_view is
    # defined; we deliberately do NOT self-source it here (a 3-line read must not
    # touch the production source graph — the isolation tests source the seam).
    # The `2>/dev/null || true` keeps the read fail-soft.
    _body=$(chp_pr_view "$PR_NUMBER" --json comments \
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
  # [INV-100] (#355): keyed by PROJECT_ID + PR_NUMBER — the bare PR-number-only
  # form collided across projects (two different projects' PRs can share a
  # number). Truncated on open (below), not appended, so a same-PR retry on a
  # later tick starts this round's log clean rather than concatenating onto a
  # prior round's (potentially large, definitely confusing) log tail.
  local log="/tmp/e2e-${PROJECT_ID:-}-${PR_NUMBER}.log"
  : > "$log" 2>/dev/null || true

  # INV-49: start each round with an empty AC-coverage sidecar so a prior round's
  # artifact can never leak into a path that never reaches the parser (pre-hook /
  # hard-fail). The reuse + fresh-success paths re-populate it from this round's
  # evidence via _write_ac_coverage_sidecar. No-op when the var is unset. If the
  # truncate FAILS (non-writable / chmodded), DISARM the sidecar (unset) so no
  # early-return path (pre-hook/hard-fail) can leave stale prior-round content
  # readable — same write-failure = no-map rule as _write_ac_coverage_sidecar.
  # The brace group's `2>/dev/null` swallows the shell's redirect-open error so
  # the INV-49 log line is the single operator-facing signal.
  if [[ -n "${E2E_AC_COVERAGE_FILE:-}" ]] && ! { : > "$E2E_AC_COVERAGE_FILE"; } 2>/dev/null; then
    log "INV-49: could not truncate the AC-coverage sidecar (${E2E_AC_COVERAGE_FILE}) at lane entry — disarming it (no structured map this round, free-form fallback)."
    unset E2E_AC_COVERAGE_FILE
  fi

  # Idempotency: a SHA-matching evidence comment for THIS HEAD already exists.
  local existing
  existing=$(_fetch_sha_evidence 1 0)
  if [[ -n "$existing" ]]; then
    log "INV-46: SHA-matching E2E evidence already present for HEAD ${PR_HEAD_SHA:0:7} — reusing, skipping pre-hook + verify."
    # INV-49: the reused comment carries any structured AC-coverage fence too —
    # re-extract it for THIS round's fan-out (the sidecar is per-round, not posted).
    _write_ac_coverage_sidecar "$existing"
    printf '0\n' > "$rc_file"
    return 0
  fi

  # Step 1: pre-hooks (if configured). Failure aborts the lane → rc != 0.
  if [[ -n "${E2E_COMMAND_PRE_HOOKS_RENDERED:-}" ]]; then
    log "INV-46: running E2E pre-hooks (once, before fan-out): ${E2E_COMMAND_PRE_HOOKS_RENDERED}"
    bash -c "${E2E_COMMAND_PRE_HOOKS_RENDERED}" >>"$log" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
      log "INV-46: E2E pre-hooks FAILED (rc=${rc}) — skipping verify + parser."
      chp_pr_comment "$PR_NUMBER" \
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
    # INV-49: extract the OPTIONAL structured AC-coverage artifact from the
    # parser output and (re)write the per-round sidecar — fail-safe, truncates on
    # absent/malformed so a prior round's artifact never leaks. Done before the
    # SHA-marker branch so the sidecar is in lock-step with the evidence the
    # fan-out will read; the helper no-ops on empty/no-fence evidence.
    _write_ac_coverage_sidecar "$evidence"
    if [[ -n "$evidence" ]] && printf '%s' "$evidence" | grep -qF "e2e-evidence: complete sha=\"${PR_HEAD_SHA}\""; then
      # Step 5: post the evidence block as a PR comment.
      # rc stays at its initialized 0 here — it is NEVER set to verify_rc on this
      # branch, so a verify_rc=124 with a recovered, SHA-marked artifact passes
      # (the artifact-recovery exception) and verify_rc=0 passes. Only a failed
      # comment-post (the `|| rc=$?` below) can make this branch non-zero.
      chp_pr_comment "$PR_NUMBER" --body "$evidence" 2>/dev/null || rc=$?
    else
      # Parser produced no SHA-marked block (malformed log, or timeout with no
      # recoverable artifact) → fail.
      log "INV-46: evidence parser produced no SHA-marked block (verify_rc=${verify_rc}) — E2E FAIL."
      rc="${verify_rc:-1}"
      [[ "$rc" -eq 0 ]] && rc=1
      chp_pr_comment "$PR_NUMBER" \
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
    chp_pr_comment "$PR_NUMBER" \
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
# [INV-46]/[INV-90]/[INV-91] (#345, #296 deferred): the id-lookup + body-fetch
# reads route through the SHIPPED `itp_list_comments` verb (shape-equivalent, NO
# new verb — the #321 verdict-choke-point migration is the worked example for this
# exact rewrite, incl. its `sort_by(.createdAt // "", .id // 0) | last` tie-break).
# ONE verb call now serves BOTH the id AND the body: the normalized element
# carries `body` verbatim, so the id-lookup element IS the body-fetch result — the
# separate `gh api …/issues/comments/<id> --jq .body` GET is redundant and dropped
# (R2). This retires the INV-46 carve-out (`provider-spec.md`/`invariants.md`
# "GET-comment-id / GET-body reads stay caller-side") that froze these two reads
# in the [INV-91] cutover baseline.
#
# Reads PR_NUMBER / REPO / PR_HEAD_SHA / BOT_LOGIN / WRAPPER_START_TS from the
# environment (all set by the wrapper before the lane). REPO_OWNER/REPO_NAME are
# no longer read here — itp_list_comments (→ `gh issue view --repo "$REPO"`) owns
# the host-side repo scope, same as _fetch_sha_evidence's chp_pr_view.
_stamp_browser_evidence_marker() {
  local marker="<!-- e2e-evidence: complete sha=\"${PR_HEAD_SHA}\" -->"
  # Author predicate: bind to BOT_LOGIN when available, else drop it (the same
  # fallback INV-20 uses when `gh api user` can't introspect the bot identity).
  # Re-expressed over the normalized `.author` (was `.user.login`, [INV-90]).
  local _author_jq=""
  if [[ -n "${BOT_LOGIN:-}" ]]; then
    _author_jq="(.author == \"${BOT_LOGIN}\") and "
  fi
  # Select the newest report comment over the normalized array (spec §3.3):
  # `.created_at`→`.createdAt` (verbatim ISO-8601 UTC string, order-identical `>=`
  # compare), `.body`/`contains()` verbatim. `sort_by(.createdAt // "", .id // 0)
  # | last` — re-sorting the already-ascending array is idempotent ([INV-90]
  # untouched) and adds the monotone REST `id` as the same-second tie-break the
  # #321 verdict poll uses, deterministic rather than relying on the backend's
  # stable-sort alone. `// empty` on both id/body: an empty-array `last` yields
  # `null`, whose `.id`/`.body` accessors also yield `null` — `jq -r` would print
  # a bare `null` as the literal string "null" — `// empty` restores the raw-gh
  # empty-on-no-match contract the numeric/empty guards below depend on.
  local _select_jq="[.[] | select(${_author_jq}(.createdAt >= \"${WRAPPER_START_TS}\") and (.body | contains(\"## E2E Verification Report\")))] | sort_by(.createdAt // \"\", .id // 0) | last"
  local _selected
  _selected=$(itp_list_comments "$PR_NUMBER" 2>/dev/null | jq -c "$_select_jq" 2>/dev/null || true)

  local _comment_id
  _comment_id=$(printf '%s' "$_selected" | jq -r '.id // empty' 2>/dev/null || true)
  if ! [[ "$_comment_id" =~ ^[0-9]+$ ]]; then
    log "INV-46: browser lane posted NO '## E2E Verification Report' comment to stamp — gate fails closed (no marker-only fabrication)."
    return 1
  fi

  # The body comes from the SAME selected element — one verb call, no second
  # id-keyed GET (R2). Idempotent: skip if the SHA marker is already present
  # (e.g. a re-run against the same comment).
  local _body
  _body=$(printf '%s' "$_selected" | jq -r '.body // empty' 2>/dev/null || true)
  if [[ -z "$_body" ]]; then
    log "INV-46: could not read the report comment body (id=${_comment_id}) — gate fails closed."
    return 1
  fi
  if printf '%s' "$_body" | grep -qF "e2e-evidence: complete sha=\"${PR_HEAD_SHA}\""; then
    log "INV-46: report comment (id=${_comment_id}) already carries the SHA marker — idempotent skip."
    return 0
  fi

  # [INV-87]/[INV-46] Stamp the SHA marker. `_new_body` is the FULL report body
  # with the marker appended on its own line (the literal newline embedded via
  # $'...'). On a provider with comment edit-in-place (`edit_comment=1`, GitHub)
  # the byte-identical PATCH leaf moves behind itp_edit_comment (→ `gh api -X
  # PATCH …/issues/comments/<id> -f body=<new_body>`).
  local _new_body="${_body}"$'\n\n'"${marker}"
  local _edit_cap; _edit_cap="$(itp_caps edit_comment 2>/dev/null || true)"
  if [[ "$_edit_cap" == "0" ]]; then
    # Degradation (spec §4.1 edit_comment row): no in-place edit, so post a FRESH
    # comment carrying the SAME `_new_body` — the full report body PLUS the SHA
    # marker — NOT a marker-only comment. `_fetch_sha_evidence` returns the
    # `last` SHA-marked comment's FULL body to the dual-signal gate; a marker-only
    # post would let an append-only provider satisfy the gate with no report,
    # screenshots, or AC evidence attached (the marker-only-fabrication hole
    # [INV-46] explicitly closes). Posting the full body reproduces the same end
    # state as the edit path (a comment carrying report + marker), just as a new
    # comment instead of an in-place edit.
    if itp_post_comment "$PR_NUMBER" "$_new_body" >/dev/null 2>&1; then
      log "INV-46: edit_comment=0 — re-posted the FULL E2E report + SHA marker as a fresh comment (provider lacks edit-in-place)."
      return 0
    fi
    log "INV-46: failed to post the fresh report+marker comment (edit_comment=0) — gate fails closed."
    return 1
  fi
  if itp_edit_comment "$PR_NUMBER" "$_comment_id" "$_new_body" >/dev/null 2>&1; then
    log "INV-46: stamped SHA marker onto the browser E2E report comment (id=${_comment_id})."
    return 0
  fi
  log "INV-46: failed to stamp the SHA marker onto the report comment (id=${_comment_id}) — gate fails closed."
  return 1
}

# ---------------------------------------------------------------------------
# _post_brokered_e2e_report — [INV-79] E2E report broker. The browser lane agent
# WRITES its `## E2E Verification Report` to E2E_REPORT_FILE (a wrapper-set path);
# the WRAPPER (full-write token) posts it on the PR. This matches the verdict-
# artifact broker direction so the report path does not DEPEND on the agent's own
# write capability (though the scoped agent token keeps issues:write, so the
# agent's direct `bash scripts/gh pr comment` remains a working fallback — a
# missed broker write never loses the report).
#
# Idempotent + fail-safe: posts ONLY when E2E_REPORT_FILE is set, exists, and is
# non-empty. A missing/empty file → no post (the agent's direct fallback already
# posted, OR there is genuinely nothing to post) and a 0 return. Reads
# PR_NUMBER / REPO / E2E_REPORT_FILE from the environment. Returns 0 always (the
# downstream SHA-marker stamp + dual-signal gate is the authoritative evidence
# check — this broker is a delivery convenience, never a gate).
_post_brokered_e2e_report() {
  [[ -n "${E2E_REPORT_FILE:-}" ]] || return 0
  [[ -s "${E2E_REPORT_FILE}" ]] || return 0
  local body
  body=$(cat "${E2E_REPORT_FILE}" 2>/dev/null) || return 0
  [[ -n "$body" ]] || return 0

  # Dedupe: if a `## E2E Verification Report` comment already exists in this
  # review's window (the agent took its documented write-FAILED fallback and
  # posted directly), do NOT post again — the wrapper's broker is the primary
  # path, the direct post is the fallback, and we must not duplicate the comment.
  # Window-bounded by WRAPPER_START_TS (the same anchor _stamp_browser_evidence_
  # marker uses); best-effort — a gh failure here just means we proceed to post.
  if [[ -n "${WRAPPER_START_TS:-}" ]]; then
    local _existing
    # [#333/#296] Comment LIST read → the SHIPPED itp_list_comments verb (shape-
    # equivalent, no new verb). The verb emits the normalized [INV-90] array
    # `[{id,author,authorKind,body,createdAt}]`; the dedup `select` stays caller-side.
    # `.created_at` → the normalized `.createdAt` (same ISO-8601 `…Z` string, so the
    # `>=` window compare is order-identical), `.body`/`contains()` verbatim. The
    # select is literal `contains`/`>=` (no `test()`/regex), so moving it from
    # `gh --jq` (RE2) to the system `jq` introduces no engine divergence. `| tail -n1`
    # is KEPT as a zero-cost net: the verb yields one `length` line today, but were a
    # future provider to re-paginate into multi-line output, a bare `length` would
    # feed the numeric guard below a multi-line value → fail-closed → double-post.
    _existing=$(itp_list_comments "$PR_NUMBER" 2>/dev/null \
      | jq -r "[.[] | select((.createdAt >= \"${WRAPPER_START_TS}\") and (.body | contains(\"## E2E Verification Report\")))] | length" \
      2>/dev/null | tail -n1 || true)
    if [[ "$_existing" =~ ^[0-9]+$ ]] && [[ "$_existing" -gt 0 ]]; then
      log "INV-79: an E2E report comment already exists in this review window (agent posted directly) — skipping the brokered post to avoid a duplicate."
      return 0
    fi
  fi

  if chp_pr_comment "$PR_NUMBER" --body "$body" >/dev/null 2>&1; then
    log "INV-79: wrapper brokered the browser E2E report comment onto PR #${PR_NUMBER} (agent wrote ${E2E_REPORT_FILE})."
  else
    log "INV-79: brokered E2E report post failed (non-fatal) — the agent's direct issues:write fallback may already have posted; the SHA-marker stamp + gate remain authoritative."
  fi
  return 0
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

### Step 7: Deliver the E2E report (broker — [INV-79])
WRITE your structured report to the file path in the \`E2E_REPORT_FILE\`
environment variable (\`\$(printenv E2E_REPORT_FILE)\`); the WRAPPER reads that
file and posts it on PR #${PR_NUMBER} for you (the brokered, credential-split
path — your scoped token cannot approve/merge, so report DELIVERY is brokered
through the wrapper, like the verdict artifact). The WRAPPER appends the SHA
evidence marker — you do NOT add it.
ONLY IF writing that file FAILS (e.g. the path is unwritable), fall back to
posting the SAME report directly as a PR comment on #${PR_NUMBER} (NOT the
issue) — your token retains issues:write. Do NOT do both: writing the file is
the primary path and the wrapper handles the post, so a direct post on top
would duplicate the comment. Use this format for the report:

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

If ALL E2E checks pass, exit 0 after writing/posting the report. If ANY check
fails, write/post the report with the failures recorded and exit non-zero — the
wrapper's E2E hard gate will then FAIL the review WITHOUT fanning out the code
reviewers.

IMPORTANT: Work autonomously. Do NOT review code — only run the browser E2E and
deliver the report (write \`\$E2E_REPORT_FILE\` + post as a fallback).
E2E_BROWSER_LANE
}
