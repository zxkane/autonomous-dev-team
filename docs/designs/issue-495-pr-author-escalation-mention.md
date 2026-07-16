# Design: resolve a responsible human per PR for escalation mentions (issue #495)

## Problem

Human-in-the-loop escalation comments ("marking stalled", "please investigate", "please
approve and merge") unconditionally `@`-mention `${REPO_OWNER}`. On GitHub, `REPO_OWNER` is
usually an individual account, so this is benign. On GitLab, `REPO_OWNER` is the project's
*group* namespace — mentioning it notifies **every member of the group** on every stall.

The obvious fix, "mention the PR author instead," is inverted for this pipeline: an
autonomous PR's author is normally the dev-agent **bot** itself (`app/...` on GitHub, a
service account on GitLab), so a naive author-mention notifies nobody — strictly worse than
the group blast.

## Decision

Add a resolver, `resolve_pr_author_mention <PR_NUMBER>`, that is bot-detection-FIRST: it
reads the PR's author via the provider seam and mentions that human only when the author is
demonstrably NOT a bot (structural rules: GitHub `app/` prefix, `[bot]` suffix, GitLab
service-account regex, or an exact match against the wrapper's resolved `BOT_LOGIN` /
operator-configured `DEV_BOT_LOGIN`). Every other case — bot author, null/empty author,
malformed provider output, non-numeric PR arg, or a leaf failure — falls back through the
new `HUMAN_ESCALATION_LOGIN` conf var to `REPO_OWNER`.

`author` becomes the 15th §3.2.1 pr_view vocabulary member on both providers, deliberately
**pr_view-only**: `chp_pr_list`/`chp_find_pr_for_issue` keep rejecting it on both hosts (a
provider-parity pin — GitHub already has two separate vocabulary constants for this split;
GitLab's single shared constant gets an explicit per-verb rejection instead of a second
constant, since only one verb needs the new field).

Call sites split into three classes, enumerated (not grep-converted, since two of the
grep-matched sites are prompt-heredoc text, not comment bodies):

1. **PR-scoped stall/escalation reports** (a PR is already resolved) → call
   `resolve_pr_author_mention <PR_NUMBER>`.
2. **Maintainer-only sites** (approval-failed, no-auto-close) → call the sibling
   `resolve_operator_mention` (no args), never `resolve_pr_author_mention` — a PR author
   cannot approve or merge their own PR.
3. **Operator-only sites** (no PR guaranteed to exist — MAX_RETRIES, liveness notices, the
   class-level park backstop) → also call `resolve_operator_mention`, no PR-author resolver
   call.

`resolve_operator_mention` (round 4 finding #1) is a thin public wrapper over the same
`_rpam_fallback` chain `resolve_pr_author_mention` falls through to — added because the
2 maintainer-only + 6 operator-only sites originally interpolated
`@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}` directly, bypassing the malformed-token
validation the resolver's own fallback path already applies.

The 2 genuine prompt-text literals inside `build_review_prompt` are left byte-unchanged.

## Review-round follow-ups (this PR)

Findings from three rounds of codex review, folded into the implementation rather than
tracked as separate issues (all are hardening of the same resolver/propagation surface):

| Round | Finding | Fix |
|---|---|---|
| 1 | `BOT_LOGIN` is never set in the dispatcher's own process (only inside `autonomous-review.sh`), so a plain-login dev-agent identity slips past bot-detection on the `lib-dispatch.sh` call path; `HUMAN_ESCALATION_LOGIN`/`DEV_BOT_LOGIN` were dropped for inline (`remote-aws-ssm`) projects in `dispatcher-multi-tick.sh` | New `DEV_BOT_LOGIN` conf var (dispatcher-side counterpart to `BOT_LOGIN`); `tick_inline_project` re-exports both vars into the inline subshell |
| 1 (self-review) | The round-1 export fix could itself leak an AMBIENT `HUMAN_ESCALATION_LOGIN`/`DEV_BOT_LOGIN` into an inline project whose own block omits both | `tick_inline_project` `unset`s both before `eval`-ing the inline block (mirrors the pre-existing `ISSUE_FILTER`/`ISSUE_SCAN_LIMIT` guard, issue #436) |
| 2 | A malformed `.author` JSON shape (e.g. `{"login":"evil"}`) or a whitespace/newline-containing author string would be echoed verbatim into the mention, breaking the "exactly one `@<token>`" contract | Resolver requires a single-token JSON *string* author; anything else falls back |
| 3 | The round-1 ambient-leak fix only covered the INLINE branch of the per-project loop — the LOCAL path-entry branch had no `unset` at all | Same `unset HUMAN_ESCALATION_LOGIN DEV_BOT_LOGIN` added immediately before the local-path branch's `AUTONOMOUS_CONF=... bash dispatcher-tick.sh` invocation |
| 3 | `_rpam_fallback` prints a configured `HUMAN_ESCALATION_LOGIN` verbatim — a value containing whitespace or an embedded `@` breaks the same single-token contract from the config side | `_rpam_fallback` validates the configured value (`_rpam_malformed_mention_token`) before using it; a malformed value falls through to `REPO_OWNER` instead |
| 3 | Missing design canvas + PR template Pipeline Docs section | This doc; PR body updated to the repo's template shape |
| 4 | The 8 maintainer-/operator-target sites interpolated `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}` directly, bypassing `_rpam_fallback`'s malformed-token validation entirely — a value containing whitespace or an embedded `@` broke the exactly-one-token contract at these 8 sites even though the resolver's own fallback path (round 3 finding) was already hardened against it | New `resolve_operator_mention` (no args, `lib-review-resolve-author.sh`) — a thin public wrapper over the SAME `_rpam_fallback` chain; all 8 sites now call it instead of interpolating the raw conf var |
| 4 | PR #499's description is missing the repo's PR template's Pipeline Docs declaration/Test Plan checklist | **Not resolved by this dev round** — the scoped agent token has `pull_requests:read`, not `pull_requests:write` (`gh pr edit`/`PATCH .../pulls/N` both 403 "Resource not accessible by integration"); there is no [INV-79] broker for editing an EXISTING PR's body (only `drain_agent_pr_create` for the initial create). Flagged for a maintainer to edit the PR body directly, or as a follow-up broker if this recurs. |
| 5 | `resolve_pr_author_mention`'s author-string validation only rejected embedded whitespace (`*[[:space:]]*`), not an embedded `@` — a malformed `chp_pr_view` projection like `{"author":"alice@evil"}` would render `@alice@evil`, a second/malformed mention token, instead of falling back | Swapped the ad hoc whitespace-only `case` guard for the existing `_rpam_malformed_mention_token` helper (already used to validate `HUMAN_ESCALATION_LOGIN`), which rejects both whitespace and embedded `@` |
| 6 | The unit suite only covered a GitLab `author`-object payload for `chp_gitlab_pr_view`; it never asserted the `"author": null` degraded-payload normalization that GitHub's leaf already pins (TC-PAEM-002) — a regression in the GitLab leaf's `// null` fallback would not be caught | Added TC-PAEM-005b: a GitLab MR-view stub with `"author": null` asserts `{"author":null}`, rc 0 — mirrors TC-PAEM-002 on the GitHub leaf |

The round-1 `DEV_BOT_LOGIN`-unset gap (a plain-login bot author with no configured
`DEV_BOT_LOGIN`) remains a documented residual — closing it would require a raw `gh api
user`/GitLab `/user` call inside the dispatcher's own process, which both violates this
lib's provider-neutral "`chp_pr_view` is the only PR-read primitive" contract ([INV-87]) and
would collide with several verdict-authentication invariants that depend on `BOT_LOGIN`
staying permanently unset in `lib-dispatch.sh`'s process. Operators close it by setting
`DEV_BOT_LOGIN` once in `autonomous.conf`.

## Out of scope

Changing which events escalate, or comment wording beyond the mention target.
Account-status (deleted/suspended) detection. Mentioning the ISSUE author. Broad `*bot*`
substring matching (false positives on human logins).

## Test plan

See `docs/test-cases/pr-author-escalation-mention.md` — resolver bot-detection/fallback
matrix, call-site source-shape pins, and the multi-project propagation/ambient-leak table
(`tests/unit/test-pr-author-escalation-mention.sh`,
`tests/unit/test-multi-tick-inline-projects.sh`,
`tests/unit/test-handle-completed-session-routing.sh`).
