# Test Cases: Multiple parallel review agents (unanimous-PASS aggregation)

Issue: #166

The review wrapper is too heavy to run end-to-end (it makes live `gh` calls and
spawns agent CLIs), so coverage follows the repo's existing two-pronged style:

1. **Pure aggregation-logic harness** — a self-contained helper that mirrors
   the unanimous-PASS rule, unit-tested over the full truth table.
2. **Source-of-truth greps** — assert the wrapper script contains the
   structural pieces the design requires (config resolution, backgrounded
   fan-out, per-subshell overrides, per-agent jq predicate, aggregation),
   without executing the wrapper.

Test file: `tests/unit/test-autonomous-review-multi-agent.sh`
Prompt discriminator extension: `tests/unit/test-autonomous-review-prompt.sh`

## Aggregation logic (pure helper `_aggregate_review_verdicts`)

The helper takes a list of per-agent outcomes (`pass` / `fail` /
`unavailable`) and prints the aggregate decision: `pass`, `fail`, or
`all-unavailable`.

| ID | Inputs (per-agent outcomes) | Expected aggregate | Rationale |
|----|------------------------------|--------------------|-----------|
| TC-MAR-AGG-01 | `pass pass` | `pass` | unanimous PASS |
| TC-MAR-AGG-02 | `pass fail` | `fail` | one FAIL → aggregated FAIL |
| TC-MAR-AGG-03 | `fail fail` | `fail` | all FAIL → FAIL |
| TC-MAR-AGG-04 | `pass unavailable` | `pass` | decide on available agent |
| TC-MAR-AGG-05 | `unavailable unavailable` | `all-unavailable` | crash fallback |
| TC-MAR-AGG-06 | `unavailable fail` | `fail` | a posted FAIL counts even with one dropped |
| TC-MAR-AGG-07 | `pass` (N=1) | `pass` | single-agent PASS unchanged |
| TC-MAR-AGG-08 | `fail` (N=1) | `fail` | single-agent FAIL unchanged |
| TC-MAR-AGG-09 | `unavailable` (N=1) | `all-unavailable` | single-agent crash → fallback |

## Source-of-truth greps (wrapper structure)

| ID | Assertion |
|----|-----------|
| TC-MAR-SRC-01 | `AGENT_REVIEW_AGENTS` config var is read in the wrapper |
| TC-MAR-SRC-02 | `REVIEW_AGENTS_LIST` resolves to `("$AGENT_CMD")` when `AGENT_REVIEW_AGENTS` is empty (N=1 collapse) |
| TC-MAR-SRC-03 | `build_review_prompt` is defined as a function taking agent name + session id |
| TC-MAR-SRC-04 | the prompt instructs the agent to emit a `Review Agent: <name>` discriminator line |
| TC-MAR-SRC-05a | the fan-out calls `run_agent` inside the per-agent subshell |
| TC-MAR-SRC-05b | the per-agent subshell is backgrounded (`) &`) — required so per-agent `AGENT_CMD` / launcher / `AGENT_PID_FILE` overrides are local to each agent |
| TC-MAR-SRC-06 | each subshell overrides `AGENT_CMD` locally |
| TC-MAR-SRC-07 | each subshell neutralizes the launcher (`AGENT_LAUNCHER_ARGV=()`) for non-claude members (INV-38) |
| TC-MAR-SRC-08 | each subshell does `unset AGENT_PID_FILE` (no PID-file thrash) |
| TC-MAR-SRC-09 | the wrapper `wait`s for the backgrounded agents |
| TC-MAR-SRC-10 | the per-agent verdict jq predicate keys on `Review Agent: ` |
| TC-MAR-SRC-11 | all-unavailable raises `AGENT_EXIT=1` on a genuine CLI crash (rc ≠ 0) |
| TC-MAR-SRC-11b | per-agent rc captured under `set -e` (`run_agent ... \|\| _rc=$?`) so a failing launch's true code is recorded, not masked |
| TC-MAR-SRC-11c | all-unavailable defaults `AGENT_EXIT=0` (clean-but-silent → `failed-substantive`, legacy N=1 parity) |
| TC-MAR-SRC-12 | **no** `emit_verdict_trailer` call inside the per-agent collection loop (exactly one aggregated trailer downstream) |
| TC-MAR-SRC-13 | a dropped-agent summary comment is posted on partial unavailability |
| TC-MAR-SRC-14 | wrapper passes `bash -n` |

## Per-agent discriminator (extends test-autonomous-review-prompt.sh)

| ID | Assertion |
|----|-----------|
| TC-ARP-06 | the review prompt contains the `Review Agent: ` discriminator instruction |
| TC-ARP-07 | the per-agent jq verdict predicate references `Review Agent: ` |

## Backward-compatibility regression sweep (must stay green)

These existing suites must continue to pass unchanged with `AGENT_REVIEW_AGENTS`
unset (single-agent path byte-for-byte equivalent):

- `test-autonomous-review-prompt`
- `test-autonomous-review-verdict-regex`
- `test-autonomous-review-verdict-trailer`
- `test-autonomous-launcher-verdict-fresh`
- `test-autonomous-review-reviewed-head-annotation`
- `test-autonomous-review-auto-merge-failure`
- `test-classify-recent-review-verdict`
- `test-lib-agent-per-side-cmd`
- `test-lib-agent-per-side-launcher`
- `bash -n` on `autonomous-review.sh`

## Acceptance criteria mapping

| Acceptance criterion (issue #166) | Covered by |
|---|---|
| `AGENT_REVIEW_AGENTS` unset → behaves as today | TC-MAR-SRC-02, regression sweep |
| both agents PASS → approved + one passed trailer | TC-MAR-AGG-01, TC-MAR-SRC-12 |
| one FAIL → aggregated FAIL → `−reviewing +pending-dev` | TC-MAR-AGG-02/06 |
| one of two unavailable → WARN + summary + decide on available | TC-MAR-AGG-04, TC-MAR-SRC-13 |
| all unavailable → crash fallback | TC-MAR-AGG-05, TC-MAR-SRC-11 |
| INV-40 added, INV-20 amended, docs synced | docs/pipeline/* (pipeline-docs gate) |
