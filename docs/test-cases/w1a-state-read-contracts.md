# Test Cases: W1a abstract state-read contracts (#371, #347 phase-2)

Covers the conversion of `itp_list_by_state` / `itp_count_by_state` /
`itp_list_forbidden_combos` from a byte-identical `gh`-argv passthrough
([INV-87], #281) to an abstract, provider-neutral contract — no `gh` flags and
no jq programs cross the seam (`docs/pipeline/provider-spec.md` §3.1). Driven
by `tests/unit/test-w1a-state-read-contracts.sh` (leaf-level) and
`tests/unit/test-w1a-state-read-parity.sh` (decision-level, per R5).

## Decision-level behavior parity (R5) — `test-w1a-state-read-parity.sh`

For each of the six `lib-dispatch.sh` callers, OLD (pre-#371, byte-identical
passthrough) and NEW (post-#371, abstract contract) select the exact same
issue-number SET (order-insensitive) / count, across four fixture classes.
The golden values are captured once from the OLD code and committed to
`tests/unit/fixtures/w1a-parity/decision-golden.json` (provenance in the
sidecar `.meta` file); this suite runs only the NEW code and diffs against
that golden.

| ID | Caller | Fixture class | Expected |
|---|---|---|---|
| TC-W1A-PARITY-001 | `list_new_issues` | normal | matches OLD golden `[1]` |
| TC-W1A-PARITY-002 | `list_pending_review` | normal | matches OLD golden `[2]` |
| TC-W1A-PARITY-003 | `list_pending_dev` | normal | matches OLD golden `[3]` |
| TC-W1A-PARITY-004 | `list_stale_candidates` | normal | matches OLD golden `[4,5]` |
| TC-W1A-PARITY-005 | `list_hygiene_residue` | normal | matches OLD golden `[6]` |
| TC-W1A-PARITY-006 | `count_active` | normal | matches OLD golden `2` |
| TC-W1A-PARITY-010..015 | all six | empty (0 issues) | matches OLD golden (`[]`/`0`) |
| TC-W1A-PARITY-020..021 | `list_new_issues`, `count_active` | >limit (120 issues) | matches OLD golden (own jq logic over a large set) |
| TC-W1A-PARITY-030..034 | all six | terminal-label residue present alongside a clean issue | matches OLD golden — residue excluded per [INV-25] |

## Leaf-level shape / argv / fail-closed — `test-w1a-state-read-contracts.sh`

### AC2 — zero gh flags / jq programs cross the seam

| ID | Scenario | Expected |
|---|---|---|
| seam-trace | Stub `itp_github_{list_by_state,count_by_state,list_forbidden_combos}` to record every argv they RECEIVE from all six real `lib-dispatch.sh` callers | no received argument starts with `--`; none contains `select(`, `.labels[]`, or `\| length` (a jq-program fragment) |
| seam-trace sanity | Same harness | recorded args ARE the expected abstract positional grammar (`state`, `labels-CSV`, `limit`, `fields-CSV`\|`any-of-CSV`) — proves the harness captured real calls |
| secondary guard | Source grep over `lib-dispatch.sh`'s call sites for the three verbs | zero `--json`/`--label`/` -q ` tokens |

### Leaf normalization shape

| ID | Scenario | Expected |
|---|---|---|
| sort | `itp_github_list_by_state` against an out-of-number-order gh payload | output sorted `number` ascending regardless of gh's own order |
| labels shape | Same | `labels` is an array of NAME strings, not `{name}` objects |
| comments shape | Same, payload with one comment | `comments` is the [INV-90] normalized array |
| empty | gh returns `[]` | leaf returns `[]` (never null, never empty string) |
| field projection | `FIELDS_CSV=number,labels` vs `FIELDS_CSV=number` | output objects carry EXACTLY the requested keys |

### `itp_count_by_state` — bare integer, any-of semantics

| ID | Scenario | Expected |
|---|---|---|
| any-of match | 3 issues, any-of=`in-progress,reviewing`, 2 match | count = `2` |
| any-of empty | Same 3 issues, any-of=`""` | count = all AND-matches (`3`) |

### `itp_list_forbidden_combos` — leaf owns the combo filter

| ID | Scenario | Expected |
|---|---|---|
| combo filter | 4 issues: terminal+transitional, autonomous-only, terminal+transitional, terminal-only | only the two terminal+transitional issues survive |
| combo fields | Same | output fields are exactly `number,labels` |

### R2 — fail-closed

| ID | Scenario | Expected |
|---|---|---|
| gh rc≠0 | Stub `gh` fails for each of the 3 verbs | leaf rc≠0, no partial stdout |
| malformed JSON | `gh` returns rc 0 with garbage (non-JSON) body | leaf rc≠0 (fail-closed, not a silently-empty success) |

## Provider-conformance runner (R6) — `tests/provider-conformance/`

`itp_list_by_state` / `itp_count_by_state` / `itp_list_forbidden_combos`
flipped from `pending` to `asserted` in `coverage.conf` (and their
`CONTRACT-PENDING` tokens removed from `provider-spec.md` §3.1) in this same
PR, per the R6/W2 tripwire. New fixtures: `fixtures/payloads/issue-list-valid.json`
(+ `.meta`); new assertion helpers `_run_shape_assert` (extended to accept
`number`-ascending, not just `createdAt`-ascending) and `_run_count_assert`
(bare-integer shape). The `github`/`degraded`/`broken` fixture providers each
gained real leaves for the three verbs so all three conformance runs keep
their documented PASS/SKIP/FAIL counts (github: 0 FAIL; degraded: 0 FAIL, 3
SKIP; broken: exactly the 4 pre-existing deliberate violations, unchanged).

## Downstream shape-consumer rewrites (R3)

Every consumer of the OLD `.labels[].name` object-array shape was rewritten
in this PR to consume the NEW name-string array:

| Site | Change |
|---|---|
| `dispatcher-tick.sh` Step 5 (`labels=$(jq -r ".[$i].labels[].name" ...)`) | `.labels[].name` → `.labels[]` |
| `lib-dispatch.sh::_has_terminal_label` | `[.[].name] \| contains(...)` → `contains(...)` over the array directly |
| `lib-dispatch.sh::hygiene_strip_residual_labels` | `[.[].name] as $names` → `. as $names` |
| `lib-dispatch.sh::run_hygiene_pass` (terminal-label branch) | `[.[].name] \| contains(["approved"])` → `contains(["approved"])` |
| `docs/pipeline/spec-guard-map.json`'s `only-autonomous-label` guard anchor | `contains(["in-progress"])` → `. == "in-progress"` (the new literal `list_new_issues` emits) |
| `tests/unit/test-step0-hygiene.sh`, `tests/unit/test-itp-transition-variadic.sh` fixture builders | `[{"name":"x"}]` → `["x"]` |

`grep -rn '\.labels\[\]\.name'` outside `providers/` after this PR returns
ONLY `itp_read_task` call sites (`status.sh`, `autonomous-review.sh:3530`,
`test-itp-read-task-b5b7.sh`) — a different, unmigrated verb whose `--json
labels` still returns gh's raw `[{"name":...}]` shape (out of scope for this
issue; W1(b)). Zero hits remain from the three verbs this issue migrates.
