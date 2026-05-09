# Design Canvas — Config-driven Multi-project Dispatcher (PR-8)

**Branch**: `feat/multi-project-dispatcher`
**Closes**: #62 (axes 1 + 3 only — pluggable execution backend deferred to a follow-up).
**Pipeline-docs touched**: `docs/pipeline/dispatcher-flow.md` (new outer-loop section).

---

## Why

Today the dispatcher tick is single-project: `dispatcher-tick.sh` sources one `autonomous.conf` at startup and runs one tick. To dispatch across multiple repositories, an operator forks the skill and edits its hardcoded `PROJECTS=()` array — losing upstream updates and turning every repo onboarding into a code change.

This PR keeps `dispatcher-tick.sh` unchanged and wraps it in a tiny outer loop driven by a separate `dispatcher.conf` file. The schema is intentionally minimal so the change is reviewable and reversible.

## Scope

In scope:
- New `dispatcher.conf.example` declaring a `PROJECTS=()` array of paths to per-project `autonomous.conf` files.
- New `dispatcher-multi-tick.sh` outer loop.
- Updated SKILL.md / dispatcher-flow.md documenting the new entry point and its backwards-compat fallback.
- Tests covering iteration, env-override propagation, and per-project failure isolation.

Out of scope (deferred):
- Pluggable execution backend (`EXECUTION_BACKEND=local|ssm`). Will be a follow-up PR (PR-9 if pursued) once the multi-project plumbing is verified.
- `dispatch-ssm.sh` brand-new SSM driver. Larger surface, would need its own design canvas.

## Schema

```bash
# dispatcher.conf
# Lookup priority: $DISPATCHER_CONF env, $HOME/.autonomous/dispatcher.conf,
# $XDG_CONFIG_HOME/autonomous/dispatcher.conf.

# Required: list of per-project autonomous.conf paths.
# Each path must point to a project's existing autonomous.conf; the dispatcher
# sources it (in a subshell) before running one tick.
PROJECTS=(
  "/data/git/myrepo-a/scripts/autonomous.conf"
  "/data/git/myrepo-b/scripts/autonomous.conf"
)
```

Per-project values (REPO, PROJECT_ID, MAX_CONCURRENT, DISPATCHER_APP_ID, DISPATCHER_APP_PEM, ...) all stay in each project's `autonomous.conf`. The outer loop just iterates.

## Per-tick semantics

```text
dispatcher-multi-tick.sh tick:
  load dispatcher.conf  (sets PROJECTS array)
  for each conf_path in PROJECTS:
    in a subshell with AUTONOMOUS_CONF=$conf_path:
      bash dispatcher-tick.sh
      capture exit code, log it
    on exit: subshell teardown (env restored automatically)
  exit 0  # outer loop never fails the tick — one bad project must not block others
```

Key isolation property: each project gets its own subshell. Variables set by one project's `autonomous.conf` (REPO, PROJECT_ID, MAX_CONCURRENT, etc.) cannot leak into the next project's tick. This matches the `lib-config.sh::load_autonomous_conf` priority-1 path (`AUTONOMOUS_CONF` env override) introduced in PR-4 — no new mechanism needed.

## Concurrency model — per-project, not global

Each per-project tick checks its own `MAX_CONCURRENT` against issues with its own `REPO`'s active labels. There is **no** global cross-project concurrency cap. Rationale:

- Different projects often run on different cloud-station instances or with different agent quotas.
- Adding global concurrency would require shared state across ticks (a file lock or a count file under the PID dir).
- Operators who need a global cap can compose: set per-project `MAX_CONCURRENT=2` and have at most N projects.

## Backwards compatibility

The dispatcher's existing single-project behavior is preserved exactly:

- `DISPATCHER_CONF` unset → SKILL.md continues to advise `bash dispatcher-tick.sh` directly. No wrapper involved. Existing single-repo deployments do not need to migrate.
- `DISPATCHER_CONF` set but file missing → `dispatcher-multi-tick.sh` writes a clear error to stderr and exits non-zero, so cron logs surface the misconfiguration instead of silently skipping ticks.
- `DISPATCHER_CONF` set, `PROJECTS=()` empty → loop runs zero iterations, exits 0 with a single log line.

## GitHub App auth (issue #62 axis 3)

The wrappers (`autonomous-dev.sh`, `autonomous-review.sh`) already read `DISPATCHER_APP_ID` / `DISPATCHER_APP_PEM` from each project's own `autonomous.conf` via `lib-auth.sh::setup_github_auth`. This already works — the multi-project wrapper inherits it for free because each project's `autonomous.conf` is sourced fresh in the subshell.

The cron prompt in SKILL.md updates from "set REPO, source autonomous.conf, run dispatcher-tick.sh" to just "run dispatcher-multi-tick.sh" — the per-project auth happens inside each iteration.

## Failure isolation

The outer loop must continue past per-project failures (one project's misconfiguration must not stall others). Use:

```bash
for conf in "${PROJECTS[@]}"; do
  if ! ( AUTONOMOUS_CONF="$conf" bash "$SCRIPT_DIR/dispatcher-tick.sh" ); then
    log "  WARN: tick failed for $conf (rc=$?)"
  fi
done
```

The inner subshell's exit code is captured but does NOT short-circuit the loop. Each project gets one tick attempt per cron cycle.

## Tests

`tests/unit/test-dispatcher-multi-tick.sh`:

1. PROJECTS=() is honored — iterates the right number of times.
2. Each iteration runs `dispatcher-tick.sh` with `AUTONOMOUS_CONF` set to the right path (verified via a stub `dispatcher-tick.sh` that records its env).
3. Per-project failure does not break the loop — second project still runs after first one fails.
4. DISPATCHER_CONF unset → wrapper aborts with a clear message (it is opt-in, not a silent no-op).
5. DISPATCHER_CONF set but file missing → non-zero exit + diagnostic.
6. PROJECTS unset (or empty array) inside dispatcher.conf → exit 0 with a single log line.

The existing test suite continues to pass unchanged because `dispatcher-tick.sh` itself is not modified.

## SKILL.md cron contract

Old cron command (single-project, still supported):
```bash
bash "$PROJECT_DIR/scripts/dispatcher-tick.sh"
```

New cron command (multi-project):
```bash
DISPATCHER_CONF="$HOME/.autonomous/dispatcher.conf" \
  bash "$PROJECT_DIR/scripts/dispatcher-multi-tick.sh"
```

Both are documented in SKILL.md; the multi-project form is recommended when more than one repo is in scope.

## Trust gate on dispatcher.conf source (CWE-94)

`source` of an operator-controlled file means arbitrary code execution as the dispatcher user. The wrapper enforces a trust gate before sourcing `dispatcher.conf`:

- File must be owned by the current uid (or root).
- File must NOT be group- or other-writable.
- Parent directory must NOT be group- or other-writable.

These are the same trust checks `sudo` and `ssh` apply to their config files. `/tmp` (mode 1777) is rejected by the parent-dir check, so operators are nudged toward `$HOME/.autonomous/dispatcher.conf` (mode 0700 home dir).

Escape hatch: `AUTONOMOUS_TRUST_CONF=1` disables the gate. Documented in `dispatcher.conf.example` for shared-VM cases where the conf is owned by a different uid by design.

The gate applies only to `dispatcher.conf` in this PR — per-project `autonomous.conf` files are sourced inside the subshell via `lib-config.sh::load_autonomous_conf` (existing pattern, not modified here). A follow-up PR could extend the trust gate to that path; out of scope for this change.

## What we're explicitly not doing

- **Not** changing dispatcher-tick.sh's interface or any of its 5 steps.
- **Not** adding cross-project state (shared counters, locks, JUST_DISPATCHED across projects).
- **Not** adding `EXECUTION_BACKEND` routing — that's a separate axis with a much larger surface (a brand new `dispatch-ssm.sh` driver).
- **Not** changing how individual wrappers read auth — they already pull from per-project `autonomous.conf`.
