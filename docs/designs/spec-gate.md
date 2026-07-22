# Design Canvas — Executable Spec Gate (issue #236)

> CI-checker half of the executable-spec pillar. Documents and **gates** the
> existing state machine. **Zero dispatch behavior change** — no wrapper /
> dispatcher / lib-*.sh runtime code is touched.

## Problem

"Docs are authoritative" has no enforcement. 73 invariants and a hand-drawn
mermaid diagram drift from ~11K lines of bash silently; every drift is a future
incident. A full runtime reconciler is gated/stop-ruled (see
[[project_stability_redesign_2026_06]]); the CI-checker level is cheap and pays
immediately: undeclared label transitions become PR-blocking, and the diagram
can never lie again.

## Artifacts (all additive; nothing runtime-path is edited)

| Artifact | Role |
|---|---|
| `docs/pipeline/observation-snapshot.md` | Typed enumeration of every dispatcher-consulted input, each citing the `file:line` that reads it today. The HARD part — must come first (a label-only table would be performative). |
| `docs/pipeline/schemas/observation-snapshot.schema.json` | Draft-07 schema for a single ObservationSnapshot instance. Validates a fixture snapshot assembled from stubbed `gh` outputs. |
| `docs/pipeline/schemas/examples/observation-snapshot.golden.*.json` | ≥1 golden fixture snapshot (validates). |
| `docs/pipeline/transitions.json` | `schema_version`'d data encoding of every legal `(from, event, guards[], actions[], to)` tuple for the dev + review lifecycles, incl. the human-edit events (`no-auto-close` added, manual label flip). Each transition carries a `mermaid` edge string so the diagram is generated **from** the table. |
| `docs/pipeline/schemas/transitions.schema.json` | Draft-07 schema for `transitions.json`. |
| `docs/pipeline/schemas/examples/transitions.{golden,negative}.*.json` | Golden (validates) + negatives (rejected). |
| `docs/pipeline/spec-guard-map.json` | In-repo mapping: every `guard`/`action` token in `transitions.json` → a named function or greppable predicate string in `lib-dispatch.sh` / the wrappers. Maintained by hand; the checker fails when a token has no mapping or a mapped predicate is no longer greppable. |
| `docs/pipeline/spec-codesite-map.json` | Three sections: `code_sites` (every **code-bearing** transition id → `{file, anchor}`) for C.3; a `sites[]` per-physical-site manifest (`{file, movement, anchor}`, one per literal write site, anchor grep-unique + write-adjacent) for C.4 (count) and C.5 (anchor adjacency); and `variable_write_allowlist` (currently empty) for any future P1.1 exception. Maintained by hand alongside `transitions.json`; an orphaned `code_sites` entry, a stale/ambiguous anchor, a `sites[]` count drift, a relocated write (anchor no longer adjacent), or a non-allowlisted variable write fails the checker. |
| `scripts/gen-state-machine.sh` | `transitions.json` → mermaid block in `state-machine.md` (idempotent; marker-delimited region). |
| `scripts/check-spec-drift.sh` | The drift checker: (a) regenerate-and-diff; (b) guard-mapping + label-write-site completeness. Reused by CI and the unit test. |
| `.github/workflows/ci.yml` → `spec-drift` job | Runs the checker on plain GitHub-hosted CI (no credentials). |
| `invariants.md` triage tags | One-line `[machine-checked: …]` / `[design-rationale]` / `[superseded]` per INV. No content rewrites. |
| `tests/unit/test-spec-drift.sh` | TC-SPEC-GATE-NNN unit suite. |
| `docs/test-cases/spec-gate.md` | Test case document. |

## Why JSON (not YAML)

No stdlib YAML in any candidate substrate (bash + `jq`); `jq` is already a hard
dependency throughout the pipeline scripts. Per the issue's Design Considerations.

## Generator + marker contract

`state-machine.md` gains a marker-delimited region:

```
<!-- BEGIN GENERATED: state-machine — edit transitions.json + run scripts/gen-state-machine.sh -->
```mermaid
… generated …
```
<!-- END GENERATED: state-machine -->
```

- `gen-state-machine.sh` (default) **rewrites** the region in place from
  `transitions.json`.
- `gen-state-machine.sh --check` (used by CI) regenerates to a temp file and
  `diff`s; non-zero exit + a unified diff on any drift. It never mutates the doc.
- Idempotence: running the generator twice is a no-op (the second run produces a
  byte-identical region). The unit test asserts this.

The mermaid body is reproduced **faithfully from the existing hand-drawn diagram**
so the first CI run is green. Each `transitions.json` row carries the exact
`mermaid` edge label; `diagram.notes[]` carries the two `note right of …` blocks
verbatim. The generator is a pure serializer — it adds no edges the table does
not declare.

## Drift checker — three independent checks (A / B / C, matching `check-spec-drift.sh`)

### Check A — diagram drift (`gen-state-machine.sh --check`)
- Edit `transitions.json`, not the doc → regenerated region differs from
  committed region → **CI red**.
- Edit the doc inside the marker region, not the table → committed region differs
  from regenerated → **CI red**.

### Check B — guard/action mapping (`check-spec-drift.sh`)
- Every distinct `guard`/`action` token across all transitions must have an entry
  in `spec-guard-map.json`. Each entry names either a `function` (asserted to be
  defined: `^<name>\(\)` in the cited file) or a `predicate` (a literal grep
  pattern asserted to still match in the cited file). A token with no mapping, or
  a mapped predicate that no longer greps, → **CI red** naming the missing/stale
  pair.

### Check C — label-write-site completeness (`check-spec-drift.sh`)
FIVE sub-checks (plus a hard ban on un-allowlisted variable-valued writes) over
every `label_swap …` call, direct `itp_transition_state …` call, and
`gh issue edit … --add-label/--remove-label` literal across the six pipeline
files:
- **C.1 vocabulary**: every label literal written appears as a `state` or
  inside an `actions[]` (add-label:X / remove-label:X) of some transition. A
  brand-new label (e.g. a typo) with no transitions.json entry → **CI red**.
- **C.2 movement**: every write *site* performs a label MOVEMENT — the set of
  labels it removes plus the set it adds, normalized as
  `<sorted-removes>|<sorted-adds>`. That movement must equal the
  `(remove-label:…, add-label:…)` actions of some transition. A new write that
  reuses *existing* labels in an **undeclared combination** —
  e.g. `label_swap "$n" "approved" "stalled"` — passes C.1 (both labels exist)
  but **fails C.2**, because no transition declares the `approved→stalled`
  movement. C.1 alone is a vocabulary check and would let an undeclared
  transition between known labels through.
- **C.3 code-site coverage**: C.2 is movement-*set* membership, which is still
  not enough — two transitions can share one movement, so deleting one of them is
  invisible to C.2 (the other still declares the movement). `spec-codesite-map.json`
  pins every **code-bearing** transition (actor ∉ {maintainer, github}; human /
  GitHub events have no pipeline write site) to a grep-stable code **anchor**
  (function name or distinguishing literal), and C.3 checks the correspondence
  **both ways**: *forward* — every code-bearing transition has a map entry whose
  anchor still greps in its file (catches a new untracked transition, or a
  renamed/removed write site); *reverse* — every map entry's key is a live
  transition id (catches a **deleted** transition row whose movement is shared
  elsewhere). Deleting `dispatch-pending-dev-pr-exists` — whose
  `pending-dev→pending-review` movement is also declared by
  `dispatch-review-aware-reroute-review` — keeps C.2 green but leaves an orphaned
  `spec-codesite-map.json` entry → **C.3 CI red**.
- **C.4 discovered-site reconciliation**: C.2/C.3 never iterate the *discovered*
  write sites to confirm each is **accounted for**, so a brand-new site whose
  movement already exists elsewhere (a second
  `label_swap "$n" "pending-dev" "pending-review"`) passes both. C.4 closes that:
  the **count** of literal write sites the scanner finds per `(file, movement)`
  must equal the count of `spec-codesite-map.json`'s **`sites[]`** manifest entries
  for that `(file, movement)`. Adding a site → discovered > manifest → **CI red**;
  removing → below → **CI red**; a `(file, movement)` with no manifest entry →
  **CI red**. The count is over CODE SITES, not transition rows — one site can
  back several rows (`mark_stalled` → two `stalled` transitions) and one row can
  collapse several physical paths (`dev-trap-noprorfail`) — so the count is the
  stable, reconcilable quantity.
- **C.5 per-site anchor adjacency**: C.4 is a *count*, so **relocating** a write
  within the same file (same movement, count unchanged) is invisible to it — and
  C.3's transition anchors can be a whole function away from the write. The
  `sites[]` manifest gives every physical write site a grep-stable `anchor`; C.5
  asserts each anchor (a) greps **exactly once** in its file and (b) has a write
  of its `movement` **within ±8 lines**. Moving the
  `label_swap "$n" "pending-dev" "pending-review"` out of
  `handle_pending_dev_pr_exists()` (its anchor `transitioning to pending-review
  instead of` keeps greping, the count stays 2) leaves that anchor with no
  adjacent matching write → **C.5 CI red**. (For a *cluster* of same-movement
  sites packed within ±8 lines of each other, C.5's per-anchor adjacency could let
  one relocate behind a sibling's write; **C.4's exact per-`(file, movement)`
  count is the backstop** there — an add/remove still drifts the count. The two
  checks are complementary: C.4 counts, C.5 locates.)
- **P1.1 variable-write ban**: a variable-valued `--add/--remove-label "$x"` is a
  hard **CI red** (not a green NOTE) — it can inject an undeclared label the
  literal-site checks never see. `variable_write_allowlist` is currently empty:
  the former `label_swap` and `hygiene_strip_residual_labels` sites now delegate
  to `itp_transition_state` and contain no variable-valued label flags. The ban
  keys on the variable write's enclosing function, grep-stable.

C.1+C.2+C.3+C.4+C.5 + the variable-write ban together make the AC *"a PR adding
(even a duplicate / shared-movement / relocated / variable) or removing a
label-write site without the matching transitions.json entry fails CI with an
actionable message"* actually hold.

The checker prints `all N literal label-write sites map to declared labels`
(C.1), `all M label-write movements map to declared transitions` (C.2),
`all K code-bearing transitions map to a resolvable code site` (C.3),
`all discovered label-write sites reconcile with the sites[] manifest (G
file/movement groups)` (C.4), and `all S manifest sites are uniquely anchored and
adjacent to their write` (C.5) on success, plus an `allowlisted variable label
write …` line per allowlisted variable site. On failure a per-failure `::error::`
line names the undeclared movement / orphaned or unmapped transition / stale or
ambiguous anchor / unaccounted (or count-mismatched) site / relocated write /
non-allowlisted variable write.

> **Robustness:** the guard map keys on **function names** and **greppable
> predicate strings**, never on line numbers — line numbers drift on every edit
> and would make the checker brittle. The `observation-snapshot.md` citations DO
> carry `file:line` (they are documentation, re-verified by hand on change), but
> the *checker* only relies on grep-stable anchors.

## Decisions (autonomous; per Decision Making Guidelines)

- **Source of truth** = `skills/autonomous-dispatcher/scripts/` (root `scripts/`
  is a symlink into it). New scripts live there; they self-locate via
  `BASH_SOURCE`/`PROJECT_ROOT`.
- These are **CI/dev tools**, not wrapper-`source`d libs — they never run on the
  dispatch hot path, so a missing project symlink cannot crash a wrapper. (The
  Post-install Step-2 footgun applies only to files the wrappers `source`.)
- Checker depends only on `jq` + coreutils (`grep`, `diff`, `mktemp`) so it runs
  on bare `ubuntu-latest` with no credentials.
- Triage tags are derived mechanically where an INV already cites a `**Test**:`
  line (→ `machine-checked`); INVs with no test and a pure "Why" rationale →
  `design-rationale`; explicitly superseded INVs → `superseded`.

## Out of scope (per issue)

- Runtime reconciler / single-writer enforcement (gated phase, stop-rule).
- Events-channel selection (separate ADR spike).
- Rewriting `invariants.md` content (annotation only).
