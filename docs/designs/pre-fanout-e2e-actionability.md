# Pre-fan-out E2E actionability

## Problem

INV-46 treats every non-zero E2E lane result as a code defect. Some project
adapters use one non-zero exit code for both code failures and operator/runtime
failures, so the exit code cannot safely decide whether DEV should run. Because
the gate exits before review fan-out, it also lacks the Reviewed HEAD evidence
that INV-98 uses to avoid re-reviewing the same commit.

## Smallest native extension

The review wrapper creates a private per-run E2E lane directory and exports
`E2E_FAILURE_CLASSIFICATION_FILE`, whose value is exactly
`$lane_dir/e2e-failure-classification`. Both command and browser integrations
inherit it. On a non-zero lane result an integration may atomically rename a
regular file into that path containing exactly one of:

```text
dev-actionable=true
dev-actionable=false
```

Absence preserves the historical fail-open `true`. Presence is accepted only
for a non-symlink regular file no larger than 1 KiB with the exact one-line
grammar. Every unsafe or invalid present object resolves fail-closed to
`dev-actionable=false`. The wrapper never derives actionability from exit codes,
logs, evidence prose, or agent judgment.

Before moving `reviewing` to `pending-dev`, an E2E failure must durably write the
strict issue/full-HEAD/self-authored pre-fan-out disposition
`result=e2e-failed`, followed by INV-92's `failed-substantive` trailer carrying
the classification. The disposition deliberately has no actionability field:
it only proves that this HEAD completed a terminal pre-fan-out decision, while
INV-92 remains the single durable actionability authority. Any required write
failure leaves the issue out of `pending-dev`.

The dispatcher then uses its existing same-HEAD verdict-aware recovery:
`dev-actionable=true` reaches the bounded correction route and
`dev-actionable=false` reaches the INV-92 operator/stall route. A changed HEAD
remains review-owned. Conflict, convergence, request-changes, retry, and strict
linkage machinery remain unchanged.
