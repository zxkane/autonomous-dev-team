#!/bin/bash
# tests/unit/fixtures/provider-fbdisp-noleaf/chp-fbdispnoleaf.sh
#
# NAMED fake NON-GitHub CHP provider for the #346 fail-loud disposition tests
# (TC-FBDISP-010/011). Selected through the PUBLIC seam: CODE_HOST=fbdispnoleaf +
# AUTONOMOUS_PROVIDERS_DIR=<this dir>. Pairs with chp-fbdispnoleaf.caps
# (review_bots=1 so the drain_agent_bot_triggers review_bots short-circuit does NOT
# fire first — the broker must reach the leaf-absent fail-loud gate this fixture
# exercises).
#
# It DELIBERATELY OMITS the chp_fbdispnoleaf_create_pr and
# chp_fbdispnoleaf_trigger_bot leaves — so `chp_has_leaf create_pr` /
# `chp_has_leaf trigger_bot` return false on this backend, driving the
# CODE_HOST != github fail-loud branch (no raw GitHub call).
#
# It DOES define chp_fbdispnoleaf_pr_list so the brokers' PR-existence /
# PR-number reads resolve (the bot-trigger broker skips before the loop if no PR
# is found; the pr-create broker treats an empty list as "no existing PR" and
# proceeds to the create branch — reaching the fail-loud gate under test).

# For drain_agent_pr_create the existence COUNT read must return 0 (no existing PR
# → proceed to create). For drain_agent_bot_triggers the PR-number read must return
# a number (so the broker reaches the posting gate). The verb forwards `--json`/`-q`
# from the caller; emit a fixed one-PR array so the caller's own jq selector picks
# it up for the number read, while the pr-create existence COUNT selector (…| length
# over a body not mentioning #<issue>) yields 0.
chp_fbdispnoleaf_pr_list() {
  # Emit a single open PR whose body does NOT mention the issue number, then let the
  # caller's own `-q` selector run. The pr-create broker's existence selector
  # (select(.body|test("#N")) | length) → 0; the bot-trigger broker's number selector
  # ((.[0].number // empty)) → 4242 (first element). Route through the same gh args
  # the caller passes, but with a canned JSON body via a here-string to jq.
  local args=("$@") jq_q="" i
  # Extract the caller's `-q <selector>` (last one wins).
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in -q|--jq) jq_q="${args[$((i+1))]}" ;; esac
  done
  # The canned PR body is env-configurable so one fixture serves BOTH broker reads:
  #   - drain_agent_pr_create existence COUNT wants a body that does NOT mention
  #     #<issue> (→ count 0 → proceed to create). Default.
  #   - drain_agent_bot_triggers PR-NUMBER read wants a body that DOES mention
  #     #<issue> (→ number 4242). Set CHP_FBDISP_PR_BODY to include the ref.
  local body="${CHP_FBDISP_PR_BODY:-a PR body that does not mention the issue}"
  local canned
  canned=$(jq -cn --arg b "$body" '[{"number":4242,"body":$b}]')
  if [[ -n "$jq_q" ]]; then
    printf '%s' "$canned" | jq -r "$jq_q"
  else
    printf '%s\n' "$canned"
  fi
}
