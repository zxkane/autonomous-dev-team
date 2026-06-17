# Test Cases: Two-token split + agent env scrubbing (issue #234)

ID format: `TC-TOKEN-SPLIT-NNN`. INV-77.

## Unit — scoped-token mint / refresh (`get_gh_app_scoped_token`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-TOKEN-SPLIT-001 | `get_gh_app_scoped_token` POSTs a `permissions` object scoping `contents:write, issues:write, pull_requests:read` AND a `repositories` array of the single repo | request body contains the exact permissions JSON + the repo name (asserted against a stubbed curl) |
| TC-TOKEN-SPLIT-002 | `gh-token-refresh-daemon.sh` accepts an optional `--permissions <json>` arg and forwards it to the scoped mint | daemon writes a token to the scoped file; mint stub receives the permissions JSON |
| TC-TOKEN-SPLIT-003 | scoped mint failure (stub curl 422) | helper returns non-zero with a clear error; daemon's initial-write fails loudly |

## Unit — `setup_agent_token` (app mode)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-TOKEN-SPLIT-010 | app mode: `setup_agent_token` mints scoped token to `AGENT_GH_TOKEN_FILE` and starts a second daemon | `AGENT_GH_TOKEN_FILE` set, non-empty, mode 600; a daemon PID is tracked |
| TC-TOKEN-SPLIT-011 | scoped token file lives in the per-run private dir (not a predictable /tmp path) | path is under `GH_WRAPPER_DIR` (mode 700) |
| TC-TOKEN-SPLIT-012 | `cleanup_github_auth` kills the scoped daemon and clears `AGENT_GH_TOKEN_FILE` | after cleanup both the full + scoped daemon are reaped; vars cleared (idempotent re-setup) |

## Unit — PAT mode degradation

| ID | Scenario | Expected |
|----|----------|----------|
| TC-TOKEN-SPLIT-020 | PAT mode: `setup_agent_token` is a no-op | `AGENT_GH_TOKEN_FILE` stays empty; no daemon spawned |
| TC-TOKEN-SPLIT-021 | PAT mode: WARN logged exactly ONCE across repeated `setup_agent_token` calls | log contains `enforcement degraded to convention in PAT mode` once |
| TC-TOKEN-SPLIT-022 | PAT mode: `build_agent_env_argv` emits an EMPTY prefix (no scrub) | array length 0 → agent inherits unchanged env (byte-identical behavior) |

## Unit — env scrub assembly (`build_agent_env_argv`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-TOKEN-SPLIT-030 | scoped token armed → prefix sets `GH_TOKEN=<scoped>` (snapshot fallback) | `GH_TOKEN=` element present with the scoped token value |
| TC-TOKEN-SPLIT-031 | prefix points `GH_TOKEN_FILE` at the SCOPED file (refresh-aware, not unset) + unsets `GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_USER_PAT` | `GH_TOKEN_FILE=<AGENT_GH_TOKEN_FILE>` present, no `-u GH_TOKEN_FILE`; `-u GITHUB_PERSONAL_ACCESS_TOKEN -u GH_USER_PAT` present |
| TC-TOKEN-SPLIT-032 | prefix does NOT rewrite PATH (keep the shim resolvable) | no `PATH=` element; `_strip_path_entry` removed |
| TC-TOKEN-SPLIT-033 | no scoped token (PAT / app-no-scope) → empty prefix | length 0 |
| TC-TOKEN-SPLIT-092 | bare `gh` under the scrub (REAL_GH host) → real `gh` with the scoped token, reading the scoped file | dump shows scoped token + scoped `GH_TOKEN_FILE`, not the wrapper's full-write file |
| TC-TOKEN-SPLIT-093 | agent `gh` is refresh-aware — a scoped-file refresh between calls is picked up | call 1 sees initial token, call 2 sees the refreshed token |

## Unit — scrub completeness (env-dump assertion, the verify-by-construction gate)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-TOKEN-SPLIT-040 | `_run_with_timeout` runs a stub "agent" that dumps `env`; scoped token armed | dump shows `GH_TOKEN`=scoped, NO `GH_TOKEN_FILE`, NO `GITHUB_PERSONAL_ACCESS_TOKEN`, NO `GH_USER_PAT`, PATH head ≠ `GH_WRAPPER_DIR` |
| TC-TOKEN-SPLIT-041 | same stub, NO scoped token | dump is byte-identical to the unscrubbed env (regression pin: PAT/no-scope unaffected) |

## Unit — wrapper own-calls unaffected (regression pins)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-TOKEN-SPLIT-050 | the wrapper's OWN `gh` (bare, on PATH via `GH_WRAPPER_DIR`) still resolves the full-write token after scrub helpers run | `GH_TOKEN_FILE` (wrapper-side) still set in the WRAPPER shell; scrub touches only the agent subtree prefix, never the wrapper's exported env |
| TC-TOKEN-SPLIT-051 | dev push/PR-create path: `contents:write` suffices to push a branch | scoped permissions include `contents:write` |

## Unit — self-merge regression gate (the headline AC)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-TOKEN-SPLIT-060 | scoped permissions JSON has `pull_requests:read` (NOT write) | a token minted with this scope is rejected (403) by `gh pr review --approve` / `gh pr merge` — asserted at the scope level (the permissions object the helper sends) |
| TC-TOKEN-SPLIT-061 | the wrapper's INV-44/52 approve/merge path uses the WRAPPER token (full-write), not the scoped one | wrapper's approve/merge calls run in the wrapper shell (full-write env), never under the scrub prefix |

## Unit — E2E report broker

| ID | Scenario | Expected |
|----|----------|----------|
| TC-TOKEN-SPLIT-070 | `build_browser_e2e_prompt` instructs the agent to write the report to `$E2E_REPORT_FILE` (broker) | prompt mentions the broker file + that the wrapper posts it |
| TC-TOKEN-SPLIT-071 | `_post_brokered_e2e_report`: file present + non-empty → wrapper posts it on the PR | a `gh pr comment` is issued with the file body; SHA marker stamped after |
| TC-TOKEN-SPLIT-072 | broker file missing/empty → wrapper does not post (agent's direct issues:write fallback already posted) | no spurious empty comment; helper returns gracefully |

## Verify-by-construction env-dump gate (the conformance proof)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-TOKEN-SPLIT-080 | a stub agent (`env`) is run through the REAL `_run_with_timeout` with a scoped token armed; its dumped env is asserted | scoped `GH_TOKEN` present; NO full-write credential (`GH_TOKEN_FILE` / `GITHUB_PERSONAL_ACCESS_TOKEN` / `GH_USER_PAT`); the `GH_WRAPPER_DIR` shim dir is absent from the agent PATH. **Realized by TC-TOKEN-SPLIT-040/041** in `tests/unit/test-token-split-234.sh` — `_run_with_timeout` IS the production launch seam every adapter routes through, so dumping `env` through it (with a stub `env` "agent") proves the scrub by construction. The existing hermetic conformance suite (`tests/conformance/`) pins the per-CLI *output-classification* contract (drop-reason / verdict-state) and intentionally is NOT extended for env (env is not an AdapterResult axis); the env proof lives in the unit suite where the launch seam is exercised directly. |

## E2E (stub-fleet — documented in PR; not a new CI lane)

- Stub-fleet run asserting dev agent pushes + comments OK; simulated approve/merge
  from the agent token is rejected; wrapper merge path unaffected. (Covered by the
  unit env-dump + scope assertions above; a full stub-fleet soak is noted in the
  PR body for the self-hosting dogfood rollout.)
- One real-fleet soak note in the PR body: enable on THIS repo first.

## Acceptance criteria mapping

- AC "env dump shows no full-write credential, no wrapper gh shim" → TC-040, TC-080.
- AC "dev full cycle green under scoped token" → TC-051 (+ PR-create broker), TC-040.
- AC "agent approve/merge fails 403" → TC-060.
- AC "PAT byte-identical + WARN; ShellCheck + suites green; docs same PR" →
  TC-020/021/022/041/050.
</content>
