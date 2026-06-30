# Test Cases — `mark-issue-checkbox.sh` body-read behind `itp_read_task` (#296 B-mark-checkbox)

Migrate the single issue-body READ in `mark-issue-checkbox.sh` (the body fetched
to perform the `- [ ]`→`- [x]` rewrite) behind the already-shipped `itp_read_task`
provider verb (#281). This is the body READ that #303 (B1) **explicitly retained**
when it deleted the hardcoded-GitHub PATCH-write fallback.

## Shape-equivalent, NOT byte-identical

The OLD call is the raw REST endpoint
`gh api "repos/$REPO/issues/$N" --jq '.body'`; the NEW call is
`itp_read_task "$ISSUE_NUMBER" body -q '.body'`, whose GitHub leaf
(`itp_github_read_task`) emits
`gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json body -q '.body'` — a
DIFFERENT `gh` subcommand + endpoint (`gh issue view --json` vs `gh api … REST`)
and `-q` (vs `--jq`). **The returned issue-body string is identical**, so the test
is a **behavior-equivalence** test (same body returned, same error handling), NOT
a byte-identical golden-trace. This is the exact shape of B2 (#306) and #281's
read-leaf migrations.

| | OLD (pre-migration) | NEW (this PR) |
|---|---|---|
| call site | `mark-issue-checkbox.sh:78` | `mark-issue-checkbox.sh:78` |
| primitive | `gh api "repos/$REPO/issues/$N" --jq '.body'` | `itp_read_task "$ISSUE_NUMBER" body -q '.body'` |
| github leaf argv | `api repos/$REPO/issues/$N --jq .body` | `issue view $N --repo $REPO --json body -q .body` |
| returned value | the issue body string | the SAME issue body string |
| error handler | `|| { echo "Error: Failed to fetch …"; return 1; }` | unchanged, verbatim |

## 1. Behavior-equivalence (run the REAL script as a subprocess) — AC2

Run the REAL `mark-issue-checkbox.sh` as a subprocess with a binary `gh` stub on
`PATH` (NOT by calling `itp_read_task` directly), so the test exercises
seam-sourcing + the `|| { … }` handler + the retry path end-to-end.

| ID | Setup | Assertion |
|---|---|---|
| TC-MCB-EQUIV-HAPPY | `gh issue view … --json body` stub returns a body containing `- [ ] Do the thing`; PATCH stub records the new body | script exits 0, prints `Checked: …`, and the PATCHed body contains `- [x] Do the thing` (same outcome as the old `gh api … --jq .body` read produced) |
| TC-MCB-EQUIV-READSHAPE | same stub records the READ argv | the READ the script issues is `gh issue view <N> --repo <REPO> --json body -q .body` (the migrated shape), NOT `gh api repos/.../issues/<N> --jq .body` |
| TC-MCB-EQUIV-ERROR | `gh issue view … --json body` stub exits non-zero (read error) | the `|| { … }` handler fires identically: stderr carries `Error: Failed to fetch issue #<N>`, the script returns non-zero, and NO PATCH is attempted |

## 2. REPO-fallback preserved — AC2 (self-repo, no `autonomous.conf`)

The migration swaps ONLY the gh read primitive; the REPO-resolution path
(conf-lookup → `GITHUB_REPO`/`REPO` → `owner/repo` default) is unchanged.

| ID | Setup | Assertion |
|---|---|---|
| TC-MCB-REPO-FALLBACK | run the script in an isolated dir with NO `autonomous.conf` reachable and `REPO`/`GITHUB_REPO` unset; the provider lib resolves so `itp_read_task` is defined but the read fails against the placeholder `owner/repo` | the script exits non-zero (the same exit-1-when-REPO-unresolvable behavior as before the migration) — the migration did NOT alter REPO resolution |

## 3. Provider-lib-absent fails EARLIER (intentional, option b) — AC2c

After migration the body READ routes through `itp_read_task`. When the provider
lib cannot be resolved at all, BOTH `itp_read_task` and `itp_mark_checkbox` stay
undefined, so the script fails LOUD in the **fetch** handler (earlier than the
pre-migration PATCH-cap branch) with a `verb-not-available` message — NOT a raw
`command not found` and NEVER a raw-`gh` fallback (re-adding one would re-introduce
the exact survivor this migration removes → violate INV-91). The source guard at
`:42` is widened to source the seam when `itp_read_task` OR `itp_mark_checkbox` is
undefined, so the genuinely-absent-lib case still attempts the source.

| ID | Setup | Assertion |
|---|---|---|
| TC-B1-CHECKBOX-ABSENT (re-baselined) | a COPY of the script ALONE (no sibling provider lib); both verbs undefined; tripwire `gh` on PATH | the script fails loud with a verb-not-available message (names `itp_read_task`), exits non-zero, and NO `gh` call (read or PATCH) is made — the earlier fail-loud, not `command not found` |

## 4. Degraded-fixture caps-branch reachable — AC2b

`TC-CAP-CHECKBOX0-BRANCH` (`ISSUE_PROVIDER=degraded`) must still reach the
`body_checkbox=0` cap-branch after the migration. With the body read now routed
through `itp_read_task` → `itp_degraded_read_task`, the degraded fixture
(previously an empty scaffold) MUST define `itp_degraded_read_task` so the read
succeeds and returns a body BEFORE the cap-branch is evaluated — otherwise the
script dies at `itp_degraded_read_task: command not found` and never reaches the
branch under test.

| ID | Assertion |
|---|---|
| TC-CAP-CHECKBOX0-BRANCH (`test-itp-write-leaves.sh`) | `ISSUE_PROVIDER=degraded` → the read succeeds via `itp_degraded_read_task`, the script reaches and fires the documented `body_checkbox=0` native-subtask remap (`body_checkbox=0` in stderr), no `command not found`, no PATCH |
| body_checkbox END-TO-END (`test-provider-caps-branches.sh`) | same — the degraded body_checkbox=0 branch executes end-to-end (the cap-branch coverage gate stays green) |

## 5. Stubs updated for the new read shape — AC2a

The 3 `gh` stubs in `test-itp-write-leaves.sh` (TC-B1-CHECKBOX-HAPPY,
TC-CAP-CHECKBOX0-BRANCH, TC-B1-CHECKBOX-ABSENT) were keyed on the OLD
`$1==api && $3==--jq` body-read shape. They are updated to recognize the new
`gh issue view … --json body` shape (`$1==issue && $2==view` → return the body).

| ID | Assertion |
|---|---|
| TC-B1-CHECKBOX-HAPPY | the happy path still PATCHes via the github verb leaf (the read stub now serves `gh issue view --json body`) |
| TC-CAP-CHECKBOX0-BRANCH | see §4 |
| TC-B1-CHECKBOX-ABSENT | see §3 |

## 6. Cutover-baseline shrinks by exactly 1 + spec gate — AC3, AC4 (verified via CI)

| ID | Surface | Assertion |
|---|---|---|
| TC-MCB-BASELINE-SHRINK-1 | CI Spec Drift + PR diff | `cutover-baseline.json` shrinks by EXACTLY 1 — only the `mark-issue-checkbox.sh` `body=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.body')` survivor is removed; every other survivor remains; `check-provider-cutover.sh` exits 0 |
| TC-MCB-INV91-LOG | CI Spec Drift / unit | `docs/pipeline/invariants.md` INV-91 Migration log (a) retracts the now-false "body-READ leaf … is retained (batch B7/B8)" clause in the `#296 B1` bullet, and (b) adds a new Migration-log bullet for this batch (`itp_github_read_task`, shape-equivalent, baseline −1); `check-spec-drift.sh` exits 0 |
| TC-MCB-DOCS-GATE | CI Pipeline Docs Gate | `pipeline-docs-gate.yml` is SATISFIED — the PR touches `docs/pipeline/invariants.md` (the watched_regex matches `autonomous-common/scripts/*.sh`) |

All ACs are deterministic CI greps/tests; no subjective reviewer step.
