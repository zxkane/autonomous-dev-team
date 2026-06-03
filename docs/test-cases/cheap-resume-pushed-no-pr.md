# Test Cases: Cheap resume when branch pushed but PR not created (#178)

Scope: `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` — the `needs_open_pr_only`
helper and the `## Open-PR-only fast path` prompt-block wiring.

Strategy: the wrapper is too heavy to execute end-to-end, so the helper logic is exercised by
sourcing the wrapper's helper definitions in isolation (the helper is guarded so sourcing does
not run the wrapper body), with `git` and `gh` stubbed; and the prompt wiring is pinned with
source-of-truth greps (same pattern as `test-autonomous-dev-rebase-marker.sh`).

| Test ID | Scenario | Expected |
|---------|----------|----------|
| TC-CR-001 | `feat/issue-178-foo` pushed to origin, ahead of base, no open PR | `needs_open_pr_only 178` → 0 (fast path) |
| TC-CR-002 | `fix/issue-178` pushed to origin, ahead of base, no open PR | `needs_open_pr_only 178` → 0 (fast path) |
| TC-CR-003 | branch name with non-default suffix (`feat/issue-178-some-long-name`) | detected via glob → 0 |
| TC-CR-004 | No pushed branch at all (genuine early crash), no PR | `needs_open_pr_only 178` → 1 (normal full re-dev) |
| TC-CR-005 | Pushed branch exists but **zero commits ahead** of base | `needs_open_pr_only 178` → 1 (not finished work) |
| TC-CR-006 | An **open PR already exists** for the issue (branch pushed too) | `needs_open_pr_only 178` → 1 (PR-exists handoff owns this) |
| TC-CR-007 | `git ls-remote` fails (transient network) | fail-closed → 1 (no false fast path) |
| TC-CR-008 | Remote-only objects: `rev-list` can't count (0) but branch head SHA ≠ base SHA | ahead-fallback → 0 (fast path) |
| TC-CR-015 | Issue 178 must not match a longer number (`feat/issue-1789-x`) | `*issue-178*` glob matches `issue-1789`, but the `issue-<N>(non-digit\|end)` anchor rejects it → 1 |
| TC-CR-009 | Resume prompt contains the `Open-PR-only fast path` block, gated by the helper | grep: block + helper call present in resume branch |
| TC-CR-010 | Fast-path block instructs skipping design/test/implement and going to open-PR step | grep: block mentions "skip" design/test/implement + "gh pr create" / open-PR |
| TC-CR-011 | [INV-06] keyword contract: fast-path block has NO `Task appears to have crashed` / `process not found` | grep -v assertion |
| TC-CR-012 | Detection globs both `feat/issue-N*` and `fix/issue-N*` (source pins both) | grep: `ls-remote` glob pattern present |
| TC-CR-013 | Wrapper still passes `bash -n` | syntax check |
| TC-CR-014 | resume-fallback (new-session) prompt and MODE=new prompt also include the fast-path block | grep: block referenced for both full-prompt builders |

## Acceptance mapping (issue #178 Acceptance Criteria)

- Pushed-branch-no-PR resume opens PR directly → TC-CR-001/002/009/010
- Detection globs agent-chosen head branch → TC-CR-001/002/003/012/015
- PR-exists handoff-to-review unchanged → TC-CR-006 (helper returns 1; existing
  `handle_pending_dev_pr_exists` path untouched — pinned by existing `test-lib-dispatch.sh`)
- Genuine no-commit/no-push crash still retries dev → TC-CR-004/005
- No new comment trips [INV-06] crash-keyword contract → TC-CR-011
- Opens PR within one tick; no oscillation → TC-CR-009/010/014 (fast path active on every
  mode the dispatcher can route)
- New INV + docs → verified by pipeline-docs-gate CI + INV-45 in invariants.md
