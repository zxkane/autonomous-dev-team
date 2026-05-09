# Review-Agent Wrapper Flow

> **Status: scaffold.** This file is filled in by PR-2.

## Purpose

Describes the lifecycle of a single review-agent invocation: from `dispatch-local.sh` spawning `autonomous-review.sh`, through review checklist execution, through merge / send-back decision and the exit trap.

## Outline (filled by PR-2)

1. **Spawn** — same `kill_stale_wrapper` discipline as dev. PID file: `/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUM}.pid`.
2. **PID guard** — same defense as dev wrapper.
3. **Auth setup** — review-agent typically uses Sonnet (vs dev Opus) and a separate App identity.
4. **Mergeability check** — `gh pr view ... --json mergeable` (`MERGEABLE` / `CONFLICTING` / `UNKNOWN`). Rebase procedure on `CONFLICTING`. Wait+retry on `UNKNOWN`.
5. **Requirement drift detection (mandatory pre-diff step)** — read all issue comments for scope changes after the issue was first opened.
6. **Review checklist** — process compliance, code quality, testing, infra, optional bot reviewer verification.
7. **E2E verification** — Chrome DevTools MCP procedure (only if a preview URL is configured).
8. **Acceptance criteria marking** — `mark-issue-checkbox.sh` per criterion, only after verification.
9. **Findings → Decision gate** — `BLOCKING ⇒ FAIL` rule, no middle ground.
10. **Reviewed-HEAD trailer** — wrapper posts `Reviewed HEAD: ` after each verdict so the dispatcher's Step 5b can skip redundant reviews when the PR HEAD didn't change (#53).
11. **Exit trap** — labels: PASS → `approved` (+ auto-merge unless `no-auto-close`); FAIL → `pending-dev`.

## Cross-references

- [`dispatcher-flow.md`](dispatcher-flow.md) — Step 5b's HEAD-SHA comparison depends on the trailer this wrapper posts.
- [`handoffs.md`](handoffs.md) — review-→-dev send-back is one of the five handoff points.
- [`invariants.md`](invariants.md) — Reviewed-HEAD trailer format; decision-gate hard rule.
