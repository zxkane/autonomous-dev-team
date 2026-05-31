# Test Cases: per-agent model + extra-args resolution for the review fan-out (#168)

Covers INV-41 (per-agent `AGENT_REVIEW_MODEL_<AGENT>` /
`AGENT_REVIEW_EXTRA_ARGS_<AGENT>` resolution) layered on the INV-40 multi-agent
review fan-out. The wrapper is too heavy to run end-to-end, so testing is two
pronged (mirrors `test-autonomous-review-multi-agent.sh`):

1. **Pure helper harness** — source `lib-review-resolve.sh` and drive the three
   pure functions over the normalization + precedence truth table.
2. **Source-of-truth greps** — assert the structural wiring in
   `autonomous-review.sh` without executing the wrapper.

Test file: `tests/unit/test-autonomous-review-per-agent-model.sh`.

## Pure helper: `_review_agent_key_suffix`

| ID | Input | Expected output |
|----|-------|-----------------|
| TC-PAM-SUF-01 | `agy` | `AGY` |
| TC-PAM-SUF-02 | `kiro` | `KIRO` |
| TC-PAM-SUF-03 | `claude` | `CLAUDE` |
| TC-PAM-SUF-04 | `claude-code` | `CLAUDE_CODE` (hyphen → `_`) |
| TC-PAM-SUF-05 | `gpt.4o` | `GPT_4O` (dot → `_`) |
| TC-PAM-SUF-06 | `a b` | `A_B` (space → `_`) |
| TC-PAM-SUF-07 | `Agy` (mixed case) | `AGY` (uppercased) |

## Pure helper: `_resolve_review_agent_model` (precedence)

`AGENT_REVIEW_MODEL_<SUFFIX>` (per-agent) → `AGENT_REVIEW_MODEL` (shared) →
empty (caller applies the `sonnet` lib default).

| ID | Env | Agent | Expected |
|----|-----|-------|----------|
| TC-PAM-MOD-01 | `AGENT_REVIEW_MODEL=sonnet[1m]`, no per-agent key | `kiro` | `sonnet[1m]` (shared) |
| TC-PAM-MOD-02 | `AGENT_REVIEW_MODEL=sonnet[1m]`, `AGENT_REVIEW_MODEL_KIRO=claude-sonnet-4.6` | `kiro` | `claude-sonnet-4.6` (per-agent wins) |
| TC-PAM-MOD-03 | `AGENT_REVIEW_MODEL=sonnet[1m]`, `AGENT_REVIEW_MODEL_KIRO=claude-sonnet-4.6` | `agy` | `sonnet[1m]` (agy has no per-agent key → shared) |
| TC-PAM-MOD-04 | `AGENT_REVIEW_MODEL=""`, no per-agent key | `kiro` | `` (empty; caller defaults to sonnet) |
| TC-PAM-MOD-05 | `AGENT_REVIEW_MODEL_KIRO=""` (explicit empty), `AGENT_REVIEW_MODEL=sonnet[1m]` | `kiro` | `sonnet[1m]` (explicit empty per-agent key falls back to shared) |
| TC-PAM-MOD-06 | per-agent key for `claude-code` set as `AGENT_REVIEW_MODEL_CLAUDE_CODE=x` | `claude-code` | `x` (suffix normalization wires the right key) |

## Pure helper: `_resolve_review_agent_extra_args` (precedence)

`AGENT_REVIEW_EXTRA_ARGS_<SUFFIX>` (per-agent) → `AGENT_REVIEW_EXTRA_ARGS` (shared).

| ID | Env | Agent | Expected |
|----|-----|-------|----------|
| TC-PAM-XA-01 | `AGENT_REVIEW_EXTRA_ARGS="--shared"`, no per-agent key | `kiro` | `--shared` |
| TC-PAM-XA-02 | `AGENT_REVIEW_EXTRA_ARGS="--shared"`, `AGENT_REVIEW_EXTRA_ARGS_KIRO="--trust-all-tools"` | `kiro` | `--trust-all-tools` |
| TC-PAM-XA-03 | both unset/empty | `kiro` | `` (empty) |
| TC-PAM-XA-04 | `AGENT_REVIEW_EXTRA_ARGS_AGY="--approval-mode yolo"`, shared empty | `agy` | `--approval-mode yolo` (multi-token preserved) |
| TC-PAM-XA-05 | `AGENT_REVIEW_EXTRA_ARGS_KIRO=""` (explicit empty), shared `--shared` | `kiro` | `--shared` (explicit empty per-agent falls back to shared) |

## Source-of-truth greps (against `autonomous-review.sh`)

| ID | Assertion |
|----|-----------|
| TC-PAM-SRC-01 | wrapper sources `lib-review-resolve.sh` |
| TC-PAM-SRC-02 | fan-out resolves a per-agent model var (`_resolve_review_agent_model`) inside the subshell |
| TC-PAM-SRC-03 | the `run_agent` model arg is the resolved per-agent value, NOT a bare `${AGENT_REVIEW_MODEL:-sonnet}` literal (the literal is no longer the only model source for the fan-out call) |
| TC-PAM-SRC-04 | fan-out resolves per-agent extra-args (`_resolve_review_agent_extra_args`) |
| TC-PAM-SRC-05 | resolved extra-args is assigned to `AGENT_DEV_EXTRA_ARGS` inside the subshell (the var `run_agent` reads) so it reaches `_parse_extra_args` |
| TC-PAM-SRC-06 | `_review_agent_key_suffix` defined in `lib-review-resolve.sh` (symbol present) |
| TC-PAM-SRC-07 | `bash -n` clean on the wrapper |

## Backward-compatibility regression gate (all per-agent keys unset)

The full pre-existing sweep stays green:
`test-autonomous-review-multi-agent`, `test-autonomous-review-prompt`,
`test-autonomous-review-verdict-regex`, `test-autonomous-review-verdict-trailer`,
`test-autonomous-launcher-verdict-fresh`,
`test-autonomous-review-reviewed-head-annotation`,
`test-autonomous-review-auto-merge-failure`, `test-classify-recent-review-verdict`,
`test-lib-agent-per-side-cmd`, `test-lib-agent-per-side-launcher`, plus `bash -n`.

## Acceptance mapping

- AC "all unset → byte-for-byte today" → TC-PAM-MOD-01/04, TC-PAM-XA-01/03 + regression sweep.
- AC "`kiro` gets `claude-sonnet-4.6`, claude-fam keeps `sonnet[1m]`" → TC-PAM-MOD-02/03.
- AC "per-agent extra-args reaches `_parse_extra_args`; unset falls back" → TC-PAM-XA-02/01 + TC-PAM-SRC-05.
- AC "normalizer uppercases + non-alphanumeric→`_`" → TC-PAM-SUF-01..07.
