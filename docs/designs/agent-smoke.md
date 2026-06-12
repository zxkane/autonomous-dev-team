# Design: agent-smoke E2E — three-state `smoke_agent` lib + PR-gating matrix harness

Issue: #222

## Problem

This repo's PRs routinely change `lib-agent.sh` and the per-CLI invocation
branches, but nothing executes the real CLIs end-to-end before merge. Unit
tests stub the CLIs, so the launch → auth → model chain is never exercised.
Past incidents an agent smoke would have caught at PR time:

- **#180 root cause** — codex fan-out members dropped `unavailable` on every
  review due to a `BEDROCK_AWS_REGION` env pollution.
- **#205** — agy silent exit-0 with no model call (quota wall).
- **#215** — kiro auth/login token expiry.

"Can it run" is the bar: CLI starts → auth works → model truly responds.

## Three-state contract (the core design decision)

`smoke_agent <agent-cmd> <model> [timeout-seconds]` returns one of three rcs:

| rc | State | Meaning | Gate effect |
|---|---|---|---|
| 0 | **PASS** | stdout contains the nonce — the model truly responded | non-blocking, the win |
| 2 | **UNAVAILABLE** | quota exhausted / backend capacity / transient backend failure | recorded, **non-blocking** (environmental, self-healing) |
| 1 | **FAIL** | everything else: CLI fails to launch, auth/config error, region drift, timeout with no response | **blocking** — this is what the gate exists to catch |

**The split is the whole point**: `FAIL = operator-side config/launch breakage
(gate-worthy)`, `UNAVAILABLE = environmental quota/capacity (ignorable)`.
Promoting a quota wall to a deciding FAIL would block every PR whenever an
agent's daily quota is spent — strictly worse than recording it and moving on.
This mirrors the [INV-40] review-side treatment of `unavailable`.

## Mechanism — reuse the production chain

`smoke_agent` does NOT write a parallel invocation path. It:

1. Generates a random nonce (`SMOKE-<16 hex>`), built without `$RANDOM` reliance
   alone — uses `openssl rand`/`/dev/urandom` with a PID+nonce-counter fallback.
2. Builds a prompt: *reply with exactly this token and nothing else; use no
   tools.*
3. Sets `AGENT_CMD=<agent-cmd>` and a short `AGENT_TIMEOUT` override, then calls
   the **existing `run_agent`** (sourced from `lib-agent.sh`). This exercises the
   exact production chain — [INV-34] stdin channel, [INV-50] agy model
   validation, launcher handling, EXTRA_ARGS parsing — with zero duplicated
   invocation code.
4. Captures stdout + the per-CLI log sidecar (agy `--log-file`).

### Classification

```
run_agent rc == 124/137 (timeout/kill) AND no nonce  → check drop-reason scrapers:
                                                          quota/capacity → UNAVAILABLE(2)
                                                          else           → FAIL(1)  (timeout = config/launch)
nonce present in stdout                              → PASS(0)
nonce absent, rc whatever                            → drop-reason scrapers:
   _classify_agy_drop_reason   → quota-exhausted*    → UNAVAILABLE(2)
                                → auth-failed         → FAIL(1)
   _classify_kiro_drop_reason  → auth-failed         → FAIL(1)
   _classify_codex_drop_reason → stream-error*       → UNAVAILABLE(2)  (upstream 5xx = transient backend)
   no signal                                         → FAIL(1)
```

Quota/capacity/transient-backend signal ⇒ rc 2; auth/config signal or **no
signal at all** ⇒ rc 1. (No signal = the model never answered and we have no
environmental excuse → treat as operator-side breakage, the conservative,
gate-worthy default.)

### Evidence line (machine-readable, INV-46-parser-friendly)

One line per run on stdout:

```
SMOKE <agent> <PASS|FAIL|UNAVAILABLE> <elapsed>s reason=<...>
```

## Harness — `tests/e2e/run-agent-smoke.sh`

- Reads a matrix config `tests/e2e/e2e.conf` (gitignored; commit
  `tests/e2e/e2e.conf.example`). Each entry:
  `name|agent_cmd|model|env-setup` where `env-setup` is `eval`'d in the entry's
  own subshell (operator-trusted config, same trust model as `AGENT_LAUNCHER`).
- An entry whose declared required env (e.g. an API key the env-setup references
  via a `require:VAR` directive) is missing → **SKIP** (not FAIL).
- Entries run **in parallel**, each `smoke_agent` in a clean subshell with
  per-entry env; overall wall-clock ≈ slowest entry.
- Aggregation: any FAIL → overall **rc 1**; UNAVAILABLE recorded but
  non-blocking; SKIP non-blocking. Final line:
  `SMOKE-SUMMARY pass=N fail=N unavailable=N skip=N`.
- **Stub-mode self-test** (`SMOKE_STUB=1`): runs the full harness against stub
  CLIs on `PATH` so CI exercises the harness end-to-end without real
  CLIs/credentials.

### Matrix entry format

```
# name | agent_cmd | model | env-setup (eval'd in the entry subshell)
claude-bedrock|claude|sonnet|export CLAUDE_CODE_USE_BEDROCK=1 AWS_REGION=us-east-1
codex-bedrock|codex|<model>|export CODEX_… ; export BEDROCK_AWS_REGION=us-east-2   # pin region (#180)
kiro-workspace|kiro|claude-sonnet-4.6|export …
agy-default|agy||true                                                              # quota wall → UNAVAILABLE
claude-minimax|claude|<model>|require:ANTHROPIC_API_KEY; source ~/.config/agent-smoke/secrets.env; export ANTHROPIC_BASE_URL=… ANTHROPIC_API_KEY; unset CLAUDE_CODE_USE_BEDROCK AWS_REGION
```

`require:VAR` is a harness directive: if `VAR` is unset/empty after the
env-setup runs, the entry is SKIP. (The custom-endpoint API key lives in a
gitignored local secrets file the operator sources from env-setup.)

## Why no wrapper-specific coupling

A follow-up issue (Phase A.5) will consume `smoke_agent` from the review
wrapper as a pre-fan-out gate. So `lib-agent-smoke.sh` stays free of
wrapper-specific assumptions — it only needs `lib-agent.sh` + the three
drop-reason libs. It sources them by `BASH_SOURCE`-relative path ([INV-14]
symlink-vendor pattern).

## Files

| File | Purpose |
|---|---|
| `skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh` | the `smoke_agent` lib (NEW) |
| `tests/e2e/run-agent-smoke.sh` | matrix harness + stub-mode self-test (NEW) |
| `tests/e2e/e2e.conf.example` | committed example matrix (NEW) |
| `tests/e2e/e2e.conf` | gitignored, machine-local |
| `tests/unit/test-lib-agent-smoke.sh` | unit tests (stub CLIs + fixtures) (NEW) |
| `docs/pipeline/agent-smoke.md` | three-state smoke contract doc (NEW) |
| `docs/pipeline/invariants.md` | new `INV-63` entry |
| `docs/autonomous-pipeline.md` | reference to the smoke contract |
| `.gitignore` | add `tests/e2e/e2e.conf` |
| `.github/workflows/ci.yml` | shellcheck the new lib + harness; run stub-mode self-test |

## Post-install / upgrade

This PR adds `lib-agent-smoke.sh`. After merge + user-scope skill update, re-run
`install-project-hooks.sh` on every onboarded project, or wrappers that later
source the new lib will crash on a missing symlink. (Per CLAUDE.local.md
Post-merge Step 2.)
