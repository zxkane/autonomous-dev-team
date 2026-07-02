# Design — #296 FINAL batch: reword 6 gh-token log strings + allowlist upload-screenshot.sh (#344)

## Goal

Retire the last cosmetic/out-of-seam raw-`gh` residue from `providers/cutover-baseline.json`:

1. **R1/R2** — reword 6 message strings that only trip the guard's `(^|[^A-Za-z_-])gh `
   matcher because they mention the literal token `gh ` in prose, not because they perform
   any I/O. Zero behavior change: each site is a `log`/`echo`/`printf` diagnostic string.
2. **R3/R4** — allowlist `upload-screenshot.sh` in `check-provider-cutover.sh`'s
   `ALLOWLISTED_FILES` now that PR #335 (chp_commit_file) reduced it to a single
   `command -v gh` presence-guard survivor, and regenerate the baseline.
3. **R5** — record the disposition + resulting permanent-residue classes in INV-91's
   migration log (`docs/pipeline/invariants.md`).

No wrapper *behavior* changes — this is the same "touches NO runtime wrapper logic" posture
`check-provider-cutover.sh` itself carries; the 6 sites are diagnostic strings whose CONTENT
changes but whose trigger condition / control flow / semantics are untouched.

## The 6 reword sites

| File:line | Old (trips scanner) | New |
|---|---|---|
| `autonomous-dev.sh:740` | `log "Exiting with code $exit_code (agent never ran, no ISSUE_NUMBER or gh — silent)."` | `log "Exiting with code $exit_code (agent never ran, no ISSUE_NUMBER or CLI proxy — silent)."` |
| `lib-error.sh:303` | `_error_log "token-refresh gh proxy not resolvable (…); degrading envelope ${code} to log-only:"` | `_error_log "token-refresh CLI proxy not resolvable (…); degrading envelope ${code} to log-only:"` |
| `lib-error.sh:332` | `_error_log "failed to surface envelope ${code} on issue #${issue} (gh rc=${post_rc}); degrading to log-only:"` | `_error_log "failed to surface envelope ${code} on issue #${issue} (cli rc=${post_rc}); degrading to log-only:"` |
| `lib-review-postfail.sh:119` | `printf 'post-failed (verdict comment post failed; gh rc %s — …)\n' "$rc"` | `printf 'post-failed (verdict comment post failed; cli rc %s — …)\n' "$rc"` |
| `post-verdict.sh:277` | `echo "Error: token-refresh gh proxy not found/executable at '${GH}'. Refusing to post the verdict via bare PATH gh (it would mis-attribute the comment). Re-run install-project-hooks.sh to restore the scripts/gh symlink (INV-56)." >&2` | `echo "Error: token-refresh CLI proxy not found/executable at '${GH}'. Refusing to post the verdict via a bare PATH CLI call (it would mis-attribute the comment). Re-run install-project-hooks.sh to restore the token-refresh proxy symlink (scripts/gh, INV-56)." >&2` |
| `post-verdict.sh:301` | `echo "Error: failed to post verdict comment on issue #${ISSUE_NUMBER} (gh rc=${POST_RC})"` | `echo "Error: failed to post verdict comment on issue #${ISSUE_NUMBER} (cli rc=${POST_RC})"` |

Rule applied uniformly: `gh` → `CLI`/`cli` when it is the SUBJECT of the diagnostic (the proxy
binary / the process being described); `gh rc=` → `cli rc=` (display prose) because the scanner's
token is `gh ` (with a trailing space) — `gh_rc=` (the machine breadcrumb KEY, no space) does NOT
match and is explicitly left alone (see Requirements note in the issue). `post-verdict.sh:277`'s
reword moves the literal `scripts/gh` filename to right before `symlink` (`gh symlink` — no
trailing space after `gh`, so it does not match the `gh ` token) so the remediation hint still
names the real on-disk file; every other `gh ` mention on that line (`gh proxy`, `bare PATH gh`)
is reworded to `CLI proxy`/`CLI call`. All 6 rewordings below are verified against the guard's
LIVE regex (`grep -oE '(^|[^A-Za-z_-])gh '`) to have zero matches before implementing.

## R3 — allowlist `upload-screenshot.sh`

Add `upload-screenshot.sh` to `ALLOWLISTED_FILES` in `check-provider-cutover.sh` (alongside the
existing auth/transport wrappers). Its only remaining raw-gh signature after #335
(`command -v gh >/dev/null 2>&1 || fail "gh CLI is required but not found in PATH"`) is a
capability-presence guard, not I/O — the same class of allowlisted survivor
`lib-auth.sh`'s `command -v gh` / `gh auth status` lines already are (`lib-auth.sh` is NOT itself
allowlisted, but is a caller-layer file whose baselined survivors are auth-detection, not I/O —
`upload-screenshot.sh` differs in being a single-purpose non-caller-layer utility script entirely
about GitHub upload, so file-level allowlisting is the correct disposition, matching the review's
sibling class of "auth/transport wrappers").

Remove `upload-screenshot.sh`'s baseline entry (the `command -v gh` line) since an allowlisted file
is excluded from the scan entirely (`discover_guarded_sites` skips `in_list "$rel"
"${ALLOWLISTED_FILES[@]}"` BEFORE emitting any line for that file).

## R4 — regenerate baseline

Net shrink = 6 reword signatures (autonomous-dev.sh ×1, lib-error.sh ×2, lib-review-postfail.sh ×1,
post-verdict.sh ×2) + 1 allowlisted-file signature (upload-screenshot.sh) = **7 signatures / 7
occurrences** (each of the 7 removed lines has `count: 1` in the current baseline — no duplicates).
Regenerate via `check-provider-cutover.sh --generate-baseline` and commit the result.

## R5 — INV-91 migration log entry

Append a new bullet to the `**Migration log**` list in `docs/pipeline/invariants.md` under
INV-91, following the existing bullet format (see `#286-amendment (#343)` as the most recent
precedent), recording:
- what moved (6 reword sites + 1 allowlisted file)
- the resulting **permanent residue classes** the baseline now holds exclusively: auth/identity
  sites (spec §8), the guard's own self-scan PASS/FAIL message strings, agent-prompt heredoc
  prose, and the spec-sanctioned capability fallbacks (`autonomous-review.sh` `gh issue close`,
  `lib-auth.sh` leaf-absent fallbacks) — explicitly noting these last two categories are NOT
  touched by this issue (own disposition issues, out of scope here).
- the exact baseline delta (signature/occurrence counts before → after).

## Verification (no behavior change)

- `bash -n` every touched file.
- `grep` each OLD string across `tests/` before editing (done — see below) and update every
  match in the SAME PR.
- Diff review: confirm the ONLY change per file is inside a string literal passed to
  `log`/`_error_log`/`printf`/`echo` — no change to control flow, variable names, or the
  executable path.
- `check-provider-cutover.sh --require-trusted-ref` exits 0 with the baseline strictly shrunk
  (Check 4 monotonicity).
- Full unit suite green, including every test updated for R2.

## Test-pin inventory (R2 — grepped BEFORE rewording)

| Old string fragment | Pinned in | Action |
|---|---|---|
| `gh rc 1` (from `_postfail_drop_reason_phrase` output) | `tests/unit/test-lib-review-postfail.sh:182` (`TC-PF-PHR-01b`) | update assertion text to `cli rc 1` |
| `gh rc` (not-contains check) | `tests/unit/test-lib-review-postfail.sh:187` (`TC-PF-PHR-02b`) | update to assert `cli rc` absent (still proves no rc leaks into the bare phrase) |
| `gh_rc=1` (breadcrumb KEY, unrelated to R1) | `tests/unit/test-post-verdict.sh:524`, `tests/unit/test-lib-review-postfail.sh:123,131` | **NO CHANGE** — machine key, not display prose, doesn't match the scanner |
| `not resolvable` (substring of the lib-error.sh:303 reword) | `tests/unit/test-lib-error-envelope.sh:329` (`012b`) | no change needed — substring survives the `gh`→`CLI` swap (`token-refresh CLI proxy not resolvable`) |
| `INV-56` (substring of post-verdict.sh:277) | `tests/unit/test-post-verdict.sh:490` (`TC-PV-16c`) | no change needed — INV-56 reference preserved verbatim |
| `bare PATH gh` (test asserts the HELPER never falls back, via a side-channel marker file — does not assert the ERROR STRING text) | `tests/unit/test-post-verdict.sh:484-487` (`TC-PV-16b`) | no change needed — assertion is behavioral (marker file absence), not a string-content pin |

No test pins the exact `autonomous-dev.sh:740` string, the `lib-error.sh:332` string, or the
`post-verdict.sh:301` string verbatim — those 3 rewords need no test updates.
