# Design: Verdict Artifact Channel (issue #233, INV-78)

## Problem

Today a review agent's PASS/FAIL verdict travels to the wrapper through a GitHub
**comment**. The wrapper polls the issue comments, matches the agent's verdict by
actor + time-window + the `Review Session:` (INV-20) / `Review Agent:` (INV-40)
trailers, and classifies the first line (`Review PASSED` / `Review findings:`,
lib-review-poll.sh::`_classify_verdict_body`).

That comment-as-channel produced a long incident tail — double-posts, silent
non-posts (the `agy` INV-56 bug), narration false-convergence (codex INV-51/53),
and comment-propagation lag (INV-43 poll-budget scaling). All of it exists only
because the verdict is a *comment*.

The adapter-spec v1 (#229, INV-66) already names the target: §4.3 a `verdict`
axis `{ state ∈ valid|absent|malformed, payloadRef }`, and §5 a typed
**verdict artifact** conforming to `schemas/verdict-artifact.schema.json`. This
issue (#233) makes the wrapper actually *read* that artifact, with comment
scraping kept as an explicitly-logged fallback.

## Scope

**Review side only** (per the issue's Out of Scope): the dev side keeps comment
parsing; comment-fallback is NOT removed (only after #228 metrics show fallback
rate ~0). This change moves the verdict CHANNEL — the absence model
(`absent` → today's bounded-retry/drop) is unchanged.

## Architecture

```
                         ┌─────────────────────────────────────────┐
  build_review_prompt    │ inject VERDICT_ARTIFACT_PATH +           │
  (per agent)            │ atomic-write instructions (tmp+rename)   │
                         └─────────────────────────────────────────┘
                                          │
                                          ▼
  review agent runs ── writes verdict-<agent>.json (atomic) ──┐
       │  (also still posts its human comment via post-verdict.sh)
       ▼                                                       ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │ fan-out join → per-agent verdict resolution (artifact FIRST)       │
  │  1. read artifact at VERDICT_ARTIFACT_PATH                          │
  │     - valid    → pass/fail (verdict-source=artifact)                │
  │     - malformed→ loud error envelope (#231) + treated as absent     │
  │                   for the vote (Clause V1) → drop/timeout-veto      │
  │     - absent   → 2. comment fallback (verdict-source=comment-fallback│
  │                     logged) → today's poll loop / codex stdout path │
  └──────────────────────────────────────────────────────────────────┘
                                          │
                                          ▼
            _aggregate_review_verdicts (INV-40 unanimous-PASS) — UNCHANGED
                                          │
                                          ▼
            wrapper renders ONE aggregate verdict comment + the
            <!-- review-verdict: … --> trailer (INV-35) — UNCHANGED format
            → machine consumers (dev-resume parser, dispatcher INV-03/06/07)
              keep working; pinned by tests in this PR.
```

### Artifact path

Per the issue:
`${XDG_STATE_HOME:-$HOME/.local/state}/autonomous-<project>/runs/<run-id>/verdict-<agent>.json`

- `<project>` = `PROJECT_ID` (the dispatcher's per-project id).
- `<run-id>` = the per-agent minted session UUID (`_agent_session_id`, already the
  `Review Session:` trailer value, INV-20). One subdir per agent run → no
  collision across a multi-codex fleet.
- The wrapper creates the `runs/<run-id>/` dir (mode 0700, owner-only — it can
  contain a findings body) before launch and exports `VERDICT_ARTIFACT_PATH` into
  the agent's environment AND interpolates it into the prompt.

The XDG-state base mirrors the wrapper's existing PID-file convention
(`pid_dir_for_project()` in lib-config.sh), so artifacts live alongside the
pipeline's other per-run state, not in world-readable `/tmp`.

### Reader / validator — `lib-review-artifact.sh` (new)

Pure, sourced lib (mirrors lib-review-poll.sh / lib-review-aggregate.sh) so the
classification is unit-testable without a live agent. Functions:

- `_verdict_artifact_path <project> <run-id>` — echoes the per-agent artifact
  path. Single source of truth shared by the provisioner and the reader so they
  can never diverge.
- `_classify_verdict_artifact <path>` — echoes one of `valid` / `malformed` /
  `absent` (the §4.3 `verdict.state`). Reads the file ONCE (Clause VA5: ignore
  post-read writes — a later write is simply never observed because we cat once),
  validates against `verdict-artifact.schema.json`, and on `valid` ALSO echoes the
  canonicalized JSON on a second line for the caller. Validation backend mirrors
  test-adapter-spec-schemas.sh: prefer `python3 -m jsonschema` (full Draft-07
  conditionals), fall back to a `jq` structural check (required keys, enum
  membership, the FAIL⇔≥1-blocking rule) so it runs on bare CI with no pip.
- `_verdict_from_artifact_json <json>` — echoes `pass` / `fail` from a validated
  artifact's `verdict` field (`PASS`→pass, `FAIL`→fail), feeding the existing
  `_aggregate_review_verdicts` token vocabulary verbatim.
- `_artifact_schema_error <path>` — echoes a one-line human schema-error summary
  for the malformed error envelope (#231).

**Atomic-rename land detection.** The agent is instructed to write
`<path>.tmp.$$` then `rename(2)` to `<path>` (an `mv` on the same filesystem is
atomic). The reader only ever stats/cats the final `<path>`; a half-written
`.tmp` is never the read target, so a torn read is structurally impossible. The
reader reads exactly once and keeps that snapshot — a duplicate/late write that
lands after the read is ignored and logged (Clause VA5).

### Aggregation precedence (artifact > comment)

The fan-out join loop, before the comment poll, resolves each agent's verdict:

1. `_classify_verdict_artifact` on its `VERDICT_ARTIFACT_PATH`.
   - `valid` → set `AGENT_VERDICTS[i]` from the artifact; log
     `verdict-source=artifact agent=<a>`. **No comment poll for this agent** (AC:
     zero comment-list API calls when all agents produce artifacts).
   - `malformed` → emit the loud error envelope (#231), log
     `verdict-source=artifact-malformed`, and **treat as absent for the vote**
     (Clause V1 — never coerced to a silent PASS). The agent then flows into the
     existing no-verdict terminal sweep (`_classify_noverdict_agent`): rc 124/137
     → `timed-out` veto, else `unavailable` drop.
   - `absent` → fall through to the comment fallback.
2. Comment fallback (only for `absent` agents): today's `_run_verdict_poll_loop`
   + codex stdout fallback, exactly as now, but every agent resolved this way is
   logged `verdict-source=comment-fallback agent=<a>` so #228 metrics can measure
   fallback frequency per CLI.
3. Conflicting sources can't both be consumed for one agent: the artifact, when
   `valid`, wins and the comment poll is skipped for that agent (logged). (If an
   agent both writes a valid artifact AND posts a comment, only the artifact is
   read — the comment stays for humans, INV-56.)

The poll loop already skips agents whose `AGENT_VERDICTS[i]` is already set
(`[[ -n … ]] && continue`), so seeding artifact verdicts before the loop gives
"artifact > comment" for free, and the "all agents have artifacts" path makes the
loop's first round find everything already resolved → it breaks immediately with
**zero** `gh issue view --json comments` calls (the AC).

### Malformed = loud (#231 envelope)

A malformed artifact is surfaced via `lib-error.sh` (the #231/#242 operator error
envelope, `class=config`, `surface=issue-comment`) naming the agent and the
schema error — never silently treated as `absent`. The vote treatment is still
`absent` (Clause V1), but the operator sees a distinct, actionable comment + a
`verdict-source=artifact-malformed` log line, distinguishable from a never-wrote
agent.

### post-verdict.sh stays the only comment poster (INV-56)

Unchanged. Agents still post their human-facing verdict comment through it (the
prompt keeps that instruction). The comment is no longer the wrapper's *own*
aggregation parsing surface when an artifact exists — but it remains the
fallback channel and the human record. The wrapper's rendered aggregate comment
(`Review PASSED` / `Review findings:`) and the `<!-- review-verdict: … -->`
trailer are produced by the wrapper post-aggregation and are **format-unchanged**.

## Machine consumers of the comment format (load-bearing — enumerated)

These keep working because #233 does NOT change what the wrapper RENDERS, only
the channel it READS from the agents. Each is pinned by a test in this PR:

| Consumer | What it parses | Where | Pinned by |
|---|---|---|---|
| **dev-resume** | `Review findings:` change-request comment (INV-57 post-approval) | autonomous-dev.sh:391,757 | render-format pin test |
| **dispatcher INV-03/06/07** | `<!-- review-verdict: … -->` HTML trailer (passed / failed-substantive / failed-non-substantive cause=…) | lib-dispatch.sh::`classify_recent_review_verdict` (lib-review-verdict.sh::`emit_verdict_trailer`) | render-format pin test |
| **comment poller (fallback)** | `Review PASSED`/`Review findings:` + `Review Session:`/`Review Agent:` trailers | lib-review-poll.sh | existing tests + fallback-parity test |
| **post-verdict.sh** | composes the canonical first line + trailer | post-verdict.sh | unchanged; existing test-…-verdict-via-helper |

## Out of scope (deferred)

- Dev-side artifact adoption (review-side first; dev follow-up after fleet soak).
- Removing comment-fallback (only after #228 metrics show fallback rate ~0).
- Token scoping / env scrubbing (separate issue).

## Decisions (autonomous, per Decision-Making Guidelines)

- **Reuse the existing #229 schema verbatim** — no new schema file; the artifact
  IS `verdict-artifact.schema.json`. Simpler, single source of truth.
- **Per-agent artifact keyed on the session UUID, not the agent name** — survives
  a multi-codex fleet and matches the INV-20 `Review Session:` identity already
  minted per agent.
- **Validation backend = the same dual python3/jq strategy CI already uses** — no
  new dependency; runs on bare ubuntu-latest.
- **Seed artifact verdicts into `AGENT_VERDICTS` before the poll loop** — reuses
  the loop's existing "already resolved → skip" short-circuit for artifact>comment
  precedence and the zero-comment-poll AC, with minimal new control flow.
