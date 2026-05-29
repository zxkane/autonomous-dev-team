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

## Backward-compatibility cases (existing tests must still pass)

- `tests/unit/test-autonomous-review-prompt.sh` — full file, unchanged invariants.
- `tests/unit/test-autonomous-review-auto-merge-failure.sh` — unchanged.
- `tests/unit/test-autonomous-review-reviewed-head-annotation.sh` — unchanged.
- `tests/unit/test-autonomous-review-verdict-regex.sh` — unchanged.
- `tests/unit/test-autonomous-review-verdict-trailer.sh` — unchanged.

The absent-config path (`E2E_MODE` unset, `E2E_ENABLED` unset or `false`) is the dominant case and is exercised by every existing test that sources the wrapper without setting `E2E_*`. Those must continue to render a prompt with no E2E section.
