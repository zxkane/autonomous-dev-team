# Test Cases — Resource Accounting Store (`lib-accounting.sh`, #505)

Covers D2 (storage model / projection), D3 (identity), D4 (lifecycle), D5
(strict commit), D6 (reconciliation), D7 (remote topology), plus the
metrics-isolation and zero-production-call-site guards. Hermetic: temp dirs,
frozen/stubbed PIDs and run-ids, no real sleeps.

## Identity (D3)

## TC-RESOURCEACCOUNT-001: same tuple produces the same invocation id

**Given** `run_id=R1 side=dev member_id=dev attempt=1`
**When** `accounting_invocation_id` is called twice with the identical tuple
**Then** both calls echo the identical `inv-v1-<24-hex>` string.

## TC-RESOURCEACCOUNT-002: a differing `run_id` produces a different id

**Given** the TC-001 tuple and a second tuple identical except `run_id=R2`
**When** both are hashed
**Then** the two ids differ.

## TC-RESOURCEACCOUNT-003: a differing `side` produces a different id

**Given** the TC-001 tuple and a second tuple identical except `side=review`
**Then** the two ids differ.

## TC-RESOURCEACCOUNT-004: two same-named review members with different member UUIDs produce different ids

**Given** two review fan-out members both named `codex`, with distinct `_agent_session_id` UUIDs `member_id=UUID-A` and `member_id=UUID-B`, same `run_id`/`attempt`
**Then** their invocation ids differ — proving identity keys on the member UUID, never the agent name.

## TC-RESOURCEACCOUNT-005: a dev retry's incremented `attempt` produces a different id

**Given** the TC-001 tuple and a second tuple identical except `attempt=2`
**Then** the two ids differ.

## TC-RESOURCEACCOUNT-006: construction is pure (no filesystem I/O)

**Given** a read-only, non-existent state directory
**When** `accounting_invocation_id` is called
**Then** it succeeds (rc 0) and echoes a valid id — proving it performs no I/O against the store.

## TC-RESOURCEACCOUNT-007: identity and start reject tuples outside the pinned D3 domain

**Given** an invalid side, an empty run/member id, a non-positive attempt, or a
dev-side member other than literal `dev`
**When** identity construction or `accounting_start` is attempted
**Then** rc is non-zero and no accounting path is created.

## TC-RESOURCEACCOUNT-008: public APIs reject path-like or tuple-mismatched invocation ids

**Given** an invocation id containing path traversal, or an otherwise valid id
whose canonical tuple differs from the tuple passed to `accounting_start`
**When** the API is called
**Then** rc is non-zero and no file outside the issue directory is touched.

## TC-RESOURCEACCOUNT-009: public APIs return loudly on missing arguments under `set -u`

**Given** a caller running `set -euo pipefail`
**When** any D8 public API is called with fewer than its required arguments
**Then** the function returns non-zero with a diagnostic instead of aborting on
an unbound positional parameter.

## Strict idempotent commit (D5)

## TC-RESOURCEACCOUNT-010: first commit for a fresh invocation succeeds

**Given** a `started` record for `invocation_id=X` under issue `N`
**When** `accounting_commit_usage N X 100 60 40` runs
**Then** rc 0, and the on-disk record for `X` is terminal `usage-committed` with `total_tokens=100`.

## TC-RESOURCEACCOUNT-011: identical-duplicate commit is a no-op success

**Given** `X` already holds a terminal `usage-committed` record with `total_tokens=100 input=60 output=40`
**When** `accounting_commit_usage N X 100 60 40` is replayed with the SAME payload
**Then** rc 0 and the record's mtime/content is unchanged (no write performed).

## TC-RESOURCEACCOUNT-012: conflicting-duplicate commit is rejected, no mutation

**Given** `X` already holds a terminal `usage-committed` record with `total_tokens=100`
**When** `accounting_commit_usage N X 200 - -` is attempted
**Then** rc≠0, loud stderr, and the on-disk record for `X` is unchanged (`total_tokens=100`).

## TC-RESOURCEACCOUNT-013: idempotency survives a simulated restart

**Given** `X` committed in one shell (source lib, commit, exit)
**When** a fresh shell re-sources `lib-accounting.sh` and replays the identical commit
**Then** rc 0, no-write (same as TC-011) — proving idempotency is a property of on-disk state, not in-process memory.

## TC-RESOURCEACCOUNT-014: commit write failure is loud (rc≠0), not swallowed

**Given** an injected authoritative-store writer failure
**When** `accounting_commit_usage` is attempted for a fresh invocation
**Then** rc≠0 and no partial/malformed file is left in the directory — distinct from `metrics_emit`'s swallow-all contract.

## TC-RESOURCEACCOUNT-015: `accounting_commit_unknown` writes a sticky terminal record

**Given** a `started` record for `Y`
**When** `accounting_commit_unknown N Y "dead-pid"` runs
**Then** rc 0 and `Y`'s record is terminal `usage-unknown` with the reason recorded.

## TC-RESOURCEACCOUNT-016: a non-regular record target is rejected before rename

**Given** `<issue>/<invocation_id>.json` already exists as a directory
**When** `accounting_commit_usage` attempts to persist that invocation
**Then** rc is non-zero, stderr names the refused non-regular target, and no
temporary record is moved into the directory.

## TC-RESOURCEACCOUNT-017: `accounting_start` does not treat a non-regular target as an existing record

**Given** `<issue>/<invocation_id>.json` already exists as a directory
**When** `accounting_start` is called for that invocation
**Then** rc is non-zero and the directory remains untouched; the call must not
report the idempotent success reserved for an existing regular record.

## TC-RESOURCEACCOUNT-018: terminal commits require an existing valid `started` record

**Given** a canonical invocation id with no authoritative record
**When** `accounting_commit_usage` or `accounting_commit_unknown` is called
**Then** rc is non-zero and no terminal record is synthesized with missing
identity metadata.

## TC-RESOURCEACCOUNT-019: token counts use one canonical integer spelling

**Given** an existing committed record
**When** a replay supplies a leading-zero or out-of-range total/input/output
value
**Then** the request is rejected as invalid before duplicate comparison, the
authoritative record remains unchanged, and a full-scan sum that would exceed
the exact supported range reports `corrupt` instead of wrapping.

## Lifecycle (D4)

## TC-RESOURCEACCOUNT-020: a live `started` record queries as `incomplete`, not `usage-unknown`

**Given** `accounting_start N Z dev R1 dev 1` with no matching commit or reconcile
**When** `accounting_admission_query N` runs
**Then** `Z` appears in `open_invocations`, never in `unknown_invocations`, and overall `status` is `incomplete` (assuming no other terminal/complete records).

## TC-RESOURCEACCOUNT-021: only an explicit `usage-unknown` record is sticky

**Given** two `started` records, `A` (never touched again) and `B` (explicitly committed unknown via `accounting_commit_unknown`)
**When** queried
**Then** `A` is `incomplete`/open; `B` is `usage-unknown`; a second query without any reconcile/ack leaves both states unchanged (no auto-promotion of `A`).

## TC-RESOURCEACCOUNT-022: an unwritable/lock-contended store yields `unavailable`, mutates nothing

**Given** the per-issue `.lock` is held by another process past the wait timeout
**When** `accounting_admission_query N` runs
**Then** it returns `status=unavailable`, rc reflects the failure, and no record file is created/modified as a side effect.

## TC-RESOURCEACCOUNT-023: a malformed on-disk record yields `corrupt`, mutates nothing

**Given** one invocation file under `<issue>/` contains truncated/invalid JSON
**When** `accounting_admission_query N` runs
**Then** the query reports `status=corrupt` (or flags the offending id), does not delete or rewrite the malformed file, and does not fail the whole query if other records are valid (partial-corruption is surfaced, not fatal).

## TC-RESOURCEACCOUNT-024: syntactically valid records with invalid envelopes yield `corrupt`

**Given** JSON records whose `schema_version`, `issue`, or
filename-to-`invocation_id` binding is wrong, or whose state-specific required
fields are missing/invalid
**When** `accounting_admission_query N` runs
**Then** each record produces `status=corrupt`, contributes no tokens, and is
left byte-unchanged.

## TC-RESOURCEACCOUNT-025: a projection rebuild write failure yields `unavailable`

**Given** a valid invocation scan whose missing/stale projection cannot be
atomically written (for example, `projection.json` is a symlink)
**When** `accounting_admission_query N` runs
**Then** it emits the normalized `status=unavailable` JSON, returns non-zero,
and never emits a healthy `complete` result or mutates invocation history.

## TC-RESOURCEACCOUNT-026: an invocation-record read failure yields `unavailable`

**Given** a record path that exists but cannot be read from storage
**When** `accounting_admission_query N` runs
**Then** it emits the normalized `status=unavailable` JSON and returns
non-zero; read failures are not misreported as malformed-history `corrupt`.

## TC-RESOURCEACCOUNT-027: tuple-mismatched records yield `corrupt`

**Given** a structurally valid record whose `invocation_id` and filename match
but whose `{run_id,side,member_id,attempt}` tuple hashes to another id
**When** the issue is queried
**Then** it reports `corrupt` and the record contributes no tokens.

## TC-RESOURCEACCOUNT-028: durability-sync failures are propagated

**Given** a valid `started` record and an injected failure syncing the
same-directory temporary file or the parent directory after rename
**When** a terminal commit runs
**Then** rc is non-zero, the failure is loud, and the authoritative record
remains `started` when rename was never reached; if rename already installed
the terminal record, an identical retry re-syncs it and succeeds.

## TC-RESOURCEACCOUNT-029: a directory-target race cannot consume the temporary file

**Given** the record target becomes a directory after the preflight check but
before rename
**When** the atomic writer installs the temp file
**Then** no-target-directory rename fails loudly, rc is non-zero, and no file
is moved inside the directory.

## Query / projection (D2)

## TC-RESOURCEACCOUNT-030: full scan is correct with 0 invocations

**Given** an issue directory with no invocation files
**When** queried
**Then** `total_tokens=0`, `open_invocations=[]`, `unknown_invocations=[]`, `status` reflects the empty state (`complete` with zero total).

## TC-RESOURCEACCOUNT-031: full scan is correct with 1 invocation

**Given** one `usage-committed` record with `total_tokens=50`
**Then** the query's `total_tokens` is `50`.

## TC-RESOURCEACCOUNT-032: full scan is correct with N invocations (mixed states)

**Given** 3 `usage-committed` records (`30+20+10=60`), 1 `started` (open), 1 `usage-unknown`
**Then** `total_tokens=60` (only committed usage counts), `open_invocations` has 1 entry, `unknown_invocations` has 1 entry.

## TC-RESOURCEACCOUNT-033: missing projection is rebuilt during query

**Given** no `projection.json` exists yet, and N committed records
**When** queried
**Then** a `projection.json` is written after the query with the correct total + digest + source invocation-id list.

## TC-RESOURCEACCOUNT-034: stale projection (digest mismatch) is rebuilt

**Given** a `projection.json` whose digest does not match the current file set (e.g. a new commit landed since it was built)
**When** queried
**Then** the projection is discarded and rebuilt to reflect current state; the query result reflects the CURRENT files, not the stale cache.

## TC-RESOURCEACCOUNT-035: corrupt projection is discarded and rebuilt

**Given** `projection.json` contains invalid JSON
**When** queried
**Then** the query does not fail — it discards the corrupt cache, rebuilds from a full scan, and returns the correct total.

## TC-RESOURCEACCOUNT-036: deleting projection.json and re-querying yields the same total and digest

**Given** a populated issue directory with a valid `projection.json`
**When** the file is deleted and the SAME query is re-run
**Then** the rebuilt projection's `total_tokens` and `digest` are byte-identical to the pre-deletion values.

## TC-RESOURCEACCOUNT-037: a current projection is not rewritten

**Given** a valid `projection.json` whose digest matches the locked full scan
**When** the issue is queried again with the atomic writer replaced by a
deterministic fail-if-called test double
**Then** the query succeeds and the writer is never called.

## TC-RESOURCEACCOUNT-038: projection cache validity covers its full envelope

**Given** `projection.json` carries the current digest but has a wrong/missing
schema version, total, or sorted source-id list
**When** the issue is queried
**Then** the cache is treated as corrupt and atomically rebuilt with all four
fields matching the locked scan.

## Reconciliation (D6)

## TC-RESOURCEACCOUNT-040: dead-PID evidence promotes `started` to sticky `usage-unknown`

**Given** a `started` record whose `run_id` matches the CURRENT `issue-<N>.run-id` sidecar, but the lease's recorded `pid` is not alive (`kill -0` fails)
**When** `accounting_reconcile N` runs
**Then** the record transitions to terminal `usage-unknown`, and a subsequent query lists it in `unknown_invocations`.

## TC-RESOURCEACCOUNT-041: a superseded run-id promotes `started` to sticky `usage-unknown`

**Given** a `started` record whose `run_id` no longer matches the CURRENT `issue-<N>.run-id` sidecar (a newer run started)
**When** `accounting_reconcile N` runs
**Then** the record transitions to terminal `usage-unknown`.

## TC-RESOURCEACCOUNT-042: a live lease keeps the record `incomplete`

**Given** a `started` record whose `run_id` matches the current run-id sidecar AND whose `pid` is alive
**When** `accounting_reconcile N` runs
**Then** the record is unchanged — still non-terminal, queries as `incomplete`.

## TC-RESOURCEACCOUNT-042b: missing evidence (no lease sidecars at all) keeps the record `incomplete`, never `usage-unknown`

**Given** a `started` record and NEITHER the run-id sidecar NOR `progress.json` exists (e.g. the INV-135 transient window before a fresh run's lease is written, or after it has been cleaned up)
**When** `accounting_reconcile N` runs
**Then** the record is unchanged — absence of evidence is NOT proof of death; only a POSITIVE signal (a superseded run-id, or a resolvable pid that fails `kill -0`) may promote to `usage-unknown`.

## TC-RESOURCEACCOUNT-042c: a matching run-id with no `progress.json` (pid evidence absent) keeps the record `incomplete`

**Given** a `started` record whose `run_id` matches the current run-id sidecar, but `progress.json` does not exist (so no `pid` evidence is available at all)
**When** `accounting_reconcile N` runs
**Then** the record is unchanged — a matching run-id with no pid evidence is inconclusive, not dead.

## TC-RESOURCEACCOUNT-043: closing the issue alone performs no accounting mutation

**Given** an open `started` record and no lease/PID evidence gathered
**When** the GitHub issue is closed (simulated — no call into `accounting_reconcile`)
**Then** the on-disk record is completely unchanged — closing is not itself a mutation trigger.

## TC-RESOURCEACCOUNT-044: `accounting_ack_unknown` writes an audit record and never deletes

**Given** a terminal `usage-unknown` record for `X`
**When** `accounting_ack_unknown N X` runs
**Then** rc 0, an ack record is appended/written recording the acknowledgement, and `X`'s original `usage-unknown` record file still exists on disk (never deleted).

## TC-RESOURCEACCOUNT-045: re-arm (re-running reconcile) never deletes known totals

**Given** a mix of `usage-committed` and `usage-unknown` records
**When** `accounting_reconcile N` runs a second time (idempotent re-arm)
**Then** every existing terminal record's `total_tokens`/state is unchanged — reconcile only ever promotes `started` records, never rewrites/deletes committed or already-unknown ones.

## TC-RESOURCEACCOUNT-046: reconciliation propagates a failed terminal transition write

**Given** positive proof-of-death for a `started` record and an injected atomic
write failure
**When** `accounting_reconcile N` runs
**Then** rc is non-zero, stderr reports the failed transition, and the on-disk
record remains `started`.

## TC-RESOURCEACCOUNT-047: stale progress from another run is not PID proof

**Given** the run-id sidecar matches a `started` invocation but
`progress.json.run_id` names another run with a dead PID
**When** reconciliation runs
**Then** the record remains `started`; PID evidence is usable only when both
INV-135 sidecars identify the same current run.

## TC-RESOURCEACCOUNT-048: malformed or non-regular lease evidence is ignored

**Given** a malformed/symlinked run-id or progress sidecar
**When** reconciliation runs
**Then** no sticky unknown transition occurs because no validated positive
proof-of-death exists.

## TC-RESOURCEACCOUNT-049: timestamp acquisition failures abort before mutation

**Given** an injected UTC-clock failure
**When** a start, terminal commit, reconciliation transition, or ack attempts
to create a timestamped fact
**Then** rc is non-zero with a diagnostic and no malformed or partially
timestamped history is persisted.

## Remote topology (D7)

## TC-RESOURCEACCOUNT-050: local backend query executes the library directly (no transport)

**Given** `EXECUTION_BACKEND` unset/local
**When** a dispatcher-side query runs
**Then** it calls `accounting_admission_query` in-process — no SSM/network call is made.

## TC-RESOURCEACCOUNT-051: remote-SSM query runs the library on the target and returns normalized JSON

**Given** `EXECUTION_BACKEND=remote-aws-ssm` and a stubbed SSM transport that executes the library on a simulated "remote" filesystem
**When** the dispatcher-side query runs
**Then** it returns the same normalized JSON shape as the local backend for equivalent on-disk state.

## TC-RESOURCEACCOUNT-052: an SSM/transport failure yields `unavailable`, never a dispatcher-local fallback

**Given** `EXECUTION_BACKEND=remote-aws-ssm` and a stubbed transport that fails (timeout/error)
**When** the dispatcher-side query runs
**Then** it returns `status=unavailable` and does NOT substitute any dispatcher-local accounting state as a fallback.

## Metrics isolation guard

## TC-RESOURCEACCOUNT-060: `metrics_prune` cannot reach the accounting directory

**Given** a populated `<state_dir>/accounting/<issue>/` directory alongside a populated `<state_dir>/metrics.jsonl`
**When** `metrics_prune` runs (any retention window, including 0 days)
**Then** every file under `accounting/` is byte-unchanged — `metrics_prune` only ever touches `metrics.jsonl` (and its own lock/tmp files), never walks into `accounting/`.

## TC-RESOURCEACCOUNT-061: `lib-metrics.sh` is byte-unchanged by this issue

**Given** the repository's committed `lib-metrics.sh` before and after this PR
**Then** a diff is empty (grep-pinned in the guard test, e.g. via checksum or line-count against a golden reference recorded at test-authoring time).

## Zero production call sites (grep-pin)

## TC-RESOURCEACCOUNT-070: no production wrapper/dispatcher script calls any `accounting_*` function

**Given** `skills/autonomous-dispatcher/scripts/*.sh` (excluding `lib-accounting.sh` itself and its own test/E2E files)
**When** grepped for `accounting_(invocation_id|start|commit_usage|commit_unknown|reconcile|ack_unknown|admission_query)`
**Then** zero matches — the library is inert; only tests source/call it.

## Coverage

## TC-RESOURCEACCOUNT-080: new helper branches exceed 80% coverage

**Given** the full unit suite for `lib-accounting.sh`
**When** the checked-in semantic-outcome inventory and the source-derived
shell decision-site denominator are validated under xtrace
**Then** every source marker has exactly one inventory row, every covered row
names a real test ID and executes, every shell `if`/`elif`/loop/short-circuit
site contributes automatically to the independent denominator, and both
exercised/total ratios are strictly greater than 80%.

---

## E2E (hermetic, same CI job)

## TC-RESOURCEACCOUNT-090: multi-invocation flow — dev + 2 same-name review members, projection rebuild, stable total

**Given** one dev commit (`total_tokens=100`) and two review commits both agent-named `codex` but distinct member UUIDs (`total_tokens=50` and `total_tokens=30`)
**When** all three are committed, `projection.json` is deleted, and the issue is queried
**Then** the rebuilt total is `180` and matches the total from a query taken BEFORE the deletion (same digest-equivalent total).

## TC-RESOURCEACCOUNT-091: crash flow — dead stub PID + superseded run-id reconciles to sticky `usage-unknown`

**Given** a `started` record whose lease names a stub PID that is not alive AND whose run-id sidecar has moved on to a new run
**When** `accounting_reconcile` runs, followed by `accounting_admission_query`
**Then** the query reports the invocation under `unknown_invocations` with overall `status` reflecting the presence of unknown usage.

## Acceptance mapping

- D2 (storage/projection) → TC-024..038, TC-060, TC-061
- D3 (identity) → TC-001..009
- D4 (lifecycle) → TC-020..027
- D5 (strict commit) → TC-010..019, TC-028, TC-029
- D6 (reconciliation) → TC-040..049
- D7 (remote topology) → TC-050..052
- Zero production call sites → TC-070
- Coverage → TC-080
- E2E → TC-090, TC-091
