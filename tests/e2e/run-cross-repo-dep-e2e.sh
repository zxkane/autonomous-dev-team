#!/bin/bash
# run-cross-repo-dep-e2e.sh — End-to-end driver for the #269 cross-repo
# dependency scoped-token fix (INV-83).
#
# WHAT IT DOES
# ------------
# Drives the REAL `check_deps_resolved` + `resolve_dep_state` from
# lib-dispatch.sh against a STUB `gh` on PATH that enforces the #269 token
# scope: a cross-repo `gh issue view --repo owner/repo-B` 404s UNLESS the
# in-scope $GH_TOKEN is the per-repo scoped sentinel the (stubbed) mint produces.
# This is the always-on hermetic integration test: no network, no credentials,
# runs on bare ubuntu.
#
# It proves the end-to-end path the unit test models in isolation:
#   1. App mode, an issue whose `## Dependencies` lists a CLOSED cross-repo dep,
#      the dispatcher token scoped to repo-A only → resolves (rc 0, dispatchable)
#      ONLY because resolve_dep_state minted a repo-B-scoped token. With the
#      pre-#269 ambient-token path this 404s and the issue is silently blocked.
#   2. The same fixture with the dep OPEN → blocked (rc 1).
#   3. App-not-installed (the dep repo is unreachable) → blocked + the sharpened
#      WARNING naming the scope/installation cause.
#   4. PAT mode (no mint) → cross-repo CLOSED still resolves via the ambient PAT
#      (which spans repos) — the no-regression contract.
#
# Run: bash tests/e2e/run-cross-repo-dep-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$LIB" ]] || { echo -e "${RED}FATAL${NC}: lib-dispatch.sh missing"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REPO="example-org/repo-A"     # the dispatching repo (the narrow-token repo)
DEP_REPO="example-org/repo-B" # the cross-repo dependency repo

# Stub `gh` on PATH. Enforces the #269 scope: a cross-repo state lookup only
# succeeds when GH_TOKEN is the per-repo scoped sentinel. The fixture's body +
# the dep state are read from env files so each scenario can vary them.
GHBIN="$WORK/bin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<EOF
#!/bin/bash
# args: issue view N --repo R --json F -q .X   |  issue comment N --repo R --body B
DISPATCH_REPO='$REPO'
SENTINEL_PREFIX='scoped-token-for-'
BODY_FILE='$WORK/dep-body.txt'
STATE_FILE='$WORK/dep-state.txt'      # lines: "<repo>:<num> STATE" (STATE may be __FAIL__)
SCOPE_ENFORCE_FILE='$WORK/scope-enforce'
EOF
cat >> "$GHBIN/gh" <<'EOF'
mode=""; num=""; repo=""
if [[ "$1" == "issue" && "$2" == "comment" ]]; then exit 0; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    issue|view) shift ;;
    comment) shift ;;
    --repo) repo="$2"; shift 2 ;;
    --json) case "$2" in body) mode=body;; state) mode=state;; title,body,state,labels) mode=fullread;; esac; shift 2 ;;
    -q) shift 2 ;;
    [0-9]*) num="$1"; shift ;;
    *) shift ;;
  esac
done
case "$mode" in
  fullread)
    # [W1b] the abstract itp_read_task leaf reads title/body/state/labels and
    # normalizes; serve the dep body inside a minimal raw payload.
    printf '{"title":"t","body":%s,"state":"OPEN","labels":[]}' \
      "$(jq -R -s '.' < "$BODY_FILE" 2>/dev/null || printf '""')" ;;
  body) cat "$BODY_FILE" 2>/dev/null ;;
  state)
    line=$(grep "^${repo}:${num} " "$STATE_FILE" 2>/dev/null | head -1)
    st=$(printf '%s' "$line" | awk '{print $2}')
    [[ -z "$st" ]] && st="OPEN"
    [[ "$st" == "__FAIL__" ]] && exit 1
    if [[ -f "$SCOPE_ENFORCE_FILE" && "$repo" != "$DISPATCH_REPO" ]]; then
      if [[ "${GH_TOKEN:-}" != "${SENTINEL_PREFIX}${repo}" ]]; then exit 1; fi
    fi
    printf '%s' "$st"
    ;;
esac
EOF
chmod +x "$GHBIN/gh"

# Stub the scoped mint (gh-app-token.sh's get_gh_app_scoped_token). Echo the
# per-repo sentinel so the scope-aware gh stub honors the lookup, and append the
# minted `owner/repo` to a count file so the tick-scoped-dedup scenario can prove
# how many mints happened (file, not a var — the mint runs in a `$(...)` subshell
# inside resolve_dep_state).
MINT_LOG="$WORK/mint.log"; : > "$MINT_LOG"
GAT_STUB="$WORK/gh-app-token.sh"
cat > "$GAT_STUB" <<EOF
#!/bin/bash
get_gh_app_scoped_token() { printf '%s/%s\n' "\$3" "\$4" >> '$MINT_LOG'; printf 'scoped-token-for-%s/%s' "\$3" "\$4"; }
get_gh_app_token() { printf 'scoped-token-for-%s/%s' "\$3" "\$4"; }
EOF

run_check() {
  # Runs check_deps_resolved 99 in a clean bash with the stub gh + env. stdout
  # ends with a trailing "RC=<n>" line (read via rc_of); stderr is captured to
  # $WORK/stderr.txt for the WARNING assertions. Sourcing the stubbed
  # gh-app-token.sh BEFORE lib-dispatch so resolve_dep_state finds
  # get_gh_app_scoped_token already defined.
  local mode="$1"
  PATH="$GHBIN:$PATH" \
  REPO="$REPO" REPO_OWNER="example-org" PROJECT_ID="e2e-proj" \
  MAX_RETRIES=3 MAX_CONCURRENT=5 \
  GH_AUTH_MODE="$mode" \
  DISPATCHER_APP_ID="${APP_ID:-}" DISPATCHER_APP_PEM="${APP_PEM:-}" \
  GH_TOKEN="${TOK:-}" \
  bash -c "
    set -uo pipefail
    source '$GAT_STUB'
    source '$LIB'
    set +e
    check_deps_resolved 99
    echo \"RC=\$?\"
  " 2>"$WORK/stderr.txt"
}

# Extract the trailing `RC=<n>` that run_check (and the counter-proof block) emit.
rc_of() { printf '%s' "$1" | sed -n 's/^RC=//p'; }

# ---------------------------------------------------------------------------
echo "=== E2E-CRDEP-1: app mode, CLOSED cross-repo dep → resolved via scoped mint ==="
# ---------------------------------------------------------------------------
printf '## Dependencies\n- %s#7\n' "$DEP_REPO" > "$WORK/dep-body.txt"
printf '%s:7 CLOSED\n' "$DEP_REPO" > "$WORK/dep-state.txt"
: > "$WORK/scope-enforce"   # the #269 narrow-token scope is active
APP_ID=12345 APP_PEM=/nonexistent.pem TOK=ambient-repoA-token \
  out=$(run_check app)
rc=$(rc_of "$out")
if [[ "$rc" == "0" ]]; then
  ok "CLOSED cross-repo dep dispatches (rc 0) — scoped mint defeated the repo-A-only token"
else
  bad "CLOSED cross-repo dep was blocked (rc=$rc) — the #269 fix did not route the scoped token"
fi

# Counter-proof: WITHOUT a mint (simulate the pre-#269 path by feeding only the
# ambient token in app mode but with the mint stub absent → resolve_dep_state
# falls back to ambient → 404). We model "no mint available" by NOT sourcing the
# stub; instead run the bare lib so get_gh_app_scoped_token is undefined.
out_nomint=$(PATH="$GHBIN:$PATH" REPO="$REPO" REPO_OWNER=example-org PROJECT_ID=e2e-proj \
  MAX_RETRIES=3 MAX_CONCURRENT=5 GH_AUTH_MODE=app \
  DISPATCHER_APP_ID=12345 DISPATCHER_APP_PEM=/nonexistent.pem GH_TOKEN=ambient-repoA-token \
  bash -c "set -uo pipefail; source '$LIB'; set +e; check_deps_resolved 99; echo RC=\$?" 2>/dev/null)
rc_nomint=$(rc_of "$out_nomint")
if [[ "$rc_nomint" == "1" ]]; then
  ok "counter-proof: with NO scoped mint the ambient repo-A token 404s → blocked (rc 1) — confirms the test bites"
else
  bad "counter-proof failed: expected block without a mint, got rc=$rc_nomint"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-CRDEP-2: app mode, OPEN cross-repo dep → blocked ==="
# ---------------------------------------------------------------------------
printf '%s:7 OPEN\n' "$DEP_REPO" > "$WORK/dep-state.txt"
APP_ID=12345 APP_PEM=/nonexistent.pem TOK=ambient-repoA-token out=$(run_check app)
rc=$(rc_of "$out")
[[ "$rc" == "1" ]] && ok "OPEN cross-repo dep blocks (rc 1)" || bad "OPEN cross-repo dep did not block (rc=$rc)"

# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-CRDEP-3: app mode, App-not-installed → blocked + sharpened WARNING ==="
# ---------------------------------------------------------------------------
printf '%s:7 __FAIL__\n' "$DEP_REPO" > "$WORK/dep-state.txt"
APP_ID=12345 APP_PEM=/nonexistent.pem TOK=ambient-repoA-token out=$(run_check app)
rc=$(rc_of "$out")
warn=$(cat "$WORK/stderr.txt" 2>/dev/null)
[[ "$rc" == "1" ]] && ok "unreachable cross-repo dep blocks (rc 1)" || bad "unreachable dep did not block (rc=$rc)"
if printf '%s' "$warn" | grep -qF "App may not be installed on ${DEP_REPO}"; then
  ok "sharpened WARNING names the scope/installation cause"
else
  bad "sharpened WARNING missing (got: $warn)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-CRDEP-4: PAT mode (no mint) → CLOSED cross-repo dep still resolves (no regression) ==="
# ---------------------------------------------------------------------------
printf '%s:7 CLOSED\n' "$DEP_REPO" > "$WORK/dep-state.txt"
rm -f "$WORK/scope-enforce"   # a PAT spans repos → no scope enforcement
TOK=user-pat out=$(run_check token)
rc=$(rc_of "$out")
[[ "$rc" == "0" ]] && ok "PAT mode cross-repo CLOSED resolves (rc 0) — no mint, ambient fallback" \
                   || bad "PAT mode cross-repo CLOSED blocked (rc=$rc) — regression"

# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-CRDEP-5: tick-scoped cache — two ISSUES on the same dep repo mint ONCE (AC #2) ==="
# ---------------------------------------------------------------------------
# The #269 review [P1]: AC #2 requires caching by owner/repo WITHIN the tick.
# Two issues processed in one tick (one process, one source of lib-dispatch, the
# tick-boundary reset called ONCE) that both depend on the same external repo
# must reuse the first mint → exactly ONE entry in the mint log. A per-issue
# reset would mint twice.
printf '## Dependencies\n- %s#7\n' "$DEP_REPO" > "$WORK/dep-body.txt"
printf '%s:7 CLOSED\n' "$DEP_REPO" > "$WORK/dep-state.txt"
: > "$WORK/scope-enforce"
: > "$MINT_LOG"
tick_out=$(PATH="$GHBIN:$PATH" REPO="$REPO" REPO_OWNER=example-org PROJECT_ID=e2e-proj \
  MAX_RETRIES=3 MAX_CONCURRENT=5 GH_AUTH_MODE=app \
  DISPATCHER_APP_ID=12345 DISPATCHER_APP_PEM=/nonexistent.pem GH_TOKEN=ambient-repoA-token \
  bash -c "
    set -uo pipefail
    source '$GAT_STUB'
    source '$LIB'
    set +e
    itp_begin_tick                  # the tick boundary (dispatcher-tick.sh does this once; #284 verb)
    check_deps_resolved 101; echo \"RC1=\$?\"   # issue #101 — mints
    check_deps_resolved 102; echo \"RC2=\$?\"   # issue #102 same tick — reuses
  " 2>/dev/null)
rc1=$(printf '%s' "$tick_out" | sed -n 's/^RC1=//p')
rc2=$(printf '%s' "$tick_out" | sed -n 's/^RC2=//p')
mint_count=$(grep -cx "${DEP_REPO}" "$MINT_LOG" 2>/dev/null || true); mint_count=${mint_count:-0}
[[ "$rc1" == "0" && "$rc2" == "0" ]] && ok "both issues resolve (rc 0) in one tick" \
                                     || bad "tick-dedup: an issue blocked (rc1=$rc1 rc2=$rc2)"
if [[ "$mint_count" == "1" ]]; then
  ok "tick-scoped cache: same dep repo across TWO issues minted ONCE (AC #2)"
else
  bad "tick-scoped cache violated: minted $mint_count times across two issues (expected 1) — the #269 [P1]"
fi

# ---------------------------------------------------------------------------
echo ""
echo "CROSS-REPO-DEP-E2E-SUMMARY pass=${PASS} fail=${FAIL}"
[[ $FAIL -eq 0 ]] || exit 1
