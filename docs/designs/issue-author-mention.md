# Design: @-mention the issue author, not `REPO_OWNER` — composed with #495's resolver chain (INV-138)

> **Integration note (2026-07-17)**: this design originally predated PR #499
> (issue #495), which independently built the resolver/bot-detection/
> `HUMAN_ESCALATION_LOGIN` infrastructure keyed on the PR author. The two are
> complementary halves of the same problem: the PR author on this pipeline is
> almost always the dev-agent BOT (so #495's resolver nearly always fell
> through to its fallback), while the issue author is almost always a human —
> but #492's original helper lacked bot detection (a dispatcher-filed
> follow-up issue's author IS a bot). The merged design keeps this doc's
> provider-leaf work (`itp_read_task` `author` field + the raw
> `issue_mention_login` read) as the PRIMARY signal of a composed chain in
> `lib-review-resolve-author.sh::resolve_escalation_mention`:
> issue author (bot-checked) → PR author (bot-checked) → three-state
> `HUMAN_ESCALATION_LOGIN` (unset=provider default / set=login / set-EMPTY=
> MUTE) → `@REPO_OWNER` on github, no-mention on gitlab. See [INV-138].

## Problem

Every "a human needs to act" comment the pipeline posts — retry-exhaustion
stalls, review-failure / non-actionable-finding stalls, the convergence /
review-round-cap / same-HEAD-E2E-gate circuit-breaker reports, the liveness
watchdog tier-1/tier-2 escalations, and the review wrapper's "approval failed —
merge manually" / "`no-auto-close` — merge manually" notifications — hardcoded
`@${REPO_OWNER}`.

`REPO_OWNER` is the repo/project **namespace**, not a person. This is correct
enough on GitHub (a repo owner is a single canonical login), but the pipeline
also runs against **GitLab** (provider abstraction, [INV-88]/[INV-89]), where
`REPO_OWNER` is the **group/namespace** — frequently a whole team, not an
individual. `@${group}` there either notifies no one or pings an entire group.

There is **no email-sending code** in the repo; the "email" these notices
produce is GitHub/GitLab's own @-mention notification. So fixing *who* is
@-mentioned fixes the notification.

## Decision

@-mention the **issue author** (the individual who filed the issue and actually
cares about it), resolved through the existing provider seam.

1. **Provider leaf** — add an `author` field to the abstract `itp_read_task`
   contract (`FIELDS_CSV ⊆ …,author`):
   - GitHub `itp_github_read_task`: append `author` to `gh issue view --json`
     **only when requested** (on-demand, like `comments`), normalized
     `.author.login` — so existing callers' argv stays byte-identical and no
     golden-trace/parity stub changes.
   - GitLab `itp_gitlab_read_task`: normalized `.author.username` (the leaf reads
     the whole issue object regardless, so it just projects the extra key).
   - Absent/unresolved → `""` (never null). Additive: callers that don't request
     `author` never see it, so no behavior change for existing reads.

2. **Helper** — `issue_mention_login ISSUE` in `lib-issue-provider.sh` (the only
   lib reachable from BOTH wrappers; the review wrapper does NOT source
   `lib-dispatch.sh`). Reads the author via the seam and applies a
   **provider-scoped fallback**:
   - author present → the author login (both providers).
   - author unresolved AND `ISSUE_PROVIDER=github` → `$REPO_OWNER` (preserves the
     historical target byte-for-byte on GitHub).
   - author unresolved AND non-github → **empty** (an un-mentioned notice beats
     pinging a GitLab group). Never aborts — a `read_task` failure degrades to
     the same path as an absent author.

3. **Mention sites** — the ~17 human-notice comments in `lib-dispatch.sh` (13)
   and `autonomous-review.sh` (4) resolve `_mention` locally and render
   `${_mention:+@}${_mention}` so an empty login drops the mention cleanly (no
   dangling bare `@`).

## Scope / non-goals

- Only the @-mention **text** changes. All auth/token-scoping uses of
  `REPO_OWNER` (`gh-app-token.sh`, `lib-auth.sh`, `dispatcher-tick.sh`, the
  `REPO_OWNER/REPO_NAME` splits) are untouched — they name the repo namespace for
  API calls and never carry a leading `@`.
- The review-agent prompt line "Corrections or clarifications from the repo
  owner (@${REPO_OWNER})" is left **byte-unchanged**. It is descriptive prompt
  text fed to the review agent, never a posted comment, so it never renders as
  an @-mention that pings anyone — out of scope for this change. The
  wiring-guard test explicitly excludes it (the wiring-guard test in test-issue-mention-login.sh explicitly excludes it; [INV-138]).

## Alternatives considered

- **A dedicated `itp_issue_author` verb** instead of widening `read_task`:
  rejected — `read_task` already fetches the whole issue object on both
  providers, so `author` is zero extra API cost; a new verb adds seam surface for
  no gain.
- **Compute the mention once at wrapper entry**: rejected — that would add a
  `read_task` call on every tick's hot paths. The notices fire only on cold
  "human must intervene" branches, so resolving lazily at each site is cheaper.

## Docs authority

Touches the dispatcher/wrapper subsystem, so per CLAUDE.md's Pipeline
Documentation Authority: `docs/pipeline/provider-spec.md` (`read_task` contract)
and `docs/pipeline/invariants.md` ([INV-138]) are updated in the same PR.
