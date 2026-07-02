# Test cases — #296 FINAL batch reword + upload-screenshot.sh allowlist (#344)

ID prefix: `TC-FINALBATCH`. Extends `tests/unit/test-provider-cutover.sh` (the guard itself) and
updates the 2 pre-existing pins in `test-lib-review-postfail.sh` that assert the OLD `gh rc`
phrasing. Credential-free (grep/jq/coreutils), runs in the hermetic-unit `tests/unit/test-*.sh`
CI glob.

| ID | Requirement | Scenario | Expected |
|---|---|---|---|
| TC-FINALBATCH-001 | R1 | Each of the 6 reworded lines (grep by file:line) contains no `(^\|[^A-Za-z_-])gh ` match | 0 matches per line, verified with the guard's own detector regex |
| TC-FINALBATCH-002 | R1 | Each reworded line still contains its original INV/remediation references (`INV-56` in `post-verdict.sh`, the issue-number/session context in `lib-error.sh`) | substring assertions pass — meaning preserved |
| TC-FINALBATCH-003 | R2 | `_postfail_drop_reason_phrase("post-failed:gh-rc 1")` now renders `cli rc 1` (not `gh rc 1`) | `test-lib-review-postfail.sh::TC-PF-PHR-01b` updated assertion passes |
| TC-FINALBATCH-004 | R2 | `_postfail_drop_reason_phrase("post-failed")` still contains no `cli rc` (the bare-token path names no rc) | `test-lib-review-postfail.sh::TC-PF-PHR-02b` updated assertion passes |
| TC-FINALBATCH-005 | R2 (no-op check) | The `gh_rc=` breadcrumb KEY (machine format, no trailing space) is UNCHANGED in `post-verdict.sh`, `lib-review-postfail.sh`, and their tests | `test-post-verdict.sh::TC-PF-BC-02d` and `test-lib-review-postfail.sh` breadcrumb helpers still pass unmodified |
| TC-FINALBATCH-006 | R3 | `upload-screenshot.sh` is present in `check-provider-cutover.sh`'s `ALLOWLISTED_FILES` array | grep the array literal |
| TC-FINALBATCH-007 | R3 | With `upload-screenshot.sh` allowlisted, `discover_guarded_sites` against the real tree emits ZERO signatures for `file == "upload-screenshot.sh"` | `bash check-provider-cutover.sh --generate-baseline \| jq` shows no upload-screenshot.sh entry |
| TC-FINALBATCH-008 | R4 | The committed `providers/cutover-baseline.json` contains ZERO signatures matching any of the 6 OLD reworded strings, and ZERO `upload-screenshot.sh` signatures of any kind | grep/jq the committed baseline for each OLD string + the file — 0 hits (no absolute-total pin — see the #342/#349 precedent note below) |
| TC-FINALBATCH-010 | AC1 | `check-provider-cutover.sh --require-trusted-ref` (against `origin/main`, pre-merge) exits 0 | Check 1 (reconcile) + Check 4 (monotonicity, strictly shrunk) both pass |
| TC-FINALBATCH-011 | AC3 | `git diff` of the 6 reworded files touches ONLY string-literal content inside `log`/`_error_log`/`printf`/`echo` calls — no change to any executable `gh` invocation | manual diff inspection (not machine-checked; recorded here as the AC3 verification step) |

## Baseline delta (recorded before implementation, verified after)

- Before: 47 distinct signatures / 52 total occurrences (verified on `origin/main` @ `bfabb2d`).
- After: 40 distinct signatures / 45 total occurrences (6 reword sites + 1 allowlisted-file site,
  each `count: 1`, no duplicates removed).
- These totals are recorded here as historical fact only — no test asserts them as an absolute
  pin. Per the #342/#349 precedent (`test-reply-review-comment.sh::TC-RRC-033`), an absolute
  distinct/occurrence pin goes red on any concurrent sibling #296 migration that also shrinks the
  shared baseline, and adds no coverage beyond what `check-provider-cutover.sh` itself already
  enforces (Check 1 reconciliation + Check 4 shrink-only monotonicity under `--require-trusted-ref`,
  TC-FINALBATCH-010).

## Unit tests

- `tests/unit/test-provider-cutover.sh` — add cases covering R3 (upload-screenshot.sh allowlisted,
  zero baseline signatures for it) and the overall baseline shrink; existing TC-CUTOVER-*/
  TC-CUTAMEND-* cases must stay green (they assert relative/shape properties, not absolute counts,
  per the #349 unpin).
- `tests/unit/test-lib-review-postfail.sh` — update `TC-PF-PHR-01b`/`02b` assertion text
  (`gh rc 1` → `cli rc 1`; the not-contains check for the bare-token path moves from asserting
  absence of `gh rc` to asserting absence of `cli rc` — see R2 above).
- Full unit suite (`tests/unit/test-*.sh`) green.

## E2E

Not applicable — message rewording + guard config only (per issue's Testing Requirements).
