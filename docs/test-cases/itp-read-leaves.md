# Test cases: ITP read-leaf migration (#281)

Covers the READ half of the ITP contract (`provider-spec.md` §3.1/§3.3/§3.5,
[INV-87]/[INV-88]/[INV-90]). Primary suite:
[`tests/unit/test-itp-read-leaves.sh`](../../tests/unit/test-itp-read-leaves.sh).
Existing suites that exercise the migrated callers end-to-end (proving the fetch
move is behavior-preserving) are listed under "Regression anchors".

## Golden-trace argv (§7.1(a)/§7.3) — byte-identical proof

| ID | Caller | Asserts |
|---|---|---|
| TC-GT-COUNT | `count_active` | emits `issue list --repo R --state open --limit 100 --label autonomous --json labels -q '… \| length'` byte-identical; returns an INTEGER |
| TC-GT-NEW | `list_new_issues` | `--json number,labels,title` + the no-state subtraction `-q` byte-identical |
| TC-GT-PREV | `list_pending_review` | `--label autonomous,pending-review --json number,labels` + INV-25 subtraction byte-identical |
| TC-GT-PDEV | `list_pending_dev` | `--json number,labels,comments` (incl. `comments`) byte-identical |
| TC-GT-STALE | `list_stale_candidates` | active-state selector + `approved` subtraction byte-identical |
| TC-GT-HYG | `list_hygiene_residue` | the 2-axis forbidden-combo `-q` byte-identical |
| TC-GT-READTASK-* | `itp_read_task ISSUE FIELD` | emits `issue view N --repo R --json <field>` byte-identical for `title`/`body`/`state`/`title,body`/`state,labels,title` |
| TC-GT-COMMENTS-28 | (grep/lint) | exactly **0** inline `gh issue view --json comments` in lib-dispatch.sh; the 28-site count moved behind `itp_list_comments` |

## Dispatch routing (mirrors test-cli-adapters)

| ID | Asserts |
|---|---|
| TC-RT-LIST / TC-RT-COUNT / TC-RT-FORBIDDEN / TC-RT-READTASK / TC-RT-COMMENTS | each `itp_<verb>` dispatches to `itp_github_<verb>` under default `ISSUE_PROVIDER=github` (stub the github leaf, assert it ran) |

## .caps parse (§4.3 no-behavior-change anchor)

| ID | Asserts |
|---|---|
| TC-CAPS-AND | `itp_caps server_side_state_and` → `1` |
| TC-CAPS-NEG | `itp_caps server_side_state_negation` → `0` (negation client-side jq — GitHub's path) |

## Normalized comment shape (§3.3 / [INV-90])

| ID | Asserts |
|---|---|
| TC-SHAPE-FIELDS | each element has exactly `id,author,authorKind,body,createdAt` |
| TC-SHAPE-SORT | array sorted ASCENDING by `createdAt` even when the input is out of order |
| TC-SHAPE-ID-NUM | `id` is the REST **numeric** id parsed from the comment url (`issuecomment-<n>`), type number |
| TC-SHAPE-AUTHOR | `author` = `user.login` incl `[bot]` suffix verbatim |
| TC-SHAPE-KIND | `authorKind` = `self` (== BOT_LOGIN), `bot` (`…[bot]`), `human` (else) |
| TC-SHAPE-INV85 | INV-85 exact-eq `select((.author)==$dev)` over the normalized array selects the same comment as the pre-refactor `.author.login==$dev` |
| TC-SHAPE-INV05 | INV-05/INV-57 `.createdAt > cutoff` + `sort_by(.createdAt)\|last` produce identical selection pre/post |

## Capability-branch via the fake degraded provider (§7.4)

| ID | Asserts |
|---|---|
| TC-CAP-NEG0 | `ISSUE_PROVIDER=degraded` + `AUTONOMOUS_PROVIDERS_DIR=<fixture>` → `itp_caps server_side_state_negation` = `0` (the read-side caps=0 branch is reachable through the PUBLIC seam) |
| TC-CAP-AND0 | same path → `itp_caps server_side_state_and` = `0` (list-all + client-side AND branch) |

## Conformance fixture rule (INV-75)

| ID | Asserts |
|---|---|
| TC-FIXTURE-CPR | `tests/unit/test-entry-point-startup-e2e.sh` carries `cp -r providers/` (added in #280) so the verb files resolve via the skill-tree `readlink -f` |

## Function-mock shim audit (§7.3 m3)

| ID | Asserts |
|---|---|
| TC-AUDIT-NORENAME | every moved read function keeps its name (no rename) → existing FUNCTION-level mocks (`test-handle-completed-session-routing.sh` etc.) still bind; documented rename-vs-shim policy = "shim by keeping the same name". |

## Regression anchors (existing suites, must stay green)

`test-lib-dispatch.sh`, `test-count-agent-failures-sigterm.sh`,
`test-classify-recent-review-verdict.sh`, `test-dev-report-bot-unfixable.sh`,
`test-recent-error-envelope.sh`, `test-step0-hygiene.sh`,
`test-handle-completed-session-routing.sh`,
`test-dispatcher-step4-stale-verdict.sh`, `test-check-deps-resolved.sh`,
`test-list-selectors-terminal-defense.sh`, `test-provider-dispatch.sh` —
all exercise the migrated callers and prove the fetch move is behavior-preserving.
