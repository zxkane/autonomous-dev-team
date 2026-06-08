# Design: agy quota/auth drop-reason detector (INV-58)

Issue #205. The `agy` (Antigravity CLI) member of a multi-agent review fleet
hits the Antigravity consumer **quota wall** (HTTP 429 `RESOURCE_EXHAUSTED`,
"Individual quota reached") or an **auth failure** ("not logged into Antigravity").
In both cases agy exits with **rc 0** and empty stdout/stderr, posts no verdict,
and the wrapper drops it as an opaque `unavailable` ([INV-40](../pipeline/invariants.md))
— indistinguishable from a CLI launch failure or a genuine no-verdict miss. The
only diagnostic is buried in agy's own `--log-file`
(`pid_dir_for_project()/agy-log-<session_id>.log`).

## Goal

When an agy fan-out agent is dropped `unavailable`, **classify and surface the
cause** by scraping agy's own log:

| log signal | classified reason | surfaced extra |
|---|---|---|
| `RESOURCE_EXHAUSTED (code 429)` / `Individual quota reached` | `quota-exhausted` | the `Resets in <dur>` window when present |
| `not logged into Antigravity` / `Failed to get OAuth token` | `auth-failed` | — |
| neither (genuinely silent) | `unavailable` (unchanged) | — |

The reason is surfaced in BOTH the `Per-agent verdicts` / `dropped (unavailable)`
WARN log line AND the posted "dropped agent(s)" issue comment, so an operator
reading only the wrapper log can tell agy was dropped for quota and roughly when
it recovers.

Secondary fix (same PR): the `Fanning out … (shared model: sonnet)` log line and
the Reviewed-HEAD trailer `model \`${AGENT_REVIEW_MODEL}\`` both print the SHARED
default, not each agent's **per-agent resolved** model (`_resolve_review_agent_model`).
For a per-agent-overridden fleet (`AGENT_REVIEW_MODEL_AGY`) this actively misleads
the operator into suspecting a model-pin bug — so the fan-out line lists the
per-agent resolved model and the trailer renders the representative agent's
resolved model.

## Non-goals

- This does NOT change the INV-40 vote. A `quota-exhausted` / `auth-failed` agy
  is STILL dropped from the unanimous-PASS aggregation exactly as `unavailable`
  is today — the classification is **observability only**. (It is NOT a deciding
  FAIL; a quota wall is an infra condition, not a code rejection. Promoting it to
  a veto would block every merge whenever agy's daily quota is spent, which is
  worse than degrading to the surviving fleet members.)
- No retry/backoff/wait-for-reset. Out of scope; the dispatcher re-dispatches on
  the next tick and agy recovers when its quota window rolls over.
- Codex's analogous gather-burn already has INV-51/53/55; this is the agy-shaped
  sibling for a DIFFERENT failure mode (quota, not gather-burn).

## Design

### New lib `lib-review-agy.sh`

Mirrors `lib-review-codex.sh` (a CLI-specific review-side lib, unit-testable in
isolation; verdict/GitHub knowledge stays out of the CLI-agnostic `lib-agent.sh`).

```
_classify_agy_drop_reason <log_file>
```

- rc 0 always; echoes one token on stdout:
  - `quota-exhausted[:Resets in <dur>]` — when a 429/quota signal is present
    (the reset window is appended after a `:` ONLY when agy printed `Resets in …`);
  - `auth-failed` — when an auth/login signal is present and NO quota signal;
  - empty string — neither signal (caller keeps the bare `unavailable`).
- Quota takes precedence over auth: agy logs the OAuth-token line as a SIDE EFFECT
  of the same failed call that hit the quota wall (both appear in the repro), so
  a log with both is fundamentally a quota drop.
- Fail-safe: missing / empty / unreadable log → empty (never crashes; the wrapper
  runs under `set -euo pipefail`). `grep`-based, single pass; no jq dependency
  (agy emits no JSON stream — mirrors `_agy_capture_conversation`).
- Reset window extraction: `grep -oE 'Resets in [0-9]+[hms]([0-9]+[ms])*([0-9]+s)?'`
  tolerant of `33h48m45s` / `45m10s` / `30s` shapes; whatever agy printed is
  echoed verbatim after the `:`.

A tiny presentation helper formats the reason for humans:

```
_agy_drop_reason_phrase <reason-token>   # e.g. "quota-exhausted:Resets in 33h" → "quota-exhausted (Antigravity 429; resets in 33h)"
```

### Wrapper wiring (`autonomous-review.sh`)

1. **Capture the agy log path per agent.** During fan-out, for `_agent == agy`,
   record `_agy_log_file "$_agent_session_id"` into an `AGENT_AGY_LOGS[$_i]` map
   (the session id is the wrapper's own `_agent_session_id`, so no sidecar
   plumbing is needed — the path is deterministic from the session id + project).
2. **Augment the drop reason post-resolution.** After the post-window sweep, in
   the loop that builds `_dropped_agents`, when an `unavailable` agent is `agy`,
   call `_classify_agy_drop_reason "${AGENT_AGY_LOGS[$_i]}"`. If non-empty, attach
   the phrase to that agent's entry in `_dropped_agents` AND to a parallel
   `_dropped_reasons` accumulator used in the WARN log + the posted comment.
3. **Fix model labels.** Build a `shared model` description that, in multi-agent
   mode, lists each agent's `_resolve_review_agent_model` value (e.g.
   `agy=Gemini 3.5 Flash (High), codex=sonnet`); for the trailer, render the
   representative (first) agent's resolved model.

### Aggregation unchanged

`_classify_noverdict_agent` / `_aggregate_review_verdicts` are NOT touched — a
quota/auth agy still resolves to `unavailable` (dropped). The new classification
is layered purely on the human-visible breadcrumb path.

## Files

- `skills/autonomous-dispatcher/scripts/lib-review-agy.sh` — NEW (detector + phrase helper)
- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` — source the lib; capture agy logs; augment drop reason; fix model labels
- `docs/pipeline/invariants.md` — INV-58
- `docs/pipeline/review-agent-flow.md` — detector + label-fix walkthrough
- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` — note the new diagnostic
- `.github/workflows/ci.yml` — add `lib-review-agy.sh` to shellcheck list
- `tests/unit/test-lib-review-agy.sh` — NEW
- `docs/test-cases/agy-quota-detector.md` — NEW

## Post-install / upgrade

This PR ADDS `scripts/lib-review-agy.sh`. After merge + `npx skills update -g`,
re-run `install-project-hooks.sh` on every onboarded project (CLAUDE.local.md →
Post-merge Step 2) or their review wrappers crash on the missing `source`.
