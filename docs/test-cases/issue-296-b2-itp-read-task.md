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
| TC-SPEC-GATE-058 | **Docs-retraction machine-check**: the stale phrase `remains a raw caller-side` no longer appears anywhere in `docs/pipeline/provider-spec.md` (it occurred exactly once today, only for this read). Fails loud with file context if it survives. | `tests/unit/test-spec-drift.sh` (runs in the hermetic `unit` job via the `tests/unit/test-*.sh` loop) | PASS — phrase count 0 |

> **Note on the "Spec Drift" job.** The #306 issue body refers to the new
> `TC-SPEC-GATE-NNN` case running in the CI "Spec Drift" job. In practice
> `tests/unit/test-spec-drift.sh` (where all `TC-SPEC-GATE-*` cases live) is executed
> by the **`hermetic-unit`** job's `for test in tests/unit/test-*.sh` loop, while the
> separate `spec-drift` job runs the standalone `check-spec-drift.sh` /
> `check-provider-cutover.sh` checkers. Either way the new case runs **pre-merge in CI**
> on a credential-free `ubuntu-latest` runner — the doc-retraction is a deterministic
> machine gate, not a subjective reviewer call, exactly as the AC requires.

## Acceptance mapping

- AC 1 (no raw `gh … --json body` in dep-resolution path) → TC-B2-GT-003 + local/CI grep.
- AC 2 (golden trace byte-identical argv) → TC-B2-GT-001/002.
- AC 3 (baseline shrunk by exactly 1; guard exits 0) → TC-B2-BASE-001.
- AC 4 (INV-91 migration log records B2; `pipeline-docs-gate` passes) → invariants.md B2 bullet.
- AC 5 (stale doc assertions retracted + machine-checked) → TC-SPEC-GATE-058.
- AC 6 (full unit + conformance suite green) → unit job.
