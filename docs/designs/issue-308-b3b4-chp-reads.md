# Design — #296 B3+B4: migrate lib-auth PR-existence reads + lib-review-e2e SHA-evidence read behind `chp_pr_list`/`chp_pr_view`

Issue: #308 · Part of #296 (pluggable-providers raw-`gh` migration). Follows B1 (#303) and B2 (#306).

## Goal

Migrate **three** byte-identical raw-`gh` read sites behind already-shipped CHP
provider verbs (`chp_pr_list`, `chp_pr_view`), shrinking the `[INV-91]`
cutover baseline by exactly 3. **Zero behavior change** — each verb forwards to
the exact same `gh` argv the site emits today.

This is **batches B3 + B4 of #296 combined** into one PR (the deliberate
two-verb exception, per the issue): B3 and B4 touch different files and different
verbs, so there is no edit collision; bundling shrinks the cutover baseline by
exactly 3 in one ratchet step.

## The three sites (verified against merged main `e21b8a4`)

| Batch | File:fn | Before | After |
|---|---|---|---|
| B3 | `lib-auth.sh` `drain_agent_pr_create` | `existing=$(gh pr list --repo "$repo" --state open --json body -q "<sel>" …)` | `existing=$(chp_pr_list --state open --json body -q "<sel>" …)` |
| B3 | `lib-auth.sh` `drain_agent_bot_triggers` | `pr_number=$(gh pr list --repo "$repo" --state open --json number,body -q "<sel>" …)` | `pr_number=$(chp_pr_list --state open --json number,body -q "<sel>" …)` |
| B4 | `lib-review-e2e.sh` `_fetch_sha_evidence` | `_body=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json comments --jq "<sel>" …)` | `_body=$(chp_pr_view "$PR_NUMBER" --json comments --jq "<sel>" …)` |

## Byte-identity premise

- `chp_pr_list` = `gh pr list --repo "$REPO" "$@"` (precedent: `autonomous-dev.sh:388/767/1053`).
- `chp_pr_view` = `local pr="$1"; shift; gh pr view "$pr" --repo "$REPO" "$@"` (precedent: `autonomous-review.sh:922/952/953`).
- Both hardcode the GLOBAL `$REPO`.
- The B3 sites pass a LOCAL `$repo` param; the verb supplies the GLOBAL `$REPO`.
  These are equal at runtime: `drain_agent_pr_create` / `drain_agent_bot_triggers`
  are always invoked with `"$REPO"` as the repo arg
  (`autonomous-dev.sh:762/782`, `autonomous-review.sh:775`). Dropping
  `--repo "$repo"` and letting the verb supply `--repo "$REPO"` is byte-identical.
  **AC7** pins this premise with a call-expression grep.
- The B4 site already passes the GLOBAL `$REPO`; dropping `--repo "$REPO"` (the
  verb re-supplies it) is trivially byte-identical.

## Reachability — why the verb is in scope at each site

- **B3 (`lib-auth.sh`)**: `lib-auth.sh` already self-sources `lib-code-host.sh`
  (lines ~50-54, guarded on `chp_create_pr` — the B from #282). So `chp_pr_list`
  is defined wherever `lib-auth.sh` is sourced. No source-graph change.
- **B4 (`lib-review-e2e.sh`)**: in the review wrapper, `autonomous-review.sh`
  sources `lib-code-host.sh` (line 76) BEFORE `lib-review-e2e.sh` (line 84), so
  `chp_pr_view` is defined when `_fetch_sha_evidence` runs.
  **We do NOT add a `lib-code-host.sh` self-source to `lib-review-e2e.sh`** (per
  the issue's Requirements / Out-of-Scope) — a 3-line read migration must not
  mutate the production source graph. The standalone-sourced unit/isolation tests
  source the CHP seam themselves (AC4/AC5).

## The silent-fail-soft hazard (AC4 rationale)

All three sites wrap the call in `2>/dev/null || echo "0"` / `|| true`. So an
**undefined verb does NOT crash** — it fails-soft to "0 PRs" / empty (a behavior
change with no crash). A crash-expecting test would miss it. Therefore every
test exercising a migrated site MUST:
1. source the real `lib-code-host.sh` (or mock the specific verb), AND
2. assert the gh-stub **OBSERVED** the verb's `gh pr list`/`gh pr view` argv —
   proving the path was exercised, not just reachable.

## Argument-boundary-preserving golden trace (AC2 rationale)

The migrated `-q`/`--jq` selectors contain spaces and `|` pipes
(`[.[] | select(.body | test("#N…"))] | length`). A space-joined argv capture
would not catch a word-split or re-escaped selector. The golden trace records
argv as a **NUL-delimited** stream (one arg per record), asserting argc + each
exact arg incl. the verbatim selector.

## Out of scope (MUST remain baselined / untouched)

- `lib-auth.sh` `gh pr create` (later `chp_create_pr` allowlist handling),
  `gh repo view` (no `chp_repo_view`, deferred), auth/log strings.
- `lib-review-e2e.sh` `gh api .../comments` reads + `gh pr comment` posts
  (B9 / deferred — need new verbs).
- The `$repo` param removal / selector normalization (unrelated churn).
- `provider-spec.md:804`, `observation-snapshot.md:60-63`, `invariants.md:4472`
  are NOT stale for these reads — do NOT edit. `invariants.md:4472` is made TRUE
  by this PR.

## Verification

- `check-provider-cutover.sh` finds ZERO executable raw `gh pr list` in
  `lib-auth.sh` / ZERO raw `gh pr view` in `lib-review-e2e.sh` (AC1).
- `cutover-baseline.json` shrinks by exactly 3: 79 → 76 surviving sigs (AC3),
  regenerated in-PR via `--generate-baseline`.
- Golden-trace + seam-reachability/observed-call tests
  (`tests/unit/test-issue-308-b3b4-chp-reads.sh`).
- The two existing isolation fixtures (`test-token-split-234.sh`,
  `test-autonomous-review-sequential-e2e.sh`) updated to source the CHP seam and
  assert the migrated argv (AC5).
- INV-91 Migration-log bullet added (AC6); `pipeline-docs-gate` satisfied.
