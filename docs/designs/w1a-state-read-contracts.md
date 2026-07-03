# Design: W1a abstract state-read contracts (#371, #347 phase-2)

## Problem

`providers/itp-github.sh`'s `itp_github_list_by_state` / `_count_by_state` /
`_list_forbidden_combos` leaves are literal `gh issue list "$@"` pass-throughs
— the six `lib-dispatch.sh` callers push raw gh flag tails (`--state open
--limit 100 --label … --json … -q '<jq program>'`) through the seam. A second
provider (GitLab, Asana) implementing `provider-spec.md` §3.1's abstract cells
literally would break every caller, because the cells never matched what
callers actually pass. `itp_list_comments` (the [INV-90] normalized array) is
the provider-neutral exemplar to converge on.

## Decision

Convert the three verbs to an abstract contract: the caller passes filters
(`STATE`, a label-AND CSV, `LIMIT`, a field-set CSV / any-of-labels CSV); the
leaf owns 100% of the `gh` I/O AND the normalization jq. No `gh` flags, no jq
programs cross the seam.

```
itp_list_by_state <state> <labels-and-csv> <limit> <fields-csv>
  → [{number, title, labels:[name,...], comments:[{id,author,authorKind,body,createdAt},...]}]
    sorted number ascending, projected to exactly <fields-csv>, [] on no matches

itp_count_by_state <state> <labels-and-csv> <limit> <any-of-labels-csv>
  → bare non-negative integer

itp_list_forbidden_combos <state> <labels-and-csv> <limit>
  → [{number, labels}] already filtered to terminal-AND-transitional ([INV-25])
```

This is a **deliberate shape change** — #296's byte-identical constraint is
lifted for these three verbs (per the issue). Caller-side predicates ([INV-25]
terminal-state subtraction, the no-state-label filter) are re-derived by
filtering the returned normalized array, replacing the old `-q` jq program
the caller used to author.

`itp_list_forbidden_combos` is the ONE exception to "predicates stay
caller-side": the leaf owns the 2-axis combo filter (server-side-optimizable
for a provider with a query language), so `list_hygiene_residue` becomes a
thin pass-through.

## Why not byte-identical (like #281's other READ leaves)

A byte-identical passthrough works when the caller's jq program IS the
contract (there's nothing else to abstract). Here the jq program varies per
caller (four different `-q` predicates) yet all four express the SAME
underlying operation — filter a label-set. Keeping the passthrough would mean
a GitLab/Asana leaf has to parse and re-implement an arbitrary jq AST, which
defeats the point of the seam. The fix is to move the one truly
provider-neutral primitive (label-AND enumeration + normalization) behind the
leaf and let callers express their predicate over the normalized result in
plain jq/bash — logic any provider's caller-side code can execute identically
regardless of backend.

## Proof strategy

Byte-identical golden-trace (the #281/#283 pattern) is impossible by
construction here — the shape changed. Instead:

1. **Decision-level parity** (R5): capture the OLD (pre-#371) callers' outputs
   against four fixture classes (normal/empty/over-limit/residue), commit as a
   golden fixture, then assert the NEW code selects the identical issue-number
   SET / count against the same fixtures. `tests/unit/test-w1a-state-read-parity.sh`.
2. **Leaf-level seam-trace** (AC2): a fixture provider RECORDS the argv each
   verb receives from real callers and asserts no gh-flag-shaped or
   jq-program-shaped argument crosses the seam. `tests/unit/test-w1a-state-read-contracts.sh`.
3. **Provider-conformance** (R6): the three verbs move from `CONTRACT-PENDING`
   / `pending` to asserted in the W2 runner (`tests/provider-conformance/`).

## Non-goals

- W1(b)–(f): `itp_read_task`, CHP PR reads, `chp_ci_status`/`chp_mergeable`,
  CHP write flag-tails, `chp_review_threads` pagination — separate slices.
- Any non-GitHub provider implementation.
- Prompt-heredoc provider-awareness.
