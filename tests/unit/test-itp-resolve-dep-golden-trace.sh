#!/bin/bash
# test-itp-resolve-dep-golden-trace.sh — GOLDEN-TRACE + routing tests for the
# #284 dependency-resolution provider-seam migration ([INV-83], spec §3.6/§7.1(b)).
#
# This is the MANDATORY class-(b) golden trace: it pins the BYTE-IDENTICAL
# `gh issue view` argv (and `--json` field list) that the dependency lookup emits
# AFTER the leaf moved behind itp_resolve_dep / itp_github_resolve_dep, for BOTH
# the cross-repo arm (scoped `GH_TOKEN` prefix) and the same-repo arm (ambient
# token). It also pins the SINGLE-MINT-PER-TICK / cross-issue-dedup behavior
# through itp_begin_tick (the #269 no-regression anchor), the dispatch routing,
# the cross_ref_shorthand=0 capability branch via the named degraded fake
# provider, and the PAT-mode no-mint / negative-cache no-tick-abort regressions.
#
# IDs: TC-RDGT-NNN.
#
# Run: bash tests/unit/test-itp-resolve-dep-golden-trace.sh

set -uo pipefail

PASS=0; FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB="$SCRIPTS/lib-dispatch.sh"
FAKE_PROVIDER="$SCRIPT_DIR/fixtures/provider-degraded"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then ok "$d"; else bad "$d"; echo "      expected='$e'"; echo "      actual=  '$a'"; fi; }
assert_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      needle='$n'"; echo "      haystack='${h:0:400}'"; fi; }
assert_not_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      should NOT contain: '$n'"; fi; }

export REPO=example-org/repo-A
export REPO_OWNER=example-org
export PROJECT_ID=golden-trace-proj
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ---------------------------------------------------------------------------
# Shared harness: a gh BINARY mock that RECORDS the exact argv (one line per
# call) to $_ARGV_LOG, plus the scoped-`GH_TOKEN` it ran under, and returns a
# fixed state. A mint stub records each mint owner/repo to $_MINT_LOG and echoes
# the per-repo sentinel. Both are file-backed so the command-substitution
# subshell inside itp_github_resolve_dep survives.
# ---------------------------------------------------------------------------
_ARGV_LOG=$(mktemp)
_TOK_LOG=$(mktemp)
_MINT_LOG=$(mktemp)
trap 'rm -f "$_ARGV_LOG" "$_TOK_LOG" "$_MINT_LOG"' EXIT

# Build a standalone gh stub on PATH (so the recorded argv is exactly the argv
# itp_github_resolve_dep emits — no shell-function arg munging). It records argv
# and the GH_TOKEN it saw, then echoes the dep state from a state map file.
GH_DIR=$(mktemp -d); trap 'rm -f "$_ARGV_LOG" "$_TOK_LOG" "$_MINT_LOG"; rm -rf "$GH_DIR"' EXIT
cat > "$GH_DIR/gh" <<EOF
#!/bin/bash
ARGV_LOG='$_ARGV_LOG'
TOK_LOG='$_TOK_LOG'
EOF
cat >> "$GH_DIR/gh" <<'EOF'
# Record the FULL argv verbatim (one line) + the in-scope GH_TOKEN.
printf '%s\n' "$*" >> "$ARGV_LOG"
printf '%s\n' "${GH_TOKEN:-}" >> "$TOK_LOG"
# Only `issue view … --json state -q .state` matters for the golden trace.
mode=""; num=""; repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    view) num="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --json) mode="$2"; shift 2 ;;
    -q) shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$mode" == state ]]; then printf 'CLOSED'; fi
EOF
chmod +x "$GH_DIR/gh"

# Run a snippet in a clean bash with: the gh stub on PATH, a function-level mint
# stub defined+exported BEFORE sourcing the lib, then sources lib-dispatch.sh
# (which self-sources the provider seam). Extra `KEY=VAL` env pairs are passed
# AFTER the snippet and forwarded to `env`. Stdout is the snippet's output.
# The mint stub records each owner/repo to $_MINT_LOG and echoes the per-repo
# scoped sentinel — a SCOPE-ENFORCING gh stub (GH_DIR) honors only that token for
# cross-repo lookups, so the golden trace records the real scoped GH_TOKEN.
_run() {
  local snippet="$1"; shift
  env PATH="$GH_DIR:$PATH" \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" \
      MAX_RETRIES=3 MAX_CONCURRENT=5 \
      "$@" \
  bash -c "
    set -uo pipefail
    MINT_LOG='$_MINT_LOG'
    get_gh_app_scoped_token() { printf '%s/%s\n' \"\$3\" \"\$4\" >> \"\$MINT_LOG\"; printf 'scoped-token-for-%s/%s' \"\$3\" \"\$4\"; }
    export -f get_gh_app_scoped_token
    source '$LIB'
    set +e
    $snippet
  "
}
_reset_logs() { : > "$_ARGV_LOG"; : > "$_TOK_LOG"; : > "$_MINT_LOG"; }

# ---------------------------------------------------------------------------
echo "=== TC-RDGT-001: GOLDEN-TRACE cross-repo argv byte-identical ==="
# ---------------------------------------------------------------------------
# itp_github_resolve_dep (via resolve_dep_state) MUST emit EXACTLY
#   issue view <num> --repo <owner/repo> --json state -q .state
# under the scoped GH_TOKEN. This is the pre-refactor literal verbatim.
_reset_logs
_run '
  itp_begin_tick
  st=""
  resolve_dep_state other-owner/other-repo 7 st
  echo "STATE=$st"
' GH_AUTH_MODE=app DISPATCHER_APP_ID=12345 DISPATCHER_APP_PEM=/x.pem GH_TOKEN=ambient-repoA >/dev/null
argv=$(cat "$_ARGV_LOG")
tok=$(cat "$_TOK_LOG")
assert_eq "cross-repo argv is byte-identical to the pre-#284 leaf" \
  "issue view 7 --repo other-owner/other-repo --json state -q .state" "$argv"
assert_eq "cross-repo lookup ran under the TARGET-repo scoped token (the #269 fix)" \
  "scoped-token-for-other-owner/other-repo" "$tok"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RDGT-002: GOLDEN-TRACE same-repo argv byte-identical (ambient token) ==="
# ---------------------------------------------------------------------------
# The same-repo arm resolves against $REPO. After #284 it routes through
# itp_resolve_dep too, but the provider SKIPS the mint for owner_repo == $REPO,
# so the argv is byte-identical to the pre-#284 same-repo leaf AND it runs under
# the ambient token (NOT a minted one).
_reset_logs
_run '
  itp_begin_tick
  st=""
  resolve_dep_state "$REPO" 42 st
  echo "STATE=$st"
' GH_AUTH_MODE=app DISPATCHER_APP_ID=12345 DISPATCHER_APP_PEM=/x.pem GH_TOKEN=ambient-repoA >/dev/null
argv=$(cat "$_ARGV_LOG")
tok=$(cat "$_TOK_LOG")
mints=$(awk 'END{print NR+0}' "$_MINT_LOG")
assert_eq "same-repo argv is byte-identical to the pre-#284 leaf" \
  "issue view 42 --repo example-org/repo-A --json state -q .state" "$argv"
assert_eq "same-repo lookup ran under the AMBIENT token (no scoped mint)" "ambient-repoA" "$tok"
assert_eq "same-repo dep fires ZERO scoped mints (mint skipped for \$REPO)" "0" "$mints"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RDGT-003: DISPATCH-ROUTING — itp_resolve_dep→itp_github_resolve_dep, itp_begin_tick→itp_github_begin_tick ==="
# ---------------------------------------------------------------------------
# Under ISSUE_PROVIDER=github (default), the verb shims forward to the github
# leaves. Stub the github leaves AFTER sourcing (the shim forwards at call time)
# and assert the sentinel routing.
routed=$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" MAX_RETRIES=3 MAX_CONCURRENT=5 \
  bash -c '
    source "'"$LIB"'" 2>/dev/null
    itp_github_resolve_dep() { echo "RD-ROUTED:[$1][$2][$3]"; }
    itp_github_begin_tick()  { echo "BT-ROUTED"; }
    itp_resolve_dep owner/repo 9 myvar
    itp_begin_tick
  '
)
assert_contains "itp_resolve_dep routes to itp_github_resolve_dep (args forwarded)" "RD-ROUTED:[owner/repo][9][myvar]" "$routed"
assert_contains "itp_begin_tick routes to itp_github_begin_tick" "BT-ROUTED" "$routed"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RDGT-004: SINGLE-MINT-PER-TICK — two issues, one dep repo, one itp_begin_tick → ONE mint (#269 anchor) ==="
# ---------------------------------------------------------------------------
# The #269 no-regression anchor: itp_begin_tick resets the provider-owned cache
# ONCE; two check_deps_resolved-style lookups for the same dep repo within the
# tick reuse the single minted token. get_gh_app_scoped_token invoked EXACTLY once.
_reset_logs
_run '
  itp_begin_tick
  st=""
  resolve_dep_state shared-owner/shared-repo 7 st   # issue 1 — mints
  resolve_dep_state shared-owner/shared-repo 8 st   # issue 2 same tick — reuses
' GH_AUTH_MODE=app DISPATCHER_APP_ID=12345 DISPATCHER_APP_PEM=/x.pem GH_TOKEN=ambient-repoA >/dev/null
mints=$(grep -cx "shared-owner/shared-repo" "$_MINT_LOG")
assert_eq "two refs on the same dep repo in one tick mint ONCE (driven by itp_begin_tick)" "1" "$mints"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RDGT-005: TICK-BOUNDARY RESET — a second itp_begin_tick re-mints (cache cleared by the verb) ==="
# ---------------------------------------------------------------------------
# Proves the cache is cleared by itp_begin_tick, NOT by resolve_dep_state /
# check_deps_resolved: after a second itp_begin_tick the same dep repo re-mints.
_reset_logs
_run '
  itp_begin_tick
  st=""
  resolve_dep_state shared-owner/shared-repo 7 st   # tick A — mint 1
  itp_begin_tick                                    # tick boundary
  resolve_dep_state shared-owner/shared-repo 7 st   # tick B — mint 2
' GH_AUTH_MODE=app DISPATCHER_APP_ID=12345 DISPATCHER_APP_PEM=/x.pem GH_TOKEN=ambient-repoA >/dev/null
mints=$(grep -cx "shared-owner/shared-repo" "$_MINT_LOG")
assert_eq "second itp_begin_tick clears the cache → 2 total mints (no cross-tick leak)" "2" "$mints"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RDGT-006: CAPABILITY-BRANCH — cross_ref_shorthand=0 fake provider drives the non-shorthand branch ==="
# ---------------------------------------------------------------------------
# §7.4: a degraded fake ITP provider whose .caps declare cross_ref_shorthand=0
# must NOT parse the `owner/repo#N` shorthand as a cross-repo dep — so a body
# whose ONLY dep is a cross-repo `owner/repo#N` ref resolves (rc 0) WITHOUT any
# cross-repo lookup (the shorthand is not this provider's ref form; the full-id
# branch is not live, so nothing blocks). This proves the caller's
# cross_ref_shorthand gate is reachable, not dead untested code.
#
# The fake provider is selected through the PUBLIC seam (ISSUE_PROVIDER=degraded
# + AUTONOMOUS_PROVIDERS_DIR=<fixture>), exactly like test-provider-dispatch.sh
# TC-030. The fake itp-degraded.sh is an empty scaffold, so we stub the gh BODY
# read + itp_begin_tick + itp_caps consumption via the real lib path. We use a gh
# stub that returns a `## Dependencies` body with a cross-repo ref, and a state
# map that would BLOCK if the cross-repo lookup fired.
xref0_dir=$(mktemp -d)
cat > "$xref0_dir/gh" <<'GHEOF'
#!/bin/bash
mode=""; num=""; repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    view) num="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --json) mode="$2"; shift 2 ;;
    -q) shift 2 ;;
    *) shift ;;
  esac
done
case "$mode" in
  body) printf '## Dependencies\n- other-owner/other-repo#7\n' ;;
  state) printf 'OPEN' ;;   # would BLOCK if a cross-repo lookup fired
esac
GHEOF
chmod +x "$xref0_dir/gh"
xref0_out=$(
  env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      PATH="$xref0_dir:$PATH" \
      ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" MAX_RETRIES=3 MAX_CONCURRENT=5 \
  bash -c '
    source "'"$LIB"'" 2>/dev/null
    set +e
    # confirm the seam reports cross_ref_shorthand=0 for the degraded provider
    echo "CAP=$(itp_caps cross_ref_shorthand)"
    itp_begin_tick 2>/dev/null   # degraded provider has no begin_tick leaf — guarded, no-op
    check_deps_resolved 99; echo "RC=$?"
  '
)
rm -rf "$xref0_dir"
assert_contains "degraded provider reports cross_ref_shorthand=0 through the public seam" "CAP=0" "$xref0_out"
assert_contains "cross_ref_shorthand=0: the owner/repo#N shorthand is NOT parsed as a cross-repo dep → resolved (rc 0)" "RC=0" "$xref0_out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RDGT-007: PAT-MODE no-mint — itp_begin_tick leaves the cache empty, ambient token used ==="
# ---------------------------------------------------------------------------
# In token mode (no DISPATCHER_APP_ID/PEM) the provider's mint branch is never
# entered: zero mints, the lookup uses the ambient token. byte-identical to the
# pre-refactor PAT path.
_reset_logs
_run '
  itp_begin_tick
  st=""
  resolve_dep_state other-owner/other-repo 7 st
  echo "STATE=$st"
' GH_AUTH_MODE=token GH_TOKEN=user-pat >/dev/null
mints=$(awk 'END{print NR+0}' "$_MINT_LOG")
tok=$(cat "$_TOK_LOG")
assert_eq "PAT mode fires ZERO scoped mints" "0" "$mints"
assert_eq "PAT mode cross-repo lookup uses the ambient PAT (spans repos)" "user-pat" "$tok"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RDGT-008: NEGATIVE-CACHE / no-tick-abort — mint failure is negative-cached, never aborts ==="
# ---------------------------------------------------------------------------
# A per-dep-repo mint FAILURE (App not installed) is negative-cached (empty) and
# falls back to the ambient token. It must NOT abort: a same-repo dep in the same
# tick still resolves. A SCOPE-ENFORCING gh stub returns empty for a cross-repo
# lookup made under the ambient (non-scoped) token (the #269 404), and CLOSED for
# a same-repo lookup. The process surviving + the same-repo lookup succeeding
# proves no abort (#269 T4).
neg_gh_dir=$(mktemp -d)
cat > "$neg_gh_dir/gh" <<EOF
#!/bin/bash
DISPATCH_REPO='$REPO'
EOF
cat >> "$neg_gh_dir/gh" <<'GHEOF'
mode=""; num=""; repo=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    view) num="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --json) mode="$2"; shift 2 ;;
    -q) shift 2 ;;
    *) shift ;;
  esac
done
if [[ "$mode" == state ]]; then
  # Cross-repo lookup needs the per-repo scoped token; ambient → 404 (empty).
  if [[ "$repo" != "$DISPATCH_REPO" && "${GH_TOKEN:-}" != "scoped-token-for-$repo" ]]; then
    exit 1
  fi
  printf 'CLOSED'
fi
GHEOF
chmod +x "$neg_gh_dir/gh"
neg_out=$(
  env PATH="$neg_gh_dir:$PATH" \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" MAX_RETRIES=3 MAX_CONCURRENT=5 \
      GH_AUTH_MODE=app DISPATCHER_APP_ID=12345 DISPATCHER_APP_PEM=/x.pem GH_TOKEN=ambient-repoA \
      MINT_LOG="$_MINT_LOG" \
  bash -c "
    set -uo pipefail
    : > \"\$MINT_LOG\"
    # Mint FAILS for the doomed cross-repo (rc 1, empty) — negative-cached.
    get_gh_app_scoped_token() {
      printf '%s/%s\n' \"\$3\" \"\$4\" >> \"\$MINT_LOG\"
      return 1
    }
    export -f get_gh_app_scoped_token
    source '$LIB'
    set +e
    itp_begin_tick
    st1=''
    resolve_dep_state doomed-owner/doomed 9 st1   # mint fails → ambient → 404 → empty
    echo \"DOOMED=[\$st1]\"
    st2=''
    resolve_dep_state \"\$REPO\" 42 st2            # same-repo still resolves (no abort)
    echo \"SAMEREPO=[\$st2]\"
    echo \"ALIVE=yes\"
  "
)
rm -rf "$neg_gh_dir"
assert_contains "doomed cross-repo mint-failure yields empty state (negative-cached, no abort)" "DOOMED=[]" "$neg_out"
assert_contains "same-repo dep still resolves in the same tick (mint failure did NOT abort, #269 T4)" "SAMEREPO=[CLOSED]" "$neg_out"
assert_contains "process survived the mint-failure path (no exit)" "ALIVE=yes" "$neg_out"
# The doomed repo is negative-cached: a second ref to it does NOT re-mint. Run
# only for the mint-log side effect (stdout discarded).
_reset_logs
  env PATH="$GH_DIR:$PATH" \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" MAX_RETRIES=3 MAX_CONCURRENT=5 \
      GH_AUTH_MODE=app DISPATCHER_APP_ID=12345 DISPATCHER_APP_PEM=/x.pem GH_TOKEN=ambient-repoA \
      MINT_LOG="$_MINT_LOG" \
  bash -c "
    set -uo pipefail
    get_gh_app_scoped_token() { printf '%s/%s\n' \"\$3\" \"\$4\" >> \"\$MINT_LOG\"; return 1; }
    export -f get_gh_app_scoped_token
    source '$LIB'
    set +e
    itp_begin_tick
    st=''
    resolve_dep_state doomed-owner/doomed 9 st
    resolve_dep_state doomed-owner/doomed 10 st
  " >/dev/null 2>&1
mints=$(grep -cx "doomed-owner/doomed" "$_MINT_LOG")
assert_eq "negative-cached doomed repo is minted ONCE for two refs (no re-mint per ref)" "1" "$mints"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RDGT-009: dispatcher-tick begin_tick guard is a NO-OP for a provider WITHOUT a begin_tick leaf (#284 review [P1]) ==="
# ---------------------------------------------------------------------------
# REGRESSION for the review [P1]: lib-issue-provider.sh ALWAYS defines the
# `itp_begin_tick` SHIM, so a guard on `declare -F itp_begin_tick` always passes
# and then calls an undefined `itp_<provider>_begin_tick` → `command not found` →
# aborts the tick under `set -e`. begin_tick is an OPTIONAL lifecycle hook (a
# provider with no per-tick token cache implements no leaf). The dispatcher-tick
# guard MUST key on the PROVIDER LEAF (`itp_${ISSUE_PROVIDER}_begin_tick`) so an
# absent leaf is a no-op, restoring the pre-#284 `_reset_dep_token_cache` guard
# semantics. The degraded fixture provider (itp-degraded.sh is an empty scaffold,
# NO itp_degraded_begin_tick) selected through the PUBLIC seam exercises this.
#
# (a) The buggy SHIM guard aborts under set -e; (b) the LEAF guard is a clean
# no-op; (c) the dispatcher-tick.sh source itself uses the LEAF guard.
guard_dir="$SCRIPT_DIR/fixtures/provider-degraded"
guard_out=$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      ISSUE_PROVIDER=degraded AUTONOMOUS_PROVIDERS_DIR="$guard_dir" \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" MAX_RETRIES=3 MAX_CONCURRENT=5 \
  bash -c '
    set -euo pipefail
    source "'"$LIB"'" 2>/dev/null
    # The fix: guard on the provider LEAF, exactly as dispatcher-tick.sh does.
    if declare -F "itp_${ISSUE_PROVIDER:-github}_begin_tick" >/dev/null 2>&1; then
      itp_begin_tick
    fi
    echo "TICK-NOT-ABORTED"
  ' 2>&1
)
assert_contains "degraded provider (no begin_tick leaf): the LEAF guard is a no-op, tick NOT aborted under set -e" "TICK-NOT-ABORTED" "$guard_out"
assert_not_contains "no 'command not found' from an undefined provider begin_tick leaf" "command not found" "$guard_out"
# Pin that dispatcher-tick.sh's actual guard keys on the provider LEAF, not the shim.
DISPATCHER_TICK="$SCRIPTS/dispatcher-tick.sh"
tick_src=$(cat "$DISPATCHER_TICK")
assert_contains "dispatcher-tick.sh guards itp_begin_tick on the provider LEAF (itp_\${ISSUE_PROVIDER...}_begin_tick)" \
  'declare -F "itp_${ISSUE_PROVIDER:-github}_begin_tick"' "$tick_src"
# And the GitHub default DOES define the leaf, so the real dispatcher still resets.
github_leaf=$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" MAX_RETRIES=3 MAX_CONCURRENT=5 \
  bash -c '
    source "'"$LIB"'" 2>/dev/null
    declare -F "itp_${ISSUE_PROVIDER:-github}_begin_tick" >/dev/null 2>&1 && echo "GH-LEAF-DEFINED"
  '
)
assert_contains "GitHub default DEFINES itp_github_begin_tick → the real dispatcher still resets every tick" "GH-LEAF-DEFINED" "$github_leaf"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RDGT-010: check_deps_resolved skips dep-gating (no abort) for a provider WITHOUT a resolve_dep leaf (#284 review [P1] #2) ==="
# ---------------------------------------------------------------------------
# REGRESSION for the second review [P1]: BOTH dep arms (cross-repo Stage 2a AND
# same-repo Stage 2b) route through resolve_dep_state → the itp_resolve_dep verb.
# lib-issue-provider.sh ALWAYS defines the itp_resolve_dep SHIM, so for a provider
# with no itp_<provider>_resolve_dep leaf (the degraded fixture, any
# not-yet-migrated gitlab/asana) the shim called an undefined function →
# `command not found` → aborted check_deps_resolved under `set -e` (the same-repo
# arm was a raw `gh` call on main, so this was a NEW regression). The provider-leaf
# presence guard makes check_deps_resolved skip dep-gating (return 0) for such a
# provider — never aborts, never spuriously blocks. GitHub DEFINES the leaf, so
# production dep-gating is unaffected.
#
# (a) a provider with genuinely NO resolve_dep leaf. (Issue #370 added
# itp_degraded_resolve_dep to the degraded fixture so the provider-conformance
# runner has a real body to assert against, so this regression pin now uses
# its OWN leaf-less scratch provider dir — a bare .caps with no matching .sh —
# to keep testing "leaf absent", not "leaf present and happens to resolve".)
# + a same-repo `#N` dep under set -e → resolved, no abort, no `command not found`.
noleaf_dir=$(mktemp -d)
cp "$FAKE_PROVIDER/itp-degraded.caps" "$noleaf_dir/itp-noleaf.caps"
deps_guard_out=$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      ISSUE_PROVIDER=noleaf AUTONOMOUS_PROVIDERS_DIR="$noleaf_dir" \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" MAX_RETRIES=3 MAX_CONCURRENT=5 \
  bash -c '
    set -euo pipefail
    gh() { local m=""; while [[ $# -gt 0 ]]; do case "$1" in --json) m="$2"; shift 2;; *) shift;; esac; done
          case "$m" in
            title,body,state,labels,comments) printf %s "{\"title\":\"t\",\"body\":\"## Dependencies\\n- #42\\n\",\"state\":\"OPEN\",\"labels\":[],\"comments\":[]}";;
            body) printf "## Dependencies\n- #42\n";;
            state) printf CLOSED;; esac; }
    export -f gh
    source "'"$LIB"'" 2>/dev/null
    check_deps_resolved 99 && echo "DEPS-RC=0" || echo "DEPS-RC=$?"
    echo "REACHED-END"
  ' 2>&1
)
rm -rf "$noleaf_dir"
assert_contains "no-resolve_dep-leaf provider + same-repo #N dep: check_deps_resolved did NOT abort under set -e" "REACHED-END" "$deps_guard_out"
assert_contains "no-resolve_dep-leaf provider: dep-gating skipped → resolved (rc 0), not a spurious block" "DEPS-RC=0" "$deps_guard_out"
assert_not_contains "no 'command not found' from an undefined provider resolve_dep leaf" "command not found" "$deps_guard_out"
# (b) source-pin the provider-leaf guard in lib-dispatch.sh's check_deps_resolved.
lib_src=$(cat "$LIB")
assert_contains "lib-dispatch.sh check_deps_resolved guards on the resolve_dep provider LEAF" \
  'declare -F "itp_${ISSUE_PROVIDER:-github}_resolve_dep"' "$lib_src"
# (c) GitHub (leaf present) is UNAFFECTED — it still blocks on an OPEN same-repo dep.
gh_gate_out=$(
  env -u ISSUE_PROVIDER -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID="$PROJECT_ID" MAX_RETRIES=3 MAX_CONCURRENT=5 \
  bash -c '
    set -uo pipefail
    gh() { local m="" num=""; while [[ $# -gt 0 ]]; do case "$1" in view) num="$2"; shift 2;; --json) m="$2"; shift 2;; *) shift;; esac; done
          case "$m" in
            title,body,state,labels,comments) printf %s "{\"title\":\"t\",\"body\":\"## Dependencies\\n- #42\\n\",\"state\":\"OPEN\",\"labels\":[],\"comments\":[]}";;
            body) printf "## Dependencies\n- #42\n";;
            state) [ "$num" = 42 ] && printf OPEN || printf CLOSED;; esac; }
    export -f gh
    source "'"$LIB"'" 2>/dev/null
    set +e
    check_deps_resolved 99; echo "GH-DEPS-RC=$?"
  '
)
assert_contains "GitHub (resolve_dep leaf present): still blocks on an OPEN same-repo dep (dep-gating intact)" "GH-DEPS-RC=1" "$gh_gate_out"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
