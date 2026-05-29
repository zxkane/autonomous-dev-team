# Test cases: per-run `gh` wrapper dir (issue #163)

Subsystem: `skills/autonomous-dispatcher/scripts/lib-auth.sh`
(`setup_github_auth` / `cleanup_github_auth`). Runner:
`tests/unit/test-lib-auth-gh-symlink.sh`. All cases run against a sandboxed copy of
`lib-auth.sh` + `gh-with-token-refresh.sh` so production scripts are never mutated.

## Existing (must still pass — INV-32 regression guards)

| ID | Scenario | Expected |
|---|---|---|
| TC-AUTH-SYM-001 | token-mode `setup_github_auth` | `${_LIB_AUTH_DIR}/gh` symlink exists, targets `gh-with-token-refresh.sh` |
| TC-AUTH-SYM-002 | source-level lockdown | the `${_LIB_AUTH_DIR}/gh` symlink-creation line is OUTSIDE the `GH_AUTH_MODE=app` branch |

## New (issue #163)

| ID | Scenario | Expected |
|---|---|---|
| TC-AUTH-SYM-003 | `setup_github_auth` exports a per-run `GH_WRAPPER_DIR` under `/tmp/agent-auth-*` and prepends it to `PATH` (token mode) | `GH_WRAPPER_DIR` matches `/tmp/agent-auth-*`; `${GH_WRAPPER_DIR}/gh` is a symlink to `gh-with-token-refresh.sh`; first PATH entry == `GH_WRAPPER_DIR` |
| TC-AUTH-SYM-004 | two simulated concurrent `setup_github_auth` calls | the two runs' `GH_WRAPPER_DIR` paths are **distinct** (no shared per-run `gh` path) |
| TC-AUTH-SYM-005 | after `cleanup_github_auth`, the per-run wrapper dir is gone | `${GH_WRAPPER_DIR}` no longer exists; `${GH_WRAPPER_DIR}/gh` no longer exists |
| TC-AUTH-SYM-006 | `cleanup_github_auth` does NOT touch `${_LIB_AUTH_DIR}/gh` | a sentinel `${_LIB_AUTH_DIR}/gh` symlink present before cleanup is **still present** after cleanup |
| TC-AUTH-SYM-007 | source-level lockdown: no `rm -f` of `${_LIB_AUTH_DIR}/gh` anywhere in `lib-auth.sh` | `grep` for `rm -f .*_LIB_AUTH_DIR.*/gh` finds zero matches |
| TC-AUTH-SYM-008 | `setup_github_auth` still creates the agent-facing `${_LIB_AUTH_DIR}/gh` (INV-32) and does so idempotently across two calls | symlink exists and targets the wrapper after one and after two calls (no error on the second) |

## Notes

- TC-AUTH-SYM-001/002 (INV-32) and TC-AUTH-SYM-008 together pin BOTH consumers: the
  agent's `bash scripts/gh` (project `scripts/gh`) and the wrapper's PATH-resolved
  per-run `gh`.
- TC-AUTH-SYM-005/006/007 are the concurrency-safety core: a per-run cleanup removes
  only its own `/tmp` dir and never the shared `${_LIB_AUTH_DIR}/gh`.
- The tests use `GH_AUTH_MODE=token` to avoid spawning the real token-refresh daemon /
  GitHub App calls. The `GH_WRAPPER_DIR`/PATH/`${_LIB_AUTH_DIR}/gh` logic is
  mode-independent (it runs after the mode branch), so token-mode coverage exercises
  the same code app mode hits. App mode additionally reuses the daemon's `token_dir`
  as `GH_WRAPPER_DIR`, asserted indirectly by TC-AUTH-SYM-003's `/tmp/agent-auth-*`
  shape (the same `mktemp` template both modes use).
