# Test Cases — Executable Spec Gate (issue #236)

ID format: `TC-SPEC-GATE-NNN`. Driver: `tests/unit/test-spec-drift.sh`
(GitHub-hosted CI, no credentials). All fixtures use stubbed `gh`/`jq` outputs
committed under `tests/unit/fixtures/spec-gate/`.

> Scope note: this issue **documents and gates** — it changes ZERO dispatch
> behavior. So every test asserts on the SPEC artifacts (transitions.json,
> schemas, generator, checker), never on live wrapper behavior.

## Schema validation (reuses the #229/#230 backend-detect pattern)

| ID | Scenario | Expected |
|---|---|---|
| TC-SPEC-GATE-001 | `transitions.schema.json` + `observation-snapshot.schema.json` are valid Draft-07 | meta-validation passes (python backend) / structural check (jq fallback) |
| TC-SPEC-GATE-002 | `transitions.json` validates against its schema | accepts |
| TC-SPEC-GATE-003 | Golden `transitions.golden.*.json` examples validate | accept |
| TC-SPEC-GATE-004 | Negative `transitions.negative.*.json` examples (missing `schema_version`; bad `from` state enum; `actions` with an unknown verb; transition missing `mermaid`) | rejected |
| TC-SPEC-GATE-005 | Golden `observation-snapshot.golden.*.json` (assembled from stubbed gh outputs) validates | accepts |
| TC-SPEC-GATE-006 | Negative observation-snapshot (liveness state outside {alive,dead,indeterminate}; missing a required source field) | rejected |

## Generator idempotence + drift injection

| ID | Scenario | Expected |
|---|---|---|
| TC-SPEC-GATE-010 | `gen-state-machine.sh` run once, then again, on a scratch copy | second run is a byte-for-byte no-op (idempotent) |
| TC-SPEC-GATE-011 | `gen-state-machine.sh --check` against the committed `state-machine.md` | exit 0 (committed region already matches the table) |
| TC-SPEC-GATE-012 | Drift A: edit a `mermaid` edge in a scratch `transitions.json`, run `--check` | exit ≠ 0; diff shows the changed edge |
| TC-SPEC-GATE-013 | Drift B: hand-edit the mermaid inside the marker region of a scratch doc, run `--check` against unchanged table | exit ≠ 0; diff shows the hand-edit |
| TC-SPEC-GATE-014 | Generator preserves everything OUTSIDE the marker region | bytes before BEGIN + after END marker are unchanged |
| TC-SPEC-GATE-015 | Marker region present in the real `state-machine.md` | both BEGIN/END markers found exactly once |

## Guard/action mapping (Check B.1)

| ID | Scenario | Expected |
|---|---|---|
| TC-SPEC-GATE-020 | Every `guard`/`action` token in `transitions.json` has an entry in `spec-guard-map.json` | checker exit 0 |
| TC-SPEC-GATE-021 | Every mapped `function` is actually defined (`^name\(\)`) in its cited file | checker exit 0 |
| TC-SPEC-GATE-022 | Every mapped `predicate` literal still greps in its cited file | checker exit 0 |
| TC-SPEC-GATE-023 | Remove a predicate from a scratch `spec-guard-map.json` (token now unmapped) | checker exit ≠ 0, naming the orphaned token |
| TC-SPEC-GATE-024 | Point a mapped predicate at a string that does NOT grep (simulate code drift) | checker exit ≠ 0, naming the stale predicate + file |
| TC-SPEC-GATE-025 | Point a mapped function at a name not defined in the file | checker exit ≠ 0, naming the missing function |

## Label-write-site completeness (Check C — the undeclared/removed/duplicate/relocated/variable-site catcher)

Check C has five sub-checks plus a variable-write ban: **C.1 vocabulary** (every
written label is a known label), **C.2 movement** (every write site's `removes→adds`
combination is a declared transition), **C.3 code-site coverage** (every
code-bearing transition is pinned, bidirectionally, to a grep-stable anchor in
`spec-codesite-map.json`'s `code_sites`), **C.4 discovered-site reconciliation**
(the count of literal write sites per `(file, movement)` equals the count of
`sites[]` manifest entries), **C.5 per-site anchor adjacency** (each `sites[]`
anchor greps exactly once AND has a write of its movement within ±8 lines), and the
**P1.1 variable-write ban** (a variable-valued `--add/--remove-label "$x"` fails
unless allowlisted). C.1 is vocabulary; C.2 is movement-*set* membership; C.3
catches a deleted row whose movement is shared; C.4 catches a NEW duplicate /
shared-movement site; C.5 catches a RELOCATED site (same file/movement, count
unchanged); the ban catches a variable write. Together they make the AC *"a PR
adding (even a duplicate / shared-movement / relocated / variable) **or removing**
a label-write site without the matching transitions.json entry fails CI"* hold.

| ID | Scenario | Expected |
|---|---|---|
| TC-SPEC-GATE-030 | Every label literal written by the six pipeline files (`label_swap` and direct `itp_transition_state` args plus `--add/--remove-label` literals) appears as a `state` or in an `actions[]` of `transitions.json` | checker exit 0 (C.1) |
| TC-SPEC-GATE-031 | Simulate a new `label_swap "$n" "" "frobnicate"` write site in a scratch copy (brand-new label) with no matching transition | checker exit ≠ 0 with an actionable message naming `frobnicate` (C.1) |
| TC-SPEC-GATE-032 | All 8 pipeline labels (`autonomous`, `in-progress`, `pending-review`, `reviewing`, `pending-dev`, `approved`, `no-auto-close`, `stalled`) appear in transitions.json as a state or action | present |
| TC-SPEC-GATE-033 | A `gh issue edit … --add-label "splitlabel"` whose label literal sits on a *continuation* physical line (logical-line join, M2) is still scanned | checker exit ≠ 0 naming `splitlabel` |
| TC-SPEC-GATE-034 | No variable-valued label write remains in the six pipeline files after `label_swap` and `hygiene_strip_residual_labels` delegated to `itp_transition_state` | `variable_write_allowlist.sites` is empty; checker emits neither allowlist INFO nor P1.1 failure; real repo passes |
| TC-SPEC-GATE-035 | Simulate a new `label_swap "$n" "approved" "stalled"` write site reusing EXISTING labels but in an undeclared `(remove→add)` combination | checker exit ≠ 0 naming the `approved → stalled` movement (C.2) — passes C.1 vocabulary, fails C.2 movement |
| TC-SPEC-GATE-036 | Every label movement in the committed code maps to a declared transition (real repo) | checker prints `all N label-write movements map to declared transitions` (C.2) |
| TC-SPEC-GATE-037 | **Delete** the `dispatch-pending-dev-pr-exists` transition row (its `pending-dev→pending-review` movement is shared with `dispatch-review-aware-reroute-review`), regenerate the diagram, rerun | checker exit ≠ 0 naming the orphaned `dispatch-pending-dev-pr-exists` `spec-codesite-map.json` entry (C.3) — **the second reviewer-reproduced [P1]**: C.2 stays green (shared movement), C.3 catches the removed write site |
| TC-SPEC-GATE-038 | Point a `spec-codesite-map.json` anchor at a string that no longer greps (write site renamed/removed) | checker exit ≠ 0 naming the stale anchor (C.3 forward) |
| TC-SPEC-GATE-039 | Every code-bearing transition (actor ∉ {maintainer, github}) maps to a resolvable code site (real repo) | checker prints `all K code-bearing transitions map to a resolvable code site` (C.3) |
| TC-SPEC-GATE-042 | Append a NEW `label_swap "$n" "pending-dev" "pending-review"` write site whose movement is ALREADY declared (by two existing transitions) | checker exit ≠ 0 with a `C.4:` message naming the unaccounted `dispatcher-tick.sh pending-dev\|pending-review` site (C.4) — **the third reviewer-reproduced [P1]**: C.2 + C.3 both stay green, C.4 catches the duplicate/shared-movement site. Directly re-verifies the AC |
| TC-SPEC-GATE-043 | Append a site to an already-counted group (`autonomous-review.sh reviewing\|pending-dev` declares 8 → discovered 9) | checker exit ≠ 0 with a `C.4:` message naming the 9-vs-8 count delta |
| TC-SPEC-GATE-044 | Discovered literal-site counts per `(file, movement)` all equal the `sites[]` manifest counts (real repo) | checker prints `all discovered label-write sites reconcile with the sites[] manifest` (C.4) |
| TC-SPEC-GATE-045 | Append a variable-valued `gh issue edit "$n" --add-label "$new_label"` in a NON-allowlisted spot | checker exit ≠ 0 naming the `variable label write … NOT allowlisted` site (P1.1) — **the first reviewer-reproduced [P1]**: was a green NOTE, now a hard FAIL |
| TC-SPEC-GATE-046 | **Relocate** the `label_swap "$n" "pending-dev" "pending-review"` out of `handle_pending_dev_pr_exists()` and re-insert the same call elsewhere in `lib-dispatch.sh` (same file, same movement, count unchanged) | checker exit ≠ 0 with a `C.5:` message: the anchor `transitioning to pending-review instead of` has no adjacent `pending-dev\|pending-review` write — **the second reviewer-reproduced [P1]**: C.4 count stays 2, C.3 anchor still greps, only C.5 catches the relocation |
| TC-SPEC-GATE-047 | Every `sites[]` anchor is grep-unique in its file AND has a write of its movement within ±8 lines (real repo) | checker prints `all S manifest sites are uniquely anchored and adjacent to their write` (C.5) |
| TC-SPEC-GATE-052/054/056/057 | A literal `--add-label` write in each quoting form — `=`-joined double-quote (052), single-quote (054), digit-bearing (056), and **unquoted bare word** `--add-label frobnicate` (057, reviewer [BLOCKING]) — with an undeclared label | checker exit ≠ 0 naming the label (C.1) — the form-2 scanners accept the quoted-OR-bare alternative across every quoting style; a bare label still never matches a `$`-variable write (that stays the P1.1 ban, TC-045) |
| TC-SPEC-GATE-053 | A variable label write split across backslash-continuation lines (`gh issue edit "$n" \` ⏎ `--add-label \` ⏎ `"$evil"`) in a non-allowlisted spot | checker exit ≠ 0 naming the `variable label write … NOT allowlisted` site (P1.1 logical-line join) |

## Invariant triage

| ID | Scenario | Expected |
|---|---|---|
| TC-SPEC-GATE-040 | Every `## INV-NN:` heading in `invariants.md` is followed (within its block) by exactly one triage tag line | all 73 tagged; zero untagged |
| TC-SPEC-GATE-041 | Each triage tag is one of the three allowed forms | tag ∈ {`machine-checked`, `design-rationale`, `superseded`} |

## Behavior-unchanged guard

| ID | Scenario | Expected |
|---|---|---|
| TC-SPEC-GATE-050 | No file under `skills/autonomous-{dispatcher,dev,review,common}/scripts/**` or `…/hooks/**` `.sh` is modified by this PR | git diff touches only docs/ + tests/ + new gen/check scripts + ci.yml (the new scripts are additive, not edits to runtime libs) |
| TC-SPEC-GATE-051 | Full existing unit suite still green | `tests/unit/test-*.sh` all pass |

## E2E (CI, no credentials)

| ID | Scenario | Expected |
|---|---|---|
| TC-SPEC-GATE-060 | `spec-drift` CI job runs on bare `ubuntu-latest` (jq + coreutils only) | green on a synced PR |
| TC-SPEC-GATE-061 | Deliberate-drift PR simulation (documented in PR body with a red-run link) | job goes red with the actionable message |
