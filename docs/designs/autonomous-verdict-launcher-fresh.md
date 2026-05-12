# Verdict-detection + cc-launcher + prompt_too_long fallback

Three independent fixes bundled in one PR. They share files (`autonomous-{dev,review}.sh`, `lib-agent.sh`, `lib-dispatch.sh`, `autonomous.conf.example`) so a single review pass is more efficient than three.

## Background — observed failure on a downstream consumer

A downstream consumer running this dispatcher reported an issue stuck in a `dev → review → dev → review` ping-pong every ~20 minutes for 12+ hours. Every dev tick exited 0 ("PR found, moving to pending-review"); every review tick exited 0 too but its label flip ended up at `pending-dev` instead of `approved`. Investigation surfaced three independent bugs that compound:

1. **Review wrapper's verdict detector binds to the wrapper-minted session UUID**; the agent inside posted its verdict comment with a *fresh* UUID it minted itself. The wrapper polled for `Review Session.*${WRAPPER_SID}` for 30s, never matched, declared "Review FAILED or inconclusive", flipped to `pending-dev`. The dev agent then ran, saw the PR was already there, handed back to review — infinite loop.
2. **`AGENT_DEV_MODEL=opus[1m]` and `AGENT_REVIEW_MODEL=sonnet[1m]` silently fell back to Haiku 4.5.** The aliases need `ANTHROPIC_DEFAULT_OPUS_MODEL` / `ANTHROPIC_DEFAULT_SONNET_MODEL` env to map to Bedrock IDs. The dispatcher spawns `nohup` non-interactive shells which don't source the user's `.bash_aliases` / `.zshrc`, so those env vars were absent. Wrappers ran code review and dev work on Haiku — quality dropped without anyone noticing.
3. **`is_session_completed` only treats `terminal_reason=completed` as terminal.** A session that died on `prompt_too_long` is "not completed" by that test, so the dispatcher keeps re-running `claude --resume <id>` forever. Each resume re-feeds the entire JSONL transcript (headless `claude -p` has no auto-compact — verified upstream), so once over the limit it stays over the limit. The existing `autonomous-dev.sh` fallback path (line 347–405) already handles this case correctly by minting a fresh session, but it only fires when `resume_agent` exits non-zero — and the dispatcher's `is_session_completed` short-circuits before we ever get there in some paths.

None of these are speculative — each has a fingerprint in the consumer's logs (`/tmp/agent-*-issue-*.log`, the issue's comment timeline, the JSONL `modelUsage` field).

## Fix 1 — verdict-detection: actor + time window, drop session-id binding

### Current (broken)

`autonomous-review.sh:490`:
```bash
LATEST_COMMENT=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json comments \
  -q "[.comments[] | select(
        (.body | test(\"Review PASSED|...|Changes requested\"; \"i\")) and
        (.body | test(\"Review Session.*${SESSION_ID}\"))
      )] | last | .body" 2>/dev/null || true)
```

The `Review Session.*${SESSION_ID}` predicate exists "for security so a stray third-party comment can't spoof a verdict" (per the existing comment). But it depends on the **agent** writing back the wrapper's UUID verbatim. In practice the agent often invents its own UUID, especially under aggressive context pressure — which is exactly when this matters most.

### New design

Replace the session-id predicate with three layered predicates that the wrapper itself controls:

1. **Actor binding** — the comment's `author.login` must equal the bot account that this wrapper is authenticated as. Resolved once at wrapper start via `gh api user --jq .login` (works for both PAT and GitHub App auth).
2. **Time window binding** — the comment's `createdAt` must be ≥ the wrapper's start time (captured before `run_agent`, in ISO-8601 UTC).
3. **Body trailer presence** — the comment must contain the literal substring `Review Session` (NOT bound to a specific UUID). The review agent's prompt instructs it to emit this trailer; the wrapper just checks it's there.

The first two are observable to the wrapper without trusting the agent's output. The third is the defense-in-depth layer that matters specifically in `GH_AUTH_MODE=token`: dev and review wrappers share an identity, so the dev agent's status comments could otherwise contain `LGTM` or `Review findings` and pass the actor+window predicate. The trailer requirement excludes them — the dev agent's prompt does not instruct it to emit `Review Session`, and a status comment quoting prior verdicts as conversation history doesn't contain the literal trailer phrase as a structured marker.

```bash
WRAPPER_START_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
_bot_raw=$(gh api user --jq '.login' 2>&1) && BOT_LOGIN="$_bot_raw" || {
  log "WARNING: gh api user failed; falling back to session-id binding. stderr: ${_bot_raw}"
  BOT_LOGIN=""
}
[[ "$BOT_LOGIN" == "null" || -z "$BOT_LOGIN" ]] && BOT_LOGIN=""

# ... after run_agent ...
# Predicate construction:
if [[ -n "$BOT_LOGIN" ]]; then
  _AUTH_PREDICATE="(.author.login == \"${BOT_LOGIN}\") and (.createdAt >= \"${WRAPPER_START_TS}\") and (.body | test(\"Review Session\"))"
else
  _AUTH_PREDICATE="(.createdAt >= \"${WRAPPER_START_TS}\") and (.body | test(\"Review Session.*${SESSION_ID}\"))"
fi
```

If `BOT_LOGIN` is empty (`gh api user` failed, returned empty, or returned the literal string `"null"`), fall back to a tighter trailer match that includes the wrapper's specific `SESSION_ID`. This re-introduces the brittleness this PR was trying to remove, but only on the rare path where actor binding is unavailable, and the time-window predicate still narrows out stale comments.

### Why this is safe in `GH_AUTH_MODE=app`

Each wrapper authenticates as a distinct GitHub App (e.g. `kane-coding-agent[bot]` for dev, `kane-test-agent[bot]` for review). `BOT_LOGIN` resolves to the review-app login, so even if a dev agent posts a comment containing verdict keywords on the same issue, it will be authored by a different login and the actor predicate excludes it. The trailer requirement is defense-in-depth.

### Why this is safe in `GH_AUTH_MODE=token`

Dev and review wrappers share `BOT_LOGIN`, so the actor predicate alone does NOT separate them. The trailer requirement is load-bearing here: only the review agent's prompt instructs it to emit `Review Session: <id>`. A dev agent writing a status comment that contains `LGTM` or `Review findings` will not contain the trailer marker, so the review wrapper's verdict capture excludes it. Time window further narrows to the current review run.

### Why this is safer than the prior session-id binding

The prior code required the agent to echo the wrapper's UUID verbatim (`Review Session.*${SESSION_ID}`). When the agent occasionally rewrote the UUID (observed in production), the regex missed valid verdicts and the wrapper fell through to the FAILED branch. The new design checks for the trailer's *presence* but not its UUID content, eliminating that brittleness while keeping spoof protection through actor + time window.

Existing `tests/unit/test-autonomous-review-verdict-regex.sh` cases TC-RVR-009 and TC-RVR-010 (which assert "no session id" and "wrong session id" → no-match) need updating — under the new model, those comments DO match because the actor and time window are right. New anti-spoof cases will assert "wrong author" and "comment older than wrapper start" → no-match.

### Backward compat

`autonomous-review.sh` still emits a `Review Session: \`${SESSION_ID}\`` trailer for human readability and for the `Reviewed HEAD` audit comment (consumed by `lib-dispatch.sh:last_reviewed_head`). The detector simply no longer requires the agent to echo it back.

## Fix 2 — `AGENT_LAUNCHER` for cc / Bedrock environments

### Problem

`lib-agent.sh:255` runs `env -u CLAUDECODE "$AGENT_CMD" --session-id ... -p ...` — that is, the wrapper invokes the `claude` binary directly. Users whose interactive workflow relies on a shell function or alias (e.g. `cc` in `~/dotfiles/common/.bash_aliases`) lose all the env that function sets: `CLAUDE_CODE_USE_BEDROCK=1`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `AWS_PROFILE`, telemetry tags, etc. The `nohup` non-interactive shell the dispatcher spawns inherits none of it.

### New design

Add an optional `AGENT_LAUNCHER` variable. When set, the claude/codex/kiro/opencode invocation is wrapped through it:

```bash
# autonomous.conf
AGENT_LAUNCHER='bash -c '\''source ~/dotfiles/common/.bash_aliases && exec cc "$@"'\'' --'
```

Empty (default) → today's behavior, unchanged. Direct `claude ...` invocation.

Set → command becomes `<AGENT_LAUNCHER> <AGENT_CMD> <args...>`. The launcher token is `eval`-expanded once when read from conf so users can use single-quoted heredoc-ish forms. The `--` at the end is the conventional `bash -c` boundary for `$@`.

### How autonomous-tag flows through

The wrapper exports `CC_USER` (or any env var the user's launcher reads) before invoking the launcher:

```bash
# autonomous-dev.sh
export CC_USER="autonomous-dev-bot"
export CC_ROLE_KIND="dev"           # for downstream telemetry tagging

# autonomous-review.sh
export CC_USER="autonomous-review-bot"
export CC_ROLE_KIND="review"
```

The user's `cc` function picks these up via the env (it already does `CC_USER="${USER:-unknown}"` style references). This gives downstream telemetry / billing a clean way to attribute autonomous-pipeline traffic separate from interactive work, without anyone needing to change anything other than autonomous.conf.

### Why not just add `ANTHROPIC_*` env to autonomous.conf?

Considered. Rejected because:
- Bedrock model ids change; users who maintain their own `cc` already have a single source of truth.
- Some users use OpenRouter / Mantle / Kimi via `claude-{bedrock,sso,mantle,kimi}` aliases — same launcher pattern, different env. A generic launcher hook is more flexible than a hard-coded ANTHROPIC env passthrough.
- It keeps `autonomous.conf` focused on pipeline policy, not LLM auth.

### Compatibility with codex / kiro / opencode

The launcher prefix is applied uniformly across all four CLI branches in `run_agent` and `resume_agent`. Codex's `_codex_capture_thread` pipe and opencode's `_opencode_capture_session` pipe both still see the same JSON event stream because the launcher is just an env-injection wrapper.

### Why expose the bot identity via `CC_USER`

The user already uses `CC_USER` in their interactive `cc` function (`CC_USER="${USER:-unknown}"`). Reusing it for the bot identity keeps the downstream telemetry one-dimensional — instead of "is this `$USER` or some other tag?", a single `CC_USER` field tells the cost-attribution system whether the traffic was an interactive human session or one of the autonomous bots. Documented as opt-in via `AGENT_LAUNCHER` — wrappers always set `CC_USER` regardless, so users without a launcher get a harmless extra env var.

## Fix 3 — `prompt_too_long` triggers fresh-session fallback early

### Current (resume-forever)

`lib-dispatch.sh:230`:
```bash
fields=$(jq -er '"\(.stop_reason // "")|\(.terminal_reason // "")"' <<<"$last_line") || return 1
[ "$fields" = "end_turn|completed" ]
```

If a session crashed with `terminal_reason=prompt_too_long`, this returns 1 ("not completed"), and the dispatcher's next tick happily issues `claude --resume <id>` again. That re-feeds the whole JSONL — which is what blew us up in the first place — and we crash on `prompt_too_long` again. Loop.

### New design

Treat `terminal_reason=prompt_too_long` (and any other `terminal_reason` known to be unrecoverable via resume) as "session is done — don't resume; force fresh next time".

Two surface changes:

1. `is_session_completed` returns 0 for both `end_turn|completed` AND `*|prompt_too_long`. The dispatcher's tick step that calls it (`dispatcher-tick.sh:241`) already posts an issue comment "session ended, skipping resume — manually transition" when this returns true. New comment text disambiguates: "session ran out of context — next dispatch will start fresh" and it actively *promotes* the issue back to `pending-dev` (so a fresh session runs on the next tick) instead of leaving it stuck.
2. `autonomous-dev.sh` MODE=resume already has a non-zero-exit fallback that mints `NEW_SESSION_ID` and re-runs as new (line 347–405). Strengthen it: post the new session id as a standalone `Dev Session ID: \`${NEW_SESSION_ID}\`` comment (matching the regex in `lib-dispatch.sh:extract_dev_session_id`) **immediately after** `SESSION_ID=$NEW_SESSION_ID`, not just inline as part of "Resume failed (...)". This guarantees the dispatcher picks up the new id even if the wrapper crashes mid-fallback before its trap fires.

### Why not just always force fresh on every tick?

The user has 11M-token windows on opus[1m]/sonnet[1m] and we want to preserve cache hits when the agent is making genuine progress. Resume IS a real optimization — just not when resume itself blew up. So: keep resume as the default, force fresh **only** on the prompt_too_long signal.

### Optional second trigger (future, not in this PR)

"N consecutive resumes with no PR HEAD change → fresh" is also reasonable but adds complexity (need to track resume count per session in a sidecar). Deferring until we see real-world cases that prompt_too_long alone doesn't cover. The dispatcher-tick.sh:373 logic already detects "no new commits since last review" and flips back to pending-dev — that's a related but distinct loop-breaker, and it's already in place.

## Files touched

| File | Why |
|------|-----|
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | verdict detector rewrite (Fix 1) + `CC_USER` export (Fix 2) |
| `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` | `CC_USER` export (Fix 2) + post `Dev Session ID:` after fallback (Fix 3) |
| `skills/autonomous-dispatcher/scripts/lib-agent.sh` | thread `AGENT_LAUNCHER` through `run_agent` / `resume_agent` for all CLI branches (Fix 2) |
| `skills/autonomous-dispatcher/scripts/lib-dispatch.sh` | `is_session_completed` accepts `prompt_too_long` (Fix 3) |
| `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` | `pending-dev` handoff comment text on prompt_too_long (Fix 3) |
| `skills/autonomous-dispatcher/scripts/autonomous.conf.example` | document `AGENT_LAUNCHER`, mention `CC_USER` (Fix 2) |
| `tests/unit/test-autonomous-review-verdict-regex.sh` | update TC-RVR-009/010 for new actor+time-window model, add new anti-spoof cases (Fix 1) |
| `tests/unit/test-autonomous-launcher-verdict-fresh.sh` | new — covers all three fixes end-to-end at unit level (no real `claude` invoked) |
| `docs/designs/autonomous-verdict-launcher-fresh.md` | this document |
| `docs/test-cases/autonomous-verdict-launcher-fresh.md` | test case enumeration |

## Out of scope

- Changing the default to fresh-session per tick (rejected; `--resume` is fine for the common case on 11M-token models).
- A pre-flight model-availability check (would catch the silent Haiku fallback at startup, but adds an HTTP RTT to every wrapper start; revisit if Fix 2 doesn't fully resolve the silent-fallback class).
- Any changes to the SSM-remote dispatcher path; this PR is local-execution-backend specific.
