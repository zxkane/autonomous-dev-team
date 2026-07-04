#!/bin/bash
# tests/unit/fixtures/provider-fbdisp-leaf/chp-fbdispleaf.sh
#
# NAMED fake NON-GitHub CHP provider that DOES implement the create_pr /
# trigger_bot leaves, for the #346 verb-path tests (TC-FBDISP-020/021). Selected
# through the PUBLIC seam: CODE_HOST=fbdispleaf + AUTONOMOUS_PROVIDERS_DIR=<this dir>.
# Pairs with chp-fbdispleaf.caps (review_bots=1).
#
# The leaves RECORD their argv to a sentinel file (CHP_FBDISP_LEAF_LOG) so the test
# can assert the broker took the VERB path — NOT the raw `gh`/`gh-as-user.sh`
# fallback. A non-GitHub backend WITH the leaf must route through the verb.
chp_fbdispleaf_pr_list() {
  local args=("$@") jq_q="" i
  for ((i=0; i<${#args[@]}; i++)); do
    case "${args[$i]}" in -q|--jq) jq_q="${args[$((i+1))]}" ;; esac
  done
  local body="${CHP_FBDISP_PR_BODY:-a PR body that does not mention the issue}"
  local canned
  canned=$(jq -cn --arg b "$body" '[{"number":4242,"body":$b}]')
  if [[ -n "$jq_q" ]]; then printf '%s' "$canned" | jq -r "$jq_q"; else printf '%s\n' "$canned"; fi
}

chp_fbdispleaf_create_pr() {
  # W1e (#400): positional contract — the broker passes <head> <title> <body>,
  # NOT `--head/--title/--body`. Record all three positionals in the same
  # single-line VERB_CREATE_PR shape the test asserts against.
  local head_branch="$1" title="$2" body="$3"
  printf 'VERB_CREATE_PR %s %s %s\n' "$head_branch" "$title" "$body" \
    >> "${CHP_FBDISP_LEAF_LOG:-/dev/null}"
}

chp_fbdispleaf_trigger_bot() {
  local pr="$1" trigger="$2"
  printf 'VERB_TRIGGER_BOT %s %s\n' "$pr" "$trigger" >> "${CHP_FBDISP_LEAF_LOG:-/dev/null}"
}
