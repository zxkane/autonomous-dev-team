# Test Cases: dispatcher-tick App token integration (#91)

## Strategy

Stub `gh-app-token.sh::get_gh_app_token` with a function that records args
and emits a sentinel token. Stub all `gh` calls (via PATH override) to
record the value of `$GH_TOKEN` they observe. Run `dispatcher-tick.sh` in
`bash -c` against a sandboxed temp dir so the real GitHub API is never hit.

The list/scan steps return empty arrays (no issues), so the tick just
exercises the auth setup + concurrency gate + empty steps and exits clean.

## Cases

| ID | Setup | Expected |
|---|---|---|
| TC-DISP-AUTH-001 | `GH_AUTH_MODE=app`, valid `DISPATCHER_APP_ID`+`DISPATCHER_APP_PEM` | `get_gh_app_token` invoked once with `(app_id, pem, owner, name)`; `GH_TOKEN` exported with the sentinel value before any `gh` call observes it |
| TC-DISP-AUTH-002 | `GH_AUTH_MODE=app`, `DISPATCHER_APP_ID` empty | tick exits 1, FATAL message mentions missing `DISPATCHER_APP_ID`; `get_gh_app_token` NOT invoked; no `gh` calls made |
| TC-DISP-AUTH-003 | `GH_AUTH_MODE=app`, `DISPATCHER_APP_PEM` empty | tick exits 1, FATAL message mentions missing `DISPATCHER_APP_PEM`; `get_gh_app_token` NOT invoked |
| TC-DISP-AUTH-004 | `GH_AUTH_MODE=app`, `get_gh_app_token` returns rc=1 | tick exits 1, FATAL message; no `gh` calls made |
| TC-DISP-AUTH-005 | `GH_AUTH_MODE=app`, `get_gh_app_token` echoes empty string | tick exits 1, FATAL message about empty token |
| TC-DISP-AUTH-006 | `GH_AUTH_MODE=token` (or unset) | `get_gh_app_token` NOT sourced/called; `GH_TOKEN` unchanged; tick proceeds normally |

## Out of scope

- Real GitHub API: the integration with the App API is exercised by the
  agent wrappers' own tests + manual run.
- Multi-project inline-vs-path-entry: covered by
  `test-multi-tick-inline-projects.sh` (env propagation).
