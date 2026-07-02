# issue #331 — extend `itp_transition_state` (CSV multi-remove) for the 4 label-flip survivors

```
status: DESIGN — implementing this session (autonomous, #296 second-tier)
issue: #331
scope: itp_github_transition_state leaf CSV-split + migrate 4 raw `gh issue edit` label-flip sites
       + spec-gate C.3 re-anchor + cutover-baseline shrink + provider-spec/INV/tests.
out-of-scope: chp_pr_comment / chp_list_inline_comments / chp_reply_review_comment / chp_commit_file
              (separate sub-issues); `gh issue close` (INV-33 keeps it raw).
```

## 1. Problem & motivation

`#296` drives the provider-neutral caller layer to **zero** raw `gh`. Four `gh issue edit`
label-flip survivors remain in the two HOT wrapper files + the core lib:

| # | Site | Current raw form | Fail-safe framing (MUST preserve) |
|---|---|---|---|
| A1 | `autonomous-dev.sh` (PR-found success) | `gh issue edit … --remove-label in-progress --remove-label pending-dev --add-label pending-review` | `… \|\| log "WARNING…"` |
| A2 | `autonomous-review.sh` (post-merge approved-flip, INV-33) | `gh issue edit … --remove-label reviewing --remove-label autonomous --add-label approved` | `… 2>/dev/null \|\| true` |
| A3 | `lib-dispatch.sh::hygiene_strip_residual_labels` | variadic N-remove, NO add, VARIABLE labels (`$stripped` list) | `gh "${args[@]}" 2>/dev/null \|\| true` |
| B  | `autonomous-review.sh` (auto-merge-fail re-queue) | `if ! _edit_err=$(gh issue edit … --remove-label reviewing --add-label pending-dev 2>&1 >/dev/null); then` | `if ! _err=$(… 2>&1 >/dev/null); then log` stderr-capture |

The shipped verb is **3-positional single-remove** (`itp_transition_state ISSUE REMOVE ADD`).
Sites A1/A2 do a **multi-`--remove-label`** edit it can't express; A3 is variadic-N. B is
single-remove → already expressible by the unchanged 3-positional verb (only its caller-side
stderr-capture framing is preserved).

## 2. Signature decision — Option 1 (CSV-in-REMOVE, backward-compatible)

Keep the public signature `itp_transition_state ISSUE REMOVE ADD`; redefine `REMOVE`/`ADD`
from "one label" to "one **or** a comma-separated list". A single label is a CSV of length 1
→ **every existing 3-positional caller keeps working byte-identically** (17 callers, single-label).
The leaf splits each operand on `,`, emits one `--remove-label`/`--add-label` per non-empty
member, preserving the `[ -n ]` empty-side guards.

**Rejected alternatives** (both fold into the issue's design considerations):
- `ISSUE ADD -- REMOVE…` sentinel — reorders operands; breaks the spec-gate Form-3 scanner
  (`emit_movement` hard-codes positional token #2=remove, #3=add).
- separate `itp_remove_labels` verb — breaks atomicity ([INV-08]: the two Part-A flips
  remove + add in the SAME atomic edit); needs a new shim/Form/caps line.

## 3. Design

### 3.1 The leaf (`providers/itp-github.sh::itp_github_transition_state`)
Split REMOVE/ADD on `,`; emit one flag per non-empty member; keep the empty-side flag omission.

```sh
itp_github_transition_state() {
  local issue_num="$1" remove="$2" add="$3"
  local args=() _csv _m
  IFS=',' read -ra _csv <<<"$remove"
  for _m in "${_csv[@]}"; do [ -n "$_m" ] && args+=(--remove-label "$_m"); done
  IFS=',' read -ra _csv <<<"$add"
  for _m in "${_csv[@]}"; do [ -n "$_m" ] && args+=(--add-label "$_m"); done
  gh issue edit "$issue_num" --repo "$REPO" "${args[@]}"
}
```

**Backward-compat (byte-identical):** a single label `reviewing` is `IFS=,` split into one
member `reviewing` → exactly `--remove-label reviewing` (same as today). Empty `""` →
zero members → flag omitted (same as today's `[ -n ]` guard).

**[P2] CSV-on-comma precondition (codex + plan-eng):** the split bakes an *undocumented*
"no label name may contain a `,`" precondition into the shipped verb. It is **inert today**
(every pipeline label is comma-free; A3's CSV is built from a hardcoded comma-free jq
allowlist). But a verb is a provider-portability boundary, so:
1. **Document it** in provider-spec §3.1 ("REMOVE/ADD are comma-separated; label names
   containing `,` are unsupported via this path").
2. **Add a loud guard** in the leaf — a comma-bearing *single* label cannot be distinguished
   from a 2-element CSV, so the contract is "a member must not itself contain a comma." The
   leaf has no way to know caller intent, so the explicit guard is at the documented seam:
   reject a member that is empty-after-trim only via the existing `[ -n ]`; the comma-bearing
   case is covered by the unit-test assertion + the spec doc. (We do NOT silently swallow —
   the precondition is loud in the spec and pinned by a TC-ITV case asserting the split.)

   > Decision: the leaf cannot *detect* "this single label legitimately contained a comma"
   > vs "this is a 2-member CSV" — they are the same bytes. So the guard is **documentation +
   > a test that pins the split semantics** (a comma-bearing operand splits), NOT a runtime
   > reject (which would have to reject ALL commas, breaking the multi-remove feature). This
   > is the honest contract: the seam declares "comma is the member separator."

### 3.2 Migrate the 4 sites
- **A1** `autonomous-dev.sh`: `itp_transition_state "$ISSUE_NUMBER" "in-progress,pending-dev" "pending-review" || log "WARNING: Failed to update issue labels"` (preserve `|| log`).
- **A2** `autonomous-review.sh`: `itp_transition_state "$ISSUE_NUMBER" "reviewing,autonomous" "approved" 2>/dev/null || true` (preserve `2>/dev/null || true`).
- **A3** `lib-dispatch.sh::hygiene_strip_residual_labels`: build the CSV from the REAL scalar
  `$stripped` (space-separated) via `tr ' ' ','`, no add:
  `itp_transition_state "$issue_num" "$(echo "$stripped" | tr ' ' ',')" "" 2>/dev/null || true`.
  The `_has_terminal_label` prefilter + `[[ -z "$stripped" ]]` early-return + the
  `echo "$stripped"` return stay byte-identical (atomicity preserved: one verb call = one
  atomic `gh issue edit`).
  - **[P2 fix]** the migration uses `$stripped` (the actual scalar), NOT a non-existent
    `stripped_array`.
  - **[P3]** TC-HYG-006 (already-clean issue) must still early-return → ZERO verb calls
    (no no-op `gh issue edit` with zero `--remove-label`).
- **B** `autonomous-review.sh`: `if ! _edit_err=$(itp_transition_state "$ISSUE_NUMBER" "reviewing" "pending-dev" 2>&1 >/dev/null); then log …` (single-remove via the unchanged 3-positional verb; preserve the stderr-capture `if ! …` framing).

### 3.3 [P1] Spec-gate C.3 re-anchor (load-bearing)
Migrating strips 3 `spec-codesite-map.json` `code_sites` anchor literals (the raw
`gh issue edit` forms), so `check-spec-drift.sh` FAILs C.3 with 3 `::error::code-site for …`:
| transition id | OLD anchor (stripped by migration) | NEW anchor (grep-stable near migrated call) |
|---|---|---|
| `dev-trap-success-pr` | `--add-label "pending-review"` (dev:837) | `PR found: move to pending-review for the review agent` (the adjacent comment, already a `sites[]` anchor) |
| `review-pass-merged` | `--remove-label "autonomous"` (review:3467) | `never close the issue directly` (the INV-33 comment, already a `sites[]` anchor) |
| `review-no-pr` | `--remove-label "reviewing"` (review:3553) | `a failed label transition is diagnosable` (the adjacent comment, already a `sites[]` anchor) |

The NEW anchors are literals that survive migration (comments adjacent to the migrated calls,
already used as `sites[]` C.5 anchors → proven grep-unique). The re-anchor test (AC3) is
RED-without-it: a pinned test that the 3 anchors point at the migrated forms (FAILS if the map
still lists the raw `gh issue edit` literals).

### 3.4 C.4/C.5 movements — already covered by the existing Form-3 scanner (#313)
`emit_movement` extracts token #2 (remove) and #3 (add) as single operands, then `norm()`
**splits each on `,`**. So `itp_transition_state "$I" "in-progress,pending-dev" "pending-review"`
emits movement `in-progress,pending-dev|pending-review` — which already matches the existing
`sites[]` entry (`autonomous-dev.sh … "movement": "in-progress,pending-dev|pending-review"`).
A2 → `autonomous,reviewing|approved` (sorted) matches the existing `autonomous,reviewing|approved`
entry. B → `reviewing|pending-dev` matches. **No scanner change needed; the CSV form is already
recognized.** A3 (variable `$(…)` operand) emits no movement (the `$`-skip guard / non-literal
operand) — same as today's hygiene loop, covered by the `variable_write_allowlist` entry.

### 3.5 Baseline shrink
The 4 sites are 4 distinct `(file, content)` signatures in `providers/cutover-baseline.json`:
`autonomous-dev.sh` (×1), `autonomous-review.sh` (×2: the A2 + B `gh issue edit` lines),
`lib-dispatch.sh` (×1: `gh "${args[@]}" 2>/dev/null || true`). Migrating removes all 4 →
baseline shrinks by exactly 4 (a fixed delta). **Issue said 67→63; the #296 second-tier PR
stream keeps shrinking the live baseline concurrently, so the absolute before/after numbers
drift on every rebase — the delta of 4 is the invariant, not any specific pair of numbers.**
Pinned mechanically via `--generate-baseline`; the unit test asserts the 4 specific
`(file, content)` signatures are ABSENT rather than an absolute count, so it is robust to
concurrent baseline churn.

### 3.6 provider-spec + INV + state-machine
- provider-spec §3.1 `itp_transition_state` row: document the CSV multi-label semantics + the
  comma precondition.
- New INV — landed as **INV-97** (drafted as INV-96, but #327's `chp_reply_review_comment`
  invariant merged to `main` as INV-96 first, so per the collision recipe this was bumped to the
  next free number on rebase: heading + cross-file refs + the test's triage-marker assertion all
  updated together). Heading carries the `_Triage (issue #236): [machine-checked:
  tests/unit/test-itp-transition-variadic.sh]_` marker within 2 lines (`#236` FIXED literal).
- state-machine.md: the Form-3 scanner already recognizes `itp_transition_state` (#313) and the
  `norm()` CSV-split already handles the multi-label form — confirm + note in the §2 provider
  paragraph that the migrated multi-label flips stay scanned.

## 4. Zero-behavior-regression argument
- The leaf is byte-identical for single-label callers (CSV-of-1 → one flag). CSV emits one flag
  per member in order. The empty-side omission is preserved.
- The 4 migrated calls emit the SAME `gh issue edit` argv the raw forms did (golden-trace pinned).
- The caller-side fail-safe framing (`|| log`, `2>/dev/null || true`, stderr-capture `if !`) is
  preserved per-site (pinned by source-shape tests).
- Spec-gate C.4/C.5 movements unchanged (Form-3 + `norm()` CSV-split). Only C.3 anchors move
  (re-anchored in the same PR).

## 5. Files touched
| File | Change |
|---|---|
| `providers/itp-github.sh` | CSV-split REMOVE/ADD in `itp_github_transition_state` |
| `autonomous-dev.sh` | A1 → `itp_transition_state … "in-progress,pending-dev" "pending-review"` |
| `autonomous-review.sh` | A2 → `… "reviewing,autonomous" "approved"`; B → `… "reviewing" "pending-dev"` (stderr-capture) |
| `lib-dispatch.sh` | A3 hygiene_strip → `itp_transition_state … "$(echo "$stripped"\|tr ' ' ',')" ""` |
| `docs/pipeline/spec-codesite-map.json` | re-anchor 3 `code_sites` entries to migrated forms |
| `providers/cutover-baseline.json` | shrink by 4 (delta fixed; absolute count drifts with concurrent #296 PRs), mechanical regen |
| `docs/pipeline/provider-spec.md` | §3.1 CSV-semantics + comma precondition |
| `docs/pipeline/invariants.md` | new INV (CSV multi-label semantics) + triage marker |
| `docs/pipeline/state-machine.md` | confirm Form-3 CSV recognition note |
| `tests/unit/test-itp-transition-variadic.sh` | new TC-ITV-NNN suite |

## 6. Test plan (TDD) — see `docs/test-cases/issue-331-itp-transition-csv.md`
TC-ITV backward-compat / CSV-multi-remove / hygiene_strip / B-stderr-capture / spec-gate-C.3 /
source-shape baseline −4 + per-site fail-safe framing preservation. Plus the re-anchor RED test.
No new E2E (label transitions are internal).
