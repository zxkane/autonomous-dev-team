# Design Canvas: Token Budget Gates

Feature: Per-invocation and cumulative issue token budgets
Issue: #506
Date: 2026-07-18
Status: Approved (autonomous mode)

## Scope

Add post-run token enforcement to the dev and review wrappers and cumulative
pre-dispatch admission to all dispatcher launch paths. The implementation
consumes the merged INV-139 accounting API and INV-140 terminal-intent API
without changing either protocol.

Out of scope:

- Streaming termination of a running agent.
- A second token parser or token ledger.
- Summing internal codex review reruns.
- Accounting browser-E2E and smoke-probe review invocations that have no
  existing INV-70 usage emit.
- Turn budgets, pricing, or dollar budgets.

## Components

```text
autonomous-dev.sh --------+
                          |
autonomous-review.sh -----+--> lib-token-budget.sh
                          |      |-- pure config and comparisons
dispatcher-tick.sh -------+      |-- strict metrics-to-accounting commit
lib-dispatch.sh ----------+      |-- reconcile/orphan/query projection
                                 |-- warning breadcrumb deduplication
                                 `-- dispatcher terminal admission
                                            |
                 +--------------------------+-------------------------+
                 |                          |                         |
          lib-metrics.sh             lib-accounting.sh       lib-terminal-control.sh
          parse only                 strict authority         durable terminal route
```

`lib-token-budget.sh` is side-effect free when sourced. Pure helpers validate
configuration, classify adapters, compare completed usage (`>`) and admission
usage (`>=`), derive issue-intent identities, and parse warning keys. Impure
helpers call only the established accounting, terminal-control, dispatch
marker, and provider seams so tests can replace those functions.

## Invocation Data Flow

```text
before launch
  validate config and adapter
  derive invocation id from RUN_ID/side/member UUID/attempt
  accounting_start
  capture fresh log offset (dev only)

agent runs to completion (never killed by this feature)

after launch
  metrics_parse_tokens(log, offset)
  accounting_commit_usage OR accounting_commit_unknown
  retain normalized result for wrapper cleanup/routing
```

Dev attempts use ordinals 1 and 2 within one wrapper run. Review members use
their existing session UUID as `member_id`, with attempt 1. Internal codex
reruns remain inside one review invocation and retain last-record parser
semantics.

## Projection Data Flow

```text
accounting_reconcile(issue)
  -> query open invocations
  -> commit prior-run opens as orphaned-by-crash
  -> accounting_admission_query(issue)
  -> normalize incomplete or mechanism failure to unavailable
```

An open invocation from `CURRENT_RUN_ID` is not swept. With no current run,
every open record is an orphan. Unknown and corrupt histories remain
fail-closed classes. Under `remote-aws-ssm`, dispatcher projections execute
synchronously on the execution host; transport failure becomes unavailable
and never falls back to controller-local storage.

## Decisions And Routing

| Observer | Complete boundary | `usage-unknown` / `corrupt` in hard mode | `unavailable` in hard mode |
|---|---:|---|---|
| Dev cleanup | `measured > limit` | write intent, existing cleanup stalls | log and keep normal cleanup |
| Review pre-approve | `measured > limit` | write intent, explicitly stall | hold at `pending-review` |
| Dispatcher pre-launch | `measured >= limit` | write issue intent, stall | release marker and retry next tick |

Invocation-level intents use the invocation ID for both intent and invocation.
Issue-level intents use
`token-cap-issue-<first-12-of-source_digest>` and the full digest. Dispatcher
ownership markers remain held until the terminal transition finishes. A
wrong-owner pending transition clears the just-written intent before release.

Warn mode posts one parsed-key breadcrumb for `(issue, scope, limit)` and never
changes routing. Side and measured evidence remain visible in the marker but
do not participate in deduplication.

## Failure Modes

- Invalid configured budget or mode: loud nonzero refusal before launch or
  dispatch mutation.
- Hard mode with an unaccountable adapter: loud pre-launch refusal.
  Accountability is an allowlist (`claude|codex`); all current and future
  alternatives remain unavailable until `metrics_parse_tokens` supports them.
- `accounting_start` failure: hard refuses the launch; warn runs degraded.
- Commit failure: loud; warn proceeds, hard routes as usage unknown.
- Invocation intent-write failure: stage a trusted pending marker before the
  INV-140 write; Step 5 retries unresolved markers before crash routing and
  records a resolved marker after success. Marker parsing is exact whole-body,
  and terminal routing requires an authoritative read confirming that the
  matching generation remains live; a retired generation is resolved without
  replay.
- Projection mechanism failure: normalized unavailable.
- Raced orphan sweep vs a live commit: the later conflicting commit is loud
  and follows the same commit-failure policy.
- Unset budgets: no accounting calls, no admission API calls, and existing
  routing is unchanged.
- A dispatch-marker infrastructure failure retains INV-108's fail-open
  behavior; the admission gate still runs immediately after that acquire call.
- A nested dispatcher configuration refusal propagates to the top-level tick;
  it is never collapsed into a handled/no-PR router result.

## Verification

- Pure helper and impure seam unit tests, including branch coverage above 80
  percent for the new library.
- Source wiring tests for all wrapper launch/commit points and seven dispatcher
  admission sites.
- Hermetic wrapper/dispatcher E2E fixtures for warn, hard, cumulative equality,
  fan-out identity, and crash/restart convergence.
- Spec-drift updates for every new stalled cause.
