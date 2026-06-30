# spec-gate: teach check-spec-drift.sh to recognize `itp_transition_state` calls (Form 3)

```
status: DESIGN — implementing this session
issue: prerequisite for #311 (B8 label-write migration) — the C→B path operator chose
scope: check-spec-drift.sh scanner enhancement + manifest + tests. ZERO wrapper edits, ZERO label-write migration.
out-of-scope: migrating any gh issue edit site (that is #311 itself, unblocked AFTER this lands)
```

## 1. Problem & motivation

`check-spec-drift.sh` (INV-80) is the executable-spec gate: it scans the four `PIPELINE_FILES` (`autonomous-dev.sh`, `autonomous-review.sh`, `dispatcher-tick.sh`, `lib-dispatch.sh`) for label-write sites and reconciles them (C.1–C.5 + the P1.1 variable-write ban) against `docs/pipeline/spec-codesite-map.json` + `transitions.json`.

It recognizes only TWO write forms:
- **Form 1** — `label_swap "$n" "remove" "add"` (positional: token #2=remove, #3=add).
- **Form 2** — `gh issue edit … --remove-label "X" --add-label "Y"` (literal flags).

It does **not** recognize **`itp_transition_state "$n" "remove" "add"`** — the [INV-87] ITP transition verb. As the #296 pluggable-providers migration moves label writes from raw `gh issue edit` to `itp_transition_state` (#311 B8 and beyond), those state transitions would **leave the spec-gate's view** (the literal `--add/--remove-label` moves into `providers/itp-github.sh`, outside `PIPELINE_FILES`). That is a silent coverage regression: the gate that guarantees "every label transition is declared in the spec" would stop seeing migrated transitions.

This issue closes that gap **before** #311 migrates any site: it adds **Form 3** so a direct `itp_transition_state` call in a `PIPELINE_FILE` is a first-class, scanned label-write site — keeping spec-gate coverage intact as #296 proceeds. This is the operator-chosen **C→B** path: upgrade the scanner first (C), so the later migration (B) is a pure mechanical, coverage-preserving change.

## 2. The load-bearing constraint (discovered during design)

**Two `itp_transition_state` calls already exist in scanned files and are currently invisible.** Adding Form 3 makes them visible immediately — so this PR MUST account for both in the same change or the gate self-trips:

1. **`autonomous-review.sh:3518`** — `itp_transition_state "$ISSUE_NUMBER" "reviewing" "approved"` (the `merge_closes_issue=0` terminal-transition fallback). Movement `reviewing|approved`. The manifest currently declares **2** `reviewing|approved` sites for review.sh (the raw `gh issue edit` at 3431, 3450). Once Form 3 sees line 3518, the discovered count becomes **3** → C.4 FAIL ("discovered 3, manifest declares 2") unless we **add a manifest `sites[]` entry** for 3518. (This is exactly the coverage gap the upgrade is meant to fix — 3518 SHOULD have been declared.)
2. **`lib-dispatch.sh:2118`** — `itp_transition_state "$issue_num" "$remove" "$add"`, inside the `label_swap()` body. This is a **variable-argument** call (`$remove`/`$add`, not literals). Form 3's movement scanner must **only read literal label operands and skip variable ones** (same as Form 2's bare/quoted-literal regex), so this call emits NO movement (its labels are unknowable statically — they come from label_swap's literal callers, which Form 1 already scans). It must also NOT trip the P1.1 variable-write ban (see §3.3).

## 3. Design

### 3.1 Form 3 in the three movement/write scanners (the core change)
Form 3 is structurally identical to Form 1 (positional args: #2=remove, #3=add). The minimal, lowest-risk change is to extend each Form-1 trigger to also fire on `itp_transition_state`, reusing the existing positional-parse logic verbatim.

- **`collect_movements` / `emit_movement`** (C.4): the `if (s ~ /label_swap[ \t]/)` positional branch and the outer dispatch `buf ~ /label_swap[ \t]/ || buf ~ /--(add|remove)-label/` both gain an `itp_transition_state[ \t]` alternative. The positional loop already counts quoted tokens #2/#3 — but it must **skip non-literal (variable) operands**: a token like `$remove` or `$ISSUE_NUMBER` is not a label. Refine the positional extractor so token #1 is ignored (it's the issue number) and tokens #2/#3 are used ONLY if they are bare label literals (`^[a-z][a-z0-9-]*$` after de-quoting); a `$`-leading token yields empty → no movement emitted (covers lib-dispatch.sh:2118).
- **`collect_writes` / `scan`** (C.1/C.2): Form 1 uses `emit_labels` (prints every quoted `[a-z]...` operand). `itp_transition_state` calls have the SAME shape; `emit_labels`'s regex `["'][a-z][a-z0-9-]*["']` already excludes `"$ISSUE_NUMBER"` (starts with `$`) and bare numbers. So extend the `if (s ~ /label_swap[ \t]/)` trigger to `itp_transition_state` too — the label set is the union of the literal #2/#3 operands, which C.1/C.2 validate against the declared label vocabulary.
- **`write_lines_for_file` / `movement`** (C.5): same positional extension as `emit_movement`, so a migrated site's movement sits adjacent to its manifest anchor.

### 3.2 Manifest: declare the existing review.sh:3518 site
Add one `sites[]` entry to `spec-codesite-map.json`: `{file: autonomous-review.sh, movement: reviewing|approved, anchor: <grep-unique literal within ±8 lines of 3518>}`. The anchor must be a stable literal near 3518 (e.g. the log line `"merge_closes_issue=0 — transitioning issue"`). This makes review.sh `reviewing|approved` declare 3, matching the post-Form-3 discovered count (3431, 3450, 3518). transitions.json's `reviewing→approved` row already exists (the raw sites declared it); no new transition, just one more code-site.

### 3.3 P1.1 variable-write ban — do NOT extend to Form 3
The P1.1 guard (`check_variable_writes`) bans `--add/--remove-label "$var"` in PIPELINE_FILES outside the allowlist. It keys on the literal `--(add|remove)-label[[:space:]=]+"?\$` flag pattern. An `itp_transition_state "$n" "$remove" "$add"` call contains NO `--add/--remove-label` flag, so it is invisible to P1.1 today and stays so — **correct**: the variable labels flow into the verb leaf (`providers/itp-github.sh`, outside scan) which is byte-identical and validated by `test-itp-write-leaves.sh`. We do NOT add a P1.1 check for `itp_transition_state` variable args, because lib-dispatch.sh:2118 (`label_swap` delegating with `$remove`/`$add`) is a legitimate, already-validated indirection — banning it would break the gate. (The label_swap callers' LITERAL labels are what C.1–C.5 validate via Form 1.) Document this decision in the map's NOTE.

### 3.4 Movement scanner: token #1 must be ignored
Form 1 (`label_swap`) and Form 3 (`itp_transition_state`) both put the issue-number as positional token #1, remove as #2, add as #3. The existing Form-1 loop counts quoted tokens and uses #2/#3 — `label_swap "$issue_num" "reviewing" "pending-dev"` has `"$issue_num"` as token #1 (a `$`-token, but it IS quoted so `match(/"[^"]*"/)` catches it as token #1, correctly skipped since only #2/#3 are read). Form 3 is identical: `itp_transition_state "$ISSUE_NUMBER" "reviewing" "approved"` → token #1=`$ISSUE_NUMBER` (skipped), #2=`reviewing`, #3=`approved`. **The existing #2/#3 positional logic already handles this** — but we add a guard: if token #2 or #3 starts with `$` (variable), treat as empty (no literal) so a fully-variable call like the lib-dispatch.sh:2118 delegation emits nothing.

### 3.5 Documented limitation — double-quoted positionals only (reviewed, intentional)
Form 3's positional scanner matches DOUBLE-quoted operands (`/"[^"]*"/`), mirroring Form 1. It does NOT cover single-quoted (`'reviewing'`), bare (`reviewing`), verb-via-variable, or variadic multi-remove `itp_transition_state` shapes. This is **intentional and sufficient** (verified by both reviews): an enumeration of all 38 `--add/--remove-label` operands across the four PIPELINE_FILES found **38 double-quoted, 0 single-quoted, 0 bare** — the codebase is uniformly double-quoted, and #311 mechanically transforms `gh issue edit --remove-label "X" --add-label "Y"` → `itp_transition_state "$N" "X" "Y"` (double-quoted). Multi-remove sites (e.g. `--remove-label "in-progress" --remove-label "pending-dev"`) cannot map to a 3-positional verb call, so #311 leaves them as Form-2 `gh issue edit` (still scanned) — no gap. Extending Form 3 to single-quote/bare now would be speculative gold-plating against shapes the convention does not produce. A future migration that DID introduce a single-quoted/bare `itp_transition_state` would silently escape movement coverage — if that convention ever changes, extend the `/"[^"]*"/` token regex to a quoted-or-bare alternative (mirroring Form 2's `(["'][a-z]…|[a-z]…)`) and add the matching tests. (Recorded as a known boundary, not a bug — codex review P2.)

## 4. Zero-behavior-regression argument
- The scanner change is **purely additive**: a new trigger alternative + a `$`-operand skip guard. Form 1 and Form 2 recognition is byte-unchanged (the regexes and positional logic for `label_swap`/`gh issue edit` are untouched).
- No `PIPELINE_FILE` wrapper is edited. No label-write is migrated. The dispatcher's runtime behavior is identical.
- The ONLY new gate output: review.sh:3518 + lib-dispatch.sh:2118 become visible. 3518 gets a manifest entry (now declared); the 2118 delegation emits no movement (variable args) and trips no P1.1 (no flag) → both reconcile cleanly.
- After this lands, #311 (and B5+B7's siblings, future label-write batches) can migrate `gh issue edit`→`itp_transition_state` as a **coverage-preserving** change: the migrated call is still a scanned Form-3 site, so the manifest entry stays (only the anchor literal may need re-pointing within ±8 lines), C.4 count is unchanged, no silent coverage loss.

## 5. Files touched
| File | Change |
|---|---|
| `skills/autonomous-dispatcher/scripts/check-spec-drift.sh` | Form 3 trigger + `$`-operand skip guard in `emit_movement` (C.4), `scan` (C.1/C.2), `movement` (C.5) |
| `docs/pipeline/spec-codesite-map.json` | +1 `sites[]` entry for review.sh:3518 reviewing|approved; extend the NOTE re: Form 3 / P1.1-not-extended |
| `docs/pipeline/invariants.md` | INV-80 note: spec-gate now recognizes `itp_transition_state` (Form 3) |
| `tests/unit/test-spec-drift.sh` | new TC-SPEC-GATE-050..05N: Form-3 discovery (C.4), literal-vs-variable operand, real-repo reconciliation incl. 3518, P1.1-not-tripped by the lib-dispatch.sh:2118 delegation |

## 6. Test plan (TDD — write first, see §test-cases doc)
- **TC-SPEC-GATE-050**: a synthetic `itp_transition_state "$N" "reviewing" "pending-dev"` in a fixture pipeline file → C.4 discovers movement `reviewing|pending-dev` (Form 3 recognized).
- **TC-SPEC-GATE-051**: a variable-arg `itp_transition_state "$N" "$rm" "$add"` → emits NO movement (skip-variable guard) AND does not trip P1.1.
- **TC-SPEC-GATE-052**: mixed — token #1 `"$ISSUE_NUMBER"` ignored, #2/#3 literals read; assert exactly the #2/#3 movement.
- **TC-SPEC-GATE-053**: real-repo reconciliation — with the new manifest entry, `check-spec-drift.sh` exits 0 (review.sh reviewing|approved discovers 3 == declares 3, incl. 3518).
- **TC-SPEC-GATE-054 (negative)**: remove the new 3518 manifest entry → C.4 FAILs ("discovered 3 … declares 2"), proving Form 3 sees 3518 and the manifest entry is load-bearing.
- All run in the CI `Spec Drift` job via `tests/unit/test-spec-drift.sh`.
