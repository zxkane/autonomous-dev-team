# Test Cases: `ISSUE_FILTER` per-dispatcher issue-selection scope (#436, PR-B)

Covers the new `lib-issue-filter.sh` (compiler, apply, validate, fields
helper), its wiring into `lib-dispatch.sh`'s six evaluation points, the
upfront fail-closed validation in `dispatcher-tick.sh`, the
`dispatcher-multi-tick.sh` export whitelist, and the companion
`ISSUE_SCAN_LIMIT` knob. This is PR-B of the `ISSUE_FILTER` two-PR delivery
(`docs/designs/issue-filter.md`) — depends on the seam widening shipped in
PR-A (#435, `assignees` field + `assignees=1` caps bit).

Driven by `tests/unit/test-issue-filter.sh` (compiler/apply/validate),
extensions to `tests/unit/test-lib-dispatch.sh` /
`tests/unit/test-list-selectors-terminal-defense.sh` (selector wiring),
`tests/unit/test-dispatcher-tick-review-bots.sh`-style tick-level tests
(fail-closed conf validation), and `tests/unit/test-dispatcher-multi-tick.sh`
(export propagation).

## Compiler — `issue_filter_compile` (AC-B2)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-001 | `label:foo` | compiles; matches an issue whose `labels` contains `"foo"` |
| TC-IFILT-002 | `assignee:alice` | compiles; matches an issue whose `assignees` contains `"alice"` |
| TC-IFILT-003 | `assignee:none` (unquoted, reserved) | compiles to an emptiness check on `assignees`; matches only issues with `assignees == []` |
| TC-IFILT-004 | `assignee:"none"` (quoted literal) | compiles to a membership atom against the literal login `none`, NOT the emptiness check |
| TC-IFILT-005 | `label:"name with spaces"` | tokenizes the quoted value as one atom value including the space |
| TC-IFILT-006 | `label:a and label:b` | `and` binds both atoms; matches only issues satisfying both |
| TC-IFILT-007 | `label:a or label:b` | matches issues satisfying either |
| TC-IFILT-008 | `not label:a` | matches issues NOT carrying label `a` |
| TC-IFILT-009 | `label:a or label:b and label:c` | precedence: `and` binds tighter than `or` — parses as `label:a or (label:b and label:c)` |
| TC-IFILT-010 | `not label:a and label:b` | precedence: `not` binds tighter than `and` — parses as `(not label:a) and label:b` |
| TC-IFILT-011 | `(label:a or label:b) and not label:c` | parens group the `or` before the `and`/`not` apply |
| TC-IFILT-012 | `(label:a or label:b)` immediately followed by more text with no space, e.g. `(label:a or label:b)and label:c` | adjacent-paren tokenization: `)` self-delimits from `and` even with no whitespace between them |
| TC-IFILT-013 | `((label:a))` | nested parens compile fine (redundant grouping is not an error) |
| TC-IFILT-014 | whitespace-only filter (`"   "`) | treated as unset — identity with the empty-filter path (§ AC-B1) |
| TC-IFILT-015 | multi-assignee membership: issue has `assignees:["alice","bob"]`, filter `assignee:bob` | matches (membership, not equality) |
| TC-IFILT-016 | `label:a and (label:b or label:c) and not label:wip and (assignee:alice or assignee:none)` (design doc's example) | compiles; full boolean algebra composes without error |

### Compiler error paths (AC-B2)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-020 | `bogus:foo` (unknown atom key) | rc≠0; error message names the offending token `bogus:foo` |
| TC-IFILT-021 | `(label:a` (unbalanced — missing close paren) | rc≠0; error names the unclosed `(` |
| TC-IFILT-022 | `label:a)` (unbalanced — stray close paren) | rc≠0; error names the stray `)` |
| TC-IFILT-023 | `label:a and` (dangling operator, nothing follows) | rc≠0; error names the dangling `and` |
| TC-IFILT-024 | `and label:a` (bare leading operator) | rc≠0; error names the bare `and` |
| TC-IFILT-025 | `()` (empty sub-expression) | rc≠0; error names the empty parens |
| TC-IFILT-026 | `label:` (empty atom value, no quotes) | rc≠0; error names `label:` |
| TC-IFILT-027 | `label:""` (empty atom value, quoted) | rc≠0; error names `label:""` |
| TC-IFILT-028 | `label:a label:b` (trailing tokens after a complete expression — no operator between them) | rc≠0; error names the unexpected trailing token `label:b` |
| TC-IFILT-029 | `label:"unterminated` (embedded/unterminated quote — no closing `"`) | rc≠0; error names the unterminated quoted value |
| TC-IFILT-030 | `label` (bare token, missing `:value`) | rc≠0; error names the bare token `label` |
| TC-IFILT-031 | `label:"team"a` (stray characters after a closing quote) | rc≠0; error names the malformed token — a typo after a quoted value must fail validation, not silently fall back to the unquoted literal `"team"a` |
| TC-IFILT-032 | `assignee:"bob"x` (same class, `assignee:` key) | rc≠0; same rejection |

### Reserved-label rejection (AC-B5, `issue_filter_validate`)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-040 | `label:in-progress` | `issue_filter_validate` rejects — pipeline state label |
| TC-IFILT-041 | `label:reviewing` | rejected |
| TC-IFILT-042 | `label:pending-review` | rejected |
| TC-IFILT-043 | `label:pending-dev` | rejected |
| TC-IFILT-044 | `label:stalled` | rejected |
| TC-IFILT-045 | `label:approved` | rejected |
| TC-IFILT-046 | `label:autonomous` | rejected — the baseline label |
| TC-IFILT-047 | `label:in-progress and label:team-a` (reserved label buried inside a larger expression) | rejected — the whole filter is invalid, not just the offending atom |
| TC-IFILT-048 | `label:team-a` (no reserved atom) | validate passes this gate |

### Assignee capability gate (AC-B5)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-050 | filter has an `assignee:` atom; provider caps declare `assignees=1` | validate passes this gate |
| TC-IFILT-051 | filter has an `assignee:` atom; provider caps declare `assignees=0` (or the key is absent) | validate rejects — conf-abort |
| TC-IFILT-052 | filter is label-only (no assignee atom); provider caps `assignees=0` | validate passes — label-only filters skip this gate entirely |

## Injection safety (AC-B3)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-060 | `label:") or true"` | compiles; matches ONLY an issue whose label is literally `") or true"` — never short-circuits the jq predicate |
| TC-IFILT-061 | `label:"$(whoami)"` | matches only the literal string `$(whoami)`; no shell/jq evaluation occurs |
| TC-IFILT-062 | ``label:"`id`"`` (embedded backtick) | matches only the literal backtick-containing string; no command substitution |
| TC-IFILT-063 | assert on `ISSUE_FILTER_JQ` after compiling any of the above | the compiled jq program text contains no atom value substring — every value appears only in `ISSUE_FILTER_ARGS` as a `--arg` pair |

## `issue_filter_apply` (AC-B1, AC-B4)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-070 | empty/unset `ISSUE_FILTER`, input array with `assignees` present (e.g. from `itp_list_forbidden_combos`) | output is jq-equal to input EXCEPT every row's `assignees` key is stripped |
| TC-IFILT-071 | empty/unset `ISSUE_FILTER`, input array with NO `assignees` key at all | output unchanged (`del` on a missing key is a no-op) — byte/shape identity with pre-PR selector output |
| TC-IFILT-072 | non-empty filter, first call in a fresh shell (no prior `issue_filter_compile`) | lazy-compiles on first use; `ISSUE_FILTER_JQ`/`ISSUE_FILTER_ARGS` become set as a side effect |
| TC-IFILT-073 | non-empty filter, second call reusing the same globals | does not recompile (no observable difference in output, but documents the lazy-compile contract) |
| TC-IFILT-074 | non-empty filter that fails to compile (malformed `ISSUE_FILTER` set directly, `issue_filter_validate` never called) | `issue_filter_apply` itself returns rc≠0 — fail-closed even for a standalone caller |
| TC-IFILT-075 | non-empty filter, matching array | output never contains an `assignees` key on ANY row, matched or not |
| TC-IFILT-076 | non-empty filter, array with zero matches | output is `[]` |
| TC-IFILT-077 | whitespace-only `ISSUE_FILTER` (e.g. `"   "`) | treated as unset (no select applied) — identity with the empty-filter path; `assignees` is still stripped |

## Tick-level fail-closed validation ordering (AC-B5)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-080 | malformed `ISSUE_FILTER` (any compiler error class) | tick aborts rc≠0 with `ADT_CFG_ISSUE_FILTER_INVALID` [INV-72] envelope |
| TC-IFILT-081 | `ISSUE_FILTER` referencing a reserved state label | tick aborts rc≠0, same envelope code |
| TC-IFILT-082 | `ISSUE_FILTER` with an assignee atom, caps lack `assignees=1` | tick aborts rc≠0, same envelope code |
| TC-IFILT-083 | invalid `ISSUE_SCAN_LIMIT` (non-numeric, e.g. `"abc"`) | tick aborts rc≠0 with the scan-limit envelope code |
| TC-IFILT-084 | invalid `ISSUE_SCAN_LIMIT` (`0` or negative) | tick aborts rc≠0, same envelope code |
| TC-IFILT-085 | any of TC-IFILT-080..084 | abort happens in the upfront conf-validator block — BEFORE the GH App token mint, BEFORE Step 0, before any label edit / dispatch marker / agent spawn (asserted via no-`gh`-call / no-token-mint proxy, mirroring `test-dispatcher-tick-review-bots.sh`'s pattern) |
| TC-IFILT-086 | valid empty `ISSUE_FILTER` + valid/unset `ISSUE_SCAN_LIMIT` | tick clears this validation slot with no envelope |
| TC-IFILT-087 | valid non-empty `ISSUE_FILTER` referencing only non-reserved labels, caps satisfy the assignee gate (or filter is label-only) | tick clears this validation slot with no envelope |

## Enumeration fail-closed (AC-B6)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-090 | `count_active`, empty filter, `itp_count_by_state` leaf fails | tick aborts (existing `set -e` behavior preserved) — never coerces to 0 |
| TC-IFILT-091 | `count_active`, non-empty filter, `itp_list_by_state` leaf fails | the filtered count path propagates the failure and aborts — never coerces to 0, no `2>/dev/null \|\| true` framing |
| TC-IFILT-092 | any of the five filtered `list_*` selectors, leaf failure | the selector propagates the failure (rc≠0) rather than emitting `[]` |

## Evaluation points — filter takes effect at all six sites (AC-B4)

| ID | Call site | Scenario | Expected |
|---|---|---|---|
| TC-IFILT-100 | `list_new_issues` | fixture with matching + non-matching issues, filter `label:team-a` | only matching issues returned; fields requested via `issue_filter_fields` include `assignees` when the filter is non-empty |
| TC-IFILT-101 | `list_pending_review` | same shape | filter narrows the result; existing terminal-state subtraction still applies |
| TC-IFILT-102 | `list_pending_dev` | same shape | filter narrows the result; existing terminal-state subtraction still applies |
| TC-IFILT-103 | `list_stale_candidates` | same shape | filter narrows the result; existing active-state selection still applies |
| TC-IFILT-104 | `list_hygiene_residue` | same shape | filter narrows the forbidden-combo residue to this instance's slice |
| TC-IFILT-105 | `count_active`, empty filter | — | routes through `itp_count_by_state` (asserted, not just numerically equal) |
| TC-IFILT-106 | `count_active`, non-empty filter matching ALL active issues | fixture where the filter matches every active issue | count equals the empty-filter count on the same fixture (dual-path equivalence) |
| TC-IFILT-107 | `count_active`, non-empty filter matching a SUBSET | fixture with some active issues outside the filter | count is strictly less than the unfiltered count |
| TC-IFILT-108 | any evaluation point, empty/unset filter | — | jq-equal to pre-PR output (AC-B1 identity, re-asserted per site) |
| TC-IFILT-109 | `count_active`, whitespace-only `ISSUE_FILTER` | fixture with active issues outside a would-be label match | routes through the SAME empty-filter (`itp_count_by_state`) path — count equals the unfiltered count, never switches to the enumerate-then-filter path on raw non-empty-string alone |

## `ISSUE_SCAN_LIMIT` (AC-B9)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-110 | `ISSUE_SCAN_LIMIT` unset | every one of the six call sites uses limit `100` (default) |
| TC-IFILT-111 | `ISSUE_SCAN_LIMIT=250` | at least one selector (e.g. `list_new_issues`) issues its enumeration with limit `250` |
| TC-IFILT-112 | `ISSUE_SCAN_LIMIT=250`, `count_active` filtered path | the filtered `itp_list_by_state` call also uses limit `250`, not the hardcoded `100` |
| TC-IFILT-113 | `ISSUE_SCAN_LIMIT=250`, `count_active` empty-filter path | the `itp_count_by_state` call also uses limit `250` (both paths share the knob per §3.3) |
| TC-IFILT-114 | tick-level: invalid value | see TC-IFILT-083/084 |

## Multi-tick propagation (AC-B8)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-120 | per-project inline block sets `ISSUE_FILTER='label:box-a'` and `ISSUE_SCAN_LIMIT=200` | both export into the per-project subshell; the project's tick observes them |
| TC-IFILT-121 | per-project inline block omits both attributes | project subshell runs unfiltered at limit 100 (unchanged default) |
| TC-IFILT-122 | inline `ISSUE_FILTER` value containing a `validate_inline_block`-rejected character (e.g. `` ` ``, `$`, `;`) | the whole inline block fails `validate_inline_block` loudly — the project is skipped with a WARN, not silently truncated |
| TC-IFILT-123 | path-entry project (`autonomous.conf` file, not inline) with `ISSUE_FILTER` set | no charset restriction — the file is sourced directly, same as any other conf var |

## Non-goals (documented, not tested as bugs)

| ID | Scenario | Expected |
|---|---|---|
| TC-IFILT-130 | `check_deps_resolved` | NOT filtered — dependency resolution keeps the global view regardless of `ISSUE_FILTER` (deliberate; see design §6) |
