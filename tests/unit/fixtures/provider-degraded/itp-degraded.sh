#!/bin/bash
# tests/unit/fixtures/provider-degraded/itp-degraded.sh
#
# NAMED degraded fake ITP provider (#280, provider-spec.md §8 fake-provider;
# design-spec §7.4 third bullet). Near-empty scaffold — the fake provider exists
# to exercise the caps=0 branches via itp-degraded.caps, not to implement real
# verb leaves. The few leaves it DOES define are only those a caps-branch test
# must traverse to REACH the caps=0 branch under test.
#
# The capability-branch test (test-provider-dispatch.sh TC-030) selects this
# provider through the PUBLIC seam — ISSUE_PROVIDER=degraded +
# AUTONOMOUS_PROVIDERS_DIR=<this dir> — and reads the paired itp-degraded.caps
# via itp_caps (the real provider-selection path), NOT by reading the .caps file
# directly. A downstream caps-branch test that wants leaf dispatch live can stub
# the itp_degraded_<verb> leaves it needs here.

# itp_degraded_read_task ISSUE FIELD [extra gh args…] — task-body READ leaf (#296).
#
# mark-issue-checkbox.sh now fetches the issue body via itp_read_task BEFORE it
# evaluates the body_checkbox capability. Under ISSUE_PROVIDER=degraded that read
# routes here, so without this leaf the script would die at
# `itp_degraded_read_task: command not found` and never reach the body_checkbox=0
# cap-branch the degraded fixture exists to exercise (test-itp-write-leaves.sh
# TC-CAP-CHECKBOX0-BRANCH, test-provider-caps-branches.sh body_checkbox E2E).
#
# The read must SUCCEED and return a body containing the target checkbox so the
# caller's awk rewrite runs and the body_checkbox=0 native-subtask remap is the
# branch reached (NOT a "no body" early-exit). The body is served by the test's
# binary `gh` stub on PATH; this leaf forwards to it byte-identically to the
# github leaf so the gh-stub `gh issue view … --json body` shape is what runs.
itp_degraded_read_task() {
  local issue="$1" field="$2"; shift 2
  gh issue view "$issue" --repo "$REPO" --json "$field" "$@"
}

# ---------------------------------------------------------------------------
# The 9 leaves below (issue #370, R4) give the degraded fixture a REAL
# provider-neutral body for every cap-map.conf row whose governing cap is
# `-` (always-asserted) — so tests/provider-conformance/run-provider-conformance.sh
# has something genuine to assert against instead of universal
# `command not found`. Each mirrors its GitHub counterpart's `gh`/`gh api`
# shape structurally, stripped of GitHub-specific entanglement (the [INV-83]
# token-cache mint in itp_github_resolve_dep, the injection-pre-encode in
# itp_github_label_event_ts) that is NOT part of the provider-neutral
# contract these leaves exist to exercise. `chp_close_keyword` is
# DELIBERATELY excluded — see chp-degraded.sh's header note.
# ---------------------------------------------------------------------------

# itp_degraded_transition_state ISSUE REMOVE ADD — mirrors itp_github_transition_state
# minus the CSV multi-label expansion (out of scope for the conformance check;
# the single-label 3-positional shape is what the runner asserts).
itp_degraded_transition_state() {
  local issue_num="$1" remove="$2" add="$3"
  gh issue edit "$issue_num" --repo "$REPO" --remove-label "$remove" --add-label "$add"
}

# itp_degraded_post_comment ISSUE BODY — mirrors itp_github_post_comment.
itp_degraded_post_comment() {
  local issue_num="$1" body="$2"
  gh issue comment "$issue_num" --repo "$REPO" --body "$body"
}

# itp_degraded_list_comments ISSUE — mirrors itp_github_list_comments' normalized
# [INV-90] shape. degraded's marker_channel=text / distinct_bot_author=0 do not
# change this leaf's OWN contract (those are caller-side branches per spec §4.1);
# the leaf still normalizes to [{id,author,authorKind,body,createdAt}].
itp_degraded_list_comments() {
  local issue="$1"
  gh issue view "$issue" --repo "$REPO" --json comments -q '
    [ .comments[]
      | { id: ( ( (.url // "") | capture("issuecomment-(?<n>[0-9]+)$") | .n | tonumber ) // null ),
          author: (.author.login // null),
          authorKind: "human",
          body: (.body // ""),
          createdAt: (.createdAt // null) }
    ] | sort_by(.createdAt // "")
  '
}

# itp_degraded_provision_states NAME COLOR DESCRIPTION — mirrors
# itp_github_provision_states' existence-probe-then-create shape.
itp_degraded_provision_states() {
  local name="$1" color="$2" description="$3"
  if gh api "repos/${REPO}/labels/${name}" --silent &>/dev/null; then
    echo "  [skip] '$name' already exists"
  else
    gh label create "$name" --repo "$REPO" --color "$color" --description "$description"
    echo "  [created] '$name'"
  fi
}

# itp_degraded_resolve_dep OWNER_REPO NUM OUT_VAR — mirrors itp_github_resolve_dep's
# out-var contract, minus the [INV-83] scoped-token mint (an ITP-side
# entanglement, not part of the provider-neutral lookup contract this leaf
# exists to exercise — the runner's ASSERT is scoped to the same-repo arm,
# which never mints on GitHub either).
itp_degraded_resolve_dep() {
  local owner_repo="$1" num="$2" out_var="$3"
  local _state
  _state=$(gh issue view "$num" --repo "$owner_repo" --json state -q '.state' 2>/dev/null || true)
  printf -v "$out_var" '%s' "$_state"
}

# itp_degraded_label_event_ts ISSUE LABEL — mirrors itp_github_label_event_ts's
# fail-soft (empty-on-any-failure) contract, minus the jq-injection pre-encode
# (a GitHub-transport-specific defense, not part of the provider-neutral
# fail-soft contract this leaf exists to exercise).
itp_degraded_label_event_ts() {
  local issue="$1" label="$2"
  gh api "repos/${REPO}/issues/${issue}/timeline" \
    --jq "map(select(.event == \"labeled\" and .label.name == \"${label}\")) | (.[0].created_at // empty)" \
    2>/dev/null || true
}
