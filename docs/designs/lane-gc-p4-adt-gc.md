# Design: Lane-GC P4 — `adt-gc.sh` periodic GC + `install-gc-timer.sh`

**Status:** Implementation notes for issue #380 (Lane-GC series PR-4). Full
design authority is `docs/designs/lane-containment-gc.md` §4-C5 (periodic
GC), §6 (the normative decision table), §9 PR-4. This doc records only the
PR-open numbering re-verification and the concrete diff shape; it is not a
new design — defer to the parent doc for rationale.

## Numbering re-verification (design §8/§10 F10 completeness)

The parent design assumed head INV-105 and reserved INV-106..113 (§8) for
the whole series. Since then, PR-2 (#378) shipped INV-109/INV-110 and PR-3
(#379/#405) shipped INV-114/INV-115 (both already renumbered once — see
`docs/designs/lane-gc-p3-kill-paths.md`). Current head at this PR's open was
**INV-115**, so this PR first claimed **INV-116** (drafted as INV-110 in the
parent design's normative table; renumbered per the design's own stated
"first-merged keeps, each INV-adding PR notes the convention" rule).

A subsequent rebase onto `origin/main` pulled in #422's GitLab-transport
invariant, which had independently — and, by merge order, earlier — also
claimed INV-116 for itself (it too was renumbered on a collision, from its
own drafted INV-113). Per the same repo-wide convention, the already-merged
GitLab entry keeps INV-116; this PR yields the slot and re-claims the next
free one:

- **INV-117 — GC safety predicate and periodic reclamation** (drafted as
  INV-110 → INV-116 → **INV-117**, three renumbers across the design's
  drafting and two independent merge-order collisions).

## Scope (this PR)

1. **`skills/autonomous-dispatcher/scripts/adt-gc.sh`** (new entry-point
   script): flock singleton over `$ADT_STATE_ROOT/adt-gc.lock`; modes
   `--dry-run` (default), `--kill`, `--quick` (Pass 1 only, `flock -w 3`),
   `--doctor` (probes timers/linger/flock/backend/setsid/python3-on-macOS/
   `ADT_STATE_ROOT` content). Implements the design §6 decision table's four
   passes against the registry `lib-lane.sh` (PR-2/#378) already ships.
2. **`skills/autonomous-dispatcher/scripts/install-gc-timer.sh`** (new
   entry-point script): idempotent per-host installer — crontab marker-line
   edit on Linux, launchd plist + `launchctl bootstrap` on macOS.
3. Opportunistic `adt-gc.sh --quick || true` at the top of
   `dispatch-local.sh` (busy boxes self-clean even with no timer installed).
4. Portability primitives added to `lib-lane.sh` (design §12 R13 — GC stays
   a thin entry-point; shared helpers live in the lib): `proc_argv`,
   `proc_ppid`, `proc_pgid`. No behavior change to any existing function.
5. `ADT_GC_SUMMARY` metrics line for the existing INV-70 observe-only
   metrics lane (best-effort `metrics_emit` call, guarded — GC has no
   metrics dependency and degrades silently if `lib-metrics.sh` is absent).

## Interpretation notes (decisions made where the parent design leaves a
degree of freedom — see "Decision Making Guidelines" in the autonomous-dev
skill: pick the simpler, more maintainable option)

- **Rule 2.4's "ancestry of any live wrapper" is scoped box-wide, not
  per-`PROJECT_DIR`.** `adt-gc.sh` runs once per host across every onboarded
  project's registry (`$ADT_STATE_ROOT/autonomous-*/lanes/`); it has no
  central manifest of every project's `PROJECT_DIR` to scope the protective
  `pgrep -f 'autonomous-(dev|review)\.sh'` ancestry walk to. Walking every
  live wrapper process on the box (regardless of which project spawned it)
  is strictly more conservative than a per-project-scoped walk — it can only
  cause GC to *skip* a candidate it would otherwise have been safe to sweep,
  never cause a false kill. This matches design principle 5 (fail toward
  leak, never false-kill).
- **Pass 4's "≥ 2 consecutive GC ticks" state** is tracked in a small flat
  file (`$ADT_STATE_ROOT/adt-gc-pass4.state`, one `pid last_high_epoch` line
  per tracked pid) rather than a new registry field — Pass 4 is flag-only
  telemetry, not kill-authorizing, so it does not need the durability or
  atomicity guarantees the lane registry provides.
- **3.1's "dead lane's `LANE_SCRATCH`"** is implemented against the lane
  file's existing `CHROME_PROFILE_HINT` field (already shipped by PR-2 for
  exactly this purpose) rather than a new field — no `LANE_SCRATCH` key
  exists in the registry today, and inventing one for a single Pass-3 rule
  would be scope creep beyond this issue's requirements.
- **Review round-2: Pass-3 age floors for rules 3.1/3.3/3.4** (the parent
  design's §6 table gives an explicit floor only for 3.2 — "age > 2 h" —
  and is silent for the other three). Independent review (4 P1 + 5 P2)
  found that every Pass-3 sub-rule applied an ARBITRARY SUBSET of Pass 2's
  guard set instead of the full one (3.4 applied NONE at all), fixed by
  extracting a shared `_gc_common_kill_guards <pid> <pg> <age_floor>
  [rule_id]` function every Pass-2/3 kill-authorization site now calls.
  Floors chosen for the three rules the design leaves unstated: **3.1 and
  3.4 use `age_floor=0`** — both are EXACT structural matches (a dead
  lane's own recorded `CHROME_PROFILE_HINT`/`WORKTREE` field, not a fuzzy
  heuristic), the same confidence class as rule 2.1's exact `ADT_LANE_ID`
  join, which itself needs only its own 300s floor for the SEPARATE reason
  that a startup window may precede PID-file writes — no such window
  applies to a value already recorded in a DEAD lane's registry file.
  **3.3 uses `age_floor=300`** — design row 3.3 says "∧ 2.2–2.5", pulling
  in rule 2's own conjunct set, and 3.3's `GH_TOKEN_FILE`-pattern-plus-
  dir-gone match is the same exact-positive-signal class as 2.1's exact
  join (not the weaker legacy-signature arm), so it inherits that arm's
  tighter 300s floor rather than the legacy arm's 600s.
- **Review round-2: rule 3.2's two rule-local extra conjuncts** ("no live
  process shares that profile dir" ∧ "no live chrome-devtools-mcp parent",
  design §5 line 215 / §6 row 3.2) were previously omitted entirely (P1-4).
  Both are kept OUTSIDE the shared `_gc_common_kill_guards` function — no
  other Pass-3 rule keys on a shared profile directory or an MCP-server
  ancestor, so generalizing either into the shared function would be
  premature abstraction for a single caller. The profile-dir-sharer check
  re-enumerates same-uid pids for a live `--user-data-dir=<same dir>`
  match; the MCP-parent check walks the live descendant tree of every
  process whose argv matches `chrome-devtools-mcp` (same BFS technique as
  the existing live-wrapper-ancestry gate) — defense-in-depth alongside
  the rule's own `ppid==1` requirement, covering a subreaper-race shape
  where a container's subreaper re-adopts the chrome process while its
  true MCP-server ancestor remains alive further up the tree.
- **Review round-2: kill-primitive self/pgid-0 defense (P1-3).**
  `_gc_kill_candidate` accepted any numeric pgid, including 0 (`kill -TERM
  -- -0` is a kernel alias for the SENDER's own process group, not any
  candidate's) and GC's own pgid. Fixed with `_gc_safe_kill_pgid`/
  `_gc_safe_kill_pid` gates (numeric, `>1`, not GC's own group/`$$`) at
  every kill-primitive call site (`_gc_kill_candidate`,
  `_gc_term_then_kill_pid`, rule 1.4's guardian kill) — the LAST line of
  defense before any signal fires, independent of whether an upstream
  caller already filtered its candidate correctly.
- **Review round-2: fail-closed env reads (P1-2).** `_gc_has_term_program`
  returning false when a process's env cannot be read at all (dead
  mid-scan, EPERM, or macOS with no procargs2 shim) was indistinguishable
  from "env readable, TERM_PROGRAM genuinely absent" — silently vanishing
  the operator-protection gate exactly when least is known about a
  candidate. Fixed with a new `env_readable` primitive (`lib-lane.sh`) and
  `_gc_env_unknowable` wrapper, checked FIRST and SEPARATELY from
  `_gc_has_term_program` at every kill-authorization site — an unknowable
  env now skips (fail toward leak, design principle 5) rather than
  proceeding. On macOS without the procargs2 shim this correctly makes
  every env-dependent Pass 2/3 kill refuse too, matching the design's
  registry-authoritative-only posture for that platform.
- **Review round-3 (post-round-2 verification pass): `env_of`/`env_readable`
  source alignment on Darwin, and single-quote path rejection.** Round-2's
  `env_readable` primitive probes via the procargs2 shim on Darwin, but
  `env_of`/`env_lookup` stayed Linux-only (`/proc/PID/environ` only) —
  re-opening the P1-2 hole one layer down: a TERM_PROGRAM-protected
  operator process on macOS probed "readable" via `env_readable`, then
  `env_lookup` found nothing (an empty read from a source it never
  actually consulted) and the candidate fell through to full kill
  eligibility. Fixed by making `env_of` consult the SAME procargs2 source
  on non-Linux, under the explicit contract that any read path added to
  one of the two functions must be added to both. Separately,
  `install-gc-timer.sh`'s cron entry single-quotes both paths but did not
  reject a path CONTAINING a single quote — which terminates the quoting
  mid-token (shell token injection, the same class of bug the `%`/newline
  rejection exists to prevent); `'` now joins that reject set.
- **Review round-4 (re-review of round-2's OWN kill-primitive fixes):
  `_gc_safe_kill_pid`/`_gc_safe_kill_pgid` themselves had two residual
  gaps.** `_gc_safe_kill_pid`'s regex `^[0-9]+$` matches the literal string
  "0" — pid 0 is a kernel alias for the CALLER's own process group (same
  effect as pgid 0, which the function's sibling already rejected), so a
  corrupt or hostile `GUARDIAN_PID=0` registry value reaching rule 1.4's
  guardian-kill path would have self-signaled GC's own group; fixed with
  an explicit `-gt 0` check. `_gc_safe_kill_pgid`'s
  `[[ -z "$own_pg" || "$pg" != "$own_pg" ]]` treated an UNKNOWABLE own
  pgid (a transient `proc_pgid "$$"`/`ps` failure) as "therefore safe" —
  backwards under design principle 5: not being able to prove a candidate
  pgid ISN'T GC's own group must fail toward refusing the kill, not toward
  authorizing one whose self-safety cannot be verified; fixed by requiring
  `own_pg` to be non-empty before comparing.

## Out of scope (unchanged from parent design §11, §9 PR-4's own carve-out)

- Flipping `--dry-run` → `--kill` by default (PR-8, requires a ≥2-week
  operator soak).
- Full macOS-runner CI execution — no macOS runner exists in this repo's CI
  pool. macOS-specific code paths (launchd installer, procargs2 shim, BSD
  parser) are unit-tested with mocked BSD/launchd outputs (`uname`/`ps`
  override seams already established by `lib-lane.sh`'s own tests). P8
  proposes a Linux-only waiver for the enforcement candidate; that waiver is
  not an operator sign-off, and the production gate remains open pending
  #384's soak evidence. Any future macOS rollout still requires that live
  validation first.

Guardian (P5), systemd-scope backend (P7), and the back-pressure admission
gate (P6) are later PRs in the series — not touched here.
