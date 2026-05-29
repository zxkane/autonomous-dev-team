# Design: move the wrapper's PATH `gh` to a per-run /tmp dir (issue #163)

## Problem

`setup_github_auth()` in `lib-auth.sh` creates a `gh` symlink inside
`${_LIB_AUTH_DIR}` (the project's `scripts/` directory) and `cleanup_github_auth()`
`rm -f`s it. Both `setup` and `cleanup` operate on **one shared, project-level
path** (`${PROJECT_DIR}/scripts/gh`). When two issues are dispatched in parallel on
the same cloud station, they share that one path:

- Run A's `cleanup_github_auth` runs `rm -f scripts/gh` while Run B is still mid-run.
- Run B's subsequent `gh` calls (resolved through `PATH`, which prepends
  `${_LIB_AUTH_DIR}`) then fail with `scripts/gh: No such file or directory`.

Observed downstream: a dev wrapper exited 0 (agent done, PR open) but the post-agent
label update and session-report comment failed because `scripts/gh` had vanished —
deleted by a concurrent run's cleanup.

## The constraint the issue overlooks: two consumers, two resolution mechanisms

There are **two distinct consumers** of "the `gh` symlink", and they resolve it
differently:

| Consumer | How it invokes `gh` | Resolution mechanism | Needs |
|---|---|---|---|
| **The wrapper itself** (`autonomous-dev.sh`, `autonomous-review.sh`) — bare `gh issue edit`, `gh pr comment`, … | bare `gh` | **`PATH`** lookup (`setup` prepends `${_LIB_AUTH_DIR}`) | *some* dir on `PATH` containing a `gh` → `gh-with-token-refresh.sh` |
| **The agent** — `bash scripts/gh issue comment …` | literal **relative path** `scripts/gh` | filesystem path relative to `cwd` (`autonomous-dev.sh` does `cd "$PROJECT_DIR"`, so this is `${PROJECT_DIR}/scripts/gh`) | the physical file `${PROJECT_DIR}/scripts/gh` to exist |

The agent path is mandated by **[INV-32]** and the doc-lint guard
`tests/unit/test-dev-skill-bash-scripts-gh.sh`, and is referenced from
`skills/autonomous-dev/SKILL.md` Step 12 and
`skills/autonomous-dev/references/autonomous-mode.md`. **Removing
`${PROJECT_DIR}/scripts/gh` entirely (as the issue's literal fix proposes) would
break every agent status/summary comment and violate INV-32.** Per
`CLAUDE.md` → "When code and docs disagree, the docs are authoritative", INV-32 wins;
the issue's *acceptance criterion* "`scripts/gh` is never created" cannot be honored
literally without regressing the agent path.

## Decision: split the two consumers onto two paths

Solve the *real* bug (per-run cleanup deleting a shared artifact) by giving the two
consumers separate artifacts:

1. **Wrapper's PATH `gh` → a per-run `/tmp` dir.** Reuse the existing
   `mktemp -d /tmp/agent-auth-XXXXXX` (already created + `chmod 700` in app mode;
   create it for token mode too). Export `GH_WRAPPER_DIR="$token_dir"`, prepend it to
   `PATH`, and `ln -sf gh-with-token-refresh.sh "${GH_WRAPPER_DIR}/gh"`. Each run gets
   its **own** `gh` on `PATH`, so a concurrent run's cleanup can never delete the `gh`
   this run resolves. This is the part of the issue's proposal that is correct and
   valuable.

2. **Agent's `${PROJECT_DIR}/scripts/gh` → kept, created idempotently, never deleted.**
   It is a *stable, shared, project-level* artifact pointing at the always-present
   `gh-with-token-refresh.sh`. `ln -sf` to a fixed target is idempotent and safe under
   concurrent creation. Crucially, **`cleanup_github_auth` no longer removes it** — a
   per-run cleanup must not touch a shared artifact. This is what actually fixes the
   reported failure: nothing a concurrent run does can make `scripts/gh` disappear
   mid-run.

### Why this is safe

- `gh-with-token-refresh.sh` reads the freshest token from `GH_TOKEN_FILE`
  (per-process env) at exec time; the symlink target is constant. Two runs pointing
  `scripts/gh` at the same target is harmless — each process carries its own
  `GH_TOKEN_FILE` and `REAL_GH` in env.
- The `/tmp` wrapper dir is removed together with the token file in cleanup, so no
  `/tmp` litter accumulates.
- `${PROJECT_DIR}/scripts/gh` is in `.gitignore` already (the `scripts/gh` and
  `skills/autonomous-dispatcher/scripts/gh` entries), so leaving it on disk between
  runs commits nothing.

### Rejected alternative: remove `scripts/gh` entirely (issue's literal fix)

Rejected because it breaks the agent's `bash scripts/gh` path and violates INV-32 /
the doc-lint test. The agent runs from `$PROJECT_DIR` and uses a relative path, not
`PATH` lookup, so the per-run `/tmp` dir is invisible to `bash scripts/gh`.

## Changes

- `lib-auth.sh::setup_github_auth`
  - Create `token_dir` (mktemp + chmod 700) in **both** modes; today token mode skips
    it.
  - `GH_WRAPPER_DIR="$token_dir"`; `export PATH="${GH_WRAPPER_DIR}:${PATH}"`;
    `ln -sf …/gh-with-token-refresh.sh "${GH_WRAPPER_DIR}/gh"` (per-run wrapper for the
    wrapper's own bare `gh`).
  - Keep the idempotent `ln -sf …/gh-with-token-refresh.sh "${_LIB_AUTH_DIR}/gh"` for
    the agent (INV-32). No longer prepend `_LIB_AUTH_DIR` to PATH (the per-run dir
    serves PATH; the project symlink serves the relative-path agent rule).
- `lib-auth.sh::cleanup_github_auth`
  - Remove `rm -f "${_LIB_AUTH_DIR}/gh"` — the shared artifact is never deleted by a
    per-run cleanup. The per-run `/tmp` wrapper dir is removed with the token file (the
    `gh` symlink inside it is unlinked by `rm -rf`/`rmdir` of the dir contents).

## Test plan

See `docs/test-cases/gh-wrapper-symlink-per-run.md`.

## Cross-references

- [INV-32] `docs/pipeline/invariants.md` — updated in this PR to document the
  dual-path design and the concurrency-safety contract.
- `tests/unit/test-lib-auth-gh-symlink.sh` — extended with per-run isolation +
  cleanup-non-destruction cases.
