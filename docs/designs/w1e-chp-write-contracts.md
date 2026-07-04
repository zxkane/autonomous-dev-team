# Design — W1e CHP write contracts (issue #400)

## Problem

The three CHP write verbs `chp_create_pr`, `chp_approve`, `chp_merge` were migrated in #282 as byte-identical gh-argv passthroughs — the caller composed `--head/--title/--body`, `--approve --body`, `--squash --delete-branch` and the GitHub leaf forwarded them verbatim. That kept the seam alive but coupled the caller to GitHub flag names: a GitLab leaf would receive gh-shaped flags and have to translate them. #370's provider-conformance runner accordingly labels these three verbs `CONTRACT-PENDING` (§3.2), with no argv contract at all.

## Shape

Abstract positional contracts (pinned by #400's issue body R1):

```
chp_create_pr <head-branch> <title> <body>   # rc-only; stdout MAY carry the created identifier, callers MUST NOT depend on it
chp_approve   <pr> <body>                    # rc-only
chp_merge     <pr>                           # rc; stdout/stderr = provider diagnostics (caller logs + first 500 chars → PR-comment excerpt)
```

- **No gh flags cross the seam** (AC2).
- Merge strategy is **contract-fixed** to squash + delete source branch ([INV-52] wrapper-owns-merge). Not a caller option; a future need is a spec amendment, not a flag pass-through.
- `chp_create_pr` rc is caller-visible **created / not-confirmed** — NOT a no-side-effects guarantee. A remote can create the PR and still fail the response (transport). The caller's pre-create existence check (`drain_agent_pr_create` at `lib-auth.sh:452-455` via `chp_pr_list`) makes the broker idempotent across retries; that check stays and is part of the caller contract.
- `chp_merge` provider diagnostics are surfaced through the seam so the caller keeps its first-500-chars failure-excerpt behavior (the #145 rebase-marker path) unchanged.

The precedent for the shape is `chp_github_request_changes` (chp-github.sh:118-121, `<pr> <body>` positional, leaf owns `--request-changes --body`) — this PR mirrors it exactly, including the conformance-runner treatment.

## Cut lines

| Layer | Owns |
|---|---|
| Caller (broker in `lib-auth.sh`; wrapper in `autonomous-review.sh`) | Positionals; pre-create existence check; `set +e` capture of `MERGE_OUT/MERGE_RC`; `${MERGE_OUT:0:500}` excerpt; metrics; `itp_transition_state` post-merge for `merge_closes_issue=0`; the manual-merge fallback on approve fail. |
| GitHub leaf (`providers/chp-github.sh`) | `--repo $REPO --head <head> --title <title> --body <body>`; `--repo $REPO --approve --body <body>`; `--repo $REPO --squash --delete-branch`. Fail-closed rc; stderr preserved. |
| GitLab (future) | Translates positionals into its own `create MR / approve / merge with squash + remove-source-branch` API calls. |

## Compatibility

- **[INV-91] cutover baseline** — the retained github-gated raw `gh pr create` fallback in `lib-auth.sh` (`_pr_create_ok() { gh pr create --repo "$repo" --head "$branch" --title "$title" --body "$body" >/dev/null 2>&1; }`) stays BYTE-IDENTICAL — its cutover signature is unchanged. That is spec-sanctioned INV-91 residue (see the Mapping appendix row 987 + #346's Migration-log bullet).
- **[INV-46] merge_closes_issue=1 GitHub** — the caller does NOT `itp_transition_state` after a successful merge; GitHub auto-transitions via `Closes #N`. This branch is unchanged.
- **[INV-33] wrapper-owns-terminal-state** — `merge_closes_issue=0` triggers the caller's explicit transition. Unchanged (caller-side).
- **Live merge path** — this slice touches the highest-blast-radius code in the review wrapper (approve/merge). The R5 parity fixture pins the CALLER-observable decisions (log lines, transitions, marker posts, verdict trailer, excerpt truncation) so a wiring-error in the leaf swap surfaces as a red parity test, not a red PR merge.

## Testing

TDD: FIRST commit records the PRE-change decision goldens (`tests/unit/fixtures/w1e-parity/decision-golden.json` + `.meta`); SECOND commit adds the leaves + positional callers + spec + conformance updates and re-pins the argv-golden tests to the leaf-emitted argv driven by positional inputs. `test-w1e-chp-write-parity.sh` is the load-bearing new suite (5 fixtures × ~4 assertions each).

## Deviations

- No new INV — this migrates existing behavior behind the same [INV-87] seam. The INV-87 Migration-log is amended with a bullet for #400.
