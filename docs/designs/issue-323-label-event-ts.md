# Design — `itp_label_event_ts`: close `dispatcher-tick.sh` as a raw-`gh` caller (#323)

> #296 second-tier batch. Migrates the **last** raw-`gh` survivor in
> `dispatcher-tick.sh` — the best-effort, observe-only TTHW timeline read at
> `:304-314` — behind a new focused ITP verb `itp_label_event_ts`. Closes
> `dispatcher-tick.sh` completely as a raw-`gh` caller (cutover baseline
> 67 → 66 signatures).

## Problem

`dispatcher-tick.sh` emits the `issue_labeled` metrics event when an issue is first
picked up for dev-new (the TTHW "labeled" endpoint, [INV-70]). The event `ts` is
the *dispatch* instant, which can lag the real `autonomous`-label time by ticks
(concurrency cap, unresolved deps). For accurate TTHW the tick also fetches the
true `autonomous`-label timestamp from the GitHub issue timeline and emits it as
`labeled_at`; the aggregator prefers it over `ts` so labeled→PR/merge counts the
queue wait (#228 finding 4).

Today that timeline fetch is a raw `gh api` call sitting in the provider-neutral
caller layer — the **last raw-`gh` survivor in `dispatcher-tick.sh`** ([INV-91]
cutover baseline). It must route through an `itp_*` verb so the GitHub coupling
lives only under `providers/`.

```bash
# dispatcher-tick.sh today (:304-314) — the survivor:
if declare -F metrics_emit >/dev/null 2>&1; then
  _labeled_at="$(gh api "repos/${REPO}/issues/${issue_num}/timeline" \
    --jq 'map(select(.event == "labeled" and .label.name == "autonomous")) | (.[0].created_at // empty)' \
    2>/dev/null || true)"
  ...
fi
```

## Solution

A **focused verb** `itp_label_event_ts ISSUE LABEL` whose GitHub leaf owns the
timeline jq and returns a neutral scalar (the ISO-8601 UTC timestamp of the first
`labeled` event for `LABEL`, or empty).

### Why a focused verb (the documented #281 exception)

#281 established "jq stays caller-side" — but that rule is about **provider-neutral
shapes**. The `event` / `.label.name` / `.created_at` fields are GitHub-internal
REST timeline vocabulary with **no provider-neutral shape**. Encapsulating the
query in the leaf and returning a neutral scalar (a timestamp string) is the
correct abstraction — it mirrors `itp_count_by_state` returning an int and
`itp_resolve_dep` returning an abstract state. It is NOT the §3.3 comment-array
shape.

### Three changes (+ docs)

| # | File | Change |
|---|------|--------|
| 1 | `lib-issue-provider.sh` | Mint shim `itp_label_event_ts() { itp_${ISSUE_PROVIDER}_label_event_ts "$@"; }` (bare expr, like all 13 existing shims) |
| 2 | `providers/itp-github.sh` | Add leaf `itp_github_label_event_ts ISSUE LABEL` — same `gh api …/timeline --jq` the caller emits today, but **JSON-encodes** `LABEL` into the jq string literal (injection-safe) |
| 3 | `dispatcher-tick.sh:304-314` | Call `itp_label_event_ts "$issue_num" "autonomous"` guarded by the **bare** provider expression matching the shim |
| 4 | `providers/cutover-baseline.json` | Drop the one timeline entry → 67 → 66 signatures; `dispatcher-tick.sh` now has ZERO survivors |

### The leaf (injection-safe)

```bash
itp_github_label_event_ts() {
  local issue="$1" label="$2" lbl_json
  # --arg name MUST be `lbl` (jq-1.6 reserves `label` as a keyword); gh api has NO --arg,
  # so pre-encode the label to a JSON string literal and splice it into the --jq program.
  lbl_json="$(jq -rn --arg lbl "$label" '$lbl | @json')" || { echo ""; return 0; }
  gh api "repos/${REPO}/issues/${issue}/timeline" \
    --jq "map(select(.event == \"labeled\" and .label.name == ${lbl_json})) | (.[0].created_at // empty)" \
    2>/dev/null || true
}
```

#### Injection safety (codex R1 [P1])

Raw `${label}` interpolation into the `--jq` string is a **jq injection** (verified
on-box: label `autonomous" or .label.name == "bug` widens the selector → returns
the bug event; a quote-bearing valid label → jq syntax error). The leaf
JSON-encodes the label via a **separate** `jq -rn --arg lbl "$label" '$lbl | @json'`
and splices the literal. Two on-box-verified gotchas:

1. The `--arg` name MUST be `lbl` — **jq 1.6 reserves `label` as a keyword**, so
   `--arg label` + `$label` is a parse error.
2. `gh api` has **no `--arg` flag** (`unknown flag: --arg`) — it does not forward
   jq variable bindings, so the label MUST be pre-encoded, not bound as a gojq
   `--arg`.

For `LABEL=autonomous`, `lbl_json` is exactly `"autonomous"` → **argv-equivalent**
to today's inline selector.

### Leaf-absent + guard/shim expression equality (codex R2 [P2])

The call is wrapped at the call site in
`if declare -F "itp_${ISSUE_PROVIDER}_label_event_ts"` — mirroring the
`itp_begin_tick` guard 60 lines up. **The guard expression MUST be the BARE
`itp_${ISSUE_PROVIDER}_label_event_ts`, IDENTICAL to the shim's dispatch.** A
`:-github` guard against a bare-`$ISSUE_PROVIDER` shim **diverges** when
`ISSUE_PROVIDER` is unset (guard checks `itp_github_…` and passes; shim calls
`itp__…`, undefined → `set -e` abort — verified on-box rc 127). Production is
independently safe (the seam runs `ISSUE_PROVIDER="${ISSUE_PROVIDER:-github}"` at
source time), but the bare-expression alignment removes the latent divergence and
is unit-test robust.

> **Note on the `itp_begin_tick` guard 60 lines up.** That guard reads
> `itp_${ISSUE_PROVIDER:-github}_begin_tick` — it carries a `:-github` because the
> `begin_tick` shim ALSO carries the same `:-github`? No: the `begin_tick` shim is
> bare (`itp_${ISSUE_PROVIDER}_begin_tick`). The `:-github` there is justified by a
> comment as "keeps the guard `set -u`-safe if the seam was somehow not sourced"
> and the seam always defaults `ISSUE_PROVIDER` at source time — so in production
> the two agree. For `itp_label_event_ts` we deliberately use the **bare** form to
> close the latent unset-`ISSUE_PROVIDER` divergence the panel surfaced, and the
> unit test pins it (an unset-`ISSUE_PROVIDER` case that must NOT abort the tick).

L2 capability flag is NOT needed — leaf-absent → empty + the caller guard is the
honest GitHub-caps story.

### Best-effort / no pagination (byte-identical to today)

The leaf keeps today's single `gh api …/timeline` call with **no `--paginate`** — a
label event beyond the default page returns empty (aggregator falls back to `ts`).
This is a pure relocation; `--paginate` is explicitly out of scope. A
malformed/non-array gh response makes `map()` error, swallowed by the
**preserved** `2>/dev/null || true` → empty, identical to today.

## Invariant / spec

- **provider-spec.md §3.1**: add the `itp_label_event_ts ISSUE LABEL` row +
  verb↔current-function mapping appendix entry.
- **invariants.md INV-93** (new): scoped explicitly observe-only / non-blocking —
  TTHW label-time routes through `itp_label_event_ts`; leaf-absent or any failure
  → empty → aggregator falls back to event `ts`; never blocks dispatch. Plus the
  INV-91 Migration-log bullet.
- **dispatcher-flow.md**: update the "Observe-only metrics emission" Step-2 note.
- **metrics.md**: note the `labeled_at` source is the `itp_label_event_ts` verb.

## Rollback + blast radius

LOWEST-risk batch in #296: observe-only metrics. A subtly-wrong verb → at worst an
inaccurate/absent `labeled_at` → aggregator falls back to the dispatch-instant `ts`
(pre-#228 behavior). Scheduling, concurrency, dep-gating, verdict paths UNTOUCHED.
Revert = single-file caller revert + drop leaf/shim + restore the one baseline
entry; no state/schema/TTHW-math change.

## Self-hosting / post-merge

LIVE-wrapper file (`dispatcher-tick.sh`) + seam files — dev in a worktree only.
**NO new entry-point script** (lib/leaf/caller edits) → no `install-project-hooks.sh`
re-run; Step-1 `npx skills update -g autonomous-dispatcher` alone propagates it
(libs resolve via `readlink -f` → skill tree).
