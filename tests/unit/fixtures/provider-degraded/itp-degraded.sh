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
