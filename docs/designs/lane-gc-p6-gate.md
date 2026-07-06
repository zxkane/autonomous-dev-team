# Design: Lane-GC P6 — back-pressure admission gate + remote DEFERRED plumbing

**Status:** Implementation notes for issue #382 (Lane-GC series PR-6). Full
design authority is `docs/designs/lane-containment-gc.md` §4-C6 (back-pressure
admission gate), §9 PR-6. This doc records only the PR-open numbering
re-verification, the concrete diff shape, and the decisions made where the
parent design leaves a degree of freedom — it is not a new design; defer to
the parent doc for rationale.

## Numbering re-verification (design §8/§10 F10 completeness)

The parent design drafted this PR's invariant as INV-112 (§8 table, "Back-
pressure admission gate"). By this PR's rebase onto `origin/main`, the head
had already advanced past that number — PR-3 (kill-path hardening) shipped
INV-111/INV-112 for its own bounded-teardown and back-pressure-*placeholder*
invariants under the `#405` PR (the shipped PR-3 used INV-111 for bounded
ordered teardown and reserved/consumed INV-112 differently than this design
doc's draft numbering assumed), PR-4 shipped INV-117, and PR-5 shipped
INV-118. This PR's own numbering re-verification against `docs/pipeline/
invariants.md` HEAD at PR-open time found the first free slot to be
**INV-119**, which this PR claims — per the design's own stated "first-merged
keeps, each INV-adding PR notes the convention" rule (§8, §12 R11).

- **INV-119 — Back-pressure admission gate** (drafted as INV-112 in the
  parent design's §8 table; renumbered here to the first free slot at this
  PR's open).

The INV-30 entry (`pid_alive` is authoritative under all execution backends,
`docs/pipeline/invariants.md`) gains an amendment documenting the fourth
DEFERRED verdict this PR adds to its verdict set — see that entry's own text
for the amendment, cross-referenced from INV-119.

## Scope (this PR)

1. **The gate itself, `skills/autonomous-dispatcher/scripts/dispatch-local.sh`**:
   inserted immediately after the pre-existing opportunistic `adt-gc.sh
   --quick` call (top of file) and before `kill_stale_wrapper`/spawn. Four
   independent signals (load/core, MemAvailable floor, swap% ceiling, global
   live-lane count via `lib-lane.sh::lane_global_live_count`, new this PR).
   Refusal path: log → one bounded `adt-gc.sh --quick` reclaim attempt (shared
   entry-point resolution + timeout feature-detection with the pre-existing
   opportunistic call, via a new `ADT_GC_ENTRY` var + `_run_adt_gc_quick`
   helper) → re-check the four signals ONCE → defer marker + `exit 75`, or
   fall through to the existing spawn path.
2. **`lib-lane.sh::lane_global_live_count`** (new function, this PR): the
   4th signal's data source. Registry-driven (walks every project's
   `autonomous-*/lanes/`, joins on `lane_probe`'s own `live` verdict);
   falls back to counting live PID files when NO `lanes/` directory exists
   anywhere under `ADT_STATE_ROOT` (a fresh host with no registry yet — the
   design's own explicit fallback clause).
3. **`lib-lane.sh::box_health`** (extended, not new — PR-4/PR-2 already
   shipped the Linux `/proc`-based probes as a forward-looking primitive
   "provided now so PR-6 needs no lib-lane.sh change"): this PR adds the
   macOS/BSD fallback branches (`sysctl -n vm.loadavg`/`hw.ncpu`, `vm_stat`
   free+inactive pages, `sysctl vm.swapusage`) the original comment deferred.
4. **rc=75 attribution, `lib-dispatch.sh`**: `is_dispatch_deferred_rc`
   (the sentinel predicate) + `handle_dispatch_deferred` (releases the
   dispatch marker AND reverts the caller's own immediately-preceding
   `label_swap`, so a local-backend defer nets to zero observable label
   change — see "Local-backend label-revert" below, a design amplification
   not explicit in the parent doc's rev-3 text). Wired into all four
   `dispatch()` call sites in `dispatcher-tick.sh` (Step 2 dev-new, Step 3
   review, Step 4's PTL fresh-dev-new, Step 4 dev-resume) and the two
   `dispatch dev-new` call sites inside `lib-dispatch.sh` itself (INV-35
   fresh-dev, self-heal dev-new).
5. **Remote DEFERRED plumbing (three files, per the design's own explicit
   "PR-6 grows to three dispatcher-side files" scoping, §4-C6/§9/§12 R5)**:
   - `dispatch-local.sh`: writes a `.attempt-<kind>-<issue>` token,
     unconditionally, at the very start of every invocation — before its
     own gate even runs. This is the freshness anchor item 2 below
     compares a defer marker against (added by review P1-1 — see
     "Wrapper-host attempt-marker freshness, not a controller-side
     dispatch token" below).
   - `liveness-check-remote-aws-ssm.sh`: the remote snippet now checks a
     `.defer-<kind>-<issue>` marker under the wrapper host's own lane
     registry FIRST (before the ALIVE/DEAD tiers), authorized as DEFERRED
     only when NOT superseded by a later `.attempt-<kind>-<issue>` token
     AND still within `DEFER_MARKER_MAX_AGE_SECONDS` (default 900s) — see
     "Wrapper-host attempt-marker freshness, not a controller-side
     dispatch token" below. Emits `DEFERRED\n<age_s>` (two lines, and
     exactly two — trailing content degrades to indeterminate, review
     P2-2) as a fourth verdict.
   - `lib-dispatch.sh::_remote_pid_alive_query`: parses the driver's
     two-line DEFERRED stdout into a single colon-joined token
     (`DEFERRED:<age_s>`) for its own single-line return contract.
   - `lib-dispatch.sh::pid_alive`: a new side-channel
     (`PID_ALIVE_LAST_VERDICT`/`PID_ALIVE_LAST_DEFERRED_AGE`, reset on every
     call) carries the DEFERRED verdict + age past `pid_alive`'s own
     boolean return contract (there is no third return-code slot for a
     4th verdict) — see "Side-channel, not a return-code change" below.
   - `dispatcher-tick.sh` Step 5b: fast-returns on
     `PID_ALIVE_LAST_VERDICT=DEFERRED` BEFORE the no-PR/near-success
     crash-declaration checks — no comment, no label flip, no retry
     decrement.
6. **Knobs**: `GATE_LOAD_PER_CORE`, `GATE_MIN_MEM_MB`, `GATE_SWAP_PCT`,
   `MAX_TOTAL_CONCURRENT` documented in `autonomous.conf.example`;
   `DEFER_MARKER_MAX_AGE_SECONDS` documented in `dispatcher.conf.example`
   (it is read dispatcher-side, by the SSM query, not by the remote
   project's own `autonomous.conf`).
7. **Tests**: `tests/unit/test-lane-gc-p6-gate.sh` (unit, TC-LGC6-\*),
   `tests/e2e/run-lane-gc-p6-gate-e2e.sh` + the CI-loop thin wrapper
   `tests/unit/test-lane-gc-p6-gate-e2e.sh`.

The systemd-scope backend (P7) is a separate PR — not touched here.

## Local-backend label-revert (an amplification of the design's rev-3 text)

The parent design's §4-C6 says the gate causes the issue to be "picked up
again next tick" on a defer, and §12 R5 says rc=75 gets "explicit
lib-dispatch attribution — no retry-budget decrement, no `failed-*` label."
Read literally against the ACTUAL call-site shape in `dispatcher-tick.sh`,
this is incomplete: every one of the four `dispatch()` call sites performs
its own `label_swap` (e.g. `"" → in-progress`, `pending-review → reviewing`)
**immediately before** calling `dispatch()` — under the LOCAL backend, that
label swap has ALREADY landed by the time `dispatch-local.sh`'s gate can
possibly refuse. If the caller does nothing beyond "no further label
change" (a literal reading of "no `failed-*` label"), the issue is left
sitting in an ACTIVE state (`in-progress`/`reviewing`) with NO wrapper ever
actually spawned — no PID file, no heartbeat, no Session Report, no `Dev
Session ID:` comment. The very next tick's Step 5 stale-detection would then
see a `pid_alive` miss with EVERY near-success cross-check also negative
(nothing was ever posted) and misclassify the defer as a genuine crash —
posting a false "Task appears to have crashed" comment and flipping the
label anyway, precisely the misattribution this PR exists to prevent.

`handle_dispatch_deferred` therefore takes the caller's own `label_swap`
args and reverses them (`label_swap "$n" "$revert_from" "$revert_to"`, where
`revert_from`/`revert_to` are the ORIGINAL call's `add`/`remove` args
swapped), making a local-backend defer indistinguishable, from the issue's
own label history, from "this tick never touched it" — the issue naturally
reappears in the SAME selector query (`list_new_issues` /
`list_pending_review` / `list_pending_dev`) on the next tick, with zero
extra state to reconcile. This is scoped to the LOCAL-backend synchronous
catch only: under `remote-aws-ssm`, `dispatch()`'s underlying
`dispatch-remote-aws-ssm.sh` returns 0 the instant SSM ACCEPTS the command —
the remote wrapper-host's own gate verdict is never observed synchronously,
so `handle_dispatch_deferred`'s rc=75 branch never fires there. The label is
deliberately left in its active state for that path; the remote DEFERRED
plumbing (item 5 above) is what keeps Step 5b from misclassifying it on a
LATER tick instead.

## Side-channel, not a return-code change (`pid_alive`)

`pid_alive`'s existing contract across every call site in this codebase is
boolean (rc 0 = alive, rc 1 = not-alive) — dozens of callers already branch
on it with a bare `if pid_alive ...`. Widening it to a tri-valued return
code would touch every one of those call sites and risk silently breaking a
caller that only checks `$? -eq 0`. Instead, DEFERRED is carried on two
process-global variables (`PID_ALIVE_LAST_VERDICT`,
`PID_ALIVE_LAST_DEFERRED_AGE`), reset to empty at the TOP of every
`pid_alive` call (not merely on the remote-backend branch) so a caller can
never observe a STALE verdict left over from a different issue's probe
earlier in the same tick. `pid_alive` itself still returns 1 (not-alive) for
DEFERRED — a defer genuinely means no wrapper was launched, so "not alive"
is the semantically correct boolean answer for any caller that ignores the
side channel entirely (the pre-existing behavior for every OTHER caller of
`pid_alive` is completely unaffected). Only `dispatcher-tick.sh`'s Step 5b
consults the side channel, immediately upon entering the `else` (DEAD)
branch, before its own no-PR/near-success logic runs.

## Wrapper-host attempt-marker freshness, not a controller-side dispatch
token (review P1-1)

The design's preferred mechanism (§4-C6, "defer marker fresher than the
last dispatch token for that (issue,type)") compares the marker's mtime
against a dispatch token. The first-draft implementation of this PR read
that as "the dispatch token", i.e. the controller-side
`dispatch-marker-<issue>-<mode>` file [INV-108]'s `acquire_dispatch_marker`
already writes — but that file lives on the **dispatcher** host, and under
`EXECUTION_BACKEND=remote-aws-ssm` the dispatcher and wrapper hosts are
different machines. The remote liveness snippet runs entirely inside the
SSM-delivered inner shell command **on the wrapper host**, with no
dispatcher-host filesystem access and no GitHub API access by design
(every sibling `*-remote-aws-ssm.sh` driver in this file set is a pure
SSM-transport probe, never a controller-filesystem or GitHub API caller) —
that controller-side file was never actually readable from inside the
snippet, a genuine bug the first draft shipped with (caught in review, not
by any test — the fix adds the real fixture-driven coverage that would
have caught it, see TC-LGC6-083..087).

The fix: `dispatch-local.sh` **itself** — which runs ON THE WRAPPER HOST
for every single dispatch attempt, local or SSM-invoked — writes a
`.attempt-<kind>-<issue>` token, unconditionally, at the very start of
every invocation, before its own gate even runs. This is the one component
that can honestly record "when did the dispatcher last attempt THIS exact
(kind, issue) on THIS host" in a place the snippet can actually read. The
remote snippet's DEFERRED authorization becomes a conjunction of two
conditions, not a single mechanism:

- **(a) Not superseded**: the defer marker's mtime is at-or-after the
  attempt marker's mtime (`-ge`, never strictly `-gt` — the attempt marker
  is written first and the defer marker moments later, both inside the
  SAME script run; at 1-second `stat` granularity the two routinely share
  an identical mtime, so a strict `-gt` would incorrectly treat THIS run's
  own defer as already-superseded the instant it's written — a real bug
  caught while writing TC-LGC6-084's same-run fixture).
- **(b) Within `DEFER_MARKER_MAX_AGE_SECONDS`** (default 900s / 15 min) of
  "now".

Both conditions apply together — (b) is **not** merely a fallback for a
missing attempt marker. Nothing in this pipeline re-dispatches an
already-`in-progress`/`reviewing` issue to refresh the attempt token, so a
defer that only checked (a) would hold **indefinitely** once the box has
been under pressure even once: `NOT_SUPERSEDED` would never flip back to
false, and DEFERRED would never expire into the existing
crash-declare → `pending-dev` → retry recovery cycle that condition (b)
is what actually preserves. When the attempt marker is missing or
unstattable (a pre-upgrade wrapper host that has never run the updated
`dispatch-local.sh`), condition (a) degrades to vacuously true and
condition (b) alone gates — the exact pre-fix bare-age-window behavior,
now correctly scoped to the one case it was always meant to cover instead
of being the sole mechanism for every case.

## Interpretation notes (decisions made where the parent design leaves a
degree of freedom — see "Decision Making Guidelines" in the autonomous-dev
skill: pick the simpler, more maintainable option)

- **Test-only override seam: four independent variables, not one bundled
  blob.** The issue's own body suggests `_GATE_BOX_HEALTH_OVERRIDE` (singular)
  "or per-signal overrides." This PR ships four independent
  `_GATE_<SIGNAL>_OVERRIDE` vars (plus a file-based `_OVERRIDE_FILE` variant
  of each, for the re-check-once test scenario — see below) so a test can
  isolate exactly ONE signal while the other three read the box's REAL
  (presumably healthy) values, proving per-signal independence rather than
  merely "some combination of overrides fires the gate."
- **A second, file-based override variant for the re-check-once test.** A
  bare env-var override is static for the whole `dispatch-local.sh`
  invocation and cannot simulate an ACTUAL reclaim happening between the
  gate's first failing check and its second (re-check-once) pass — the
  fake `adt-gc.sh --quick` stub a test injects via `_ADT_GC_ENTRY_OVERRIDE`
  runs as a SEPARATE process and cannot mutate the parent shell's env vars.
  A `_GATE_<SIGNAL>_OVERRIDE_FILE` variant (read fresh on every
  `_gate_check_signals` call) lets the stub rewrite the file between the
  two checks, so the "pressure clears after `--quick`" AC can be tested
  behaviorally, not merely asserted by inspection.
- **The kind-mapping helper, `_gate_kind_for_type`.** `dispatch-local.sh`'s
  own `TYPE` vocabulary (`dev-new`/`dev-resume`/`review`) differs from the
  `issue`/`review` vocabulary the PID-file scheme and the remote liveness
  driver already use (`${kind}-${N}.pid`). The gate's defer marker is named
  `.defer-<kind>-<N>` (not `.defer-<type>-<N>`, despite the design's own
  literal §4-C6 wording using `<type>`) specifically so the SAME kind token
  the remote probe already computes from its own `KIND` argument lines up
  byte-for-byte with the marker this gate writes — no separate translation
  table needed on the remote-probe side. This is a deliberate, documented
  deviation from the design's literal `.defer-<type>-<N>` phrasing in favor
  of consistency with the EXISTING kind/type split the rest of the
  dispatcher codebase already has to manage.
- **Absent box-health signals never gate, never fabricate a value.**
  `box_health` OMITS a key entirely when its source is unavailable (e.g.
  `/proc/meminfo` unreadable). The gate's `_gate_health_field` helper
  distinguishes "signal absent" from "signal present and healthy" — an
  absent MemAvailable must never be coerced to `0` (which would read as
  "critically low" for a min-floor check) and an absent load/swap value
  must never be coerced to `0` either (which would read as "perfectly
  healthy" for a max-ceiling check, masking the fact that the signal is
  actually UNKNOWN). Every signal defaults to "skip" (never gate) when its
  source can't be read — the same fail-toward-leak-not-refuse posture this
  whole design series applies to kill decisions, applied here to admission.
- **`swap_pct` is floor-rounded, never round-to-nearest** (review P3-1).
  `printf %.0f` rounds 90.5+ up to 91, so a box sitting at a steady
  90.4x% swap would occasionally round to 90 and occasionally to 91 as the
  free/total counters shift by a few KB tick to tick — flapping the gate
  across the default `GATE_SWAP_PCT=90` boundary with no real change in
  box health. Floor semantics (`int(x)`, truncation toward zero — the same
  thing for our always-non-negative ratio) make a steady 90.x% always
  report exactly 90, so the gate only ever fires at a genuine ≥91%.
- **`lane_global_live_count` takes an optional `<cap>` and short-circuits
  at it, plus skips terminal-state lanes without probing** (review P2-3).
  The gate never needs the exact global live-lane total — only "at or
  above `MAX_TOTAL_CONCURRENT`" — so scanning every remaining lane/project
  once that's already known is pure waste on a box with many onboarded
  projects (this series' own dev/CI box has 63). A lane whose `STATE` is
  `clean-exit`/`reaped-by-guardian`/`gc-reaped` (the same terminal
  vocabulary `adt-gc.sh` rule 1.3 already uses) can never be live by
  construction, so it's excluded via one cheap `lane_get STATE` read
  BEFORE the comparatively expensive `lane_probe` call, not merely used
  to reinterpret the probe's result afterward.
- **The gate's "never kills" claim is scoped to its own admission-decision
  code, never to `adt-gc.sh`'s reclaim step** (review P2-1). The refusal
  path's one bounded `adt-gc.sh --quick` call is a SEPARATE component
  under its OWN safety predicate ([INV-117]): dry-run by default (kills
  nothing — the case every existing test here exercises), but if a host
  has separately opted into `ADT_GC_ENFORCE=1`, that same `--quick` call
  CAN kill registry-dead-lane residue — authorized by INV-117's own
  decision table, not by this gate, and it would fire identically on that
  host regardless of whether the gate ever called `--quick` (the
  box-wide opportunistic call already runs on every dispatch). The
  original wording ("the gate never kills running lanes... it never kills
  or signals any process") did not distinguish the gate's OWN code from
  the reclaim step it calls into; this PR's grep-pin test and code
  comments now scope the claim precisely to the former.

## Out of scope (unchanged from parent design §11, §9 PR-6's own carve-out)

- The systemd-scope backend (design §4-C7) — P7, not touched here.
- Fixing the pre-existing remote-backend log-read blindness (#356) beyond
  the DEFERRED surfacing this PR adds (explicitly out of scope per the
  parent design's §11).
- Full macOS-runner CI execution for the gate's own macOS `box_health`
  branches — no macOS runner exists in this repo's CI pool; the macOS
  `sysctl`/`vm_stat` parsing is implemented and reviewable but not
  exercised by a live macOS CI job, the same posture PR-4 already
  established for its own macOS-specific paths.
