# Step 0: Label Hygiene Pass

Tracks: issue #115 Bug B.

## Problem

`docs/pipeline/state-machine.md::Forbidden transitions` lists "`approved` + any active state" and "`stalled` + any other active state label" as combinations that must never happen. The state machine has no enforcement: when a residue lands (wrapper crash between two label edits, [INV-15] SIGTERM race, manual edit during reconciliation), the next dispatcher tick re-picks the issue from the wrong selector. Bug A (PR #116) fixed one selector; Bug B closes the class.

## Approach

Introduce **Step 0** at the top of `dispatcher-tick.sh`, before Step 1's concurrency gate, that detects and self-heals the residue. Pure cleanup — no agent dispatch, no retry counting, no concurrency consumption. Idempotent.

### Detection

Two terminal labels are sticky:

- `approved` → must not co-exist with any of: `in-progress`, `reviewing`, `pending-review`, `pending-dev`
- `stalled`  → must not co-exist with any of: `in-progress`, `reviewing`, `pending-review`, `pending-dev`

### Action

For each match: strip the transitional labels (single `gh issue edit --remove-label A --remove-label B ...` call). Keep `approved`/`stalled`/`autonomous`/`no-auto-close` intact. Always log to dispatcher stdout.

### Issue-side audit comment (one-shot per residue set)

Post once per `(issue, sorted-labels-stripped)` tuple, gated by an idempotency marker `<!-- INV-25-hygiene:<sorted-labels> -->`. The marker lives in the comment body so a `gh issue view ... -q '[.comments[].body | select(contains("<marker>"))] | length'` returns >0 on subsequent ticks → skip the comment, still strip the labels.

Comment body: `Label hygiene: stripped \`X\`, \`Y\` from \`<terminal>\` issue (INV-25). <!-- marker -->`.

## Helper: `_has_terminal_label()`

Single-source predicate added to `lib-dispatch.sh` for use by future selectors. Returns 0 if labels JSON contains either terminal label, 1 otherwise. Existing four `list_*` selectors are NOT refactored to use it (low-risk-first; they already work correctly).

## Order in tick

```
Step 0: hygiene pass  (NEW; runs even when MAX_CONCURRENT exhausted)
Step 1: concurrency gate
Step 2: scan-new
Step 3: scan-pending-review
Step 4: scan-pending-dev
Step 5: stale-detection
```

Why before concurrency: hygiene is a label-only fix-up that doesn't spawn agents; we want it to run even when concurrency is full so the residue heals on the very next tick instead of waiting for capacity.

## Invariant

[INV-25] — `approved` and `stalled` are sticky terminal states; transitional labels co-residing with them are stripped at tick start. At most one issue notice per residue set.

[INV-15] (SIGTERM race) is one *producer* of the residue this invariant heals. Documented cross-reference both ways.

## Open questions / non-goals

- **Bug C** (suspected dev-wrapper label-flip) is investigation-only. If it turns out to be a real flipper, it's another *producer* of residue — Step 0 heals it regardless of source. Tracked separately.
- The four `list_*` selectors are not refactored. Future maintainers adding new selectors should call `_has_terminal_label()` themselves.
