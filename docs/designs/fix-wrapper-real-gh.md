# Fix: gh-with-token-refresh fails when real `gh` is outside the minimal POSIX PATH

**Date:** 2026-05-10
**Issue:** #92
**Status:** Approved

## Problem

`gh-with-token-refresh.sh` strips its own dir from PATH and runs
`command -v gh` to find the real binary (avoiding self-recursion). When
the wrapper is spawned from a non-interactive shell (cron, systemd, SSM
`AWS-RunShellScript`, GitHub Actions, `nohup`, Claude Code skill spawn)
**and** `gh` lives outside the minimal POSIX PATH (Homebrew, nvm, asdf,
`~/bin`, `/snap/bin`, container `/opt/gh/bin`, etc.), the lookup fails:

```
ERROR: Cannot find real gh binary (looked in PATH minus <dir>)
```

The dispatcher misdiagnoses this: the wrapper exits before
`AGENT_RAN=true` is set, so `cleanup()` skips the issue-comment +
label-update path. The 1-second `dispatch-local.sh` alive check may pass
(the wrapper ran briefly during startup), so the dispatcher's stale
detection eventually counts it as a **dispatcher-detected crash**, not
an **agent failure** — after MAX_RETRIES the issue is `stalled`, with
the real cause buried in `/tmp/agent-*.log`.

## Fix

Two parts:

### Part 1 — `REAL_GH` env override in `gh-with-token-refresh.sh`

Honor an explicit `REAL_GH` override at the very top of the wrapper,
before the PATH-stripping logic. `autonomous.conf` is already sourced by
`dispatch-local.sh` and `autonomous-dev.sh`, so a single conf line is
enough:

```bash
REAL_GH="/home/ubuntu/.linuxbrew/homebrew/bin/gh"
```

Why an env override and not auto-detection: the operator knows where
`gh` lives on their host. Auto-detecting Homebrew/nvm/asdf/etc.
patches a subset and grows as new install patterns emerge. `REAL_GH`
covers infinite axis-A instances with one variable. Considered and
rejected per the issue.

If `REAL_GH` is set but not executable, fall through to the existing
PATH search (don't silently misroute). On `command -v gh` failure, add
a clear hint to the existing error message: "Set REAL_GH in
autonomous.conf to override."

### Part 2 — startup-failure session report in `autonomous-dev.sh`

Currently `cleanup()` skips the comment + label-update when
`AGENT_RAN=false`. This was deliberate (don't post for early aborts
like missing args), but it conflates "wrapper crashed before reaching
the agent" with "wrapper not yet ready to log to the issue."

Fix: when `cleanup()` runs with `AGENT_RAN=false` AND we have enough
context to post (`ISSUE_NUMBER` is set AND auth is functional), still
emit an `Agent Session Report (Dev)` comment with `Exit code: 1` and
`Mode: startup-failure`. This makes the dispatcher's
`count_agent_failures` regex match it (`Agent Session Report (Dev)` +
not `Exit code: 0`), so retry counting works correctly. Also flip
labels from `in-progress` to `pending-dev` so a later retry is
attempted instead of leaving the label stuck.

Failure-mode safety:

- If `ISSUE_NUMBER` is unset (early exit during arg parsing), keep
  current silent behavior — there's nowhere to post.
- If posting the comment fails (auth broken at the same time as the
  failure), log the WARNING and continue — same pattern as the
  existing post-attempts.
- We don't try to post during pre-auth failures (the auth daemon hasn't
  started yet); cleanup's `command -v get_gh_app_token` check already
  handles that.

### Files changed

- `skills/autonomous-dispatcher/scripts/gh-with-token-refresh.sh` —
  REAL_GH override + improved error message.
- `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` — cleanup
  emits failure session report when AGENT_RAN=false but ISSUE_NUMBER
  is set; transitions labels.
- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` —
  document `REAL_GH` with a commented-out example.
- `tests/unit/test-gh-with-token-refresh-real-gh.sh` — new.
- `tests/unit/test-autonomous-dev-cleanup-startup-failure.sh` — new.

### Files deliberately not changed

- `autonomous-review.sh` — the review wrapper has the same general
  shape but uses a slightly different entry sequence. Issue #92 names
  the dev wrapper specifically; symmetric fix for review can be a
  follow-up if/when the same failure mode is observed there. Keeping
  the diff focused.

## Acceptance

- `REAL_GH` honored when set + executable; precedes PATH search.
- `REAL_GH` set but not executable → fall through to PATH (don't fail
  silently with the wrong binary).
- PATH-search failure → existing error message + new "Set REAL_GH"
  hint.
- The `env -i HOME=$HOME PATH=/usr/bin:/bin ...` repro from the issue
  succeeds when `REAL_GH=/path/to/gh` is set.
- `autonomous-dev.sh` cleanup posts an `Agent Session Report (Dev)
  ... Exit code: 1` comment when the wrapper fails after
  `ISSUE_NUMBER` is parsed but before the agent runs.
- Unit tests cover both above paths.
