# Test cases — REST existence probe for `itp_github_provision_states` (#362)

All cases live in `tests/unit/test-itp-write-leaves.sh` (the existing
golden-trace suite for the ITP write leaves) unless noted.

## Golden-trace (re-pinned)

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-GT-PROVISION-SKIP` | REST probe rc=0 (label exists) | argv is `api repos/<repo>/labels/<name> --silent`; returns 0; prints `[skip] '<name>' already exists`; NO `gh label create` call |
| `TC-GT-PROVISION-CREATE` | REST probe rc=1 (label missing) | `gh label create <name> --repo <repo> --color <hex> --description <desc>` argv unchanged (byte-identical to pre-fix); prints `[created] '<name>'`; returns 0 |

## Hermetic `gh` double (no `label view` subcommand)

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-PROVISION-NO-LABEL-VIEW` | The test double implements only `clone/create/delete/edit/list` + `api` for `gh label` (matching real `gh`); any `label view` invocation is rejected loudly (mirrors real gh's "unknown command") | proves the regression test fails against the pre-fix implementation (which called `gh label view`) and passes after the fix |

## Full-loop / AC3 (all 9 pre-existing)

| ID | Scenario | Expected |
|----|----------|----------|
| `TC-PROVISION-ALL-SKIP` | Drive the real `setup-labels.sh` loop with a double where the REST probe returns rc=0 for all 9 label names | exit 0; nine `[skip]` lines printed; zero `gh label create` calls |

## Regression suites (must stay green)

| ID | Scenario | Expected |
|----|----------|----------|
| existing suite | Full `tests/unit/` | green |
| `check-spec-drift.sh` | doc/spec consistency gate | green |
| `check-provider-cutover.sh --require-trusted-ref` | INV-91 cutover baseline | green, no baseline churn (providers/ is guard-exempt) |
