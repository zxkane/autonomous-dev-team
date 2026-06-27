#!/bin/bash
# test-provider-dispatch.sh — Unit tests for the ITP/CHP provider dispatch
# skeleton + .caps reader (#280, [INV-87]/[INV-88]/[INV-89]).
#
# Mirrors tests/unit/test-cli-adapters.sh (the [INV-75] adapter precedent):
#   - dispatch routing: itp_<verb> → itp_${ISSUE_PROVIDER}_<verb>,
#     chp_<verb> → chp_${CODE_HOST}_<verb> (default provider = github);
#   - all 13 ITP + 12 CHP shims defined after sourcing (declare -F), like
#     TC-ADAPTER-EXTRACT-013;
#   - the readlink -f-of-BASH_SOURCE skill-tree resolution ([INV-14]/[INV-65]);
#   - the .caps reader parses key=value and NEVER sources the manifest (§4/§10);
#   - the named degraded fake fixture provider exercises every caps=0 branch;
#   - the fake-skill-tree fixture rule extends cp -r adapters/ to cp -r
#     providers/.
#
# NO golden-trace test: no verb leaf carries a real `gh` argv in this PR (no
# leaf is migrated — scaffolds are empty of verb bodies), so there is no argv to
# pin (spec §7.2). Golden-trace lands in the leaf-migration siblings.
#
# IDs: TC-PROVIDER-DISPATCH-NNN.
#
# Run: bash tests/unit/test-provider-dispatch.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
ITP_LIB="$SCRIPTS/lib-issue-provider.sh"
CHP_LIB="$SCRIPTS/lib-code-host.sh"
PROVIDERS="$SCRIPTS/providers"
FAKE_PROVIDER="$SCRIPT_DIR/fixtures/provider-degraded"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then ok "$d"; else bad "$d"; echo "      expected='$e'"; echo "      actual=  '$a'"; fi; }
assert_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      needle='$n'"; echo "      haystack='${h:0:300}'"; fi; }
assert_not_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      should not contain: '$n'"; fi; }

# The 13 ITP verbs (spec §3.1) and 12 CHP verbs (spec §3.2), verbatim.
ITP_VERBS=(
  itp_list_by_state itp_count_by_state itp_list_forbidden_combos
  itp_transition_state itp_read_task itp_post_comment itp_edit_comment
  itp_list_comments itp_resolve_dep itp_mark_checkbox itp_provision_states
  itp_begin_tick itp_caps
)
CHP_VERBS=(
  chp_find_pr_for_issue chp_ci_status chp_mergeable chp_create_pr chp_approve
  chp_request_changes chp_merge chp_review_threads chp_resolve_thread
  chp_trigger_bot chp_close_keyword chp_caps
)

# ---------------------------------------------------------------------------
echo "=== TC-PROVIDER-DISPATCH-001: all 13 ITP shims defined after sourcing lib-issue-provider.sh ==="
# ---------------------------------------------------------------------------
itp_defined=$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
  bash -c 'source "'"$ITP_LIB"'" 2>/dev/null
    for v in '"${ITP_VERBS[*]}"'; do declare -F "$v" >/dev/null 2>&1 && echo "$v"; done'
)
for v in "${ITP_VERBS[@]}"; do
  if grep -qx "$v" <<<"$itp_defined"; then ok "ITP shim $v defined"; else bad "ITP shim $v NOT defined"; fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-002: all 12 CHP shims defined after sourcing lib-code-host.sh ==="
# ---------------------------------------------------------------------------
chp_defined=$(
  env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
  bash -c 'source "'"$CHP_LIB"'" 2>/dev/null
    for v in '"${CHP_VERBS[*]}"'; do declare -F "$v" >/dev/null 2>&1 && echo "$v"; done'
)
for v in "${CHP_VERBS[@]}"; do
  if grep -qx "$v" <<<"$chp_defined"; then ok "CHP shim $v defined"; else bad "CHP shim $v NOT defined"; fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-003: default-resolution routes itp_<verb>→itp_github_<verb> / chp_<verb>→chp_github_<verb> ==="
# ---------------------------------------------------------------------------
# ISSUE_PROVIDER/CODE_HOST unset → resolve to github. Stub itp_github_*/chp_github_*
# AFTER sourcing the lib (the shim forwards at call time, so a stub defined after
# the source wins), each echoing a sentinel. (Mirrors TC-ADAPTER-EXTRACT-013's
# dispatch-by-resolution check.)
routed=$(
  env -u ISSUE_PROVIDER -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
  bash -c '
    source "'"$ITP_LIB"'" 2>/dev/null
    source "'"$CHP_LIB"'" 2>/dev/null
    itp_github_list_by_state() { echo "ITP-GH-ROUTED:$*"; }
    chp_find_pr_for_issue_check() { :; }
    chp_github_find_pr_for_issue() { echo "CHP-GH-ROUTED:$*"; }
    itp_list_by_state autonomous
    chp_find_pr_for_issue 42 number,body
  '
)
assert_contains "default ISSUE_PROVIDER=github: itp_list_by_state → itp_github_list_by_state" "ITP-GH-ROUTED:autonomous" "$routed"
assert_contains "default CODE_HOST=github: chp_find_pr_for_issue → chp_github_find_pr_for_issue" "CHP-GH-ROUTED:42 number,body" "$routed"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-005: shims forward \"\$@\" verbatim (multi-arg passthrough) ==="
# ---------------------------------------------------------------------------
passthrough=$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
  bash -c '
    source "'"$ITP_LIB"'" 2>/dev/null
    itp_github_transition_state() { echo "ARGS=[$1][$2][$3]"; }
    itp_transition_state 7 in-progress pending-review
  '
)
assert_eq "itp_transition_state forwards 3 args verbatim" "ARGS=[7][in-progress][pending-review]" "$passthrough"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-004: shim bodies forward to itp_\${ISSUE_PROVIDER}_<verb> / chp_\${CODE_HOST}_<verb> ==="
# ---------------------------------------------------------------------------
# Grep the lib bodies for the forward literal per verb (mirrors lib-agent.sh:597
# adapter_invoke_"$AGENT_CMD" … "$@"). itp_caps/chp_caps are the reader shims, so
# they are exempt from the provider-forward literal.
itp_src=$(cat "$ITP_LIB")
for v in "${ITP_VERBS[@]}"; do
  [[ "$v" == "itp_caps" ]] && continue
  short="${v#itp_}"
  assert_contains "INV-87: $v forwards to itp_\${ISSUE_PROVIDER}_$short \"\$@\"" "itp_\${ISSUE_PROVIDER}_$short \"\$@\"" "$itp_src"
done
chp_src=$(cat "$CHP_LIB")
for v in "${CHP_VERBS[@]}"; do
  [[ "$v" == "chp_caps" ]] && continue
  short="${v#chp_}"
  assert_contains "INV-87: $v forwards to chp_\${CODE_HOST}_$short \"\$@\"" "chp_\${CODE_HOST}_$short \"\$@\"" "$chp_src"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-006: provider files resolved via readlink -f of own BASH_SOURCE ([INV-14]/[INV-65]) ==="
# ---------------------------------------------------------------------------
assert_contains "lib-issue-provider.sh resolves providers via readlink -f" "readlink -f" "$itp_src"
assert_contains "lib-code-host.sh resolves providers via readlink -f" "readlink -f" "$chp_src"
# NOT the brittle ${BASH_SOURCE%/*} form (spec §3 'NOT via \${BASH_SOURCE%/*}').
assert_not_contains "lib-issue-provider.sh does NOT use \${BASH_SOURCE%/*} for provider dir" 'BASH_SOURCE%/*' "$itp_src"
assert_not_contains "lib-code-host.sh does NOT use \${BASH_SOURCE%/*} for provider dir" 'BASH_SOURCE%/*' "$chp_src"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-010..013: .caps reader returns documented github values ==="
# ---------------------------------------------------------------------------
caps_read=$(
  env -u ISSUE_PROVIDER -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
  bash -c '
    source "'"$ITP_LIB"'" 2>/dev/null
    source "'"$CHP_LIB"'" 2>/dev/null
    echo "MC=$(itp_caps marker_channel)"
    echo "SSN=$(itp_caps server_side_state_negation)"
    echo "NIPL=$(chp_caps native_issue_pr_link)"
    echo "MCI=$(chp_caps merge_closes_issue)"
  '
)
assert_contains "itp_caps marker_channel → html" "MC=html" "$caps_read"
assert_contains "itp_caps server_side_state_negation → 0" "SSN=0" "$caps_read"
assert_contains "chp_caps native_issue_pr_link → 0" "NIPL=0" "$caps_read"
assert_contains "chp_caps merge_closes_issue → 1" "MCI=1" "$caps_read"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-014..015: reader handles unknown key / comments / blanks ==="
# ---------------------------------------------------------------------------
# Unknown key → non-zero rc, empty stdout. Comment/blank lines are skipped.
unknown=$(
  env -u ISSUE_PROVIDER bash -c '
    source "'"$ITP_LIB"'" 2>/dev/null
    out=$(itp_caps no_such_key); rc=$?
    echo "OUT=[$out] RC=$rc"
  '
)
assert_contains "unknown cap key → empty output, non-zero rc" "OUT=[] RC=1" "$unknown"
# A manifest with comments and blank lines parses the real value past them.
tmp_caps=$(mktemp)
printf '# a header comment\n\nserver_side_state_and=1   # trailing comment\n\n# trailing block\n' > "$tmp_caps"
comment_val=$(
  env -u ISSUE_PROVIDER bash -c '
    source "'"$ITP_LIB"'" 2>/dev/null
    # call the underlying reader directly on the temp manifest
    _provider_read_cap "'"$tmp_caps"'" server_side_state_and
  '
)
rm -f "$tmp_caps"
assert_eq "reader skips # comments and blank lines, returns the value" "1" "$comment_val"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-016: .caps reader is parsed-NEVER-sourced (§4/§10 Q1) ==="
# ---------------------------------------------------------------------------
# The reader body must NOT `source` / `.` the .caps path; it must use a parse
# loop. Inspect the reader function source (strip comments first so a comment
# mentioning "source" doesn't false-positive).
strip_comments() { awk '{ l=$0; sub(/[[:space:]]*#.*$/, "", l); print l }'; }
reader_src=$(
  env -u ISSUE_PROVIDER bash -c '
    source "'"$ITP_LIB"'" 2>/dev/null
    declare -f _provider_read_cap
  ' | strip_comments
)
assert_not_contains "reader does NOT 'source' the .caps manifest" "source " "$reader_src"
# A bare `.` sourcing the caps path would look like `. "$file"` / `. $file`.
assert_not_contains "reader does NOT '. ' (dot-source) the .caps manifest" '. "$' "$reader_src"
assert_contains "reader uses a key=value parse loop (while read)" "read" "$reader_src"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-017: itp-github.caps has EXACTLY the 9 documented keys/values (spec §4/§4.1) ==="
# ---------------------------------------------------------------------------
itp_caps_file="$PROVIDERS/itp-github.caps"
if [[ -f "$itp_caps_file" ]]; then ok "providers/itp-github.caps exists"; else bad "providers/itp-github.caps MISSING"; fi
for kv in server_side_state_and=1 server_side_state_negation=0 distinct_bot_author=1 \
          read_after_write_state=1 cross_ref_shorthand=1 body_checkbox=1 \
          edit_comment=1 label_colors=1 marker_channel=html; do
  if grep -qE "^[[:space:]]*${kv%%=*}[[:space:]]*=[[:space:]]*${kv#*=}([[:space:]]|#|$)" "$itp_caps_file" 2>/dev/null; then
    ok "itp-github.caps declares $kv"
  else
    bad "itp-github.caps missing $kv"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-018: chp-github.caps has EXACTLY the 4 documented keys/values (spec §4/§4.2) ==="
# ---------------------------------------------------------------------------
chp_caps_file="$PROVIDERS/chp-github.caps"
if [[ -f "$chp_caps_file" ]]; then ok "providers/chp-github.caps exists"; else bad "providers/chp-github.caps MISSING"; fi
for kv in native_issue_pr_link=0 rest_request_changes=1 review_bots=1 merge_closes_issue=1; do
  if grep -qE "^[[:space:]]*${kv%%=*}[[:space:]]*=[[:space:]]*${kv#*=}([[:space:]]|#|$)" "$chp_caps_file" 2>/dev/null; then
    ok "chp-github.caps declares $kv"
  else
    bad "chp-github.caps missing $kv"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-020..022: GitHub scaffolds are EMPTY of verb bodies (scope guard) ==="
# ---------------------------------------------------------------------------
# Sourcing providers/itp-github.sh / chp-github.sh must define ZERO verb bodies
# (leaf migration is downstream). declare -F a representative verb → returns 1.
scaffold=$(
  bash -c '
    source "'"$PROVIDERS"'/itp-github.sh" 2>/dev/null
    source "'"$PROVIDERS"'/chp-github.sh" 2>/dev/null
    declare -F itp_github_list_by_state >/dev/null 2>&1 && echo "ITP_VERB_PRESENT"
    declare -F chp_github_create_pr     >/dev/null 2>&1 && echo "CHP_VERB_PRESENT"
    echo "SOURCED_CLEAN"
  '
)
assert_not_contains "itp-github.sh defines NO itp_github_list_by_state body yet" "ITP_VERB_PRESENT" "$scaffold"
assert_not_contains "chp-github.sh defines NO chp_github_create_pr body yet" "CHP_VERB_PRESENT" "$scaffold"
assert_contains "providers/*.sh scaffolds source clean (no syntax error)" "SOURCED_CLEAN" "$scaffold"
# bash -n syntax check
if bash -n "$PROVIDERS/itp-github.sh" 2>/dev/null; then ok "itp-github.sh passes bash -n"; else bad "itp-github.sh syntax error"; fi
if bash -n "$PROVIDERS/chp-github.sh" 2>/dev/null; then ok "chp-github.sh passes bash -n"; else bad "chp-github.sh syntax error"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-030: capability-branch via the named degraded fake fixture provider (provider-spec.md §8 fake-provider; design-spec §7.4) ==="
# ---------------------------------------------------------------------------
# Point ISSUE_PROVIDER/CODE_HOST at the fake degraded provider and assert
# itp_caps/chp_caps report the caps=0 values — proving each caps=0 branch is
# reachable now (the caller branches ship downstream; the fixture + reader they
# consume are tested here). The fake provider's .caps lives in the fixture tree
# alongside its .sh; the reader resolves it the same way the github one is.
fake_caps=$(
  env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR bash -c '
    source "'"$ITP_LIB"'" 2>/dev/null
    source "'"$CHP_LIB"'" 2>/dev/null
    # Read the fake provider .caps directly via the shared reader (the provider
    # files do not have to be on the resolution path for the cap lookup).
    echo "SSA=$(_provider_read_cap "'"$FAKE_PROVIDER"'/itp-degraded.caps" server_side_state_and)"
    echo "DBA=$(_provider_read_cap "'"$FAKE_PROVIDER"'/itp-degraded.caps" distinct_bot_author)"
    echo "MC=$(_provider_read_cap "'"$FAKE_PROVIDER"'/itp-degraded.caps" marker_channel)"
    echo "EC=$(_provider_read_cap "'"$FAKE_PROVIDER"'/itp-degraded.caps" edit_comment)"
    echo "NIPL=$(_provider_read_cap "'"$FAKE_PROVIDER"'/chp-degraded.caps" native_issue_pr_link)"
    echo "MCI=$(_provider_read_cap "'"$FAKE_PROVIDER"'/chp-degraded.caps" merge_closes_issue)"
  '
)
assert_contains "fake provider: server_side_state_and=0 (caps=0 branch reachable)" "SSA=0" "$fake_caps"
assert_contains "fake provider: distinct_bot_author=0" "DBA=0" "$fake_caps"
assert_contains "fake provider: marker_channel=text (not html)" "MC=text" "$fake_caps"
assert_contains "fake provider: edit_comment=0" "EC=0" "$fake_caps"
assert_contains "fake provider: native_issue_pr_link=0" "NIPL=0" "$fake_caps"
assert_contains "fake provider: merge_closes_issue=0" "MCI=0" "$fake_caps"
# Fake provider .sh scaffolds must be syntactically valid too.
if bash -n "$FAKE_PROVIDER/itp-degraded.sh" 2>/dev/null; then ok "fake itp-degraded.sh passes bash -n"; else bad "fake itp-degraded.sh syntax error"; fi
if bash -n "$FAKE_PROVIDER/chp-degraded.sh" 2>/dev/null; then ok "fake chp-degraded.sh passes bash -n"; else bad "fake chp-degraded.sh syntax error"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-040: fixture-rule — fake skill tree cp -r providers/ resolves provider files ([INV-65], §6) ==="
# ---------------------------------------------------------------------------
# Build a fake skill tree the way test-entry-point-startup-e2e.sh does: copy the
# real *.sh plus `cp -r adapters/` AND `cp -r providers/`, then source the libs
# from the fixture tree and confirm the caps reader resolves the fixture .caps
# (proving the readlink -f resolution survives the fixture skill tree).
TMP_TREE=$(mktemp -d)
SKILL_TREE="$TMP_TREE/skill/autonomous-dispatcher/scripts"
mkdir -p "$SKILL_TREE"
cp "$SCRIPTS"/*.sh "$SKILL_TREE/" 2>/dev/null
[[ -d "$SCRIPTS/adapters" ]] && cp -r "$SCRIPTS/adapters" "$SKILL_TREE/adapters"
[[ -d "$SCRIPTS/providers" ]] && cp -r "$SCRIPTS/providers" "$SKILL_TREE/providers"
fixture_caps=$(
  env -u ISSUE_PROVIDER -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
  bash -c '
    source "'"$SKILL_TREE"'/lib-issue-provider.sh" 2>/dev/null
    source "'"$SKILL_TREE"'/lib-code-host.sh" 2>/dev/null
    echo "MC=$(itp_caps marker_channel)"
    echo "MCI=$(chp_caps merge_closes_issue)"
  '
)
rm -rf "$TMP_TREE"
assert_contains "fixture skill tree: providers/ copied → itp_caps resolves itp-github.caps" "MC=html" "$fixture_caps"
assert_contains "fixture skill tree: providers/ copied → chp_caps resolves chp-github.caps" "MCI=1" "$fixture_caps"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PROVIDER-DISPATCH-041: test-entry-point-startup-e2e.sh fixture also cp -r providers/ ==="
# ---------------------------------------------------------------------------
e2e_fixture="$SCRIPT_DIR/test-entry-point-startup-e2e.sh"
e2e_src=$(cat "$e2e_fixture")
assert_contains "entry-point startup E2E fixture copies adapters/" 'cp -r "$DISPATCHER_SCRIPTS/adapters"' "$e2e_src"
assert_contains "entry-point startup E2E fixture also copies providers/" 'cp -r "$DISPATCHER_SCRIPTS/providers"' "$e2e_src"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
