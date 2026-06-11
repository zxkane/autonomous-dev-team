# Test Cases: Phase-0 stable entry points (issue #227)

ID prefix: `TC-ENTRY-SHIM-NNN`

## Two-dir resolution (`tests/unit/test-entry-point-resolution.sh`)

| ID | Scenario | Expected |
|---|---|---|
| TC-ENTRY-SHIM-001 | Direct invocation (real file, no symlink) | `CONF_DIR == LIB_DIR == <real scripts dir>` |
| TC-ENTRY-SHIM-002 | Single project-side symlink → skill tree | `CONF_DIR == <project scripts>`, `LIB_DIR == <skill tree>` (differ) |
| TC-ENTRY-SHIM-003 | Nested symlink (project → shared → vendored) | `LIB_DIR == <final real dir>`; `CONF_DIR == <project scripts>` (first hop) |
| TC-ENTRY-SHIM-004 | Symlinked entry sources libs from skill tree while reading conf from symlink dir | wrapper loads `lib-config.sh` from skill tree AND sources project-side `autonomous.conf` (PROJECT_ID from project conf) |
| TC-ENTRY-SHIM-005 | **Regression pin** — upstream adds `lib-new.sh`, NO project symlink | entry `source "${LIB_DIR}/lib-new.sh"` succeeds (function defined) — the missing-lib-symlink crash class is gone |
| TC-ENTRY-SHIM-006 | Legacy layout — per-lib symlinks still present in project scripts | identical behavior; `LIB_DIR` resolves through the lib symlink to the same real lib |
| TC-ENTRY-SHIM-007 | `BASH_SOURCE[0]` empty (`bash -c`) — `$0` fallback | resolution still works (no unbound-var crash) |

## Source-site lockdown (extends `test-symlink-resolution.sh`)

| ID | Scenario | Expected |
|---|---|---|
| TC-ENTRY-SHIM-010 | Every dispatcher entry script defines `LIB_DIR` (or `_LIB_*_DIR` realpath) AND uses it for `source` of siblings | grep assertion: each `source "${...}/lib-*.sh"` uses the realpath dir, not the conf dir |
| TC-ENTRY-SHIM-011 | `lib-config.sh` still has no `readlink -f` (conf loader unchanged, #58) | grep (comment-aware) finds none |
| TC-ENTRY-SHIM-012 | conf lookups still use the unresolved dir (INV-14 preserved) | `load_autonomous_conf` / `autonomous.conf` sources use `CONF_DIR`/`SCRIPT_DIR` (BASH_SOURCE-based), never `LIB_DIR` |

## Installer doctor / dry-run / prune (`tests/unit/test-install-project-hooks.sh` additions)

| ID | Scenario | Expected |
|---|---|---|
| TC-ENTRY-SHIM-020 | `--dry-run` on a fresh temp project | prints planned symlinks; ZERO filesystem changes (inode/mtime snapshot unchanged, no new files) |
| TC-ENTRY-SHIM-021 | install symlinks ONLY the stable manifest (no `lib-*.sh`) | after install, `scripts/lib-agent.sh` etc. do NOT exist as symlinks; entry points DO |
| TC-ENTRY-SHIM-022 | prune stale per-lib symlinks | a pre-seeded `scripts/lib-foo.sh` symlink into the dispatcher dir is removed on install |
| TC-ENTRY-SHIM-023 | `--doctor` clean project | exit 0, reports all entry symlinks OK + conf present |
| TC-ENTRY-SHIM-024 | `--doctor` broken entry symlink | exit 1, reports the broken symlink |
| TC-ENTRY-SHIM-025 | `--doctor` missing conf | exit 1 (or warn), flags missing `autonomous.conf` |
| TC-ENTRY-SHIM-026 | `--doctor` + `--dry-run` both pure read-only | no fs mutation |
| TC-ENTRY-SHIM-027 | real project-local files (autonomous.conf, deploy.sh) never overwritten/pruned | preserved |

## E2E (`tests/e2e/test-entry-point-startup.sh`)

| ID | Scenario | Expected |
|---|---|---|
| TC-ENTRY-SHIM-030 | temp project: symlinked `autonomous-review.sh` entry + project conf + one lib (`lib-review-*.sh`) deliberately NOT symlinked → run startup path to first log line | wrapper sources all libs from skill tree, loads project conf, reaches config-validated startup without `No such file` crash |

## Acceptance mapping

- AC "adding a new lib upstream no longer needs installer re-runs" → TC-ENTRY-SHIM-005, TC-ENTRY-SHIM-030.
- AC "existing unit tests pass; ShellCheck passes" → full `tests/run-tests.sh` + check-shellcheck.
- AC "`--doctor` and `--dry-run` work on a fresh temp project" → TC-ENTRY-SHIM-020/023.
- AC "pipeline docs updated" → INV-65 + dispatcher-flow + INV-14 back-ref.
