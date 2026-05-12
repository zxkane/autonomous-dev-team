# Test cases — `readlink -f` → `BASH_SOURCE[0]` migration (#104)

Companion to `docs/designs/issue-104-bash-source-migration.md`. All cases live in `tests/unit/test-symlink-resolution.sh`.

## TC-INV14 (deployment topology coverage)

| ID | Topology | Asserts |
|----|----------|---------|
| TC-INV14-1 | **Vendored, project-side symlink** — `<proj>/scripts/dispatch-local.sh -> <proj>/.agents/skills/autonomous-dispatcher/scripts/dispatch-local.sh`, conf at `<proj>/scripts/autonomous.conf` | `dispatch-local.sh` loads conf via tier-1 (same-dir match after migration). Regression test for current production deployments. |
| TC-INV14-2 | **Shared-install (user-scope), project-side symlink** — `<proj>/scripts/dispatch-local.sh -> $HOME/.claude/skills/autonomous-dispatcher/scripts/dispatch-local.sh`, conf at `<proj>/scripts/autonomous.conf` | `dispatch-local.sh` loads conf via tier-1. NEW topology that fails pre-fix because `readlink -f` resolves outside any project boundary. |
| TC-INV14-3 | **System-wide install, project-side symlink** — `<proj>/scripts/dispatch-local.sh -> /opt/share/autonomous-dispatcher/scripts/dispatch-local.sh`, conf at `<proj>/scripts/autonomous.conf` | Same logic as TC-INV14-2, different install path — proves the fix isn't hardcoded to `~/.claude/`. |
| TC-INV14-4 | **Vendored, called directly (no project symlink)** — invoke `<proj>/.agents/skills/autonomous-dispatcher/scripts/dispatch-local.sh` directly; conf at `<proj>/scripts/autonomous.conf` | Loads conf via the existing `${SCRIPT_DIR}/../../../scripts/autonomous.conf` fallback in `dispatch-local.sh:34`. Regression check for projects that haven't migrated to project-side symlinks. |
| TC-INV14-5 | **End-to-end: shared-install dispatch chain** — `dispatcher-tick.sh` → `dispatch-local.sh` → `autonomous-dev.sh`, all symlinked into shared install | Every layer's `SCRIPT_DIR` resolves into the project's `scripts/`. Conf loads on the first layer that needs it. No `claude` invocation — the test stops before `nohup`. |

## Existing TC-SYM cases — regression coverage

The pre-existing `TC-SYM-001..006` cases simulate the symlink-resolution behavior. They construct `cat <<'SCRIPT'`-embedded test scripts whose source happens to use `readlink -f` (matching the production scripts of the time). After this PR, the production scripts use `BASH_SOURCE[0]`, so:

- The simulation strings inside `TC-SYM-001..003` keep using `readlink -f` because they're testing the **resolver itself**, not the production scripts. Those tests still pass — they assert how `readlink -f` behaves, which is unchanged.
- `TC-SYM-004` and `TC-SYM-005` simulate `dispatch-local.sh`'s conf-loading logic. After the PR, the production `dispatch-local.sh` no longer uses `readlink -f`, so the simulation drifts from production. Update those simulations to mirror the new `BASH_SOURCE[0]` form, retaining their regression value.

## Negative / safety

| ID | Scenario | Expected |
|----|----------|----------|
| TC-INV14-6 | All 6 production scripts contain `BASH_SOURCE[0]` and do NOT contain `readlink -f "$0"` | `grep` assertion against the source files — locks down the migration so a future revert would fail CI. |

## Out of scope (not tested)

- Real `claude` / `gh` invocation against any topology — the existing `test-autonomous-launcher-verdict-fresh.sh` already covers downstream behavior; this PR is a SCRIPT_DIR-resolution change.
- `dispatcher-tick.sh` → `dispatch-remote-aws-ssm.sh` SSM path. SSM dispatch is a string-template emission whose targets run on a remote box; its SCRIPT_DIR-resolution is identical to the local case once the remote shell starts. Adding an SSM-aware test would require mocking AWS; defer to a future SSM-specific test file if regressions appear.
- Hot-patched deployments (e.g. `<project>/.agents/skills/.../lib-agent.sh` directly edited). Not a topology this PR creates or supports.
