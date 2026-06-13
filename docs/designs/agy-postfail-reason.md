# Design: distinguish "verdict post failed" from "never reviewed" — post-failed drop reason (INV-69)

> INV number: INV-66 is the current max on main; sibling un-merged PRs race
> INV-67 (#242 error-envelope **and** #243 metrics — a known collision),
> INV-68 (#244 conformance), and INV-69 (#245 redispatch-log-retention, already
> committed on its branch). INV-69 is the next free number; it MAY shift at merge
> time and the final renumber follows the sibling-first rule (the lower number
> stays with whichever PR lands first).

Issue #247. The explicitly-deferred follow-up from #202. Every review CLI posts
its verdict through the single deterministic helper `scripts/post-verdict.sh`
([INV-56](../pipeline/invariants.md)). When that helper's underlying
`gh issue comment` returns non-zero, it correctly exits 1 — but on the **default
agent-self-post path** the helper runs **inside the agent's own session**, so its
non-zero exit is observed by the *agent*, never by the wrapper. The wrapper's
no-verdict resolution (`_classify_noverdict_agent`) keys only on the CLI launch rc
and on comment-absence, so a verdict whose post failed at `gh` time collapses into
the same opaque `unavailable` drop ([INV-40](../pipeline/invariants.md)) as an
agent that never reviewed at all.

**The one wrapper-invoked exception (INV-62 codex stdout-fallback).** There is a
single path where the *wrapper itself* calls `post-verdict.sh` on the agent's
behalf: the codex `codex review` stdout→verdict fallback
(`autonomous-review.sh:1835`, when codex produced review text but did not
self-post). There the wrapper already has the helper's rc directly — and on a
failed post its `else` branch (`autonomous-review.sh:1859-1861`) logs a WARNING
and leaves codex `unavailable`. This design's breadcrumb **unifies both paths**:
that same `post-verdict.sh` invocation (whether agent- or wrapper-launched) writes
the session-keyed breadcrumb on failure, so the CLI-agnostic post-resolution scrape
surfaces a `post-failed` reason for the codex-fallback drop too — without the
fallback branch needing its own bespoke reason plumbing. (The existing WARNING log
stays; the new reason is additive.)

This is structurally identical to the agy/codex/kiro drop-reason gap that
INV-58 / INV-62 / INV-61 already closed for CLI-specific failure modes — except
the failure here is in the **post step** (after the CLI produced its review), and
it is **CLI-agnostic** (all agents share `post-verdict.sh`).

## Goal

When ANY review agent is dropped `unavailable` and its verdict post had failed at
`gh` time, **classify and surface the cause** by reading a breadcrumb the helper
leaves behind:

| breadcrumb | classified reason | surfaced extra |
|---|---|---|
| present for this session id | `post-failed` | the `gh` rc the post failed with |
| absent | `unavailable` (unchanged) | — |

The reason is surfaced in BOTH the `dropped (unavailable)` WARN log line AND the
posted "dropped agent(s)" issue comment, so an operator reading only the wrapper
log can tell "the agent reviewed but its post failed (gh rc N)" apart from "the
agent never reached a verdict."

## Non-goals

- This does NOT change the INV-40 vote. A `post-failed` agent is STILL dropped
  from the unanimous-PASS aggregation exactly as `unavailable` is today — it
  posted no classifiable verdict comment, so it cannot be a deciding vote. The
  classification is **observability only**.
- No auto-retry / re-post / re-dispatch of a post-failed agent. Out of scope; the
  dispatcher re-dispatches on the next tick. Retrying is a larger hardening with
  its own blast radius.
- No re-fetch-to-confirm a rc-0 post actually landed (the "gh exits 0 but comment
  doesn't appear" mode). That belongs to the redesign's verdict-artifact channel
  (#233) / per-CLI adapters (#232). This issue surfaces ONLY the case `gh` itself
  reported as failed (rc != 0).

## Design

### Breadcrumb channel (`post-verdict.sh`)

The helper already knows everything needed: the issue number, agent name, session
id (5th arg), and the `gh` rc. On a failed post it writes a small breadcrumb at a
**deterministic, session-keyed path** the wrapper can reconstruct — exactly the
pattern agy's `--log-file` uses (`pid_dir_for_project()/agy-log-<session_id>.log`):

```
pid_dir_for_project()/verdict-postfail-<session_id>
```

- `post-verdict.sh` already sources `autonomous.conf` (which sets `PROJECT_ID`);
  it additionally sources `lib-config.sh` to call `pid_dir_for_project`. A
  missing/failed pid-dir resolution **skips the breadcrumb silently** — the
  helper still exits 1 on the underlying post failure (the breadcrumb is a
  diagnostic, never load-bearing for the exit code).
- Mode 0600, under the existing 0700 pid dir. Content records issue / agent /
  session / gh rc (one `key=value` per line) for the human-facing phrase.
- Best-effort: a breadcrumb-write failure must NOT change the helper's exit code
  or abort it (`set -e` safety — the write is guarded).
- Written ONLY on post failure (rc != 0). A successful post writes nothing.

### New lib `lib-review-postfail.sh`

Mirrors `lib-review-agy.sh` (a CLI-specific review-side lib, unit-testable in
isolation; verdict/GitHub knowledge stays out of the CLI-agnostic `lib-agent.sh`).
Unlike the agy/codex/kiro libs it is **CLI-agnostic** — it keys on a session id,
not on a per-CLI log.

```
_postfail_breadcrumb_path <session_id>      # echoes pid_dir_for_project()/verdict-postfail-<session_id>
_classify_postfail_drop_reason <session_id> # echoes `post-failed[:gh-rc <n>]` iff the breadcrumb exists, else empty
_postfail_drop_reason_phrase <reason-token> # e.g. "post-failed:gh-rc 1" → "post-failed (verdict comment post failed; gh rc 1 — transient GitHub/API or token error)"
```

- All three return **rc 0 always** and are fail-safe: a missing / empty /
  unreadable breadcrumb → empty token (the caller keeps the bare `unavailable`).
  Load-bearing: the wrapper runs under `set -euo pipefail`, and a non-zero `$(…)`
  inside the `_dropped_reasons` append would abort the wrapper mid-loop and strand
  the issue in `reviewing`.
- `grep`-based, single pass; no jq (the breadcrumb is plain `key=value` lines).

### Wrapper wiring (`autonomous-review.sh`)

1. **No per-agent capture needed at fan-out.** The breadcrumb path is fully
   derivable from the agent's session id (`AGENT_SESSION_IDS[$_i]`), which the
   wrapper already holds — so, unlike the agy log capture, there is no new
   `AGENT_*_LOGS` array. (The breadcrumb is written later, by the agent's
   `post-verdict.sh` call, not at fan-out time.)
2. **Augment the drop reason post-resolution, CLI-agnostic, FIRST.** In the loop
   that builds `_dropped_agents` / `_dropped_reasons`, for any `unavailable` agent,
   call `_classify_postfail_drop_reason "${AGENT_SESSION_IDS[$_i]}"` **before** the
   per-CLI `if [[ agy ]] … elif [[ codex ]] …` chain. A confirmed post failure is
   the most specific, most actionable reason, so it takes precedence: if the
   breadcrumb is present, attach the `post-failed` phrase and skip the per-CLI
   scrape for that agent; otherwise fall through to the existing per-CLI branches
   unchanged.

### Aggregation unchanged

`_classify_noverdict_agent` / `_aggregate_review_verdicts` are NOT touched — a
post-failed agent still resolves to `unavailable` (dropped). The new
classification is layered purely on the human-visible breadcrumb path.

## Files

- `skills/autonomous-dispatcher/scripts/post-verdict.sh` — source `lib-config.sh`; write the session-keyed breadcrumb on a failed `gh` post (still exit 1)
- `skills/autonomous-dispatcher/scripts/lib-review-postfail.sh` — NEW (path helper + classifier + phrase helper)
- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` — source the lib; attach the post-failed reason (CLI-agnostic, ahead of the per-CLI scrapers)
- `docs/pipeline/invariants.md` — INV-69 (number may shift at merge time; sibling PRs hold INV-67 ×2 (#228/#231), INV-68 (#244), INV-69 (#245) — see the header note)
- `docs/pipeline/review-agent-flow.md` — breadcrumb + drop-reason walkthrough
- `.github/workflows/ci.yml` — add `lib-review-postfail.sh` to the shellcheck list
- `tests/unit/test-lib-review-postfail.sh` — NEW
- `tests/unit/test-post-verdict.sh` — EXTEND (breadcrumb written on failed post / not on success)
- `docs/test-cases/agy-postfail-reason.md` — NEW

## Post-install / upgrade

This PR **ADDS** `scripts/lib-review-postfail.sh`. After merge + `npx skills update -g`,
re-run `install-project-hooks.sh` on every onboarded project (CLAUDE.local.md →
Post-merge Step 2) or their review wrappers crash on the missing `source`.
