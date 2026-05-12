# SCRIPT_DIR migration: `readlink -f "$0"` → `${BASH_SOURCE[0]:-$0}`

Closes #104.

## Background

[INV-14](../pipeline/invariants.md#inv-14-config-lookup-honors-symlink-vendor-pattern) (introduced in PR-4 to close #58) requires that all scripts loading `autonomous.conf` resolve their own directory via `${BASH_SOURCE[0]:-$0}` rather than `readlink -f`. The reason is conf-loading semantics: when a project vendors scripts as symlinks (e.g. `<project>/scripts/autonomous-dev.sh -> .agents/skills/.../autonomous-dev.sh`), `BASH_SOURCE[0]` retains the project-side path, while `readlink -f` jumps fully to the vendored location. Conf lives in the project's `scripts/`, not in the vendored copy, so `readlink -f` causes the conf-lookup to miss tier-2 (`${SCRIPT_DIR}/autonomous.conf`).

That broke INV-14 quietly for one specific deployment topology — the **shared-install topology** — where the scripts directory in the project is a directory of symlinks pointing into a single skill installation (typically user-scope at `~/.claude/skills/`). Today's vendored topology survives because:
- `dispatch-local.sh:34` has a `${SCRIPT_DIR}/../../../scripts/autonomous.conf` fallback that resolves correctly when the vendor lives at `<project>/.agents/skills/.../scripts/`.
- Once `dispatch-local.sh` finds conf, it `nohup`s the wrapper with `PROJECT_DIR` already exported — letting `lib-agent.sh` use tier-3 (`${PROJECT_DIR}/scripts/autonomous.conf`) to find conf even though tier-2 missed.

Both fallbacks fail under the shared-install topology, where `readlink -f` resolves outside any project boundary. Verified empirically during issue investigation: a `/tmp/proj-test-*` directory with only `scripts/autonomous.conf` plus symlinks pointing into `~/.claude/skills/...` failed conf-loading; the same layout with a sed-patched `BASH_SOURCE[0]` form loaded conf correctly.

## Files affected

Six production scripts violate INV-14:

| File | Line | Path-resolver name |
|---|---|---|
| `setup-labels.sh` | 12 | `SCRIPT_DIR` |
| `dispatch-local.sh` | 31 | `SCRIPT_DIR` (critical path) |
| `gh-token-refresh-daemon.sh` | 26 | `SCRIPT_DIR` |
| `autonomous-review.sh` | 17 | `SCRIPT_DIR` (critical path) |
| `autonomous-dev.sh` | 17 | `SCRIPT_DIR` (critical path) |
| `gh-with-token-refresh.sh` | 18 | `SELF_DIR` (same pattern, different var name) |

Plus test code in `tests/unit/test-symlink-resolution.sh:62, 100, 106, 137, 169, 205, 334` simulates the broken pattern. The simulations themselves are fine (they're testing what real code does today), but the test enumeration should add cases that lock down the fix.

## Change

Replace `readlink -f "$0"` with `${BASH_SOURCE[0]:-$0}` in all 6 sites. Add a one-line INV-14 citation in the surrounding comment so future "cleanup" PRs don't revert.

The behavioral difference:

| Topology | `readlink -f "$0"` resolves to | `${BASH_SOURCE[0]:-$0}` resolves to |
|---|---|---|
| Vendored, called from project-side symlink | `<project>/.agents/skills/.../scripts/` | `<project>/scripts/` ✓ |
| Vendored, called directly | `<project>/.agents/skills/.../scripts/` (same) | `<project>/.agents/skills/.../scripts/` (same) |
| Shared-install, called from project-side symlink | `~/.claude/skills/.../scripts/` ✗ | `<project>/scripts/` ✓ |
| Shared-install, called directly | `~/.claude/skills/.../scripts/` (same) | `~/.claude/skills/.../scripts/` (same) |

For the wrapper / dispatcher chain we always invoke via `<project>/scripts/<file>.sh`, so the migration converts a previously-broken topology into a working one without changing any working topology.

### Sibling-source statements unchanged

Inside each migrated file, statements like `source "${SCRIPT_DIR}/lib-agent.sh"` are unaffected: both `readlink -f` and `BASH_SOURCE[0]` resolve to a directory that *contains* a copy of `lib-agent.sh`. The semantic difference shows up only at `lib-config.sh::load_autonomous_conf`, where `${SCRIPT_DIR}` is compared against the location of `autonomous.conf`.

### Backward compat with `dispatch-local.sh:34` fallback

Keep the `${SCRIPT_DIR}/../../../scripts/autonomous.conf` fallback. After migration, `SCRIPT_DIR` always resolves to project-side `scripts/` for symlinked invocations, so tier-1 (same-dir) hits and the fallback never fires. But for callers that still invoke the vendored copy *directly* (no project-side symlink), the fallback remains the only way to find conf. Removing it would be a separate breaking change and is explicitly **out of scope** per the issue.

### Variable naming for `gh-with-token-refresh.sh`

That file uses `SELF_DIR` instead of `SCRIPT_DIR`. The migration treats it as a same-pattern, different-name case — same `${BASH_SOURCE[0]:-$0}` substitution, same INV-14 citation comment, no rename to `SCRIPT_DIR` (out-of-scope churn).

## Test enumeration

New cases extend `tests/unit/test-symlink-resolution.sh`:

| ID | Topology | Behavior asserted |
|---|---|---|
| TC-INV14-1 | Vendored, project-side symlink → `<proj>/.agents/skills/.../` | conf loads (regression for current production) |
| TC-INV14-2 | Shared-install (user-scope), project-side symlink → `~/.claude/skills/.../` | conf loads (NEW topology unblocked by this PR) |
| TC-INV14-3 | System-wide install, project-side symlink → `/opt/skills/.../` | conf loads (defensive: proves it's not hardcoded to `~/.claude/`) |
| TC-INV14-4 | Vendored, called directly (no project symlink, with `../../../scripts/autonomous.conf` layout) | conf loads via `dispatch-local.sh:34` fallback (regression) |
| TC-INV14-5 | End-to-end: `dispatcher-tick.sh` → `dispatch-local.sh` → `autonomous-dev.sh`, shared-install | every layer's `SCRIPT_DIR` resolves into project's `scripts/` (or harmless if that layer doesn't load conf), conf loads |

Each new case constructs a tmpdir mimicking the topology, places a unique `autonomous.conf` in the project-side `scripts/`, runs `dispatch-local.sh` (or a stripped wrapper that just sources the conf), and asserts the unique value made it through.

## Docs

- Update `lib-config.sh::load_autonomous_conf` docstring: explicitly list the two supported topologies (vendored, shared-install). The docstring already says "use BASH_SOURCE not readlink-f" — add why both topologies work after the migration.
- Update `INV-14` in `docs/pipeline/invariants.md`: enumerate the two topologies, note that the migration in this PR aligned all 6 prior offenders with the rule.
- Update `autonomous.conf.example`: add a comment block documenting the shared-install topology as a supported alternative to `npx skills add -p`.

## Out of scope

Per the issue:
- Removing `dispatch-local.sh:34`'s `../../../scripts/autonomous.conf` fallback. Could be deprecated separately.
- Changing `npx skills add` to install user-scope by default.
- A wrapper `install-shared-symlinks.sh` helper that auto-creates the project-side symlinks pointing into a chosen shared-install path. Useful follow-up but separable from the contract change.

## Risk

Low. Pure refactor + behavioral expansion. Existing topology behavior is preserved (TC-INV14-1, TC-INV14-4 are regression tests). Migration touches non-business-logic identifier resolution only. No config schema changes.
