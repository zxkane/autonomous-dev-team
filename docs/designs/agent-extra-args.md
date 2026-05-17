# Design: Pluggable per-CLI flag passthrough via `AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`

**Issue**: #140 (closes #102)
**Date**: 2026-05-17

## Problem

`lib-agent.sh` hardcodes operator-tunable safety flags inside per-CLI case branches:

- `gemini` always passes `--approval-mode yolo --output-format stream-json`
- `kiro` conditionally passes `--trust-all-tools` keyed on `AGENT_PERMISSION_MODE=bypassPermissions`

Both flags are operationally load-bearing (see #134/#135 and #136/#139). Adding a new CLI or
new debug flag for an existing CLI today requires editing `lib-agent.sh`, opening a PR, and
redeploying via `npx skills update` on every operator's box. That is too high a friction for
a value that is, by intent, operator-tunable.

## Goal

Demote those hardcoded flags into two new conf-level passthrough variables and append the
operator's value verbatim after each branch's structural arguments:

- `AGENT_DEV_EXTRA_ARGS` — used in `run_agent` invocations
- `AGENT_REVIEW_EXTRA_ARGS` — used in `resume_agent` invocations

Defaults are empty (unset → empty array → no flags appended). Operators migrating from prior
versions MUST add these vars to their `autonomous.conf` for `gemini` and `kiro` deployments
(documented in `autonomous.conf.example` migration callout).

## Approach

### lib-agent.sh

1. Two new arrays parsed once per `run_agent` / `resume_agent` invocation via `read -ra`
   (same pattern as `AGENT_LAUNCHER_ARGV` line ~91). Read-only after parse.

2. Each case branch (claude, codex, gemini, kiro, opencode, generic fallback) appends
   `"${extra_args[@]}"` after structural arguments and before the prompt positional.

3. **Demotions** (out of branches into EXTRA_ARGS):
   - gemini: `--approval-mode yolo --output-format stream-json` (both run + resume)
   - kiro: conditional `--trust-all-tools` block (both run + resume)

4. **Preserved as structural** (NOT demoted):
   - claude: `--permission-mode "$AGENT_PERMISSION_MODE"` (1:1 documented mapping; demoting
     would break many existing deployments)
   - All branches: `--session-id`, `--resume`, `--model`, `--output-format json`, `exec --json`,
     `run --format json`, `--agent`, `--no-interactive`, `chat`, `-p` — these are
     CLI invocation contracts, not operator-tunable safety flags.

### Append shape

```bash
case "$AGENT_CMD" in
  gemini)
    local extra_args=()
    [[ -n "${AGENT_DEV_EXTRA_ARGS:-}" ]] && read -ra extra_args <<< "$AGENT_DEV_EXTRA_ARGS"
    _run_with_timeout "$AGENT_CMD" \
      --session-id "$session_id" ${model:+--model "$model"} \
      "${extra_args[@]}" \
      -p "$prompt"
    ;;
```

### autonomous.conf.example

- Header callout noting the migration date and the two CLIs that MUST be updated.
- Per-CLI block (claude / gemini / kiro / codex / opencode) showing the recommended
  `AGENT_DEV_EXTRA_ARGS` value with a comment explaining why it's load-bearing for that CLI.

### Documentation

- README.md: existing "Supported Agent CLIs" table updated to point at the EXTRA_ARGS
  conf knobs rather than wrapper hardcoding.
- docs/autonomous-pipeline.md: new "Operator-tunable per-CLI flags" section with the
  EXTRA_ARGS contract.
- docs/pipeline/invariants.md: spot-check INV-13 / INV-22; neither references the demoted
  flags so no INV update is required.
- lib-agent.sh top-of-file docstring: gemini/kiro entries reference the conf blocks.

## Test strategy

A new file `tests/unit/test-lib-agent-extra-args.sh` runs through the same stub-CLI pattern
as `test-lib-agent-gemini.sh` / `test-lib-agent-kiro-permission.sh`:

- TC-EXTRA-001: claude run_agent appends operator EXTRA_ARGS without breaking `--permission-mode`
- TC-EXTRA-002: gemini case no longer hardcodes `--approval-mode yolo`
- TC-EXTRA-003: gemini with operator-supplied EXTRA_ARGS produces the load-bearing flags
- TC-EXTRA-004: kiro case no longer hardcodes `--trust-all-tools`
- TC-EXTRA-005: kiro with operator-supplied EXTRA_ARGS produces the trust flag
- TC-EXTRA-006: review-side `AGENT_REVIEW_EXTRA_ARGS` distinct from dev-side
- TC-EXTRA-007: structural flags preserved per CLI (regression pin)
- TC-EXTRA-008: shell quoting — paths with spaces parse as one argument
- TC-EXTRA-009: empty/unset EXTRA_ARGS yields no leftover empty argv elements
- TC-EXTRA-010: backward-compat — gemini/kiro w/o EXTRA_ARGS produce wrapper invocations
  WITHOUT the demoted flags (the migration is intentional)

The existing `test-lib-agent-gemini.sh` and `test-lib-agent-kiro-permission.sh` will be
updated where they assert the old hardcoded flags. Other unit tests should not be affected.

## Out of scope

- AGENT_LAUNCHER refactor (separate extension point, claude-only)
- Demotion of claude's `--permission-mode` (would break many deployments)
- New CLI support beyond the 5 already first-class

## Migration risk

The header callout in `autonomous.conf.example` is the load-bearing operator-facing artifact.
Any operator who pulls this version without reading it and runs gemini or kiro will reproduce
exactly the silent fabrication failure mode that #134/#136 fixed. README + the per-CLI conf
blocks reinforce the requirement.
