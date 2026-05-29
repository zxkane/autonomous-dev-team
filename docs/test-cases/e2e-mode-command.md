# Test Cases: E2E_MODE=command

Coverage for issue #161 — `E2E_MODE` dispatch in `autonomous-review.sh`. All cases use the source-of-truth grep pattern from `tests/unit/test-autonomous-review-prompt.sh` (no end-to-end agent execution; the wrapper is rendered under different env permutations and the resulting prompt or stderr is asserted against).

## Background

`E2E_MODE` is a new field in `autonomous.conf`. Three accepted values:

| `E2E_MODE` | Behavior |
|---|---|
| unset / `none` | No E2E section in the rendered prompt. |
| `browser` | Existing Chrome-DevTools-MCP block (back-compat for explicit opt-in). |
| `command` | New block; agent invokes `$E2E_COMMAND`, captures evidence via `$E2E_COMMAND_EVIDENCE_PARSER`, posts as PR comment. |

`E2E_ENABLED=true` with `E2E_MODE` unset is a **fail-loud** condition (no implicit default).

## Test cases

### TC-E2E-MODE-001: missing-mode fail-loud

**Setup:** `E2E_ENABLED=true`, `E2E_MODE` unset. All other env minimal.
**Action:** invoke `autonomous-review.sh` config-validation path.
**Expectation:** wrapper exits non-zero. stderr contains the literal string `E2E_MODE` AND mentions all three accepted values (`none`, `browser`, `command`).

### TC-E2E-MODE-002: mode=none silences E2E

**Setup:** `E2E_MODE=none` (with `E2E_ENABLED=true` or unset, both behave the same).
**Action:** render prompt.
**Expectation:** prompt contains NEITHER the browser block header (`E2E Verification via Chrome DevTools MCP`) NOR the command-mode header (`E2E Verification via project command`).

### TC-E2E-MODE-003: mode=browser preserves existing block

**Setup:** `E2E_ENABLED=true`, `E2E_MODE=browser`, `E2E_PREVIEW_URL_PATTERN` set.
**Action:** render prompt.
**Expectation:** prompt contains the existing `E2E Verification via Chrome DevTools MCP — MANDATORY` header. Back-compat for projects that explicitly opt into browser mode.

### TC-E2E-MODE-004: mode=command injects new block

**Setup:** `E2E_ENABLED=true`, `E2E_MODE=command`, `E2E_COMMAND="bash scripts/e2e.sh pr-${PR_NUMBER}"`, `E2E_COMMAND_EVIDENCE_PARSER="bash scripts/e2e-evidence.sh"`.
**Action:** render prompt for `PR_NUMBER=344`.
**Expectation:** prompt contains:
- A header matching `E2E Verification via project command — MANDATORY` (or equivalent that names the mode)
- The literal value of `$E2E_COMMAND` after `${PR_NUMBER}` substitution
- The literal value of `$E2E_COMMAND_EVIDENCE_PARSER`
- The evidence marker literal `<!-- e2e-evidence: complete -->`
- A clear PASS / FAIL decision rule referencing exit code + evidence-block presence

### TC-E2E-MODE-005: mode=command without E2E_COMMAND fails

**Setup:** `E2E_ENABLED=true`, `E2E_MODE=command`, `E2E_COMMAND` unset, `E2E_COMMAND_EVIDENCE_PARSER` set.
**Action:** invoke wrapper config-validation path.
**Expectation:** wrapper exits non-zero. stderr names `E2E_COMMAND` as the missing field.

### TC-E2E-MODE-006: mode=command without evidence parser fails

**Setup:** `E2E_ENABLED=true`, `E2E_MODE=command`, `E2E_COMMAND` set, `E2E_COMMAND_EVIDENCE_PARSER` unset.
**Action:** invoke wrapper config-validation path.
**Expectation:** wrapper exits non-zero. stderr names `E2E_COMMAND_EVIDENCE_PARSER` as the missing field.

### TC-E2E-MODE-007: invalid mode value fails

**Setup:** `E2E_ENABLED=true`, `E2E_MODE=foo`.
**Action:** invoke wrapper config-validation path.
**Expectation:** wrapper exits non-zero. stderr lists the three accepted values explicitly.

### TC-E2E-MODE-008: PR_NUMBER substitution

**Setup:** `E2E_ENABLED=true`, `E2E_MODE=command`, `E2E_COMMAND='bash scripts/e2e.sh pr-${PR_NUMBER}'`, `E2E_COMMAND_EVIDENCE_PARSER="bash scripts/e2e-evidence.sh"`. Wrapper invoked with `PR_NUMBER=344`.
**Action:** render prompt.
**Expectation:** prompt contains the literal substring `bash scripts/e2e.sh pr-344` (no unresolved `${PR_NUMBER}` in the rendered command).

## Post-review hardening cases (added in fixup)

### TC-E2E-MODE-009: case-sensitivity rejected

**Setup:** `E2E_MODE=Browser` or `E2E_MODE=COMMAND` (capitalization variants).
**Action:** invoke wrapper config-validation path.
**Expectation:** wrapper exits non-zero. Mode comparison is exact-match (case-sensitive); capitalized variants hit the invalid-mode branch.

### TC-E2E-MODE-010: command-mode fields without E2E_MODE=command

**Setup:** `E2E_COMMAND` set, but `E2E_MODE=none` or `E2E_MODE=browser`.
**Action:** invoke wrapper config-validation path.
**Expectation:** wrapper exits non-zero. Catches the "operator filled in E2E_COMMAND but forgot E2E_MODE=command" footgun.

### TC-E2E-MODE-011: substitution survives unset E2E_COMMAND_PRE_HOOKS

**Setup:** `E2E_MODE=command`, `E2E_COMMAND` and `E2E_COMMAND_EVIDENCE_PARSER` set, `E2E_COMMAND_PRE_HOOKS` left unset.
**Action:** wrapper substitution block (lines around 388-397) must use `:-` defaults.
**Expectation:** substitution lines reference `${VAR:-}` form; an explicit PR_NUMBER empty-guard precedes substitution. Without `:-` defaults, `set -u` would crash the wrapper before the agent runs.

### TC-E2E-MODE-012: F1 fix — decision FAIL message branches on E2E_MODE

**Setup:** code inspection of the wrapper's "Decision" section.
**Expectation:** the FAIL message uses a `case ${E2E_MODE}` branch — `browser` says "screenshot evidence", `command` says "log tail evidence". Pre-fix: both modes received the same screenshot-flavored language, confusing the agent in command mode.

### TC-E2E-MODE-013: F2 fix — evidence marker requires SHA binding

**Setup:** code inspection of the wrapper's prompt.
**Expectation:** the marker spec is `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->`, and the prompt contains a stale-evidence guard step that re-binds skip behavior to exact SHA match. Plain marker without SHA does NOT count.

### TC-E2E-MODE-014: F3 fix — parser only on EXIT_CODE ∈ {0, 124}

**Setup:** code inspection of the wrapper's command-mode Step 4.
**Expectation:** parser invocation is gated on `EXIT_CODE -eq 0 || EXIT_CODE -eq 124`. Hard failures (other non-zero) skip the parser and post a `tail -50` of the log file as the failure comment instead.

### TC-E2E-MODE-015: F4 fix — unbraced `$PR_NUMBER` rejected

**Setup:** `E2E_COMMAND='bash scripts/x.sh $PR_NUMBER'` (unbraced).
**Action:** invoke wrapper config-validation path.
**Expectation:** wrapper exits non-zero. Stderr names the offending field. Without this guard, the unbraced form would silently render as empty and target the wrong stage. Braced form `${PR_NUMBER}` validates clean.

### TC-E2E-MODE-016: command-mode exports PR_NUMBER + PR_HEAD_SHA

**Setup:** code inspection of the wrapper's env-export block.
**Expectation:** when `E2E_MODE=command`, the wrapper exports both `PR_NUMBER` and `PR_HEAD_SHA` so the project's evidence parser script can read `PR_HEAD_SHA` from env to embed in the marker.

## Backward-compatibility cases (existing tests must still pass)

- `tests/unit/test-autonomous-review-prompt.sh` — full file, unchanged invariants.
- `tests/unit/test-autonomous-review-auto-merge-failure.sh` — unchanged.
- `tests/unit/test-autonomous-review-reviewed-head-annotation.sh` — unchanged.
- `tests/unit/test-autonomous-review-verdict-regex.sh` — unchanged.
- `tests/unit/test-autonomous-review-verdict-trailer.sh` — unchanged.

The absent-config path (`E2E_MODE` unset, `E2E_ENABLED` unset or `false`) is the dominant case and is exercised by every existing test that sources the wrapper without setting `E2E_*`. Those must continue to render a prompt with no E2E section.
