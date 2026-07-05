# Test Cases — W-A GitLab Transport (issue #416, phase-3 #414)

Contract-freeze proof for `skills/autonomous-dispatcher/scripts/providers/lib-gitlab-transport.sh` — the two-layer GitLab transport (`_gl_http` request primitive + `_gl_api` public function) that every W-B / W-C GitLab leaf will build against. Also proves the auth-lifecycle gating (R2) — `setup_github_auth` / `setup_agent_token` / `dispatcher-tick.sh`'s app-mode credential FATAL run only under an active github seam.

**Suite**: `tests/unit/test-lib-gitlab-transport.sh` and `tests/unit/test-auth-lifecycle-gating.sh`.
**Discipline**: hermetic; stub `curl` on `PATH`; no network. bash 4 target. Run under `env -u PROJECT_DIR bash …` for CI parity.
**INV-113 machine-check target**: `test-lib-gitlab-transport.sh`.

## Conventions

- IDs `TC-GLT-NNN` for transport-layer tests; `TC-AUTH-NNN` for auth-lifecycle gating tests.
- Every transport test stubs `curl` with a shell script on the isolated PATH that:
  1. Records its argv (one per line) to a caller-provided file for post-assertion inspection.
  2. Emits pre-canned status+headers to the `<headers_out_file>` and a body to stdout.
  3. Optionally increments an invocation counter (for pagination / retry sequences).
- Auth-lifecycle tests source `lib-auth.sh` under the three topologies via `env -u`+explicit vars and snapshot module-level state (`TOKEN_DAEMON_PID`, `AGENT_TOKEN_DAEMON_PID`, `GH_WRAPPER_DIR`, `PATH`, `${_LIB_AUTH_DIR}/gh` shape).

## Test Cases

### Preflight fail-loud (R1 §preflight)

| ID | Scenario | Expected |
|---|---|---|
| TC-GLT-001 | `GITLAB_TOKEN` unset, no `GITLAB_TRANSPORT_HOOK` armed → `_gl_api ...` invoked | rc ≠ 0; recovery-guidance message to stderr naming `GITLAB_TOKEN`; no curl invocation |
| TC-GLT-002 | `GITLAB_TRANSPORT_HOOK=/no/such/file` → `_gl_api` invoked | rc ≠ 0; message naming the unreadable path; no curl invocation |
| TC-GLT-003 | Hook file present but does NOT redefine `_gl_http` (defines an unrelated function only) → `_gl_api` invoked | rc ≠ 0; message stating `_gl_http` must exist and be callable |
| TC-GLT-004 | Valid `GITLAB_TOKEN` + no hook → preflight passes; a second `_gl_api` call in the same shell does NOT re-run preflight (latched) | 2 curl invocations total, preflight log emitted once |
| TC-GLT-005 | Hook that redefines `_gl_http` cleanly + `GITLAB_TOKEN` set → preflight passes and hook's `_gl_http` is the one called | curl NEVER invoked (hook takes over); rc 0 |

### `_gl_http` shape (R1 §_gl_http)

| ID | Scenario | Expected |
|---|---|---|
| TC-GLT-010 | GET `/projects/:id/issues/42` → 200 with body `{"iid":42}` | rc 0; stdout = body verbatim; `<headers_out_file>` records `HTTP/1.1 200` + any headers (curl style) |
| TC-GLT-011 | GET returning 404 with an error body | rc 0 (transport succeeded); stdout = body; headers file records `HTTP/1.1 404`. Status classification is `_gl_api`'s job. |
| TC-GLT-012 | GET returning 500 | rc 0; stdout = body; headers file records `HTTP/1.1 500` |
| TC-GLT-013 | `_gl_http` receives an absolute URL beginning with `http` → curl is called with the URL verbatim (not `${GITLAB_HOST}/api/v4/<path>`) | curl argv contains the exact absolute URL; body on stdout |
| TC-GLT-014 | PRIVATE-TOKEN header — curl argv includes `-H PRIVATE-TOKEN: <token>` with the value from `GITLAB_TOKEN` | header present in recorded argv |
| TC-GLT-015 | POST with body-json → curl argv includes `-X POST` and `--data-binary <body-json>` (or equivalent); header includes `Content-Type: application/json` | correct argv + header |
| TC-GLT-016 | curl exits non-zero (transport failure — DNS, connection refused) | `_gl_http` rc ≠ 0; message names transport error |
| TC-GLT-017 | Paginated response with `x-next-page: 2` / `x-total-pages: 5` — headers file preserves these header lines verbatim | headers file `grep -qi 'x-next-page: 2'` succeeds |
| TC-GLT-018 | `Retry-After: 3` on a 429 response — headers file preserves the header | headers file grep succeeds |

### `_gl_api` pagination walk (R1 §_gl_api)

| ID | Scenario | Expected |
|---|---|---|
| TC-GLT-020 | Single-page `--paginate` (no `x-next-page`) — body is `[{"a":1}]` | rc 0; stdout = `[{"a":1}]` |
| TC-GLT-021 | 3-page walk (page 1 → `x-next-page:2`, page 2 → `x-next-page:3`, page 3 → no `x-next-page`) — each body is `[{"n":N}]` | rc 0; stdout = merged `[{"n":1},{"n":2},{"n":3}]` (jq -s add); 3 curl invocations |
| TC-GLT-022 | Next-page reconstruction — the 2nd curl call is issued against the ORIGINAL path with `page=2` set/replaced as a query-param (not the raw header value); the 3rd against `page=3` | argv of invocation #2 contains `page=2`; #3 contains `page=3` (idempotent replace) |
| TC-GLT-023 | Mid-walk failure — page 1 OK, page 2 returns 500 → `_gl_api` rc ≠ 0 AND stdout empty (fail-CLOSED per §3.5) | rc ≠ 0; stdout `""` |
| TC-GLT-024 | Cap-hit — `GL_TRANSPORT_PAGE_CAP=2` but response advertises `x-next-page:3` after page 2 | rc ≠ 0; stdout empty |
| TC-GLT-025 | `--max-items 2` bounded-read — response has 3 pages of 5 items each, but `--max-items 2` stops after ≥ 2 items merged | rc 0; stdout array length == 2; at most 1 curl invocation past the point of 2 items being available |
| TC-GLT-026 | `--paginate` on a non-array body (single object) | rc 0; stdout = the object verbatim (no forced array coercion; `--paginate` on single-page bodies degrades to `_gl_http`) |

### `_gl_api` 429 / Retry-After backoff

| ID | Scenario | Expected |
|---|---|---|
| TC-GLT-030 | 429 with `Retry-After: 1` → retry → 429 with `Retry-After: 1` → retry → 200 with body | rc 0; body on stdout; 3 curl invocations; 2 `sleep` calls with duration=1 recorded via stub sleep |
| TC-GLT-031 | 429 exhausted (3 retries all 429) → rc ≠ 0, stdout empty | rc ≠ 0; 4 curl invocations (initial + 3 retries) or 3 depending on retry semantics; stdout empty |
| TC-GLT-032 | 429 `Retry-After: 90` capped at 60s per sleep | recorded sleep duration ≤ 60 |
| TC-GLT-033 | Non-429 5xx (e.g. 503) does NOT trigger the backoff retry loop (fail-loud immediately) | rc ≠ 0; 1 curl invocation (no retry) |

### `_gl_api` HTTP-status channel + `--tolerate-status`

| ID | Scenario | Expected |
|---|---|---|
| TC-GLT-040 | `_gl_api /path > $tmpfile` (redirect, NOT command sub) → `GL_API_STATUS` is set in the calling shell to the final HTTP status | `GL_API_STATUS == 200` |
| TC-GLT-041 | `_gl_api --status-out $sfile /path > $tmpfile` — `sfile` contains the final HTTP status regardless of subshell placement | `cat $sfile == 200` |
| TC-GLT-042 | `_gl_api --tolerate-status 404 /path` on a 404 response | rc 0; stdout = body; `GL_API_STATUS == 404` |
| TC-GLT-043 | `_gl_api --tolerate-status 404,409 /path` on a 409 response | rc 0; stdout = body; `GL_API_STATUS == 409` |
| TC-GLT-044 | `_gl_api --tolerate-status 404 /path` on a 500 response | rc ≠ 0; `GL_API_STATUS == 500` |
| TC-GLT-045 | `_gl_api --tolerate-status 404 /path` when curl transport FAILs (rc≠0 from `_gl_http`) | rc ≠ 0 (transport failure is NOT toleratable) |

### `_gl_urlencode`

| ID | Scenario | Expected |
|---|---|---|
| TC-GLT-050 | `_gl_urlencode 'group/subgroup/project'` → `group%2Fsubgroup%2Fproject` | stdout = expected |
| TC-GLT-051 | `_gl_urlencode 'feature/foo bar'` → `feature%2Ffoo%20bar` | stdout = expected |
| TC-GLT-052 | `_gl_urlencode 'label with & ampersand'` → correctly percent-encoded (`%26`) | stdout = expected |

### Override hook

| ID | Scenario | Expected |
|---|---|---|
| TC-GLT-060 | Hook that redefines `_gl_http` to synthesize a canned response — `_gl_api` invoked → routes to hook, curl NEVER called | rc 0; stub curl argv file empty |
| TC-GLT-061 | Hook can define private helper functions (trust model: operator-owned code) — a helper alongside `_gl_http` is not rejected | rc 0 |
| TC-GLT-062 | Hook attempts to redefine `_gl_api` — has no effect (lib re-defines `_gl_api` after sourcing the hook, or the preflight explicitly rejects) | either: hook's `_gl_api` shadowed; or preflight rc ≠ 0 (implementation may choose; both are compliant) |
| TC-GLT-063 | End-to-end: hook + pagination — hook serves canned multi-page responses, `_gl_api --paginate` still merges into one array (pagination lives in `_gl_api`) | rc 0; stdout merged array |

## Auth-lifecycle gating (R2)

**Suite**: `tests/unit/test-auth-lifecycle-gating.sh`.

| ID | Scenario | Expected |
|---|---|---|
| TC-AUTH-001 | `ISSUE_PROVIDER=github CODE_HOST=github` (default via `${ISSUE_PROVIDER:-github}`) — `setup_github_auth` invoked in PAT mode | `GH_WRAPPER_DIR` created; `${_LIB_AUTH_DIR}/gh` symlink installed; behavior byte-identical to pre-change main |
| TC-AUTH-002 | `ISSUE_PROVIDER=gitlab CODE_HOST=gitlab` — `setup_github_auth` invoked | rc 0 (no-op); `TOKEN_DAEMON_PID` stays empty; no `${_LIB_AUTH_DIR}/gh` symlink created this run; no `GH_WRAPPER_DIR` created |
| TC-AUTH-003 | `ISSUE_PROVIDER=github CODE_HOST=gitlab` (mixed) — `setup_github_auth` invoked | gh lifecycle STILL runs (github ITP needs it) — `${_LIB_AUTH_DIR}/gh` symlink present |
| TC-AUTH-004 | `ISSUE_PROVIDER=gitlab CODE_HOST=github` (mixed) — `setup_github_auth` invoked | gh lifecycle STILL runs (github CHP needs it) |
| TC-AUTH-005 | `ISSUE_PROVIDER=gitlab CODE_HOST=gitlab` in PAT mode — `setup_agent_token` invoked | rc 0; no PAT WARN emitted (gated out); `_AGENT_TOKEN_PAT_WARNED` stays empty |
| TC-AUTH-006 | `ISSUE_PROVIDER=github CODE_HOST=github` in PAT mode — `setup_agent_token` invoked | PAT WARN emitted ONCE per process (existing behavior); a second call is silent |
| TC-AUTH-007 | `ISSUE_PROVIDER=gitlab CODE_HOST=gitlab` + `GITLAB_TOKEN` set + PAT-mode → one-time GitLab PAT WARN emitted | WARN mentions `GITLAB_TOKEN` + INV-79 posture; latched once |
| TC-AUTH-008 | `dispatcher-tick.sh` app-mode credential FATAL — `GH_AUTH_MODE=app`, `DISPATCHER_APP_ID`/`PEM` empty, `ISSUE_PROVIDER=gitlab CODE_HOST=gitlab` | NO FATAL, tick continues (gated) |
| TC-AUTH-009 | Same but `ISSUE_PROVIDER=github CODE_HOST=gitlab` (mixed, github ITP) | FATAL fires (github seam is active) |
| TC-AUTH-010 | Same but default `ISSUE_PROVIDER`/`CODE_HOST` unset → defaults to github/github | FATAL fires (byte-identical to pre-change) |

## Machine-check pin

`test-lib-gitlab-transport.sh` is the INV-113 machine-check target. `docs/pipeline/invariants.md`'s INV-113 entry names this test path in its `_Triage_` line.
