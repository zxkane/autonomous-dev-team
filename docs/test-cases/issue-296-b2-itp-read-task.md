# Test cases — #296 B2: migrate `lib-dispatch.sh` issue-body read behind `itp_read_task`

Issue: #306 (batch **B2** of the #296 pluggable-providers raw-`gh` migration).

## Scope

Migrate the single remaining byte-identical `gh issue view … --json body` issue-body
read in `check_deps_resolved` (`skills/autonomous-dispatcher/scripts/lib-dispatch.sh`)
behind the already-shipped `itp_read_task` ITP verb. **Zero behavior change** — the verb
shim chain forwards to the exact same `gh` argv:

```
itp_read_task "$issue_num" body -q '.body'
  → itp_${ISSUE_PROVIDER}_read_task "$@"            (lib-issue-provider.sh:98)
  → itp_github_read_task "$issue_num" body -q '.body' (default ISSUE_PROVIDER=github)
  → gh issue view "$issue_num" --repo "$REPO" --json body -q '.body'  (providers/itp-github.sh:85-88)
```

This is the last raw `gh issue view` in the dependency-resolution path. The other
`lib-dispatch.sh` raw-`gh` survivor (`gh "${args[@]}" 2>/dev/null || true`, a generic
gh-args passthrough) is **out of scope** and stays baselined.

## Test cases

| ID | Description | Surface | Expected |
|----|-------------|---------|----------|
| TC-B2-GT-001 | **Golden trace (body read)**: with a `gh` stub recording argv, the dependency-resolution path emits **exactly** `issue view <num> --repo <repo> --json body -q .body` after the migration — the same argv the raw call emitted before (no-behavior-change proof). Asserts the **body** read specifically (existing golden traces assert the `--json state` dep-lookup argv). | `tests/unit/test-itp-read-task-body-golden-trace.sh` (unit job) | PASS — body-read argv byte-identical |
| TC-B2-GT-002 | **Routing**: `itp_read_task` (default `ISSUE_PROVIDER=github`) forwards `"$@"` to `itp_github_read_task`, which emits the `gh issue view … --json body` leaf. | same | PASS — verb routes to the GitHub leaf |
| TC-B2-GT-003 | **No raw `gh issue view --json body` survives** in `check_deps_resolved`: source-grep `lib-dispatch.sh` finds the migrated `itp_read_task "$issue_num" body -q '.body'` and NO `gh issue view "$issue_num" --repo "$REPO" --json body -q '.body'`. | same | PASS |
| TC-B2-EQ-001 | **Behavior-equivalence (strongest proof)**: `tests/unit/test-check-deps-resolved.sh` mocks `gh` as a **binary** (`gh()` handling `--json body`), NOT via an `itp_read_task`/`itp_github_read_task` function-mock. After the migration the body read still bottoms out at that binary stub, so **all 46 existing dep-resolution assertions stay green with ZERO edits** — same `## Dependencies` parsing, same resolved/blocked outcomes. The unmodified-green run IS the equivalence proof. | `tests/unit/test-check-deps-resolved.sh` (unit job, unmodified) | PASS — 46/46, no edits |
| TC-B2-BASE-001 | **Cutover guard**: `check-provider-cutover.sh` exits 0 with `providers/cutover-baseline.json` shrunk by **exactly 1** (only the `lib-dispatch.sh` issue-body survivor removed: 79→78 distinct signatures, 101→100 occurrences). | `tests/unit/test-provider-cutover.sh` + the `spec-drift` ci.yml step | PASS |
| CHECK-D-001 | **Docs-retraction gate in the named `spec-drift` CI job**: `check-spec-drift.sh` **Check D** asserts `remains a raw caller-side` is absent from `docs/pipeline/provider-spec.md` (it occurred exactly once today, only for this read) and fails loud naming `provider-spec.md:LINE` if it reappears. `check-spec-drift.sh` is invoked by the **`spec-drift`** ci.yml job (`ci.yml:155`) — the exact surface the #306 owner comment named. | `check-spec-drift.sh` Check D, run by the `spec-drift` CI job | PASS — Check D green; FAILs on injection |
| TC-SPEC-GATE-058 | **Docs-retraction machine-check (drives the checker)**: (a) the committed `provider-spec.md` has the phrase absent; (b) `check-spec-drift.sh` Check D is green on it; (c) injecting the stale phrase into a scratch copy makes `check-spec-drift.sh` exit non-zero naming `provider-spec.md:LINE`. Driving `$CHECK` proves the **`spec-drift` job** (not just a local grep) enforces the retraction. | `tests/unit/test-spec-drift.sh` (hermetic `unit` job) + the `spec-drift` job via `check-spec-drift.sh` | PASS |

> **Why the gate lives in `check-spec-drift.sh` (the `spec-drift` job), not only in
> `test-spec-drift.sh`.** The #306 owner comment hardened the retraction into "a new
> case in `tests/unit/test-spec-drift.sh` (CI **Spec Drift** job)". But the
> `spec-drift` ci.yml job runs the standalone `check-spec-drift.sh` /
> `check-provider-cutover.sh` checkers — `tests/unit/test-spec-drift.sh` is executed by
> the separate `hermetic-unit` job's `test-*.sh` loop. So a TC-SPEC-GATE case living
> ONLY in the unit test would NOT execute in the named Spec Drift surface (#306 review
> [BLOCKING]). The fix moves the authoritative assertion into `check-spec-drift.sh`
> **Check D** (runs in the `spec-drift` job, no `.github/workflows/` edit — the
> dev-side scoped App token cannot push workflow files per [INV-83]); `TC-SPEC-GATE-058`
> then *drives* that checker (inject → red) so the unit job also proves the gate works.
> Both the named job and the unit job now enforce it — deterministic, no reviewer call.

## Acceptance mapping

- AC 1 (no raw `gh … --json body` in dep-resolution path) → TC-B2-GT-003 + local/CI grep.
- AC 2 (golden trace byte-identical argv) → TC-B2-GT-001/002.
- AC 3 (baseline shrunk by exactly 1; guard exits 0) → TC-B2-BASE-001.
- AC 4 (INV-91 migration log records B2; `pipeline-docs-gate` passes) → invariants.md B2 bullet.
- AC 5 (stale doc assertions retracted + machine-checked in the Spec Drift job) → `check-spec-drift.sh` Check D (CHECK-D-001) + TC-SPEC-GATE-058 driving it.
- AC 6 (full unit + conformance suite green) → unit job.
