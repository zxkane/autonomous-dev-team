# Test Cases: W1b abstract `itp_read_task` field contract (#396, #347 phase-2)

Covers the conversion of `itp_read_task` from a byte-identical `gh`-argv
passthrough ([INV-87], #281/#296/#306/#310/#315) to an abstract,
provider-neutral contract — no `gh` flags and no jq programs cross the seam
(`docs/pipeline/provider-spec.md` §3.1). Follows the [W1a] (#371) precedent.
Driven by `tests/unit/test-w1b-read-task-contracts.sh` (leaf-level) and
`tests/unit/test-w1b-read-task-parity.sh` (decision-level, per R5).

## Decision-level behavior parity (R5) — `test-w1b-read-task-parity.sh`

For each of the six callers, OLD (pre-#396, byte-identical passthrough) and
NEW (post-#396, abstract contract) select the exact same downstream decision.
The golden values are captured once from the OLD code and committed to
`tests/unit/fixtures/w1b-parity/decision-golden.json` (provenance in the
sidecar `.meta` file); this suite runs only the NEW code and diffs against
that golden.

| ID | Caller | Scenario | Expected |
|---|---|---|---|
| TC-W1B-PARITY-001 | `check_deps_resolved` (`lib-dispatch.sh`) | body with a `## Dependencies` section, one same-repo CLOSED dep | same `## Dependencies` section extraction / same resolved (rc 0) decision as OLD |
| TC-W1B-PARITY-002 | `check_deps_resolved` | body with an OPEN dep | same blocked (rc 1) decision as OLD |
| TC-W1B-PARITY-003 | `check_deps_resolved` | body with no `## Dependencies` section | same resolved (rc 0, no-op) decision as OLD |
| TC-W1B-PARITY-010 | `mark-issue-checkbox.sh` | body containing the target unchecked checkbox | same checkbox rewrite (`- [ ]` → `- [x]`) as OLD |
| TC-W1B-PARITY-011 | `mark-issue-checkbox.sh` | body with the checkbox already checked | same "Already checked" no-op decision as OLD |
| TC-W1B-PARITY-020 | `autonomous-review.sh` no-auto-close gate | labels include `no-auto-close` | same `HAS_NO_AUTO_CLOSE=true` gate decision as OLD |
| TC-W1B-PARITY-021 | `autonomous-review.sh` no-auto-close gate | labels exclude `no-auto-close` | same `HAS_NO_AUTO_CLOSE=false` gate decision as OLD |
| TC-W1B-PARITY-030 | `status.sh` `_next_action` | issue state `OPEN` | same "not terminal" branch as OLD |
| TC-W1B-PARITY-031 | `status.sh` `_next_action` | issue state `CLOSED` | same "terminal" branch as OLD |
| TC-W1B-PARITY-040 | `autonomous-dev.sh` issue-body fetch (title,body,comments) | normal fixture | normalized object contains the SAME title/body TEXT as OLD (labels/comments shape change documented, not parity-pinned per R5) |
| TC-W1B-PARITY-041 | `autonomous-dev.sh` resume-fallback fetch (title,body) | normal fixture | same title/body TEXT as OLD |

## Leaf-level shape / fields-subset / fail-closed — `test-w1b-read-task-contracts.sh`

### AC2 — zero gh flags / jq programs cross the seam

| ID | Scenario | Expected |
|---|---|---|
| seam-trace | Stub `itp_github_read_task` to record every argv it RECEIVES from all six real callers | every received argv is exactly `<issue> <fields-csv>` — no element matches `^--`, none contains `-q`/`select(`/`.labels[`/`any(` |
| secondary guard | Source grep over the caller-layer files (outside `providers/`) for `itp_read_task.*-q` / `itp_read_task.*--json` | zero matches |

### Leaf normalization shape

| ID | Scenario | Expected |
|---|---|---|
| title/body strings | gh payload with title/body | returned as plain strings |
| absent body | gh payload with `body` omitted | `body` → `""` (never null) |
| state passthrough | gh payload `state: "OPEN"` / `"CLOSED"` | returned verbatim (provider-neutral tokens already match) |
| labels shape | gh payload with `{name}` label objects | `labels` is an array of NAME strings, not objects |
| comments shape | gh payload with one comment | `comments` is the [INV-90] normalized array |
| comments source (review r2) | `comments` requested | leaf fetches `comments` via `itp_github_list_comments` (REST, [INV-90]) — a SEPARATE call from the primary `title,body,state,labels` `gh issue view`, NOT the same GraphQL response — so `author`/`authorKind` agree with `itp_list_comments` |
| comments source, gh api failure (review r2) | primary `gh issue view` succeeds, the REST comments call fails | leaf rc≠0, no partial stdout (fail-closed even though the primary call succeeded) |
| fields-subset (single) | `FIELDS_CSV=body` | output carries EXACTLY `body` |
| fields-subset (multi) | `FIELDS_CSV=state,labels,title` | output carries EXACTLY those three keys |
| empty fields-csv | `FIELDS_CSV=""` | output is `{}` |

### R2 — fail-closed

| ID | Scenario | Expected |
|---|---|---|
| gh rc≠0 | Stub `gh` fails | leaf rc≠0, no partial stdout |
| malformed JSON | `gh` returns rc 0 with garbage (non-JSON) body | leaf rc≠0 (fail-closed, not a silently-empty success) |

### Degraded-provider fixture (R4)

| ID | Scenario | Expected |
|---|---|---|
| TC-CAP-CHECKBOX0-BRANCH | `ISSUE_PROVIDER=degraded` drives `mark-issue-checkbox.sh` against the new contract | still reaches the documented `body_checkbox=0` native-subtask fallback branch; no `command not found`; no PATCH |

## Provider-conformance runner (R6) — `tests/provider-conformance/`

`itp_read_task` flipped from `pending` to `asserted` in `coverage.conf` (and
its `CONTRACT-PENDING` token removed from `provider-spec.md` §3.1) in this
same PR, per the R6/W2 tripwire. New `cap-map.conf` row `itp_read_task=-`.
New assertion helper drives the leaf with a fields-subset request and asserts
the normalized-object shape + fail-closed contract on gh failure / malformed
JSON, mirroring the `itp_list_by_state` shape-assert pattern.

## Retired golden-argv tests (R7)

The following byte-identical-argv pinning suites are retired (their coverage
is superseded by the parity + leaf-contract suites above):

- `test-itp-read-leaves.sh`'s `itp_read_task` golden-trace section (the
  `itp_list_comments` / dispatch-routing / caps / normalized-comment-shape /
  capability-branch / conformance-fixture-rule sections are UNCHANGED — those
  cover `itp_list_comments`, a different, unmigrated-by-this-PR verb).
- `test-itp-read-task-b5b7.sh` (entire file — the two byte-identical argv
  pins for the `autonomous-dev.sh` issue-body read and the
  `autonomous-review.sh` no-auto-close gate no longer apply to an abstract
  contract).
- `test-itp-read-task-body-golden-trace.sh` (entire file — TC-B2-GT-001..003
  pinned the `check_deps_resolved` body-read argv byte-identically).
- The read-shape argv pins in `test-itp-write-leaves.sh`
  (`TC-MCB-EQUIV-READSHAPE`) — replaced by a shape-equivalence assertion over
  the new normalized-object read; `TC-CAP-CHECKBOX0-BRANCH` is KEPT (still
  covers the `body_checkbox=0` branch) but its stub `gh` is updated to serve
  the new `--json title,body,state,labels,comments` shape.

## Downstream shape-consumer rewrites (R3)

| Site | Change |
|---|---|
| `lib-dispatch.sh::check_deps_resolved` | `itp_read_task … body -q '.body'` → `itp_read_task … body \| jq -r '.body'` |
| `autonomous-dev.sh` issue-body fetch (×2) | drops the forwarded `-q '.'` — the normalized object is embedded directly |
| `autonomous-review.sh` no-auto-close gate | `-q '[.labels[].name] \| any(...)'` → `\| jq -r '.labels \| any(...)'` (no `.name` — already normalized) |
| `status.sh` | `[.labels[].name]` → `[.labels[]]` |
| `mark-issue-checkbox.sh` | `itp_read_task … body -q '.body'` → `itp_read_task … body \| jq -r '.body'` |

`grep -rn 'itp_read_task.*-q\|itp_read_task.*--json'` outside `providers/`
after this PR returns ZERO hits — the last remaining `.labels[].name` /
raw-argv-forwarding survivor for this verb is gone.
