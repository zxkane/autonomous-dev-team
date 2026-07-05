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

## Out of scope (unchanged from parent design §11, §9 PR-4's own carve-out)

- Flipping `--dry-run` → `--kill` by default (PR-8, requires a ≥2-week
  operator soak).
- Full macOS-runner CI execution — no macOS runner exists in this repo's CI
  pool. macOS-specific code paths (launchd installer, procargs2 shim, BSD
  parser) are unit-tested with mocked BSD/launchd outputs (`uname`/`ps`
  override seams already established by `lib-lane.sh`'s own tests); live
  macOS verification is a non-blocking follow-up gating the PR-8 flip, not
  this PR.

Guardian (P5), systemd-scope backend (P7), and the back-pressure admission
gate (P6) are later PRs in the series — not touched here.
