# Design: `ISSUE_FILTER` — per-dispatcher issue-selection scope

**Status:** reviewed (codex + plan-eng findings folded in)
**Target repo:** `zxkane/autonomous-dev-team`
**Doc destination in PR:** `docs/designs/issue-filter.md` (+ pipeline doc updates listed in §8)
**Delivery:** TWO PRs, seam-first (§8) — PR-A widens the provider seam
(zero behavior change), PR-B ships the filter feature.

## 1. Problem

When a repo is worked on by multiple engineers, each with one or more dev boxes,
multiple dispatcher instances may scan the same repo. Today every dispatcher
selects ALL open `autonomous` issues — there is no way to scope an instance to
"my team's issues" or "issues assigned to me". Two instances on one repo
double-dispatch everything.

## 2. Requirements (as clarified)

- A single conf attribute (`ISSUE_FILTER`) that scopes which issues this
  dispatcher instance selects.
- Filter combines **labels** with full boolean algebra (`and`, `or`, `not`,
  parentheses) plus optional **assignee** atoms with the same operators.
- Applies to **all** dispatcher stages (scan-new, pending-review, pending-dev,
  stale detection, Step-0 hygiene, concurrency counting) — each dispatcher sees
  and touches only its slice.
- Multi-dispatcher overlap is handled by an **operational disjointness
  contract** (documented invariant), not a cross-host claiming mechanism.
- Empty/unset filter = today's behavior (jq-equal selector output; see AC1
  for the precise identity contract).

## 3. Conf surface

### 3.1 `autonomous.conf` (and per-project blocks in `dispatcher.conf`)

```bash
# Optional. Scopes THIS dispatcher instance to a subset of open `autonomous`
# issues. Empty/unset = no additional filtering (current behavior).
#
# Grammar:  atoms    label:<name> | assignee:<login> | assignee:none
#           quoting  label:"name with spaces"   (double quotes; embedded
#                                                double-quotes unsupported)
#           ops      not > and > or, parentheses for grouping
#           matching exact, case-sensitive string comparison (provider-neutral;
#                    GitLab labels ARE case-sensitive)
#           reserved pipeline state labels (in-progress, reviewing,
#                    pending-review, pending-dev, stalled, approved) and
#                    `autonomous` are REJECTED as atoms (conf error)
#
# The filter is a CONJUNCTIVE refinement on top of the `autonomous` baseline:
# it can only narrow the selection, never widen it past `autonomous`.
ISSUE_FILTER='label:team-a and (label:frontend or label:backend) and not label:wip and (assignee:alice or assignee:none)'
```

- `assignee:<login>` means `<login> ∈ assignees` (issues can have multiple
  assignees). `assignee:none` means the assignees list is empty.
  `assignee:none` is a reserved form; a real login literally named `none`
  is expressed as `assignee:"none"` (quoted = always a literal value).
- No `assignee:me`: the dispatcher is an unattended bot; "me" is ambiguous
  (bot login? operator?). Explicit logins are auditable.
- `dispatcher-multi-tick.sh`'s per-project export whitelist gains
  `ISSUE_FILTER` (same pattern as `MAX_CONCURRENT`). **Charset restriction
  for inline per-project blocks:** `validate_inline_block` rejects `$`,
  backticks, `;`, `&`, `|`, `\` in any RHS (CWE-95 defense-in-depth) — an
  inline `ISSUE_FILTER` cannot contain those characters. Labels needing
  them (pathological) require the project's own `autonomous.conf`, which is
  sourced directly and has no such restriction. Documented in
  `dispatcher.conf.example`.

### 3.2 Semantics of `MAX_CONCURRENT` under a filter

With a non-empty filter, `count_active` counts only issues in this
dispatcher's slice, so `MAX_CONCURRENT` becomes a **per-dispatcher-slice**
limit. This is the desired semantics for multi-instance operation and is
documented in the conf example and `dispatcher-flow.md`.

### 3.3 `ISSUE_SCAN_LIMIT` — filter-after-limit starvation guard

Every selector currently enumerates with a hard-coded server-side
`limit=100` **before** caller-side subtraction. With a filter, the first
100 `autonomous` issues could be mostly out-of-slice, starving this
dispatcher while matching issues sit beyond the limit. Mitigation:

- New optional conf var `ISSUE_SCAN_LIMIT` (default `100` — unset =
  today's value). All six §6 call sites replace the
  literal `100` with `${ISSUE_SCAN_LIMIT:-100}` — **including BOTH
  `count_active` paths** (the empty-filter `itp_count_by_state` path takes
  the same limit; otherwise a raised limit on selectors with a 100-capped
  active count would under-count actives beyond the first 100 and dispatch
  past `MAX_CONCURRENT`).
- Validated upfront next to the filter validation (§4.3): non-numeric or
  ≤0 → conf-abort, same envelope pattern as `EXECUTION_BACKEND` validation.
- The conf example instructs: when setting `ISSUE_FILTER` on a repo whose
  open `autonomous` issue count can approach 100, raise `ISSUE_SCAN_LIMIT`
  to comfortably exceed the repo's total open `autonomous` count.
- The new INV (§7) names filter-after-limit truncation as a known hazard
  bounded by this knob.

## 4. New library: `lib-issue-filter.sh`

A sibling `lib-*.sh` in `skills/autonomous-dispatcher/scripts/` (lib-only PR:
no installer re-run needed; wrappers/tick resolve libs via `readlink -f` per
the #227 contract).

**Sourcing:** `lib-dispatch.sh` self-sources `lib-issue-filter.sh` with the
established idempotent `readlink -f` guard block (same idiom as its existing
lib-pr-linkage / lib-issue-provider / lib-code-host blocks) — so every
standalone consumer (unit tests source `lib-dispatch.sh` directly and call
selectors) resolves `issue_filter_apply` without changes. `dispatcher-tick.sh`
additionally calls `issue_filter_validate` explicitly (§4.3).

### 4.1 `issue_filter_compile <expr>`

Recursive-descent parser (pure bash, no eval) over the token stream:

- Tokens: `label:<v>`, `label:"<v>"`, `assignee:<v>`, `assignee:none`,
  `assignee:"<v>"`, `and`, `or`, `not`, `(`, `)`. The tokenizer is a
  character scanner, not a whitespace `split`: `(` and `)` self-delimit
  (so `(label:a` tokenizes as `(` + `label:a`), a `"` after `key:` opens a
  quoted value that may contain whitespace and closes at the next `"`
  (embedded `"` unsupported → parse error), everything else is
  whitespace-delimited. Pinned edge cases: whitespace-only `ISSUE_FILTER`
  ≡ unset (identity); empty atom value (`label:` / `label:""`) → parse
  error; trailing tokens after a complete expression → parse error
  (the parser must consume the entire token stream).
- Grammar: `expr := term (or term)* ; term := factor (and factor)* ;
  factor := not factor | ( expr ) | atom`.
- Output (on success, rc 0): two globals —
  `ISSUE_FILTER_JQ` (a jq boolean expression referencing only `$aN`
  variables and the normalized fields `.labels` / `.assignees`) and
  `ISSUE_FILTER_ARGS` (array of `--arg aN <value>` pairs).
- **Injection safety:** atom values NEVER appear in the jq program text —
  they travel exclusively via `--arg`. `label:") or true"` can only ever be
  an exact-match literal.
- Atom compilation:
  - `label:<v>`      → `((.labels // []) | index($aN) != null)`
  - `assignee:<v>`   → `((.assignees // []) | index($aN) != null)`
  - `assignee:none`  → `((.assignees // []) | length == 0)` — only the
    UNQUOTED spelling; `assignee:"none"` compiles as a literal-login
    membership atom (§3.1).
- Errors (unknown atom key, unbalanced parens, bare token, dangling operator,
  empty sub-expression, embedded quote) → rc≠0 with a message naming the
  offending token and its position.

### 4.2 `issue_filter_apply`

Reads a normalized JSON array on stdin, writes the filtered array:

- Empty/unset `ISSUE_FILTER` → `jq 'map(del(.assignees))'` — no select, but
  still strips any `assignees` key (needed because `itp_list_forbidden_combos`
  returns it unconditionally, §5). `del` on a missing key is a no-op, so
  selectors that never requested `assignees` pass through semantically
  unchanged.
- Non-empty → **lazy-compiles on first use** (if `ISSUE_FILTER_JQ` is unset,
  call `issue_filter_compile "$ISSUE_FILTER"`; compile failure → rc≠0,
  fail-closed — a standalone caller that never ran `issue_filter_validate`
  still gets defined behavior), then
  `jq "${ISSUE_FILTER_ARGS[@]}" "[.[] | select(${ISSUE_FILTER_JQ})] | map(del(.assignees))"`.
- Contract: the output **never contains `assignees`** — it is a
  filter-internal field, never part of any selector's public shape
  (`{number, labels, title?, comments?}` stays exactly as documented today).
  Identity under an empty filter is **semantic (jq-equal)**, not byte-level
  (the extra jq pass may reflow whitespace; every consumer parses with jq).

### 4.3 `issue_filter_validate`

Dry-run: compile + evaluate the compiled program against `[]`. Called by
`dispatcher-tick.sh` in the **existing upfront conf-validator block** —
after the lib sources, alongside the `EXECUTION_BACKEND` / `REVIEW_BOTS`
validators and **before the GH App token mint** (a poisoned conf must not
mint a token; this also gives AC6's test a stable anchor). On failure:
emit an **[INV-72] error envelope** — new code `ADT_CFG_ISSUE_FILTER_INVALID`
via `error_surface`, with a matching `docs/pipeline/errors.md` entry (same
pattern as `ADT_CFG_EXECUTION_BACKEND_INVALID`) — and abort the entire tick
rc≠0. **Fail-closed; a malformed filter never dispatches anything and never
falls back to unfiltered scanning** (an unfiltered fallback would silently
violate the disjointness contract and double-dispatch against sibling
instances).

Two additional validations in the same slot:

- **Reserved-label rejection:** a compiled filter whose atoms reference any
  pipeline state label (`in-progress`, `reviewing`, `pending-review`,
  `pending-dev`, `stalled`, `approved`) or the `autonomous` baseline label
  is a conf error (same envelope). Slice membership keyed on a state label
  would mutate as the state machine runs — violating the §7.2 stability
  corollary by construction; `autonomous` is already the implicit baseline.
- **Assignee capability gate (fail-open guard):** the `(.assignees // [])`
  fold means a provider leaf that OMITS `assignees` would make every issue
  look unassigned — `assignee:none` / `not assignee:X` would silently WIDEN
  the slice (the exact failure this feature exists to prevent). When the
  compiled filter contains any assignee atom, `issue_filter_validate`
  requires the provider caps file to declare `assignees=1` (new `.caps` bit,
  set to 1 for both in-tree providers in PR-A); absent/0 → conf-abort with
  the same envelope. Label-only filters skip this gate (`labels` is
  mandatory in the normalized shape).

### 4.4 Fields helper

`issue_filter_fields <base-csv>` returns `<base-csv>` unchanged when the
filter is empty, `<base-csv>,assignees` when non-empty — the leaf is asked
for `assignees` only when a filter will actually consume it. (Note this is a
`FIELDS_CSV`-projection statement, not a leaf-argv one: the GitHub leaf's
internal `--json` set gains `assignees` unconditionally, exactly as it
already over-fetches `comments` for callers that don't request them —
projection happens in `_itp_github_project_fields`.)

## 5. Provider seam change (the only cross-seam delta)

`itp_list_by_state`'s `FIELDS_CSV` vocabulary (provider-spec §3.1) gains
**`assignees`** — normalized as an array of login strings (like `labels`,
never objects):

- **GitHub leaf:** add `assignees` to the `gh issue list --json` field set in
  `_itp_github_state_read`, normalize `[.assignees[].login]`. Same single
  call — zero extra API cost. Projection helper already generic.
- **GitLab leaf:** the REST `/issues` response already carries `assignees`;
  normalize `[.assignees[].username]` in `_itp_gitlab_normalize_issue_row`.
- **`itp_list_forbidden_combos`** return shape widens from `number,labels`
  to `number,labels,assignees` **unconditionally** (Step-0 hygiene must also
  respect the slice; the verb takes no `FIELDS_CSV`, so the widening is a
  documented spec amendment, not conf-dependent). Both leaves updated
  identically. Existing callers read only `number`/`labels` — additive-safe.
- New **`.caps` capability bit `assignees=1`** on both in-tree providers —
  consumed by the §4.3 assignee capability gate (an out-of-tree provider
  that doesn't declare it can't be sliced by assignee, fail-closed).
- Filter evaluation stays entirely **caller-side** (INV-25 precedent: no jq
  programs cross the seam). The leaf only learns a new projectable field.
- `provider-spec.md` §3.1 amended; `tests/provider-conformance/
  run-provider-conformance.sh` gains shape assertions for the new field on
  both providers (present, array-of-strings, `[]` when unassigned).
- `spec-codesite-map.json` / `spec-guard-map.json` entries refreshed if the
  touched lines shift (mechanical; verified by `check-spec-drift.sh`).

## 6. Evaluation points (all stages)

All in `lib-dispatch.sh`; each selector pipes through `issue_filter_apply`
AFTER its existing jq predicate, and requests fields via
`issue_filter_fields`:

| Call site | Change |
|---|---|
| `list_new_issues` | fields `number,labels,title` → helper; `… \| issue_filter_apply` |
| `list_pending_review` | fields `number,labels` → helper; append apply |
| `list_pending_dev` | fields `number,labels,comments` → helper; append apply |
| `list_stale_candidates` | fields `number,labels` → helper; append apply |
| `list_hygiene_residue` (Step 0) | append apply (leaf now returns `assignees` too) |
| `count_active` | empty filter → current `itp_count_by_state` path (only the limit changes per §3.3). Non-empty → `itp_list_by_state open "autonomous" $LIMIT number,labels,assignees \| issue_filter_apply` then caller-side any-of + `length` — same semantics as the count leaf, filtered |

All six sites replace the literal `100` with `${ISSUE_SCAN_LIMIT:-100}` (§3.3,
both `count_active` paths included).

**Fail-closed on enumeration errors (both count paths):** the filtered
count path is a multi-stage pipe; it MUST propagate leaf failure (pipefail /
capture-then-check), never coerce to 0 — an API outage read as "0 active"
would open the Step-1 gate and over-dispatch. No `2>/dev/null || true`
framing on this path. Same contract as today's `set -e` abort on the
`itp_count_by_state` path.

**Deliberately NOT filtered:** `check_deps_resolved` (`itp_read_task` on a
single issue). A dependency may live in another dispatcher's slice or have no
`autonomous` label at all; dependency resolution must keep the global view.
This is stated in the doc/invariant so it is never "fixed" as an oversight.

Wrappers (`autonomous-dev.sh` / `autonomous-review.sh`) are unchanged — they
operate on a single already-selected issue and never scan.

## 7. Multi-dispatcher contract (new invariant)

New `INV-NN` in `docs/pipeline/invariants.md` (number claimed at PR-open time
to dodge rebase collisions), stating:

1. `ISSUE_FILTER` is a conjunctive refinement over the `autonomous` baseline;
   it narrows, never widens.
2. When multiple dispatcher instances serve one repo, their filters MUST be
   pairwise disjoint (no issue may match two instances' filters). This is an
   **operational contract** — the pipeline does not implement cross-host
   claiming; the label state machine's swap semantics already bound the
   residual race to the same single-instance window that exists today.
   **Corollary — slice membership must be stable while an issue is active:**
   the contract covers not just static filter disjointness but *mutation
   discipline*: routing labels / assignees on an issue in a transitional
   state (`in-progress`, `reviewing`, `pending-review`, `pending-dev`) must
   not be changed. Re-slicing an issue (moving it between boxes) is done
   only at rest (no state label). Label edits are plain writes, not
   compare-and-swap — a mid-tick re-route can make two hosts each see the
   issue in their slice for one tick; the per-controller dispatch marker
   ([INV-108]) does NOT dedupe across hosts.
3. Recommended pattern (in both conf examples): one routing label per box —
   `box-tokyo`, `box-sg` — and each instance filters `label:box-<id> and …`.
4. A malformed filter fail-closes the tick (§4.3). An issue matching NO
   instance's filter is simply never dispatched — that is operator-visible
   backlog, not an error; `status.sh` output is unaffected (it reads single
   issues).
5. Step-0 hygiene runs per-slice; label residue on issues outside every
   slice is cleaned by whichever instance's filter matches, or by the
   operator if none does (consequence of 4, documented).

**INV-25 amendment (PR-B, mandatory):** INV-25's current wording is an
unconditional global heal ("strip … at the very top of every tick"). Per-slice
hygiene narrows that guarantee, so the PR must amend INV-25 itself — scope the
heal to "issues matching this instance's `ISSUE_FILTER`" and cross-reference
the new INV — not merely add the new INV beside it (Pipeline Documentation
Authority: code diverging from a documented invariant is a bug by definition).
The new INV heading carries the `_Triage (issue #236): [machine-checked: …]_`
marker within 2 lines (machine-checked convention).

`state-machine.md` is untouched (no label-state transitions change).

## 8. Files touched (TWO PRs, seam-first)

Two PRs, following the one-seam-delta-per-PR discipline (#281/#283/W1a
precedent). PR-A is additive-safe with zero behavior change and merges
first; PR-B depends on it.

### PR-A — seam widening (zero behavior change)

| File | Change |
|---|---|
| `skills/autonomous-dispatcher/scripts/providers/itp-github.sh` | `assignees` in state-read `--json` + normalize `[.assignees[].login]`; forbidden-combos shape widened |
| `skills/autonomous-dispatcher/scripts/providers/itp-gitlab.sh` | `assignees` normalize `[.assignees[].username]`; forbidden-combos shape widened |
| `skills/autonomous-dispatcher/scripts/providers/itp-github.caps` / `itp-gitlab.caps` | new `assignees=1` capability bit |
| `docs/pipeline/provider-spec.md` | §3.1 `FIELDS_CSV` + forbidden-combos shape amendment; caps bit |
| `tests/provider-conformance/run-provider-conformance.sh` | exact-key `assignees` assertions (both providers, both verbs) |
| `docs/pipeline/spec-codesite-map.json` / `spec-guard-map.json` | refresh if touched lines shift (`check-spec-drift.sh`) |

### PR-B — filter feature (depends on PR-A)

| File | Change |
|---|---|
| `skills/autonomous-dispatcher/scripts/lib-issue-filter.sh` | new (compiler + apply + validate + fields helper) |
| `skills/autonomous-dispatcher/scripts/lib-dispatch.sh` | self-source block + 6 call sites (§6) + `ISSUE_SCAN_LIMIT` |
| `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` | `issue_filter_validate` + `ISSUE_SCAN_LIMIT` validation in the upfront conf-validator block (before token mint) |
| `skills/autonomous-dispatcher/scripts/dispatcher-multi-tick.sh` | export whitelist + `ISSUE_FILTER`, `ISSUE_SCAN_LIMIT` |
| `skills/autonomous-dispatcher/scripts/autonomous.conf.example` | `ISSUE_FILTER` + `ISSUE_SCAN_LIMIT` block (grammar, disjointness contract, box-label pattern, MAX_CONCURRENT note) |
| `skills/autonomous-dispatcher/scripts/dispatcher.conf.example` | same, per-project (+ inline charset restriction note) |
| `docs/pipeline/dispatcher-flow.md` | new pre-step "filter validation" section; filter-conjunction notes in the Step 0-5 sections; new failure-modes-table row (malformed filter → tick aborts, no side effects) |
| `docs/pipeline/invariants.md` | new INV-NN (§7, with triage marker) + **INV-25 scope amendment** |
| `docs/pipeline/errors.md` | `ADT_CFG_ISSUE_FILTER_INVALID` (+ scan-limit invalid) entries |
| `tests/unit/test-issue-filter.sh` | new — compiler + apply + validate unit tests |
| `tests/unit/…` (existing selector tests) | fixtures for filtered selectors + count_active dual path |

Both PRs are lib/provider/doc-only → **no `## Post-install / upgrade`
note needed** (no new entry-point script; Step 1 `npx skills update -g`
covers everything).

## 9. Acceptance criteria

ACs 1, 5 belong to PR-A (AC1's selector-level identity is re-asserted in
PR-B); the rest belong to PR-B.

- **AC1 — identity regression.** With `ISSUE_FILTER` unset/empty and
  `ISSUE_SCAN_LIMIT` unset: all five selectors and `count_active` produce
  **jq-equal** output to today (existing unit suites pass with at most
  fixture-shape refreshes; a new explicit assertion pins the empty-filter
  path of `issue_filter_apply`, including its `assignees`-stripping on
  forbidden-combos output). Identity is asserted at the **selector-output
  level**, not leaf argv: the W1a contract is shape-based, and this PR
  legitimately adds `assignees` to the GitHub leaf's `--json` set and
  widens the forbidden-combos shape (§5) — conformance assertions are
  UPDATED for those, not held byte-frozen. `count_active` empty-filter path
  must still route through `itp_count_by_state` (asserted).
- **AC2 — compiler correctness.** Unit tests cover: each atom form; operator
  precedence (`not` > `and` > `or`); parentheses (including adjacent-paren
  tokenization `(label:a or label:b)`); quoted labels with spaces;
  multi-assignee membership; `assignee:none` vs `assignee:"none"`
  (reserved form vs quoted literal). Error cases (unknown atom key,
  unbalanced parens, bare token, dangling operator, empty expression, empty
  atom value, trailing tokens, embedded quote) each → rc≠0 + message naming
  the offending token.
- **AC3 — injection safety.** A label value containing jq/shell
  metacharacters (`") or true`, `$`, backticks) is matched as an exact
  literal; fixture-asserted.
- **AC4 — evaluation coverage.** Fixture-driven tests assert the filter takes
  effect at all six §6 call sites; `count_active` asserted on both paths
  (empty ↔ non-empty filter give equal counts on a filter-matching-all
  fixture).
- **AC5 — seam conformance.** Both providers asserted by the conformance
  runner with **exact-key assertions** (not just is-array/sort): for
  `itp_list_by_state`, `assignees` present as an array of login strings when
  requested via `FIELDS_CSV`, `[]` when unassigned, and ABSENT when not
  requested; for `itp_list_forbidden_combos`, the widened
  `number,labels,assignees` shape with exactly those keys.
- **AC6 — fail-closed conf validation.** A malformed `ISSUE_FILTER` aborts
  the tick rc≠0 in the upfront validator block — before the GH App token
  mint, before Step 0: no token mint, no label edits, no dispatch markers,
  no agent spawn — emitting the `ADT_CFG_ISSUE_FILTER_INVALID` [INV-72]
  envelope; asserted by a tick-level test with a poisoned conf. Same
  assertions for: a filter referencing a reserved state label; an
  assignee-atom filter against a provider whose caps lack `assignees=1`;
  an invalid `ISSUE_SCAN_LIMIT`.
- **AC6b — fail-closed enumeration.** On provider-leaf failure, BOTH
  `count_active` paths abort the tick (never coerce to a 0 count), and a
  filtered selector propagates the failure rather than emitting `[]`;
  asserted with a failing-leaf fixture.
- **AC7 — docs in same PR.** PR-A: provider-spec §3.1 + caps bit. PR-B:
  dispatcher-flow (pre-step section + Step 0-5 notes + failure-modes row),
  invariants (new INV-NN with `_Triage (issue #236):` marker within 2 lines
  of the heading, **plus the INV-25 scope amendment**), errors.md entries,
  both conf examples — each in the same PR as its code (Pipeline
  Documentation Authority rule).
- **AC8 — multi-tick propagation.** Per-project `ISSUE_FILTER` /
  `ISSUE_SCAN_LIMIT` values export correctly into each project's subshell
  (existing multi-tick test pattern extended); a project without the
  attributes stays unfiltered at limit 100. An inline `ISSUE_FILTER`
  containing a `validate_inline_block`-rejected character fails the block
  validation loudly (existing behavior, asserted for this key).
- **AC9 — scan-limit knob.** `ISSUE_SCAN_LIMIT` reaches all six §6
  enumeration sites (fixture-asserted on at least one selector +
  `count_active`'s filtered path); unset defaults to 100.

## 10. Out of scope

- Cross-host claiming / owner labels (rejected as YAGNI; revisit only if the
  disjointness contract proves operationally insufficient).
- Server-side filter push-down into provider query languages (rejected:
  violates the seam principle; the bounded scan (§3.3 `ISSUE_SCAN_LIMIT`)
  keeps client-side filtering cheap).
- `assignee:me` indirection (rejected: ambiguous for an unattended bot).
- Filtering `check_deps_resolved` (deliberate non-goal, §6).
- Case-insensitive matching (dishonest on GitLab; labels are exact strings).
