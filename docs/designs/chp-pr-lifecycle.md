# Design — CHP PR-lifecycle leaf migration (#282)

```
status: design (autonomous mode)
scope: migrate the Code-Host-Provider (CHP) PR-lifecycle `gh` leaves behind the
       chp_* verbs. GitHub-refactor-only, ZERO behavior change.
date: 2026-06-27
```

## 1. Problem & intent

Per the normative `docs/pipeline/provider-spec.md` §3.2 (CHP verb table) and the
design `docs/superpowers/specs/2026-06-27-pluggable-issue-and-code-host-providers-design.md`
§3.2/§4.2, the code-host coupling must move behind a verb seam so a future
GitLab CHP can slot in. #280 shipped the dispatch skeleton: `lib-code-host.sh`
already defines the 11 `chp_<verb>` shims + the `chp_caps` reader, and
`providers/chp-github.sh` is an EMPTY scaffold. This issue (#282) fills the 11
`chp_github_<verb>` bodies with the `gh` leaves moved **byte-identically** out of
the caller layer, and rewires the callers to the verbs.

`providers/chp-github.caps` (also from #280) declares **exactly today's
behavior** — `native_issue_pr_link=0`, `rest_request_changes=1`, `review_bots=1`,
`merge_closes_issue=1` — so every caller takes the identical code path it takes
now ([INV-88]).

## 2. The 11 verbs and their leaves

| Verb | GitHub leaf (byte-identical) | Cut site (real, post-#277/app-mode) |
|---|---|---|
| `chp_github_find_pr_for_issue ISSUE FIELDS` | `gh pr list --repo $REPO --state open --json $all_fields -q "$q"` | `lib-pr-linkage.sh:73` (`resolve_pr_for_issue`) + `:99` (`verify_pr_closes_issue`) — the issue's `lib-dispatch.sh:1471` is STALE; `fetch_pr_for_issue` is now a pure delegate |
| `chp_github_ci_status PR` | `gh pr checks $pr --repo $REPO --json state -q '[.[].state]'` | `lib-dispatch.sh:1554` (`ci_is_green`) |
| `chp_github_mergeable PR` | `gh pr view $PR --repo $REPO --json mergeable -q '.mergeable'` | `autonomous-review.sh:3202` (the ONLY leaf moved; [M2]) |
| `chp_github_create_pr …` | `gh pr create --repo $REPO --head … --title … --body …` | `lib-auth.sh:459` (`drain_agent_pr_create`) — **OUT OF SCOPE to edit** (issue: "NO auth-code change"). Verb body defined for the contract; the broker rewire is an auth-side follow-up |
| `chp_github_approve PR` | `gh pr review $PR --repo $REPO --approve --body …` | `autonomous-review.sh:3306` |
| `chp_github_request_changes PR BODY` | `gh pr review $PR --repo $REPO --request-changes --body $body` | `lib-review-request-changes.sh:49` (inside `submit_request_changes`) |
| `chp_github_merge PR` | `gh pr merge $PR --repo $REPO --squash --delete-branch` | `autonomous-review.sh:3344` |
| `chp_github_review_threads PR` | `gh api graphql … reviewThreads.nodes[]` → M8 shape | `resolve-threads.sh:38` |
| `chp_github_resolve_thread THREAD_ID` | `gh api graphql … resolveReviewThread(input:{threadId})` | `resolve-threads.sh:73` |
| `chp_github_trigger_bot PR TRIGGER` | real-user trigger post (`gh-as-user.sh pr comment`) | live broker is `lib-auth.sh:538` (`drain_agent_bot_triggers`) — **OUT OF SCOPE to edit**; verb body defined for the contract, gated by `review_bots` cap |
| `chp_github_close_keyword ISSUE` | renders `Closes #<ISSUE>` (no `gh`) | `autonomous-dev.sh` `Closes #${ISSUE_NUMBER}` prompt literals |

## 3. Scoping decision (the load-bearing call)

The issue's per-verb instructions name EXACTLY which leaf each verb moves
("move ONLY the … leaf"). The spec §3.2 verb table + Mapping appendix are the
authoritative enumeration. Therefore:

- **Migrate ONLY the leaves the spec names** (the table above). This mirrors how
  #281 scoped the ITP read migration — it migrated only its 5 named verbs and
  left other `gh issue view` reads raw.
- **Leave unnamed incidental PR reads RAW** (enumerated in the PR body): the
  issue-keyed body-mention `gh pr list … select(.body|test("#N"))` COUNT/number
  lookups (`autonomous-dev.sh:379/709/801/982`) and the PR-number-keyed
  `gh pr view $PR --json comments/state/headRefName/headRefOid/reviews`
  (`autonomous-dev.sh:547`, `autonomous-review.sh:873/903/904/1484/3119/3153`).
  Folding the body-mention lookups into `chp_find_pr_for_issue` would silently
  swap their resolution semantics to the INV-86 close-linkage form — a behavior
  change (and a #277 regression), violating the ZERO-behavior-change mandate.
- **`chp_create_pr` / `chp_trigger_bot`**: their live executable leaves are in
  `lib-auth.sh` (the brokers `drain_agent_pr_create` / `drain_agent_bot_triggers`).
  The review of PR #290 ruled (correctly) that a defined-but-unwired verb does
  NOT complete the seam — so #282 routes both brokers through the verbs as a
  **LEAF-ONLY swap**: only the innermost `gh pr create` / `gh-as-user.sh pr comment`
  primitive moves behind the verb (byte-identical argv), with a fallback to the
  raw leaf if the verb is unavailable. This honors the *intent* of "NO auth-code
  change" — no token minting, scoping, refresh, or allow-list logic changes; only
  the bottom `gh` primitive is swapped for the verb that emits the identical
  command. The `lib-auth.sh` source gains one guarded `lib-code-host.sh` source.

### grep-AC compliance (phrased per-shape, like #281)

The AC grep over the 6 files surfaces three benign residual classes:
1. **kept same-named caller-side shims** (`fetch_pr_for_issue`) — required by the
   function-mock policy (5 test files mock the function);
2. **prompt-heredoc instructional text** (`gh pr create/merge/view` strings the
   agent reads, never executed by the caller layer);
3. **incidental PR reads NOT named by the spec §3.2 verb table** (enumerated
   above) — owned by no current verb; the literal-`gh`-freedom lint INV is the
   separate downstream `cutover-guard-lint` issue.

## 4. Wiring

`lib-code-host.sh` is sourced via the guarded `readlink -f` idiom
(`lib-dispatch.sh:35-61` pattern: `if ! declare -F chp_ci_status; then source …`)
into `lib-pr-linkage.sh`, `lib-dispatch.sh`, `autonomous-review.sh`,
`lib-review-request-changes.sh`, and `resolve-threads.sh`. No installer re-run
(lib-only; Step 1 `npx skills update -g` suffices).

## 5. Invariants

- **REFERENCE** the provider-dispatch [INV-87] (callers MUST NOT raw-`gh` in the
  caller layer) — extend its scope note to the CHP caller layer. Mint NO new INV.
- **Extend [INV-33]** with the `merge_closes_issue` cross-seam note: on GitHub
  merge auto-transitions the issue via the PR body `Closes #N` keyword, so the
  wrapper MUST NOT call `itp_transition_state` after `chp_merge`; a
  `merge_closes_issue=0` backend MUST.

## 6. Tests

`tests/unit/test-chp-pr-lifecycle.sh` (auto-discovered by CI `test-*.sh` glob):
golden-trace byte-identical argv per migrated leaf (recording `gh` stub),
M8 thread-shape assertion, capability-branch via the existing
`fixtures/provider-degraded/chp-degraded.caps` (`rest_request_changes=0`,
`review_bots=0`, `merge_closes_issue=0`), and the function-mock-shim audit
(`fetch_pr_for_issue` keeps its name; the 5 mocking test files pass unedited).
Routing + `.caps` parse are already covered by `test-provider-dispatch.sh` (#280).
