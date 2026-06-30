# Design — `chp_count_reviews_by_login` (#324, #296 second-tier)

## Goal

Mint a focused CHP provider verb `chp_count_reviews_by_login REPO PR LOGIN` and migrate the
single raw-`gh api …/pulls/N/reviews --paginate --jq '… | length'` count inside
`missing_bot_reviews` (`lib-review-bots.sh`) behind it. This is part of `#296` — the strangler-fig
migration of surviving caller-layer raw-`gh` sites behind pluggable `itp_*`/`chp_*` verbs.

`missing_bot_reviews` is the [INV-79] **wrapper bot-review hard-gate**: under the scoped-token scrub
the review agent cannot fail on an absent mandatory bot review, so the WRAPPER counts each configured
bot's reviews on the PR; a count of 0 → the bot is still MISSING → block the PASS and re-queue. It is
**fail-SAFE**: a `gh` failure counts the bot as MISSING (block), never fail-open to a false PASS.

## What moves, what stays

| Layer | Before | After |
|---|---|---|
| **Leaf I/O** | inline `gh api …/reviews --paginate --jq '\|length' \| awk` in `missing_bot_reviews` | `chp_github_count_reviews_by_login` in `providers/chp-github.sh` |
| **Shim** | — | `chp_count_reviews_by_login()` in `lib-code-host.sh` |
| **Decision logic** | `^[0-9]+$` validation + `-eq 0` MISSING decision in `missing_bot_reviews` | **STAYS** caller-side (provider-neutral), mirroring `chp_github_mergeable`'s raw-token / classify-caller-side split |

The verb returns the **summed integer** (across all pages) or `0` on any failure. The `--paginate` +
`awk '{s+=$1}'` sum is a GitHub-transport artifact (`gh api --paginate --jq '\|length'` emits a `length`
per page) with no provider-neutral meaning — so encapsulating it in the leaf and returning the final int
is correct (mirrors `itp_count_by_state` returning an int).

## Leaf contract — `chp_github_count_reviews_by_login REPO PR LOGIN`

```
chp_github_count_reviews_by_login() {
  local repo="$1" pr="$2" login="$3" login_json lengths
  # JSON-encode LOGIN into the jq string literal (injection-safe).
  login_json="$(jq -rn --arg loginarg "$login" '$loginarg | @json' 2>/dev/null)" || { echo 0; return 0; }
  # CAPTURE gh output, CHECK exit, THEN sum (closes the partial-pagination fail-open).
  lengths="$(gh api "repos/${repo}/pulls/${pr}/reviews" --paginate \
    --jq "[.[] | select(.user.login == ${login_json})] | length" 2>/dev/null)" \
    || { echo 0; return 0; }
  awk '{s+=$1} END {print s+0}' <<<"$lengths"
}
```

Three correctness properties:

1. **REPO threaded from arg, NOT global `$REPO`.** `missing_bot_reviews` threads its own `repo=$3`; the
   verb mirrors that. A global-`$REPO` verb would query the wrong repo if they ever differ
   (correctness-by-construction; today's sole caller passes `$REPO` as `$3`, so equal now).
2. **Injection-safe LOGIN.** Raw `${login}` interpolation into `--jq` is a jq injection (a login with `"`
   widens/breaks the selector). The leaf JSON-encodes via a SEPARATE
   `jq -rn --arg loginarg "$login" '$loginarg | @json'`. The `--arg` name MUST be non-reserved
   (jq-1.6 reserves `label` etc.; `loginarg` is safe). `gh api` has NO `--arg`, so pre-encoding is the
   only path. For `github-actions[bot]`, `login_json` is exactly `"github-actions[bot]"` →
   count-equivalent to today.
3. **Fail-SAFE on ANY gh failure.** The leaf CAPTURES gh output, CHECKS its exit, THEN sums. Piping gh
   straight to `awk` (today's inline leaf) swallows gh's exit — so a partial-pagination stream
   (page-1 count emitted, page-2 errors) is summed → count>0 → false PRESENT → **fail-OPEN at the
   hard-gate**. Verified on-box: today's leaf with `gh` echo 1 then exit 1 → count 1. The new verb
   returns 0 on a non-zero gh exit → bot MISSING → block. This is the ONLY intentional behavior change,
   strictly toward the INTENDED [INV-79] fail-safe direction.

## Caller wiring (in `missing_bot_reviews`)

```bash
if declare -F chp_count_reviews_by_login >/dev/null 2>&1 \
   && declare -F "chp_${CODE_HOST}_count_reviews_by_login" >/dev/null 2>&1; then
  count=$(chp_count_reviews_by_login "$repo" "$pr_number" "$login")
else
  count=0   # leaf/shim absent → MISSING (fail-safe)
fi
[[ "$count" =~ ^[0-9]+$ ]] || count=0
[[ "$count" -eq 0 ]] && printf '%s\n' "$bot"
```

**Guard BOTH the shim AND the bare leaf expr.** The leaf-expr is the BARE
`chp_${CODE_HOST}_count_reviews_by_login`, IDENTICAL to the shim's dispatch — a `:-github` guard against
a bare-`$CODE_HOST` shim diverges when `CODE_HOST` is unset (guard checks `chp_github_…`, passes; shim
calls `chp__…`, undefined → `set -e` abort). `CODE_HOST` is defaulted at the seam's source time so
production is safe, but the bare-expr alignment + dual guard removes the latent divergence and is
unit-test robust.

`missing_bot_reviews` does not source `lib-code-host.sh` itself — the review wrapper sources the CHP seam
before calling it. The dual guard is the safety net for any context where the seam isn't loaded
(`CODE_HOST` unset, provider without the leaf): the caller fails-safe to `count=0` (bot MISSING), never
aborts.

## Baseline delta

`scripts/providers/cutover-baseline.json` shrinks by the **1 real-code entry** (the
`count=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" --paginate \` survivor): 67 → **66** signatures.
The **3 prompt-prose** `gh api …/reviews` lines (the agent-facing review heredoc at :231/:273/:284) STAY
as permanent residue (agent-facing text, not a caller-layer call) — their `COUNT=3` baseline entry is
unchanged.

## INV mint — INV-94 (collision-aware vs #323)

#323 (in flight, unmerged) also mints INV-93 — an INV-number collision. #323 was filed first + is
dispatched, so it keeps INV-93; this takes **INV-94**. On rebase against a merged #323, check the ACTUAL
next-free INV on rebased main (don't blind-assume INV-94 — if a sibling also grabbed it, take the next
free), keep BOTH headings, renumber in ONE commit (heading + cross-file refs + test).

## Rollback / blast radius

MODERATE-risk (gates a PASS), but fail-SAFE on every gh failure (capture-check-sum) — a wrong count goes
too LOW → falsely block (re-queue, recoverable), never fail-open. Also CLOSES a latent partial-pagination
fail-open (net safety improvement). Revert = single-file caller revert + drop leaf/shim + restore the one
baseline entry; no state/schema change.

## Self-hosting / post-merge

LIVE-path file (`lib-review-bots.sh` is sourced by the review wrapper) + seam files — dev in a worktree
only. **NO new entry-point script** (lib/leaf/caller edits) → no `install-project-hooks.sh` re-run;
Step-1 `npx skills update -g autonomous-dispatcher` suffices.
