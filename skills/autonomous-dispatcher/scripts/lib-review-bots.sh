#!/usr/bin/env bash
# lib-review-bots.sh — registry of GitHub PR review bots and helpers.
#
# Replaces the hardcoded /q review enforcement in autonomous-review.sh
# with a configurable per-project REVIEW_BOTS setting (PR-12).
#
# Usage (sourced by autonomous-review.sh):
#
#   source "$SCRIPT_DIR/lib-review-bots.sh"
#   parse_review_bots "$REVIEW_BOTS"      # validates each bot name
#   for bot in $(parse_review_bots "$REVIEW_BOTS"); do
#     trigger=$(get_bot_trigger "$bot")
#     login=$(get_bot_login   "$bot")
#     ...
#   done
#
# Or:
#   render_bot_review_section "$REVIEW_BOTS" "$PR_NUMBER"
#   # echoes the Markdown block for the review-agent prompt.
#
# Built-in registry:
#   q     → trigger "/q review",     login "amazon-q-developer[bot]"
#   codex → trigger "/codex review", login "codex[bot]"
#   claude → trigger "@claude review", login "claude[bot]"
#
# Custom bots: declare REVIEW_BOTS_<UPPERCASE_NAME>_TRIGGER and
# REVIEW_BOTS_<UPPERCASE_NAME>_LOGIN, then include the short name in
# REVIEW_BOTS. Both vars must be set or the bot is rejected.

# Built-in registry — keep these aligned with the table in
# `docs/designs/configurable-review-bots.md`.
_review_bot_trigger_q='/q review'
_review_bot_login_q='amazon-q-developer[bot]'

_review_bot_trigger_codex='/codex review'
_review_bot_login_codex='codex[bot]'

# Claude uses @claude review (not /claude review) — see
# code.claude.com/docs/en/code-review.
_review_bot_trigger_claude='@claude review'
_review_bot_login_claude='claude[bot]'

# parse_review_bots <REVIEW_BOTS-value>
#
# Echoes the validated list of bot short names (whitespace-separated,
# normalized to lowercase). Empty input echoes nothing and returns 0.
# Returns 1 (with a stderr error) if any bot in the list is unknown
# (not in the built-in registry AND no env-var override pair set).
#
# Validation here is fail-fast: an unknown bot in autonomous.conf
# blocks the dispatcher tick, surfacing the typo loudly instead of
# silently dropping the bot.
parse_review_bots() {
  local input="${1:-}"
  local bot bot_lower out=""
  for bot in $input; do
    # Normalize to lowercase so users can write Q / q / Codex / codex.
    bot_lower=$(printf '%s' "$bot" | tr '[:upper:]' '[:lower:]')
    if ! _review_bot_known "$bot_lower"; then
      echo "ERROR: unknown review bot '$bot' in REVIEW_BOTS." >&2
      echo "       Built-in: q, codex, claude." >&2
      echo "       Custom: set REVIEW_BOTS_$(printf '%s' "$bot_lower" | tr '[:lower:]' '[:upper:]')_TRIGGER and _LOGIN." >&2
      return 1
    fi
    out+="$bot_lower "
  done
  printf '%s' "${out% }"
}

# _review_bot_known <lowercase-name>
# Returns 0 if the bot is in the built-in registry OR has both env-var
# overrides set. 1 otherwise.
_review_bot_known() {
  local name="$1"
  case "$name" in
    q|codex|claude) return 0 ;;
  esac
  # Custom bot — both TRIGGER and LOGIN must be set.
  local upper var_trigger var_login trigger_val login_val
  upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  var_trigger="REVIEW_BOTS_${upper}_TRIGGER"
  var_login="REVIEW_BOTS_${upper}_LOGIN"
  trigger_val="${!var_trigger:-}"
  login_val="${!var_login:-}"
  [[ -n "$trigger_val" && -n "$login_val" ]]
}

# get_bot_trigger <name>
# Echo the trigger phrase for the bot. Returns 1 if unknown.
get_bot_trigger() {
  local name="$1"
  case "$name" in
    q)      printf '%s\n' "$_review_bot_trigger_q"      ;;
    codex)  printf '%s\n' "$_review_bot_trigger_codex"  ;;
    claude) printf '%s\n' "$_review_bot_trigger_claude" ;;
    *)
      local upper var
      upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
      var="REVIEW_BOTS_${upper}_TRIGGER"
      if [[ -n "${!var:-}" ]]; then
        printf '%s\n' "${!var}"
      else
        echo "ERROR: no trigger phrase known for bot '$name'" >&2
        return 1
      fi
      ;;
  esac
}

# get_bot_login <name>
# Echo the GitHub user.login string the bot posts as. Returns 1 if
# unknown.
get_bot_login() {
  local name="$1"
  case "$name" in
    q)      printf '%s\n' "$_review_bot_login_q"      ;;
    codex)  printf '%s\n' "$_review_bot_login_codex"  ;;
    claude) printf '%s\n' "$_review_bot_login_claude" ;;
    *)
      local upper var
      upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
      var="REVIEW_BOTS_${upper}_LOGIN"
      if [[ -n "${!var:-}" ]]; then
        printf '%s\n' "${!var}"
      else
        echo "ERROR: no bot login known for bot '$name'" >&2
        return 1
      fi
      ;;
  esac
}

# bot_trigger_allowlist <REVIEW_BOTS-value>
#
# Echoes the exact trigger phrases for the configured bots, one per line. Used by
# the wrapper-side bot-trigger broker (drain_agent_bot_triggers) to restrict what a
# scoped agent can ask the wrapper to post as the host user — only an EXACT
# configured trigger phrase is forwarded ([INV-79], #234 review [P1]: the broker is
# a "review-bot trigger only" exception, not an arbitrary-comment channel). Empty
# REVIEW_BOTS → nothing. Returns non-zero if REVIEW_BOTS does not validate.
bot_trigger_allowlist() {
  local review_bots="$1" bots bot
  bots=$(parse_review_bots "$review_bots") || return $?
  [[ -z "$bots" ]] && return 0
  for bot in $bots; do
    get_bot_trigger "$bot" || return 1
  done
}

# missing_bot_reviews <REVIEW_BOTS-value> <PR_NUMBER> <REPO>
#
# Echoes (one per line) the short-name of every configured bot that has NOT yet
# posted a review on the PR. Empty output = all configured bots have reviewed (or
# REVIEW_BOTS is empty). Used by the wrapper-side hard gate ([INV-79], #234 review
# [P1]): under the scoped scrub the review agent brokers the bot trigger and does
# NOT fail on an absent bot review, so the WRAPPER must block a PASS while a
# mandatory bot review is still missing (re-queue; a later tick sees it present).
#
# Fail-safe: a count failure for a bot counts it as MISSING (block, don't
# fail-open). Returns 0 always (the missing list is the signal).
#
# The per-bot review count routes through the CHP verb `chp_count_reviews_by_login`
# ([INV-94], #324) — the `--paginate` all-pages sum is a GitHub-transport artifact
# encapsulated in the leaf, while the `^[0-9]+$` validation + the `-eq 0` MISSING
# decision STAY here (provider-neutral). The verb is fail-SAFE on ANY failure
# (returns 0 → bot MISSING). The review wrapper sources the CHP seam before calling
# this; the dual `declare -F` guard (the shim AND the bare leaf expr, IDENTICAL to
# the shim's own dispatch) is the safety net for any context where the seam is not
# loaded (CODE_HOST unset, a provider without the leaf): the caller fails-safe to
# `count=0` (bot MISSING), never aborts under `set -e`.
missing_bot_reviews() {
  local review_bots="$1" pr_number="$2" repo="$3" bots bot login count
  bots=$(parse_review_bots "$review_bots" 2>/dev/null) || return 0
  [[ -z "$bots" ]] && return 0
  for bot in $bots; do
    login=$(get_bot_login "$bot" 2>/dev/null) || { printf '%s\n' "$bot"; continue; }
    if declare -F chp_count_reviews_by_login >/dev/null 2>&1 \
       && declare -F "chp_${CODE_HOST}_count_reviews_by_login" >/dev/null 2>&1; then
      count=$(chp_count_reviews_by_login "$repo" "$pr_number" "$login")
    else
      count=0   # leaf/shim absent → MISSING (fail-safe)
    fi
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    [[ "$count" -eq 0 ]] && printf '%s\n' "$bot"
  done
  return 0
}

# render_bot_review_section <REVIEW_BOTS-value> <PR_NUMBER> <REPO>
#
# Echoes the Markdown block to splice into the review-agent prompt.
# Empty REVIEW_BOTS → emits nothing (the entire bot-review section
# is omitted from the prompt — review proceeds without bot involvement).
#
# Builds one mandatory check-trigger-poll loop per configured bot, all
# sharing the existing 3-min poll window. Caller is responsible for
# making sure REVIEW_BOTS validates (parse_review_bots) before calling
# this; render_bot_review_section trusts its input.
render_bot_review_section() {
  local review_bots="$1" pr_number="$2" repo="$3"
  local bots
  bots=$(parse_review_bots "$review_bots") || return $?

  if [[ -z "$bots" ]]; then
    return 0  # caller emits nothing into the prompt
  fi

  # [INV-79] Scoped-token mode: GH_USER_PAT is scrubbed from the review-agent
  # subtree, so the agent CANNOT run gh-as-user.sh itself. When AGENT_GH_TOKEN_FILE
  # is set, the trigger step is BROKERED — the agent writes the trigger phrase to
  # AGENT_BOT_TRIGGER_FILE and the wrapper posts it post-run via gh-as-user.sh
  # (drain_agent_bot_triggers). In that mode the same-run poll can't observe the
  # bot review (the trigger posts after the agent exits), so the prompt tells the
  # agent to broker the trigger and let the NEXT review tick verify — not to FAIL on
  # a same-run timeout. Empty AGENT_GH_TOKEN_FILE (PAT / no-scope) → unchanged
  # direct gh-as-user.sh + same-run poll.
  local scoped=0
  [[ -n "${AGENT_GH_TOKEN_FILE:-}" ]] && scoped=1

  if [[ "$scoped" -eq 1 ]]; then
    cat <<EOF
## Configured Review Bots — MANDATORY

The following bots are configured for this project: ${bots}.

Your token is SCOPED and CANNOT post the real-user bot triggers (\`/q review\` etc.;
those bots reject GitHub-App accounts). Do NOT run \`gh-as-user.sh\` yourself — it
cannot authenticate. For EACH configured bot, before approving:

EOF
    local bot trigger login
    for bot in $bots; do
      trigger=$(get_bot_trigger "$bot")
      login=$(get_bot_login "$bot")
      cat <<EOF
### Bot: ${bot}

- Trigger phrase: \`${trigger}\`
- Bot login (user.login filter): \`${login}\`

Steps:
1. Check if a review by this bot already exists on this PR:
   $(provider_prompt_fragment bots.review_count_check "${repo}" "${pr_number}" "${login}")
2. If COUNT > 0, the bot already reviewed — read its inline comments and verify
   all threads are resolved, then proceed.
3. If COUNT is 0, the bot has not reviewed yet. APPEND the trigger phrase to the
   file in the \`AGENT_BOT_TRIGGER_FILE\` env var (\`\$(printenv AGENT_BOT_TRIGGER_FILE)\`),
   one phrase per line, e.g. \`echo '${trigger}' >> "\$(printenv AGENT_BOT_TRIGGER_FILE)"\`.
   The WRAPPER posts it as a real user after you finish. Do NOT FAIL the review for a
   not-yet-present bot review in this case — the dispatcher re-runs the review on the
   next tick and that run will see the bot's review (COUNT > 0). Note this as
   "awaiting ${bot} review (trigger brokered)" in your verdict reasoning.

EOF
    done
    return 0
  fi

  cat <<EOF
## Configured Review Bots — MANDATORY

The following bots are configured for this project: ${bots}.

For EACH configured bot, perform these steps before approving the PR.
Bots reject \`/<name> review\` triggers from GitHub App bot accounts,
so use \`scripts/gh-as-user.sh\` to post the trigger as a real user.

EOF

  local bot trigger login
  for bot in $bots; do
    trigger=$(get_bot_trigger "$bot")
    login=$(get_bot_login "$bot")
    cat <<EOF
### Bot: ${bot}

- Trigger phrase: \`${trigger}\`
- Bot login (user.login filter): \`${login}\`

Steps:
1. Check if a review by this bot already exists on this PR:
   $(provider_prompt_fragment bots.review_count_check "${repo}" "${pr_number}" "${login}")
2. If COUNT is 0, trigger the bot via gh-as-user.sh:
   \`\`\`bash
   bash scripts/gh-as-user.sh pr comment ${pr_number} --body "${trigger}"
   \`\`\`
3. Poll for the bot's review to appear (every 30s, timeout 3 min):
   \`\`\`bash
   for i in {1..6}; do
     sleep 30
     $(provider_prompt_fragment bots.review_count_check_bare "${repo}" "${pr_number}" "${login}")
     if [[ "\$COUNT" -gt 0 ]]; then break; fi
   done
   \`\`\`
4. If the bot still hasn't reviewed after the timeout, FAIL the PR
   review with status "${bot} review timeout". The dispatcher will
   retry on the next tick.
5. Read inline review comments and verify all threads are resolved.

EOF
  done
}
