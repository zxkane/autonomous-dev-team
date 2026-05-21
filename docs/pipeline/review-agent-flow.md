# Review-Agent Wrapper Flow

The review-agent wrapper is `skills/autonomous-dispatcher/scripts/autonomous-review.sh`. The dispatcher launches it via `dispatch-local.sh review <issue>`. The wrapper finds the PR linked to the issue, runs the underlying agent against it, parses the agent's verdict from issue comments, and either approves+merges (PASS) or sends the issue back to dev (FAIL).

The wrapper is the **producer** for two of the five [handoffs](handoffs.md) (review → approved/merged, review → pending-dev) and the **consumer** for one (dispatcher → review).

The default model is Sonnet (vs Opus for dev) — review is checklist-driven and benefits less from the larger model, and using a different model class avoids quota contention with the more expensive dev sessions.

## Lifecycle

```mermaid
sequenceDiagram
    participant D as dispatch-local.sh
    participant W as autonomous-review.sh
    participant L as lib-agent.sh
    participant A as claude / codex / gemini / kiro / opencode
    participant GH as GitHub API

    D->>D: kill_stale_wrapper(PID_FILE)
    D->>W: nohup autonomous-review.sh --issue N
    W->>W: setup_github_auth
    W->>W: acquire_pid_guard(PID_FILE)
    W->>GH: find PR linked to issue (3 fallback methods)
    alt no PR found
        W->>GH: comment 'Review failed - no PR found'
        W->>GH: remove reviewing, add pending-dev
        W-->>D: exit 1
    end
    W->>GH: extract preview URL (if E2E_ENABLED)
    W->>W: build review prompt (mergeability, drift, checklist, decision)
    W->>L: run_agent
    L->>A: claude --session-id ... --model sonnet -p PROMPT
    A->>GH: post verdict comment ('Review PASSED' or 'Review findings')
    A-->>L: agent exits
    W->>GH: poll for verdict comment (6 attempts, 5s each, actor + window + trailer)
    W->>GH: post 'Reviewed HEAD' trailer (if verdict and SHA known)
    alt verdict PASS
        W->>GH: gh pr view --json state (re-check OPEN)
        W->>GH: gh pr review --approve
        opt no-auto-close NOT set
            W->>GH: gh pr merge --squash --delete-branch
            alt merge succeeded
                W->>GH: remove autonomous and reviewing, add approved
                Note over W,GH: GitHub auto-closes issue via 'Closes #N' (INV-33; wrapper does NOT call gh issue close)
            else merge failed (INV-33)
                W->>GH: gh pr comment 'Auto-merge failed: ... Re-dispatching dev'
                W->>GH: remove reviewing, add pending-dev (autonomous KEPT)
            end
        end
        opt no-auto-close set
            W->>GH: remove reviewing, add approved (autonomous KEPT)
        end
    else verdict FAIL or missing
        W->>GH: remove reviewing, add pending-dev
    end
    W->>W: rm -f PID_FILE and cleanup_github_auth
```

## Spawn, PID guard, auth

Same pattern as the dev wrapper — see [`dev-agent-flow.md`](dev-agent-flow.md#spawn-in-dispatch-localsh) — except:

- PID file: `${PID_DIR}/review-<N>.pid` ([INV-01](invariants.md#inv-01-pid-file-naming)) — `${PID_DIR}` resolved by `lib-config.sh::pid_dir_for_project`.
- Auth: review-agent app mode uses `REVIEW_AGENT_APP_ID` / `REVIEW_AGENT_APP_PEM` (separate App identity from dev so reviewer comments are attributed correctly).

## PR discovery (3 fallback methods)

1. **Body reference**: `gh pr list --state open --json number,body` and select the one whose body matches `#N` (with a non-digit boundary so `#1` doesn't match `#123`).
2. **Comment-mention extract**: scan issue comments for `(?:PR|pull)[/ #]*<digits>`.
3. **Search**: `gh pr list --search "issue N"` as a last resort.

If all three fail → comment "Review failed: no PR found linked to this issue. Please ensure the PR description contains 'Closes #N'." → `−reviewing +pending-dev` → exit 1.

This is one of the five legitimate ways the wrapper can transition to `pending-dev` even though the agent never ran. The dispatcher's Step 4a retry counter does NOT count this as a dev-failure — only `Agent Session Report (Dev)` comments and the dispatcher's own crash regex feed the counter.

## Preview URL extraction (E2E only)

Only relevant when `E2E_ENABLED=true` AND `E2E_PREVIEW_URL_PATTERN` is configured. The wrapper builds a URL from the pattern (replacing `{N}` with the PR number) and also scans PR comments for the most recent comment containing "Preview" + an `https://` URL. Comment-extracted URL takes priority (it's specific to the actual deploy).

If E2E is enabled but preview URL extraction yields nothing, the agent's review prompt receives `Preview URL: NOT_FOUND`, and the agent is instructed to FAIL the review with "E2E verification failed: PR preview URL not found."

## Prompt construction

The prompt encodes the entire review procedure as numbered steps. The wrapper does NOT execute any of those steps itself — they're all instructions to the underlying agent. The wrapper's job is to construct the prompt, kick off the agent, and parse the verdict.

Major prompt sections:

| Section | Purpose |
|---|---|
| **Step 0: merge-conflict resolution** | Mandatory pre-review. `gh pr view --json mergeable` ⇒ proceed (`MERGEABLE`), rebase (`CONFLICTING`), wait+retry (`UNKNOWN`). On rebase failure the agent FAILs with "[BLOCKING] Merge conflict with main" and step-by-step rebase instructions. |
| **Step 0.5: requirement drift detection** | Read all issue comments before reading the PR diff. Find scope changes posted after implementation began. Drift ⇒ FAIL with "[BLOCKING] Requirement drift". |
| **Review checklist** | Process compliance, code quality, testing, infra. The Kiro path skips `code-simplifier` / `pr-review` items since Kiro doesn't support those. |
| **Acceptance criteria verification** | For each `## Acceptance Criteria` checkbox in the issue body, verify against PR code/tests/build then mark via `bash scripts/mark-issue-checkbox.sh`. ALL must be checked before approving. |
| **Amazon Q Developer trigger** | Mandatory bot-review trigger. Q ignores `/q review` from bot accounts ⇒ wrapper instructs the agent to use `bash scripts/gh-as-user.sh pr comment N --body "/q review"`. Poll up to 3 min for the bot to respond. |
| **E2E verification (if enabled)** | Chrome DevTools MCP procedure: navigate, login, execute happy-path + feature test cases, screenshot+upload each, post structured E2E report on PR. |
| **Decision** | Single line: PASS ⇒ post "Review PASSED ... Review Session: \`<id>\`" on the **issue** (not PR). FAIL ⇒ post "Review findings: ..." with numbered remediation list, ending with the same session-id trailer. |

The session-id trailer is the wrapper's only way to identify which comment is its own verdict — see [Verdict polling](#verdict-polling) below.

## Verdict polling

After the agent exits, the wrapper polls issue comments up to 6 times (5s interval = 30s window) looking for a comment that satisfies all applicable predicates:

- Body matches a verdict phrasing (case-insensitive). The supported set was broadened in #95 to handle agent phrasing drift:
  - **Pass-side**: `Review PASSED`, `Review APPROVED`, `APPROVED FOR MERGE`, `LGTM`, `Review PASS`.
  - **Fail-side**: `Review findings:`, `Review FAILED`, `Review REJECTED`, `Changes requested`.
- Authenticity binding — three layers, all required (primary path):
  - **Actor**: `author.login == BOT_LOGIN`. The wrapper resolves `BOT_LOGIN` once at startup via `gh api user --jq .login`. In `GH_AUTH_MODE=app` the dev and review wrappers authenticate as distinct GitHub Apps, so the actor predicate alone separates them.
  - **Time window**: `createdAt >= WRAPPER_START_TS`. Captured before `run_agent` in ISO-8601 UTC. Excludes stale verdict comments left by a prior tick.
  - **Body trailer presence**: body matches `/Review Session/`. Note: the trailer's UUID is NOT bound to the wrapper's `SESSION_ID` — only the trailer's presence is checked. This eliminates a long-standing brittleness where the agent occasionally rewrote the UUID and broke the regex match. The trailer requirement is load-bearing in `GH_AUTH_MODE=token`, where dev and review wrappers share `BOT_LOGIN`: only the review agent's prompt instructs it to emit `Review Session:`, so the trailer excludes the dev agent's status comments that contain a verdict keyword as quoted history.

Fallback path: if `gh api user` fails at startup (returns empty, errors out, or returns the literal string `"null"` from a misconfigured GitHub App), `BOT_LOGIN` is treated as unset and the predicate becomes `createdAt >= WRAPPER_START_TS AND body matches Review Session.*<SESSION_ID>`. This restores the prior brittleness (agent must echo the wrapper's UUID) only on the rare path where actor binding is unavailable.

If polling completes without finding a verdict comment, the wrapper proceeds to the FAIL branch (no false-positive PASS).

### Pass-vs-fail classification

Once polling finds a candidate comment, the wrapper applies a two-step classification (#95 — was previously a brittle `head -1 | grep -qi "^Review PASSED"` check that missed "APPROVED FOR MERGE" and similar drift):

1. **FAIL pattern first** (`Review FAILED|Review REJECTED|Review findings:|Changes requested`) — if any matches, classify as FAIL. Conservative on ambiguity: a comment containing both "LGTM" and "Review findings:" routes to FAIL since the agent flagged at least one issue.
2. **PASS pattern next** (`Review PASSED|Review APPROVED|APPROVED FOR MERGE|LGTM|Review PASS`) — if any matches and no FAIL phrasing did, classify as PASS.
3. Otherwise FAIL by default.

The classification scans the entire body, not just the first line, because some agents emit a heading (`## Review Verdict`) on line 1 and the verdict on line 2.

## Reviewed HEAD trailer

Posted as a separate comment, exactly once, only when:

- A verdict comment was found in polling AND
- `PR_HEAD_SHA` (captured at prompt-build time) is non-empty.

Format ([INV-04](invariants.md#inv-04-reviewed-head-trailer-format)):
```
Reviewed HEAD: `<sha>` (issue #N, session `<id>`)
```

The dispatcher's Step 5b reads the most recent trailer matching `Reviewed HEAD: \`<sha>\`` and compares it to the current `PR.headRefOid`. If they match, the dispatcher sends the issue back to `pending-dev` ("no new commits since last review") instead of bouncing it through review again — see [`dispatcher-flow.md` § Step 5b in-progress](dispatcher-flow.md#dead--in-progress) and [#53](https://github.com/zxkane/autonomous-dev-team/issues/53).

If the trailer post fails (token expiry, 403, rate limit), the wrapper logs `WARNING: Failed to post Reviewed HEAD trailer` and continues — the failed trailer means the dispatcher cannot detect SHA-match, but the empty-trailer fallthrough routes to `pending-review` ([INV-07](invariants.md#inv-07-empty-reviewed-head-trailer-routes-to-pending-review)) which is the safe default.

## Verdict = PASS path

```
1. Re-check PR state: gh pr view --json state
   if state != "OPEN": skip approve+merge silently, just remove `reviewing` and exit 0
2. refresh_token_env (token may have expired during the review)
3. gh pr review --approve --body "All acceptance criteria verified. ..."
   if approve fails (permission issue):
     comment "Review PASSED but formal PR approval failed... please approve and merge manually"
     −reviewing +approved
     exit 0
4. Read no-auto-close label
   if no-auto-close set:
     comment "Review PASSED — this issue has the 'no-auto-close' label..."
     −reviewing +approved (autonomous and no-auto-close kept)
   else (auto-merge path):
     MERGE_OUT=$(gh pr merge --squash --delete-branch 2>&1); MERGE_RC=$?
     if MERGE_RC == 0:
       −autonomous −reviewing +approved
       (issue auto-closes via GitHub's `Closes #N` resolution — wrapper does NOT call `gh issue close`, INV-33)
     else (auto-merge failed — INV-33):
       PR comment "Auto-merge failed: <stderr-excerpt>. Re-dispatching dev agent to rebase onto main."
       −reviewing +pending-dev (autonomous retained)
       (next dispatcher tick re-dispatches dev; dev resume detects the marker and rebases first)
```

### Auto-merge failure → dev re-dispatch (INV-33)

When `gh pr merge` returns non-zero, the wrapper:

1. Captures `MERGE_OUT` (combined stdout+stderr, truncated to 500 chars for the comment).
2. Posts a comment on the **PR** (not the issue) with prefix `Auto-merge failed:` followed by the captured excerpt and the directive `Re-dispatching dev agent to rebase onto main.`
3. Does NOT call `gh issue close`. Does NOT add `+approved`. Does NOT remove `autonomous` (the dispatcher's `list_pending_dev` selector gates on `autonomous`).
4. Edits the issue: `−reviewing +pending-dev`.

The dev wrapper's resume branch detects the marker by querying PR-issue comments for one whose body starts with `Auto-merge failed:`, and prepends a `## Pre-implementation: rebase` section to the resume prompt instructing `git fetch origin && git rebase origin/main && git push --force-with-lease`. Once the rebase succeeds, the dev wrapper trap transitions back to `+pending-review`, the next dispatcher tick re-dispatches review, and the merge succeeds — at which point GitHub closes the issue via the PR's `Closes #N` keyword.

If the rebase has unresolvable conflicts, the dev agent posts a `needs human` comment and exits cleanly. The dispatcher's MAX_RETRIES gate eventually transitions the issue to `stalled` if the loop fails to converge.

### Approval guard (`PR.state != OPEN`)

A maintainer running `/q review` plus a manual `gh pr merge` while the autonomous review wrapper is in flight can cause the PR to be merged before the wrapper reaches step 3. Without the guard, `gh pr review --approve` against a closed PR would fail noisily and the wrapper would fall into the approval-failure branch — incorrect, since the PR was already approved+merged by the human. The guard short-circuits to a silent `−reviewing` (no add) and exit 0. See [`state-machine.md` § Concurrent reviews on the same PR](state-machine.md#concurrent-reviews-on-the-same-pr) and [#31](https://github.com/zxkane/autonomous-dev-team/issues/31).

## Verdict = FAIL or missing path

```
1. If agent exit ≠ 0 AND no verdict comment was found:
     post "Review process encountered an error (agent exit code: N). Moving back to development for investigation."
   (This is the only fallback comment; if a verdict was posted but agent exited non-zero, the verdict already says everything.)
2. −reviewing +pending-dev
```

The next dispatcher tick's Step 4 will pick the issue up. Crucially, this `pending-dev` does NOT count toward the dispatcher's retry counter — only `Agent Session Report (Dev)` failures and the dispatcher's own crash-regex matches do ([INV-05](invariants.md#inv-05-retry-counter-cutoff-rule), [INV-06](invariants.md#inv-06-crashed--process-not-found-keyword-contract)).

## Exit trap (`cleanup`)

Different from the dev wrapper's trap — this one's contract is **only** to handle the case where the wrapper crashed *before* the result-parsing block ran. The trap uses `RESULT_PARSED=true` (set on the last line of the script) as the signal that the verdict-handling code already updated labels and the trap should do nothing label-related.

```mermaid
flowchart TD
    enter([trap fires<br/>exit_code captured]) --> rm_pid[rm -f PID_FILE]
    rm_pid --> parsed{RESULT_PARSED?}
    parsed -- true --> auth_done[cleanup_github_auth]
    auth_done --> done([exit])

    parsed -- false --> exit_branch{exit_code != 0?}
    exit_branch -- no --> auth_done
    exit_branch -- yes --> refresh[refresh GH App token]
    refresh --> crash_comment[comment 'Review process crashed exit N']
    crash_comment --> to_dev[remove reviewing<br/>add pending-dev]
    to_dev --> auth_done
```

This means if the script exits 0 (normal completion) but `RESULT_PARSED` was never set (logic bug), the trap silently leaves labels alone — defense-in-depth against a future refactor that forgets to set the flag would manifest as "issue stuck in `reviewing`" rather than "issue corrupted to `pending-dev` for no reason".

## Cross-references

- [`dispatcher-flow.md`](dispatcher-flow.md) — Step 3 is the producer side of the dispatcher → review handoff.
- [`dev-agent-flow.md`](dev-agent-flow.md) — the consumer of the `pending-dev` label this wrapper sets on FAIL.
- [`handoffs.md`](handoffs.md) — invariants for review → approved and review → pending-dev.
- [`invariants.md`](invariants.md) — INV-01, INV-04, INV-05, INV-06, INV-07, INV-08 are all referenced here.
