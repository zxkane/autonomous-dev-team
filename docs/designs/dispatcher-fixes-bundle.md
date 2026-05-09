# Dispatcher fixes bundle: 4 mechanical bugs + shared lib refactor

PR-4 of the pipeline-docs plan. Closes 4 issues with a consolidate-then-fix structure: extract one shared helper first, then apply per-issue fixes. The shared helper is itself the fix for #58.

## Issues addressed

| # | Title | Fix shape |
|---|---|---|
| #58 | `readlink -f` breaks autonomous.conf lookup with symlinked vendoring | Refactor: extract `lib-config.sh::load_autonomous_conf`, drop `readlink -f`, fix the `../../../` fallback depth |
| #61 | Dependency check treats merged PRs as unresolved (state != CLOSED misses MERGED) | One-line: `state != "CLOSED"` → `state ∉ {"CLOSED", "MERGED"}` |
| #70 | Dev Session ID regex uses Python-style named group, fails on jq 1.6+ | One-character: `(?P<id>...)` → `(?<id>...)` |
| #73 | `grep -oP` in `check_deps_resolved` is GNU-only | Mechanical: replace with portable `grep -oE '#[0-9]+' \| sed` |

## Refactor first, fix on top

Per project direction: any fix that touches code with duplicated patterns must consolidate before fixing. Three of the four issues touch dispatcher / lib-agent / lib-auth, where the `autonomous.conf` loading block appears **byte-identical in three files**:

- `skills/autonomous-dispatcher/scripts/lib-agent.sh` lines 6–17
- `skills/autonomous-dispatcher/scripts/lib-auth.sh` lines 8–19
- `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` lines 19–31

The lib-agent and lib-auth versions use `readlink -f`; dispatcher-tick (written in PR-3) doesn't. **The dispatcher-tick variant is the correct shape per #58.** PR-4 lifts that shape into a shared helper and points all three callsites at it.

### New file: `lib-config.sh`

One function `load_autonomous_conf` with the following contract:

- Tries 3 sources in priority order:
  1. `$AUTONOMOUS_CONF` env var (highest, explicit override)
  2. Same directory as the *invocation* path (NOT `readlink -f`, so symlink-vendor pattern works — #58 fix)
  3. `${PROJECT_DIR}/scripts/autonomous.conf` if `PROJECT_DIR` is set (more robust than the broken `../../../scripts/` fallback)
- Sources the chosen file with `# shellcheck disable=SC1090,SC1091` annotations.
- Returns 0 if config was loaded, 1 if no source was found.
- Function-scoped: writes `AUTONOMOUS_CONF_LOADED_FROM` global for diagnostics, doesn't pollute caller scope otherwise.

### Three callsites switch to the helper

```bash
# lib-agent.sh, lib-auth.sh, dispatcher-tick.sh — all become:
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib-config.sh
source "${SCRIPT_DIR}/lib-config.sh"
load_autonomous_conf "${SCRIPT_DIR}"
```

Each callsite drops 10–15 lines of duplicated bash. Net diff: roughly −30 lines of duplication, +20 lines of new helper, +tests.

### Why not consolidate `_LIB_AGENT_DIR` / `_LIB_AUTH_DIR` etc. too?

Each file's other code uses its own `_LIB_*_DIR` variable. PR-4 will keep those for now — they're cheap, single-use, and consolidating them would mean editing every reference inside each file (out-of-scope creep). The `load_autonomous_conf` helper is the only block that's truly identical across all three.

## Other small fixes layer on top

Once `lib-config.sh` lands and #58 is closed, the other three fixes are independent one-liners in `lib-dispatch.sh` (PR-3's helper module):

- **#61**: `check_deps_resolved` — change the state comparison to also accept `MERGED`. Update INV-11 status to ENFORCED.
- **#70**: `extract_dev_session_id` — change `(?P<id>...)` to `(?<id>...)`. Update test (3 currently-broken-asserting tests now assert real extraction). Add INV-16 documenting jq Oniguruma vs Python regex syntax.
- **#73**: `check_deps_resolved` — same function as #61, replace `grep -oP '#\K[0-9]+'` with `grep -oE '#[0-9]+' | sed 's/^#//'`.

#61 and #73 both touch `check_deps_resolved`. They land in the same diff; the test covers both behaviors at once.

## Test plan

- New test: `tests/unit/test-lib-config.sh` (4 cases)
  1. `AUTONOMOUS_CONF` env var takes priority over filesystem search.
  2. Script-local `autonomous.conf` is found (no `readlink -f` so symlinked path works).
  3. `${PROJECT_DIR}/scripts/autonomous.conf` fallback is found when neither of the above is set.
  4. Returns non-zero when no config is found and `PROJECT_DIR` is unset.

- Update existing `test-lib-dispatch.sh`:
  - Three previously-asserting-broken tests for `extract_dev_session_id` now assert real session-id extraction (revert to expecting `abc-123-def` etc.). Issue #70 closed by this.
  - One new fixture for `check_deps_resolved` covering MERGED state. Issue #61 closed by this.
  - One new fixture for `check_deps_resolved` covering multi-line / mixed-whitespace dep lists. Issue #73 closed by this.

- Update existing `test-bash-source-empty.sh`:
  - The test that simulates the symlinked-vendoring layout (#58 / #39 reproducer) now passes against the new `load_autonomous_conf`.

## Per CONTRIBUTING.md Rule 1

This PR touches `skills/autonomous-dispatcher/scripts/*.sh` (multiple watched files). It also touches `docs/pipeline/invariants.md` (INV-11, INV-14 status flips, new INV-16). The CI gate passes via the docs-touched path.

## Behavior preservation everywhere except the 4 documented fixes

Strict rule: every diff line not directly tied to one of the 4 issue fixes must be a refactor that preserves byte-equivalent behavior. No "while I'm here" cleanups.

The lib-config.sh refactor is functionally a behavior change (it removes `readlink -f` and fixes the path-depth fallback), but that change IS the #58 fix — there's no honest way to extract the helper without picking one of the two variants, and the dispatcher-tick.sh variant is the one #58 documents as correct.

## Risk

Medium. The lib-config.sh refactor touches three callsites at once; if it's wrong, the dispatcher and both wrappers fail at startup. Mitigations:

- Unit tests for `load_autonomous_conf` covering all 3 priority paths.
- Manual smoke test: source each of the three callsites in a clean shell and assert `REPO`, `REPO_OWNER`, `PROJECT_ID` are all set.
- Code-reviewer pass focused on "does the new path resolution match each callsite's actual invocation context?".

## Out of scope

- #59 resume-on-completed-session — wrapper-side, deferred to PR-5.
- #60 wall-clock timeout — wrapper-side, deferred to PR-5.
- #62 multi-repo dispatch — major architectural change, PR-6.
- #67 INV-15 SIGTERM race — wrapper-side, deferred.
- #72 PID files CWE-377 — separate small PR.
- #64/#65/#68 — hooks-side bug cluster, deserves its own PR (security-relevant, not just polish).
