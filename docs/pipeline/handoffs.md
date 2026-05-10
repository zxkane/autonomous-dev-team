# Handoff Points and Their Invariants

The pipeline has three actors (dispatcher, dev wrapper, review wrapper) but five places where work is handed off. Bugs in this kind of system live almost exclusively at handoff points — the seams where one actor's output becomes another actor's input.

This file enumerates each handoff, the data carriers (label, comment, PID file, PR), the producer-side and consumer-side invariants, and the failure mode if either side breaks contract.

## The five handoffs

```mermaid
flowchart LR
    M([Maintainer]) -. label autonomous .-> Dis[Dispatcher]
    Dis -. H1 label in-progress<br/>+ session-id from uuidgen .-> DevN[Dev wrapper<br/>mode=new]
    Dis -. H2 label in-progress<br/>+ session-id from comments .-> DevR[Dev wrapper<br/>mode=resume]
    DevN -. H3 label pending-review<br/>+ open PR with #N .-> Dis2[Dispatcher]
    DevR -. H3 label pending-review<br/>+ open PR with #N .-> Dis2
    Dis2 -. H4 label reviewing .-> Rev[Review wrapper]
    Rev -. H5a verdict PASS<br/>+ approved label .-> done([approved])
    Rev -. H5b verdict FAIL<br/>+ label pending-dev .-> Dis3[Dispatcher]
    Dis3 -. H2 .-> DevR
```

| # | Handoff | Producer | Consumer | Carrier |
|---|---|---|---|---|
| **H1** | dispatcher → dev (new) | Dispatcher Step 2 | Dev wrapper, mode=new | `+in-progress` label, dispatched subprocess |
| **H2** | dispatcher → dev (resume) | Dispatcher Step 4 | Dev wrapper, mode=resume | `+in-progress` label, session-id extracted from issue comments |
| **H3** | dev → review | Dev wrapper trap | Dispatcher Step 3 (then Step 3 → review wrapper via H4) | `+pending-review` label, open PR referencing the issue |
| **H4** | dispatcher → review | Dispatcher Step 3 | Review wrapper | `+reviewing` label |
| **H5** | review → dev (send-back) OR review → approved | Review wrapper | Dispatcher Step 4 (FAIL) or terminal (PASS) | `+pending-dev` or `+approved` label, "Review findings:" / "Review PASSED" comment with session-id, optional Reviewed-HEAD trailer |

## H1: dispatcher → dev (new)

**Trigger**: Step 2 finds an issue labeled `autonomous` only, deps resolved.

**Producer-side invariants** (dispatcher must guarantee):

- Atomic `+in-progress` label set BEFORE `nohup` spawn. Otherwise Step 5 in the same tick could probe a non-existent PID file and falsely diagnose DEAD ([INV-09](invariants.md#inv-09-just_dispatched-skip-rule) is the safety net for this; `JUST_DISPATCHED` only protects against the same-tick race, the label ordering protects against an immediately-following tick).
- `JUST_DISPATCHED` includes the issue.
- Dispatch goes through `dispatch-local.sh dev-new`, never directly invokes `autonomous-dev.sh`. The dispatch script is the only place that does `kill_stale_wrapper` (#57), input validation, and pre-creates the log file with 0600.

**Consumer-side invariants** (dev wrapper must tolerate):

- Wrapper might find no PID file when it tries to `acquire_pid_guard` — that's fine, `acquire_pid_guard` writes the PID file from scratch.
- Wrapper might find the issue already labeled `pending-review` or `pending-dev` if the dispatcher's previous tick was racing — wrapper trap will overwrite cleanly via `−in-progress +<target>` calls (the `−in-progress` is a no-op when already absent).

**Race window**: between Step 2's `nohup` and Step 5's PID probe in a *later* tick (the same-tick case is handled by `JUST_DISPATCHED`). The wrapper has ~5 minutes of cron interval to write its PID file before being mistaken for DEAD; in practice the file is written within ~50ms of `nohup`.

**Failure modes**:

- Wrapper fails to start *after* arg parsing (e.g. `gh-with-token-refresh.sh` can't find real `gh` per #92, missing required env, auth setup failure) → trap posts `Agent Session Report (Dev) ... Mode: startup-failure` with non-zero exit code AND flips `in-progress` → `pending-dev`. The dispatcher's `count_agent_failures` counter sees it next tick (correct retry counting), and the underlying error is visible on the issue itself instead of buried in `/tmp/agent-*.log`. The dispatcher Step 5b is no longer the primary recovery path for this class of failure — though it remains the safety net for the residual case below.
- Wrapper fails *before* arg parsing (e.g. malformed `--issue` arg before `ISSUE_NUMBER` is set) → trap stays silent (nowhere to post) → next-tick Step 5b sees DEAD-no-PR → bumps the dispatcher-crash counter → eventually `stalled`.
- `dispatch-local.sh` errors out before `nohup` (e.g. `kill_stale_wrapper` refuses because a previous wrapper survived SIGKILL) → returns exit 1 to dispatcher. Dispatcher Step 2 currently doesn't check the return code — issue is already labeled `in-progress` but no wrapper is running. Step 5b next tick sees DEAD-no-PR, recovers. Tracked as a soft-bug; not worth a synchronous check given the recovery path works.

## H2: dispatcher → dev (resume)

**Trigger**: Step 4 finds an issue labeled `pending-dev` with retries below `MAX_RETRIES`.

**Producer-side invariants**:

- Atomic label swap `−pending-dev +in-progress` (single `gh issue edit` call).
- Session-id extracted from the most recent comment matching `Dev Session ID: \`<id>\`` ([INV-03](invariants.md#inv-03-dev-session-report-comment-format)). Crucially, this regex must NOT match `Review Session ID:` — both share the word "Session", so the prefix `Dev` is what disambiguates.
- Retry counter calculated correctly: only count failure events after the most recent `Marking as stalled` comment ([INV-05](invariants.md#inv-05-retry-counter-cutoff-rule)).
- Dispatch via `dispatch-local.sh dev-resume <issue> <session-id>`; the dispatch script validates the session-id matches `[a-zA-Z0-9_-]+`.
- **Future invariant** [INV-12](invariants.md#inv-12-resume-only-against-unfinished-sessions): query session terminal state and skip if `terminal_reason=completed`. Not yet enforced; tracked in [#59](https://github.com/zxkane/autonomous-dev-team/issues/59).

**Consumer-side invariants**:

- Wrapper accepts `--mode resume --session <id>` and tolerates an empty session-id by falling back to `--mode new` (logs WARN). This handles the dispatcher edge case where Step 4b couldn't extract a session.
- Wrapper's resume path falls back to a fresh session if `claude --resume` exits non-zero — defense against sessions the CLI no longer recognizes.

**Race window**: same as H1.

**Failure modes**:

- Resume against a `completed` session hangs indefinitely (#59). Until [INV-12](invariants.md#inv-12-resume-only-against-unfinished-sessions) is enforced, the only mitigation is the future wall-clock timeout ([INV-13](invariants.md#inv-13-wall-clock-cap-on-agent-invocations), [#60](https://github.com/zxkane/autonomous-dev-team/issues/60)) plus the dispatcher's Step 5a SIGTERM after 5 min of CI-green idleness. Step 5a covers the "completed-session-hang-after-PR-already-up" subset cleanly; it does NOT cover hangs that occur before any PR exists.

## H3: dev → review

**Trigger**: dev wrapper exits 0 with a PR referencing `#N`. Trap labels the issue `−in-progress +pending-review`.

**Producer-side invariants**:

- Wrapper trap MUST verify a PR exists before setting `pending-review`. An exit-0 with no PR routes to `pending-dev` instead — see [`dev-agent-flow.md` § Trap contract details](dev-agent-flow.md#trap-contract-details) and [#40](https://github.com/zxkane/autonomous-dev-team/issues/40).
- Trap MUST post the Agent Session Report comment with format described in [INV-03](invariants.md#inv-03-dev-session-report-comment-format) — the dispatcher's Step 4 retry counter parses this format.
- Trap MUST be idempotent against label state ([INV-08](invariants.md#inv-08-wrapper-exit-trap-is-idempotent-against-label-state)): even if the dispatcher's Step 5a already moved the issue to `pending-review` (SIGTERM-mid-trap race), the trap's redundant `+pending-review` is a no-op.

**Consumer-side invariants** (dispatcher Step 3 must tolerate):

- The PR returned by `gh pr list` may have a body that mentions multiple issues (`Closes #1, fixes #2`). The body-match regex (`#N[^0-9]` OR `#N$`) must not over-match (e.g. `#10` for issue 1).
- The Reviewed-HEAD trailer may not yet exist (this is the first review). Step 5b's empty-trailer fallthrough routes to `pending-review` ([INV-07](invariants.md#inv-07-empty-reviewed-head-trailer-routes-to-pending-review)) — same as the new-commits case.

**Race window**: Step 5a's SIGTERM path is the most concurrent case. Dispatcher and wrapper trap both edit labels in a ~few-second window. Both write `pending-review`, both post a comment. Worst case: 2 comments and 2 redundant label edits per ~1% of transitions — bounded and self-healing.

**Failure modes**:

- Wrapper trap fails to post Session Report (token expired, network) → next-tick dispatcher Step 4 cannot find a `Dev Session ID:` to resume from → falls back to new session via the wrapper's mode-normalization. Some context is lost but the pipeline progresses.
- Wrapper trap fails to edit labels (token, perm) → issue stuck in `in-progress`, no PR-ready trailer to drive next decision → next-tick Step 5b probes PID, finds DEAD, sees the PR, routes to `pending-review` correctly. The wrapper's trap is a fast-path; Step 5b is the slow safety net.

## H4: dispatcher → review

**Trigger**: Step 3 finds an issue labeled `autonomous` AND `pending-review` AND NOT `reviewing`.

**Producer-side invariants**:

- Atomic label swap `−pending-review +reviewing`.
- Dispatch via `dispatch-local.sh review <issue>`.
- `JUST_DISPATCHED` includes the issue.

**Consumer-side invariants**:

- Review wrapper must run PR discovery (3 fallback methods) — the issue may have multiple PRs, or the PR body may not yet say `Closes #N`. If discovery fails, the wrapper exits with `−reviewing +pending-dev` and a clear comment.
- Review wrapper must filter verdict comments by session-id ([anti-spoofing defense](review-agent-flow.md#verdict-polling)): another commenter could write "Review PASSED" verbatim.

**Race window**: Step 5b's DEAD-reviewing path can race with the wrapper's trap. Wrapper trap clears `reviewing`; if dispatcher's probe ran before that, dispatcher also clears `reviewing` and adds `pending-dev`. Both writes converge.

**Failure modes**:

- Concurrent manual `/q review` + auto-merge → wrapper finds `PR.state != OPEN` at approve time → silent `−reviewing` exit ([state-machine § concurrent reviews](state-machine.md#concurrent-reviews-on-the-same-pr), [#31](https://github.com/zxkane/autonomous-dev-team/issues/31)).

## H5: review → dev (send-back) OR review → approved

Two sub-handoffs depending on verdict:

### H5a: review → approved (verdict PASS)

**Producer-side invariants**:

- Verdict comment posted on the **issue** (not PR), starts with "Review PASSED", contains the session-id trailer.
- `gh pr review --approve` succeeded (else fall-back path: `+approved` label but manual notification).
- Reviewed-HEAD trailer posted (best-effort) so future Step 5b SHA-comparison works.
- Auto-close path: removes `autonomous` AND `reviewing`, adds `approved`, closes issue with reason `completed`, merges PR with `--squash --delete-branch`.
- `no-auto-close` path: keeps `autonomous`, removes `reviewing`, adds `approved`, leaves PR open. Maintainer merges manually.

**Consumer-side invariants**: the dispatcher does not look at issues labeled `approved` — it's a terminal state. No active consumer.

**Failure modes**:

- Auto-merge fails (CI red, branch protection) → wrapper logs WARNING and posts "auto-merge failed, please merge manually". Issue stays open in `approved`. Maintainer needs to act.
- Approval succeeds but issue close fails → labels are correct (`+approved -reviewing -autonomous`) but issue is open. Cosmetic; no pipeline impact.

### H5b: review → dev (verdict FAIL)

**Producer-side invariants**:

- Verdict comment "Review findings:" with numbered remediation list, ending with session-id trailer.
- For each PR inline review comment the agent wrote, the resume prompt picks them up via `gh api repos/.../pulls/N/comments`. The dev resume prompt instructs the agent to fix-then-reply-then-resolve each thread.
- Reviewed-HEAD trailer posted (so when dev pushes new commits, Step 5b sees a different headRefOid and routes back to `pending-review`; if dev pushes nothing, Step 5b routes to `pending-dev` — a "no progress" loop that the dispatcher detects via the retry counter).
- `−reviewing +pending-dev`.

**Consumer-side invariants** (dispatcher Step 4 must tolerate):

- The "Review findings:" comment is what the dev resume prompt highlights — the dev agent needs it. The wrapper does NOT count it as a dev failure ([INV-06](invariants.md#inv-06-crashed--process-not-found-keyword-contract): only `Agent Session Report (Dev)` exit-non-zero comments and dispatcher crash comments count).
- The session-id in the verdict trailer is the *review* session-id, not the dev session-id. The dispatcher's Step 4b session-id extraction explicitly anchors on `Dev Session ID:`, NOT `Review Session:` — see [INV-03](invariants.md#inv-03-dev-session-report-comment-format).

**Failure modes**:

- Trailer post fails → empty-trailer fallthrough. Next-tick Step 5b can't compare SHAs. If dev pushes new commits, Step 5b goes to `pending-review` (correct). If dev pushes nothing and exits with no PR change, Step 5b sees PR exists, can't read trailer, routes to `pending-review` ([INV-07](invariants.md#inv-07-empty-reviewed-head-trailer-routes-to-pending-review)) — review re-runs on identical code, posts the same findings, and wastes Sonnet quota. This is the documented downside of the empty-trailer-fallthrough; operationally it surfaces as the same review verdict in repeated cycles.

## Cross-cutting concerns

These don't belong to any single handoff but cut across multiple:

### Wrapper-trap-vs-dispatcher race (H3 / H4 / H5)

Whenever the dispatcher's Step 5 acts on the same issue as a still-running wrapper's trap, label edits race. The contract: wrappers ALWAYS use `−from +to` in single `gh issue edit` calls, never sequential add-then-remove. The dispatcher does the same.

**Step 5b case (DEAD)**: the wrapper trap has already finished by the time Step 5b probes the PID. So Step 5b sees the post-trap state. No live race.

**Step 5a case (ALIVE+PR ready ⇒ SIGTERM)**: a genuine race with non-deterministic outcome — see [INV-15](invariants.md#inv-15-step-5a-sigterm-race-is-non-deterministic). The dispatcher and trap target **different** final states (`pending-review` vs `pending-dev`). The race is non-fatal — the PR is preserved either way and the next dispatcher tick recovers — but review can be delayed by one tick. This is a known imperfection captured in the invariant; fix is out of scope for the docs PR.

### Trailer empty fallthrough (H3 / H5b)

[INV-07](invariants.md#inv-07-empty-reviewed-head-trailer-routes-to-pending-review) routes empty `Reviewed HEAD` to `pending-review`. Two distinct causes converge here: review-never-ran-yet (the safe first-review case) and trailer-post-failed (a transient bug). Operationally indistinguishable from the dispatcher's view; only the review log can tell them apart.

### Resume-on-completed-session hang (H2)

[INV-12](invariants.md#inv-12-resume-only-against-unfinished-sessions) — not yet enforced; tracked in #59. Combined with the future wall-clock timeout ([INV-13](invariants.md#inv-13-wall-clock-cap-on-agent-invocations), [#60](https://github.com/zxkane/autonomous-dev-team/issues/60)) provides defense in depth.

## Cross-references

- [`state-machine.md`](state-machine.md) — the label edges these handoffs traverse.
- [`dispatcher-flow.md`](dispatcher-flow.md) — what the dispatcher does at each handoff.
- [`dev-agent-flow.md`](dev-agent-flow.md), [`review-agent-flow.md`](review-agent-flow.md) — what the wrappers do.
- [`invariants.md`](invariants.md) — the rules each side must uphold.
