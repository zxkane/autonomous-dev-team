# Test Cases — Cross-type stale-wrapper kill (issue #126)

**Feature**: Type-scoped pgrep fallback in `dispatch-local.sh::kill_stale_wrapper`
**Issue**: #126
**Design**: `docs/designs/dispatch-local-pgrep-type-scope.md`
**Invariant**: INV-28 (added in this PR)
**Test file**: `tests/unit/test-dispatch-local-pgrep-type-scope.sh`

## Acceptance criteria coverage

| AC (from #126) | Test cases |
|---|---|
| `dev-*` dispatch never SIGTERMs `autonomous-review.sh`, and vice versa | TC-PGREP-001, TC-PGREP-002 |
| Same-type orphan still group-killed | TC-PGREP-003 |
| No regression of #109 (PID file vs `$$` reparenting) | TC-PGREP-003 (orphan w/ no PID file still reaped); INV-23 PID-file path is unchanged in code |
| `KILL_STALE_PGREP_FALLBACK=false` unchanged | TC-DISABLE-001 |
| Word-boundary preserved (issue 9 vs 99) | TC-PGREP-004 |
| Cross-project isolation (multiple autonomous projects on same host, overlapping issue N) | TC-PGREP-005 |
| `dispatcher-tick.sh:483-503` classifier unchanged | Out of scope; covered by existing INV-26/INV-27 tests |

## Test scenarios

### TC-PGREP-001 — dev-resume must NOT kill live review wrapper (regression for #126)

**Given**:
- A live decoy process whose argv0 path ends in `autonomous-review.sh` and whose
  argv contains `--issue 998877`.
- No PID file at `${PID_DIR}/issue-998877.pid` (so the PID-file path of
  `kill_stale_wrapper` is a no-op and the pgrep fallback runs).

**When**: `kill_stale_wrapper` runs in `TYPE=dev-resume` context for issue 998877.

**Expect**:
- `kill_stale_wrapper` exits 0.
- The decoy `autonomous-review.sh --issue 998877` process is **still alive**.

### TC-PGREP-002 — review must NOT kill live dev wrapper (mirror of TC-PGREP-001)

**Given**:
- A live decoy `autonomous-dev.sh --issue 998877`.
- No `${PID_DIR}/review-998877.pid`.

**When**: `kill_stale_wrapper` runs in `TYPE=review` context for issue 998877.

**Expect**:
- `kill_stale_wrapper` exits 0.
- The decoy `autonomous-dev.sh --issue 998877` is **still alive**.

### TC-PGREP-003 — same-type orphan IS group-killed (no regression of #109 fallback)

**Given**:
- A live decoy `autonomous-dev.sh --issue 998877` (orphan; no PID file).

**When**: `kill_stale_wrapper` runs in `TYPE=dev-resume` context for issue 998877.

**Expect**:
- `kill_stale_wrapper` exits 0.
- The decoy is **dead** within 5 s (fallback successfully reaped it).

### TC-PGREP-004 — word boundary preserved (issue 9 vs issue 99)

**Given**:
- A live decoy `autonomous-dev.sh --issue 99` (note: NOT 9).

**When**: `kill_stale_wrapper` runs in `TYPE=dev-resume` context for issue 9.

**Expect**:
- `kill_stale_wrapper` exits 0.
- The decoy for issue 99 is **still alive** (word-boundary stops the
  numerically-prefix match).

### TC-PGREP-005 — cross-project isolation (multi-project box)

**Given**:
- Two distinct `PROJECT_DIR` paths (e.g. `/tmp/.../proj-a/` and
  `/tmp/.../proj-b/`), each with its own `scripts/autonomous-dev.sh` copy.
- A live decoy at `${PROJ_B}/scripts/autonomous-dev.sh --issue 998877`
  (project B's wrapper).

**When**: `kill_stale_wrapper` runs with `PROJECT_DIR=${PROJ_A}` and
`TYPE=dev-resume` for issue 998877.

**Expect**:
- `kill_stale_wrapper` exits 0.
- The project-B decoy is **still alive** (project A's pgrep regex
  anchors on `${PROJ_A}/scripts/`, so project B's wrapper is not in the
  match set).

This is the multi-project case the dispatcher box hits in production: per
`CLAUDE.local.md`, the cloud station (Singapore `i-0c87da4b7346b86d6`)
runs `vidsyllabus`, `quant-scorer`, `podcast-curation`, `panoptes`, and
`llm-wiki` simultaneously. Issue numbers are per-repo and overlap
constantly, so without project-path anchoring, every dispatch is a
potential cross-kill.

### TC-DISABLE-001 — KILL_STALE_PGREP_FALLBACK=false short-circuits

**Given**:
- A live decoy `autonomous-dev.sh --issue 998877`.
- `KILL_STALE_PGREP_FALLBACK=false` in the environment.

**When**: `kill_stale_wrapper` runs in `TYPE=dev-resume` context for issue 998877.

**Expect**:
- `kill_stale_wrapper` exits 0.
- The decoy is **still alive** (the entire fallback block is skipped).

### TC-REGEX-001 — `TYPE=dev-new` selects `${PROJECT_DIR}/scripts/autonomous-dev\.sh`

Static-behavioral assertion: `script_re` for `TYPE=dev-new` must contain
the regex-quoted `${PROJECT_DIR}/scripts/` AND `autonomous-dev\.sh`, and
must NOT match the review wrapper.

### TC-REGEX-002 — `TYPE=dev-resume` selects dev wrapper under project path

Same as TC-REGEX-001 for `dev-resume`.

### TC-REGEX-003 — `TYPE=review` selects review wrapper under project path

Static-behavioral assertion: `script_re` for `TYPE=review` must contain the
regex-quoted `${PROJECT_DIR}/scripts/` AND `autonomous-review\.sh`, and
must NOT match the dev wrapper.

### TC-REGEX-004 — Default fallthrough preserves project anchor + both wrappers

Static-behavioral assertion: the `*)` catch-all branch's `script_re`
matches `${PROJECT_DIR}/scripts/autonomous-(dev|review)\.sh`. The project
path anchor is preserved even in the catch-all so a future refactor that
calls the function with an unexpected `TYPE` cannot accidentally cross
project boundaries.

### TC-REGEX-005 — `PROJECT_DIR` is regex-quoted

Static-behavioral assertion: a `PROJECT_DIR` containing `.` (e.g.
`/home/x/.local/foo`) must be literalized in the regex — i.e. the `script_re`
must contain `\\.` not `.` for that character. Guards against operator
PROJECT_DIR paths with dots, brackets, or parens silently widening the
match set.

### TC-STATIC-001 — pgrep regex ANDs project + script + issue

Static grep against `dispatch-local.sh`: the `pgrep -f` invocation must use
a single regex string that contains `${script_re}` (which itself contains
the project path anchor) AND `--issue ${ISSUE_NUM}\\b`. Pins the
implementation against regression to the type-agnostic / project-agnostic
regex.

### TC-STATIC-002 — INV-28 referenced from `dispatch-local.sh` comment

Static grep: the comment block above the pgrep fallback references
`INV-28` so future maintainers find the invariants doc.

## How tests run

```bash
bash tests/unit/test-dispatch-local-pgrep-type-scope.sh
```

The test file is plain bash and follows the existing harness pattern of
`tests/unit/test-pid-guard.sh` (PASS/FAIL counters, `assert_eq` /
`assert_contains` helpers, `mktemp -d` per-test scratch dir, fixture
processes via `bash -c 'exec -a <argv0> sleep 60'`). No bats dependency.
