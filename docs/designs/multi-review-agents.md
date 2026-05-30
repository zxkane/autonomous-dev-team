# Design: Multiple parallel review agents with unanimous-PASS aggregation

Issue: #166

## Problem

Today `autonomous-review.sh` runs exactly ONE review agent (`AGENT_REVIEW_CMD`,
default `claude`), builds one prompt with one `SESSION_ID`, polls for one
verdict comment, and acts on that lone verdict. Running two *independent
verdict-reaching* agents (e.g. `agy` + `kiro`) against the same PR and gating
the merge on their agreement would raise confidence before an autonomous
merge — a blocking finding one model misses, the other may catch.

This is distinct from the existing `REVIEW_BOTS` mechanism (`/q review`,
`/codex review`), which triggers *external GitHub bots* whose comments are
read as **input** by the single verdict agent. This feature runs multiple
**verdict-reaching** agents.

## Core technical problem — per-agent verdict attribution

Verdict detection (INV-20) selects the `last` comment matching
`author == BOT_LOGIN` + `createdAt >= WRAPPER_START_TS` + body contains
`Review Session`. With N agents under the **same** GitHub identity (the
`GH_AUTH_MODE=token` common case; even app-mode shares
`REVIEW_AGENT_APP_ID`), all N verdict comments share the same author and
`Review Session` trailer, so `last` collapses them to one.

**Fix:** mint a distinct `SESSION_ID` per agent and instruct each agent to end
its verdict comment with a `Review Agent: <name>` discriminator line (in
addition to the retained `Review Session: <uuid>`). The wrapper runs one jq
query per agent keyed on `Review Agent: <name>`, taking `last` per agent. The
per-agent UUID remains the `BOT_LOGIN`-empty fallback narrowing predicate.

## Locked design decisions (from the issue)

1. **Unanimous PASS** — aggregated verdict is PASS iff **every available
   agent** passed; any single FAIL → aggregated FAIL → existing
   `−reviewing +pending-dev` path. Matches decision-gate "any blocking
   finding → FAIL".
2. **Single wrapper fans out internally** — `autonomous-review.sh` spawns all
   agents itself (parallel subshells); dispatcher / PID file / `reviewing`
   label unchanged.
3. **Unavailable = CLI launch failure OR no verdict comment in the poll
   window** → dropped from the vote with a WARN (a FAIL it *did* post still
   counts). If **all** agents are unavailable → fall back to today's
   single-agent crash path verbatim.

## Architecture

```
                        ┌──────────────────────────────────────────┐
                        │ autonomous-review.sh (single wrapper)      │
                        │  one PID file (review-N.pid), reviewing    │
                        │  label — UNCHANGED                         │
                        └──────────────────────────────────────────┘
                                          │
              REVIEW_AGENTS_LIST=(agy kiro)│  (empty AGENT_REVIEW_AGENTS
                                          │   → ("$AGENT_CMD"), N=1 legacy)
            ┌─────────────────────────────┼─────────────────────────────┐
            │ subshell: agy               │ subshell: kiro               │
            │  AGENT_CMD=agy              │  AGENT_CMD=kiro              │
            │  SESSION_ID=<uuid-a>        │  SESSION_ID=<uuid-k>        │
            │  AGENT_LAUNCHER_ARGV=()     │  AGENT_LAUNCHER_ARGV=()     │
            │  unset AGENT_PID_FILE       │  unset AGENT_PID_FILE       │
            │  log=/tmp/...-review-N-agy  │  log=/tmp/...-review-N-kiro │
            │  PROMPT=build_review_prompt │  PROMPT=build_review_prompt │
            │    agy <uuid-a>             │    kiro <uuid-k>            │
            │  run_agent ... &            │  run_agent ... &            │
            └─────────────────────────────┴─────────────────────────────┘
                                          │ wait
            ┌─────────────────────────────┴─────────────────────────────┐
            │ collect: per-agent jq query keyed on `Review Agent: <n>`   │
            │  classify each: FAIL-first then PASS (existing 2-step)      │
            │  unavailable = launch-failed OR no verdict comment          │
            └─────────────────────────────┬─────────────────────────────┘
                                          │ aggregate (unanimous PASS)
            ┌─────────────────────────────┴─────────────────────────────┐
            │ set PASSED_VERDICT / LATEST_COMMENT / AGENT_EXIT            │
            │  → existing downstream PASS / FAIL / crash branches run     │
            │    UNCHANGED (exactly ONE INV-35 trailer, ONE INV-04 trailer)│
            └─────────────────────────────────────────────────────────────┘
```

### Backward compatibility (N=1)

`AGENT_REVIEW_AGENTS` empty/unset resolves `REVIEW_AGENTS_LIST` to
`("$AGENT_CMD")`. With one element, the fan-out still uses a subshell per
agent, but:
- The per-subshell `AGENT_CMD` override equals the already-rebound
  `$AGENT_CMD` (`$AGENT_REVIEW_CMD`), so dispatch is unchanged.
- `AGENT_LAUNCHER_ARGV` is preserved for the single agent if it equals
  `$AGENT_CMD` (claude with launcher still works); neutralized only for
  *additional* non-claude members.
- The per-agent jq query keyed on `Review Agent: <name>` still resolves
  because `build_review_prompt` always emits the discriminator. The legacy
  single-agent verdict path is preserved byte-for-byte in terms of label
  transitions, trailers, and approve/merge.

### Per-agent SESSION_ID and prompt

`build_review_prompt <agent_name> <agent_session_id>` is the existing prompt
heredoc, parameterized so:
- `SESSION_ID` references the per-agent value (the `Review Session:` trailer).
- A new instruction tells the agent to end its verdict comment with
  `Review Agent: <agent_name>` on its own line.
- The kiro-checklist branch keys on the per-agent name, not the global
  `$AGENT_CMD`, so a mixed `agy kiro` list gives kiro the kiro checklist and
  agy the full checklist.

### Fan-out (parallel subshells)

For each agent in `REVIEW_AGENTS_LIST`, a subshell:
- overrides `AGENT_CMD="$agent"` locally,
- mints its own `SESSION_ID` via `uuidgen`,
- neutralizes `AGENT_LAUNCHER_ARGV=()` when the member is NOT `claude`
  (INV-38: a claude-only launcher must not wrap a non-claude CLI),
- `unset AGENT_PID_FILE` so the per-subshell `run_agent` does not thrash the
  single shared `review-N.pid` (the wrapper owns that file; agents must not
  rewrite it),
- writes to its own log `/tmp/agent-${PROJECT_ID}-review-${N}-${agent}.log`,
- builds its prompt via `build_review_prompt "$agent" "$SESSION_ID"`,
- backgrounds `run_agent ... &`.

`wait` blocks for all. Each subshell records its CLI exit code and its
per-agent `(name, session_id)` so the collection step can query per agent.
Subshell↔parent communication uses a per-agent sidecar file (the subshell
cannot mutate parent variables) holding `exit_code` + `session_id`.

### Verdict collection (per agent)

For each agent, one jq query identical in shape to today's INV-20 predicate
plus the `Review Agent: <name>` discriminator:

- BOT_LOGIN known: `author.login == BOT_LOGIN AND createdAt >= WRAPPER_START_TS
  AND body matches /Review Session/ AND body matches /Review Agent: <name>/`,
  take `last`.
- BOT_LOGIN empty (fallback): drop actor, keep window + the per-agent
  `Review Session.*<that-agent's-session-id>` narrowing.

Each collected comment is classified with the existing two-step FAIL-first
rule. An agent is **unavailable** when its subshell launch failed (non-zero
CLI exit) AND it produced no classifiable verdict comment. A FAIL it *did*
post counts even if the CLI also exited non-zero (the verdict is authoritative).

### Aggregation (unanimous PASS)

- Deciding agents = those that produced a classifiable verdict.
- Aggregated PASS iff ≥1 deciding agent AND every deciding agent PASSED AND
  no deciding agent FAILED.
- Any deciding FAIL → aggregated FAIL.
- Zero deciding agents (all unavailable) → aggregated "all-unavailable":
  set `LATEST_COMMENT=""` and fall back to today's single-agent FAIL path.
  `AGENT_EXIT` preserves the legacy distinction so the N=1 path is
  byte-for-byte: `AGENT_EXIT=1` when any agent's CLI actually crashed
  (rc ≠ 0) → crash-fallback comment + `failed-non-substantive other`;
  `AGENT_EXIT=0` when every agent exited cleanly but posted no verdict →
  no crash comment + `failed-substantive`. Both route `−reviewing +pending-dev`.

The aggregation writes the existing `PASSED_VERDICT` (true/false),
`LATEST_COMMENT` (a synthesized human-readable aggregate used only for the
FAIL-finding flow and for the Reviewed-HEAD trailer gate), and `AGENT_EXIT`,
so the downstream PASS / FAIL / crash branches and the four
`emit_verdict_trailer` call sites run unchanged. Exactly **one** aggregated
INV-35 trailer and **one** INV-04 Reviewed-HEAD trailer are emitted.

### Partial unavailability

When some (but not all) agents are unavailable, the wrapper posts ONE
human-visible issue comment listing dropped vs. deciding agents and logs a
WARN. The decision is made on the deciding agents' verdicts under the same
unanimous-PASS rule.

## Invariant impact

- **NEW INV-40** — multi-agent attribution + unanimous aggregation +
  all-unavailable fallback.
- **Amend INV-20** — the verdict-authenticity trailer layer becomes per-agent
  (`Review Agent: <name>`), with an explicit N=1-unchanged carve-out.
- `reviewing` stays a single label; multi-agent is internal to the wrapper
  (state-machine.md, handoffs.md).

## Out of scope (documented follow-up)

Per-agent model map / per-agent extra-args (all listed agents currently share
`AGENT_REVIEW_MODEL`).
