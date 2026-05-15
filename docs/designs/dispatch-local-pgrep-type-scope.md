# Design — Type-scoped pgrep fallback in `dispatch-local.sh::kill_stale_wrapper`

**Issue**: #126
**Status**: Proposed
**Author**: zxkane (autonomous-dev session)

## Problem

`dispatch-local.sh::kill_stale_wrapper` falls back to a `pgrep -f` matcher that
selects orphan agent processes by `--issue <N>` argv only. Both
`autonomous-dev.sh` and `autonomous-review.sh` are launched with the same
argv shape, so the fallback **does not distinguish wrapper type**. It also
does **not** distinguish between projects on a multi-project box: dispatching
project A's `dev-resume` for issue 100 group-kills any project-B wrapper
also running with `--issue 100` on the same host.

Concrete failure mode (from #126 reproduction):

1. `review` wrapper for issue N is alive and mid-work (>5 min CLI run).
2. A `pid_alive review` miss (race or normal slow review) leads
   `dispatcher-tick.sh` to post "Review process appears to have crashed" and
   flip `reviewing` → `pending-dev`. The review wrapper is still alive.
3. The next tick dispatches `dev-resume`. `dispatch-local.sh` invokes
   `kill_stale_wrapper` against `issue-<N>.pid` (the dev PID file). The PID
   file is clean, but the pgrep fallback regex `[-]-issue ${ISSUE_NUM}\b`
   matches the live review wrapper by argv and SIGTERMs (then SIGKILLs) its
   process group.
4. The review agent exits 143 in the verdict-posting window, producing zero
   actionable output; ~$1 of sonnet-1M time wasted.

This is a second loop, distinct from the FAILED-verdict / same-HEAD loop,
and reproduces on clean PRs with no FAILED verdict.

**Multi-project amplification.** On the dispatcher box that runs multiple
autonomous projects in parallel (the operator's actual topology — see
`CLAUDE.local.md` for the OpenClaw cloud-station running 5+ projects against
the same EC2 instance), the bug is even worse: any two projects whose issue
numbering overlaps (e.g. project A issue 200, project B issue 200) cross-kill
each other on every dispatch. Even after type-scoping by wrapper script, the
`autonomous-dev.sh` script-name is **not** unique across projects — every
project has its own copy. Type-scope alone is necessary but not sufficient.

## Constraints / invariants we must preserve

- **#109 (PID file vs `$$` reparenting)**: the pgrep fallback exists because
  PID-file-based reaping misses subtrees from pre-fix wrappers, races between
  `acquire_pid_guard` and `_run_with_timeout`, and rotational kills. The
  fallback must continue to find genuine same-type orphans.
- **Word boundary on `--issue N`**: prevents issue 9 from matching issue 99.
- **`KILL_STALE_PGREP_FALLBACK=false`** must remain a complete bypass.
- **No new argv** on the wrapper scripts (additive surface invites compat
  bugs and we don't need it). The wrapper script *path* is already on the
  argv via `nohup "<path>/autonomous-dev.sh" ...`.
- **Pipeline doc parity**: the existing pgrep-fallback rule is documented in
  `INV-23` ("Defence in depth (option C)") and worded as type-agnostic. That
  wording is now incorrect, and a new INV-NN must capture the type-scoping
  rule explicitly so future code can't regress.

## Design

### Approach: scope by project's wrapper *path* + wrapper script name

Compose a regex from two pieces of information **already present on argv**:

1. **`PROJECT_DIR`** — the project's root directory, sourced from
   `autonomous.conf`. Every wrapper invocation in `dispatch-local.sh:199-220`
   runs `nohup "${PROJECT_DIR}/scripts/autonomous-(dev|review).sh" ...`, so
   `pgrep -f` sees the absolute path on argv0.
2. **`TYPE`** — selects which of the two wrapper scripts (`autonomous-dev.sh`
   or `autonomous-review.sh`) is the legal kill target.

```bash
# Regex-quote PROJECT_DIR so any '.' / '+' / etc. in the path are literal.
project_re=$(printf '%s' "${PROJECT_DIR}/scripts/" | sed 's|[][\\.*^$+?(){}|]|\\&|g')
case "$TYPE" in
  dev-new|dev-resume) script_re="${project_re}autonomous-dev\\.sh" ;;
  review)             script_re="${project_re}autonomous-review\\.sh" ;;
  *)                  script_re="${project_re}autonomous-(dev|review)\\.sh" ;;
esac
orphan_pids=$(pgrep -f "${script_re}.*[-]-issue ${ISSUE_NUM}\b" 2>/dev/null \
  | grep -vw "$$" || true)
```

Why path-anchored *and* type-anchored:

- **Multi-project safety**. The dispatcher box typically runs 5+ projects;
  per `CLAUDE.local.md`, `vidsyllabus`, `quant-scorer`, `podcast-curation`,
  `panoptes`, and `llm-wiki` all live on the same cloud station and overlap
  on issue numbers regularly. Anchoring on `${PROJECT_DIR}/scripts/` ensures
  project A's dispatch never even *sees* project B's wrappers in its match
  set.
- **Zero ABI change**. `nohup` already invokes wrappers by absolute path
  (the path is on argv[0]); we don't need to add `--project` or `--type`.
- The wrappers use disjoint script names (`autonomous-dev.sh` vs
  `autonomous-review.sh`); combined with the project path anchor, the match
  set is bounded to *exactly* "this project's wrapper of this type for this
  issue".
- `dispatch-local.sh:188-192` *already* maps `TYPE` to wrapper-script-keyed
  PID files (`issue-N.pid` vs `review-N.pid`). Extending the same mapping to
  the pgrep fallback is the smallest change consistent with the existing
  architecture.

### Why regex-quote `PROJECT_DIR`

`PROJECT_DIR` is operator-supplied via `autonomous.conf`. Most paths are
plain `/data/git/<project>` and don't need quoting, but defense in depth
matters here: a path containing `.` (e.g. `/home/ops/.local/share/...`)
would otherwise let one project match another by a wildcarded char, and a
path containing `[` or `(` would syntax-error the pgrep regex. The
`sed`-based escape is local to the function (no helper proliferation).

### Why not `--type <kind>` argv (rejected alternative)

The issue mentions a more invasive option: add `--type <kind>` to both
wrappers and match `--type ${TYPE}.*--issue ${N}\b`. Rejected because:

- Both wrapper scripts and every caller (dispatcher's `dispatch-local.sh`,
  remote-AWS-SSM `dispatch-remote-aws-ssm.sh`, manual operator invocations,
  any in-tree tests that exec the wrappers) would need to pass the new flag.
- Forward-compat hazard: a future remote-only dispatch path that doesn't yet
  pass `--type` would silently regress to the broken matcher.
- The script-name approach gives the same selectivity at zero compat cost
  because the script path is already on argv.

### Default-case fallthrough

If `TYPE` is anything other than `dev-new|dev-resume|review` (which the
case statement at `dispatch-local.sh:197` already rejects with exit 1),
the function would already not be reached — but to be defensive against a
future call site refactor, the catch-all `*)` branch keeps the project
path anchor and a *type-agnostic* script-name matcher
(`autonomous-(dev|review)\.sh`) so we don't silently let escaped wrappers
of *this project* run forever. This is strictly safer than "match any
process", because it still requires the wrapper script name to be
`autonomous-(dev|review).sh` AND the path to be under
`${PROJECT_DIR}/scripts/`.

### Logging

The "Found orphan agent process(es) for issue #N" message gains a `type=`
prefix so operator log-spelunking can see why a kill was chosen:

```
Found orphan dev-resume agent process(es) for issue #126: 12345 — group-killing
```

This aids debugging the next regression class without changing the
machine-readable parts of the dispatcher protocol.

## Test plan

**Test cases doc**: `docs/test-cases/dispatcher-stale-wrapper-cross-type.md`
captures TC-A through TC-D from the issue, plus TC-E for the multi-project
case:

- **TC-A**: `review` wrapper alive (PID file present + responsive),
  `dispatch-local.sh dev-resume <N>` is invoked. Expect: review wrapper
  still alive after `kill_stale_wrapper` returns; new dev wrapper spawns
  clean.
- **TC-B**: Mirror — `autonomous-dev.sh` alive, dispatch `review`. Expect:
  dev wrapper untouched, review wrapper spawns.
- **TC-C**: Same-type orphan — real escaped `autonomous-dev.sh --issue N`
  subtree from a prior crash, no PID file, dispatch `dev-resume`. Expect:
  pgrep fallback still finds and group-kills the orphan.
- **TC-D**: Negative — issue 9 vs issue 99. Dispatch `--issue 9`. Expect:
  a live wrapper for `--issue 99` is not matched (existing word-boundary
  preserved).
- **TC-E (new, multi-project)**: project A's `dev-resume` for issue N must
  not kill project B's wrapper for the same issue N (different
  `PROJECT_DIR`). Mirrors the operator's actual topology where 5+ projects
  share a host and overlap on issue numbers.

**Unit tests** (new file
`tests/unit/test-dispatch-local-pgrep-type-scope.sh` following the existing
plain-bash harness pattern of e.g. `tests/unit/test-pid-guard.sh`):

- **TC-REGEX-001..004**: extract the regex-selection code into a testable
  function (in-test eval against the source file by `sed`-pattern, no
  source modification needed for testability) and assert each `TYPE` maps
  to the documented `script_re`.
- **TC-PGREP-001..004**: spawn fixture `sleep 60` processes whose `argv0`
  matches each wrapper-script pattern, run a stripped-down version of
  `kill_stale_wrapper`'s pgrep-fallback block (sourced into the test
  process), and assert the kill set per `TYPE`. Notably TC-PGREP-002 is
  the regression for #126: dispatch `dev-resume`, decoy is
  `autonomous-review.sh --issue N`, decoy must remain alive.
- **TC-DISABLE-001**: `KILL_STALE_PGREP_FALLBACK=false` short-circuits the
  fallback regardless of decoys.
- **TC-STATIC-001..002** (grep-asserted): `dispatch-local.sh` must compute
  `script_re` per `TYPE`, and the case branches must match what this
  design canvas declares. Pins the implementation against silent
  regression to the type-agnostic regex.

## Pipeline doc updates (in same PR)

- `docs/pipeline/invariants.md`: append **INV-28** — "pgrep fallback in
  `kill_stale_wrapper` MUST scope by `${PROJECT_DIR}/scripts/` path AND
  wrapper script name". Cross-references INV-23, INV-26.
- `docs/pipeline/invariants.md::INV-23`: amend the "Defence in depth (option
  C)" paragraph to call out the type-scoping requirement and link forward
  to INV-28. The previous wording is no longer authoritative on its own.
- `docs/pipeline/dispatcher-flow.md`: no structural change required — the
  doc references `kill_stale_wrapper` as a black box; the regex-scope is
  an INV-level rule, not a flow-step change.

## Acceptance criteria mapping (from #126)

| AC | Verification |
|---|---|
| `kill_stale_wrapper` from `dev-*` never SIGTERMs `autonomous-review.sh`, and vice versa, even with same issue N | TC-PGREP-001/002 |
| Same-type orphan still group-killed | TC-PGREP-003 |
| No regression of #109 PID-vs-$$ reparenting | INV-23 unchanged for PID-file path; pgrep fallback only narrows match set |
| `KILL_STALE_PGREP_FALLBACK=false` unchanged | TC-DISABLE-001 |
| `dispatcher-tick.sh:483-503` classification unchanged | This fix is upstream of the classifier; not touched |
| Cross-project isolation (different `PROJECT_DIR`, same issue N) | TC-PGREP-005 |

## Out of scope

- Fixing the `pid_alive review` race that misclassifies a slow live review
  as crashed (root cause of step 2 in the failure narrative). That's a
  separate dispatcher-side correctness issue with its own design surface
  (intersection of INV-24 and `pid_alive` debounce). The fix here only
  prevents the cross-type kill that #126 documents.
- Any change to `autonomous-dev.sh` or `autonomous-review.sh` argv.
- Remote-AWS-SSM dispatch path: the SSM-side dispatcher invokes the same
  `dispatch-local.sh`-equivalent code on the cloud station, so the fix is
  inherited unchanged.
