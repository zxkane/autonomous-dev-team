# Design Canvas — Configurable Review Bots (PR-12)

**Branch**: `feat/configurable-review-bots`
**Closes**: nothing (no specific issue — driven by user feedback that hardcoded `/q review` enforcement assumes bot configuration that may not exist downstream).
**Pipeline-docs touched**: none — review-bot enforcement isn't an INV-* invariant.

---

## Problem

Today the autonomous-review wrapper hard-codes Amazon Q Developer review:

- `skills/autonomous-dispatcher/scripts/autonomous-review.sh:295-319` injects a "MANDATORY Q review" block into the review-agent prompt with `/q review` trigger and `amazon-q-developer[bot]` login filter.
- `skills/autonomous-dev/SKILL.md` Step 10 + 11 list `/q review` and `/codex review` as the universe.
- `references/review-commands.md` has both as default in code examples.

Two problems:
1. **Downstream repos may not have Q installed.** The wrapper hangs on the 3-minute polling loop, then "fails" because `Q_COUNT == 0` forever. Annoying false negative.
2. **Codex is documented but not enforced.** Inconsistent with Q.

User wants: **per-project `REVIEW_BOTS` setting**. Configured bots are mandatory (must run + findings resolved). Empty config skips the bot-review step entirely.

## Decision

Replace the hardcoded Q-review block with a **bot registry + loop**:

```bash
# autonomous.conf
REVIEW_BOTS="q codex"   # space-separated short names; empty = skip
```

The dispatcher's review-wrapper templates the prompt with one Q-review-style block per configured bot. Each block uses the bot's trigger phrase and login pattern from a built-in registry; custom bots can be defined via env-var pairs.

## Built-in registry

| Short name | Trigger phrase | Bot login (filter `user.login` in `gh api .../reviews`) |
|---|---|---|
| `q` | `/q review` | `amazon-q-developer[bot]` |
| `codex` | `/codex review` | `codex[bot]` |
| `claude` | `@claude review` | `claude[bot]` |

Note: Claude uses **`@claude review`**, not `/claude review` — that's the actual upstream convention per anthropics/claude-code-action and code.claude.com/docs.

All three require `gh-as-user.sh` for triggering (tested: Q rejects bot triggers; Claude's `allowed_bots` defaults to empty so bot triggers are also blocked unless opted in).

## Custom-bot extension

For users with bots outside the built-in registry, `autonomous.conf` can set:

```bash
REVIEW_BOTS="q codex mycompany"

REVIEW_BOTS_MYCOMPANY_TRIGGER="/mycompany review"
REVIEW_BOTS_MYCOMPANY_LOGIN="mycompany-reviewer[bot]"
```

The lookup falls back to env-var pairs `REVIEW_BOTS_<UPPERCASE>_TRIGGER` and `REVIEW_BOTS_<UPPERCASE>_LOGIN` for any short name not in the built-in registry. Missing env vars → fail-fast at config-validation time (loud error during dispatcher tick).

### Two layers of validation

`parse_review_bots` is called twice, on purpose:

1. **`dispatcher-tick.sh` startup precheck** — before any GitHub API calls or label transitions. A bad value (typo, missing custom env-var pair) aborts the entire tick with `exit 1` and a clear error. No issue gets a label change, no retry counter advances. The single-project tick fails clean; the multi-project wrapper logs the failure for that project and continues with the rest.
2. **`autonomous-review.sh` startup validation** — defense in depth: the wrapper re-validates after sourcing `autonomous.conf`, in case the wrapper is invoked outside the dispatcher (manual run, custom backend).

Without layer 1, a typo would let the tick swap an issue's label to `reviewing` and spawn the wrapper, which then exits 1 — burning a retry slot every tick until `MAX_RETRIES` is hit. The precheck makes config errors loud and reversible.

## Behavior changes

### `autonomous-review.sh` review prompt

Before:
```text
## Amazon Q Developer Review — MANDATORY
... 30 lines of Q-specific instructions ...
```

After:
```text
## Configured Review Bots — MANDATORY
The following bots are configured for this project: q, codex.

For EACH configured bot:
1. Check if a review by that bot exists already.
2. If not, trigger via `bash scripts/gh-as-user.sh pr comment ${PR_NUMBER} --body "<trigger>"`.
3. Poll for the review to appear (every 30s, timeout 3 min).
4. Read inline comments, ensure all threads are resolved.

Per-bot details:
- q     — trigger "/q review",     login "amazon-q-developer[bot]"
- codex — trigger "/codex review", login "codex[bot]"

If the configured bot does not appear within timeout: the PR review FAILS with
status "bot review timeout" and the dispatcher retries on the next tick.
```

When `REVIEW_BOTS=""` (empty): the entire "Configured Review Bots" section is omitted from the prompt. Review continues without bot-review enforcement.

### `lib-review-bots.sh` (new)

Sourced helper providing:

- `parse_review_bots <REVIEW_BOTS>` — echo space-separated short names, validate each is in the registry or has env-var overrides.
- `get_bot_trigger <name>` — echo the trigger phrase or fail.
- `get_bot_login <name>` — echo the bot login or fail.
- `render_bot_review_section` — emit the Markdown block that goes into the review prompt.

### `autonomous-dev` SKILL.md / references

Step 10 / 11 in autonomous-dev/SKILL.md and the per-bot tables in references/review-threads.md and references/review-commands.md become **examples** instead of enumerated truths. They still mention q/codex as the most common cases but with phrasing like "if your project configures Q, then ...".

### `autonomous.conf.example`

Add a new section:

```bash
# === Review Bots ===
# Space-separated short names of bot reviewers that MUST run on every
# PR before the review agent approves. Configured bots are mandatory:
# the review wrapper triggers each, polls for the bot's review to
# appear, and fails the review if any configured bot doesn't respond
# within 3 minutes.
#
# Built-in registry (short names → trigger → bot login):
#   q     → /q review     → amazon-q-developer[bot]
#   codex → /codex review → codex[bot]
#   claude → @claude review → claude[bot]
#
# Empty string disables bot-review enforcement entirely (dev/review
# agents proceed with no bot involvement).
#
# Custom bots: declare REVIEW_BOTS_<UPPERCASE>_TRIGGER and
# REVIEW_BOTS_<UPPERCASE>_LOGIN, then add the short name to REVIEW_BOTS.
REVIEW_BOTS="q"
```

Default of `q` (single bot) preserves current behavior for existing deployments.

## Schema changes summary

| Variable | Where | Purpose |
|---|---|---|
| `REVIEW_BOTS` | autonomous.conf (existing per-project file) | space-separated bot list, or empty |
| `REVIEW_BOTS_<NAME>_TRIGGER` | autonomous.conf (optional) | custom bot trigger phrase |
| `REVIEW_BOTS_<NAME>_LOGIN` | autonomous.conf (optional) | custom bot user.login filter |

For multi-project deployments, the inline-metadata block in dispatcher.conf already accepts arbitrary KEY=value lines (PR-9), so REVIEW_BOTS gets exported the same way as REPO/PROJECT_ID.

## Backwards compatibility

- **Existing single-project deployments** that don't set `REVIEW_BOTS` get the default `q` from `autonomous.conf.example`. Same as before.
- **Existing deployments without Q installed** → previously hit the 3-minute timeout silently; now they explicitly set `REVIEW_BOTS=""` to skip the gate.
- **No format change to `autonomous.conf`** — purely additive variable.

## Tests

`tests/unit/test-lib-review-bots.sh`:

1. `parse_review_bots "q codex"` → `q codex`, both validated.
2. `parse_review_bots ""` → empty, OK (no error).
3. `parse_review_bots "q bogus"` → fail (bogus not in registry, no env override).
4. `parse_review_bots "q mycustom"` with `REVIEW_BOTS_MYCUSTOM_*` set → succeed.
5. `get_bot_trigger q` → `/q review`. `get_bot_login q` → `amazon-q-developer[bot]`.
6. `get_bot_trigger claude` → `@claude review`. (Verifies the @-not-/ rule.)
7. Custom bot via env vars only (not in built-in) → trigger / login resolve correctly.

`tests/unit/test-autonomous-review-prompt.sh` (new — exercises the wrapper's prompt generation):

8. With `REVIEW_BOTS="q"` → prompt contains the q-review block, mentions `/q review` and `amazon-q-developer[bot]`.
9. With `REVIEW_BOTS="q codex"` → both blocks present.
10. With `REVIEW_BOTS=""` → "Configured Review Bots" section absent.
11. With `REVIEW_BOTS="q bogus"` → wrapper fails fast at config validation.

## Out of scope

- Auto-detecting which bots are installed in the GitHub repo. Operators declare what they want; if they declare a bot that isn't installed they get a timeout failure (which the user explicitly requested as the strict semantic).
- `autonomous-dev/SKILL.md` Step 10/11 don't currently invoke the wrapper — they're guidance for the dev agent during development, not the review agent's enforcement loop. We update both to talk in REVIEW_BOTS terms but the actual loop only runs in autonomous-review.sh.
- Per-bot resolved-thread polling timing (we use the existing 3-minute window for all bots).
- Filing a bug about the `_managed_note` cosmetic issue from PR-11c review (separate concern).

## Files touched

New:
- `skills/autonomous-dispatcher/scripts/lib-review-bots.sh`
- `tests/unit/test-lib-review-bots.sh`
- `tests/unit/test-autonomous-review-prompt.sh`
- `docs/designs/configurable-review-bots.md` (this file)

Modified:
- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` (replace hardcoded Q block)
- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` (add REVIEW_BOTS section)
- `skills/autonomous-dev/SKILL.md` (Step 10 / 11 generalized)
- `skills/autonomous-dev/references/review-threads.md` (per-bot table → REVIEW_BOTS-driven)
- `skills/autonomous-dev/references/review-commands.md` (per-bot table → REVIEW_BOTS-driven)
- `skills/autonomous-review/SKILL.md` (Triggering Bot Reviewers subsection updated)

## Risk

Medium-low. The wrapper-side change is isolated to one heredoc block. Existing deployments default to `REVIEW_BOTS="q"` so nothing changes by default. The skill-side changes are documentation-only.
