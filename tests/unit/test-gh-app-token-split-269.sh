#!/bin/bash
# test-gh-app-token-split-269.sh — Unit tests for the #269 T1 structural split of
# gh-app-token.sh: the JWT-gen → installation-lookup → token-exchange core is
# extracted into `_app_install_token`, and `get_gh_app_token` becomes a thin
# wrapper that builds the body via `_build_access_token_body` then delegates.
#
# These are SOURCE-LEVEL + body-shape assertions only (no network). The
# behavioral equivalence of get_gh_app_token / get_gh_app_scoped_token is covered
# by tests/unit/test-token-split-234.sh (TC-TOKEN-SPLIT-001/002/003) and
# tests/unit/test-dispatcher-tick-app-auth.sh, which MUST stay green after the
# extraction (byte-identical contract, #269 T1).
#
# Run: bash tests/unit/test-gh-app-token-split-269.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GAT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/gh-app-token.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
echo "=== TC-APPTOK-269-001: _app_install_token is defined and get_gh_app_token delegates to it ==="
# ---------------------------------------------------------------------------
if bash -c "source '$GAT'; declare -F _app_install_token >/dev/null"; then
  assert_pass "_app_install_token is defined (structural extraction landed)"
else
  assert_fail "_app_install_token is NOT defined"
fi
# get_gh_app_token's body must call _app_install_token (the delegation).
if awk '/^get_gh_app_token\(\)/,/^}/' "$GAT" | grep -q '_app_install_token'; then
  assert_pass "get_gh_app_token delegates to _app_install_token"
else
  assert_fail "get_gh_app_token does NOT call _app_install_token (delegation missing)"
fi
# _app_install_token must perform the token EXCHANGE (the POST), and
# get_gh_app_token must no longer inline it (it lives in the shared core now).
if awk '/^_app_install_token\(\)/,/^}/' "$GAT" | grep -q 'access_tokens'; then
  assert_pass "_app_install_token owns the access_tokens exchange (shared core)"
else
  assert_fail "_app_install_token does NOT own the access_tokens exchange"
fi
if awk '/^get_gh_app_token\(\)/,/^}/' "$GAT" | grep -q 'access_tokens'; then
  assert_fail "get_gh_app_token still inlines the access_tokens exchange (not delegated)"
else
  assert_pass "get_gh_app_token no longer inlines the exchange (fully delegated)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-APPTOK-269-002: full-grant body unchanged (byte-identical regression) ==="
# ---------------------------------------------------------------------------
# The #269 T1 extraction must not change the request body shape. No-permissions
# arg → the pre-INV-79 full-grant body, exactly.
body_full=$(bash -c "source '$GAT'; _build_access_token_body 'myrepo' ''")
if [[ "$body_full" == '{"repositories":["myrepo"]}' ]]; then
  assert_pass "full-grant body unchanged: $body_full"
else
  assert_fail "full-grant body shape changed: $body_full"
fi
# Scoped body still embeds the permissions object (the per-dep-repo read token
# in #269 reuses this exact shape via get_gh_app_scoped_token).
body_scoped=$(bash -c "source '$GAT'; _build_access_token_body 'myrepo' '{\"issues\":\"read\"}'")
if [[ "$body_scoped" == '{"repositories":["myrepo"],"permissions":{"issues":"read"}}' ]]; then
  assert_pass "scoped {\"issues\":\"read\"} body well-formed (the #269 dep-lookup shape): $body_scoped"
else
  assert_fail "scoped body wrong shape: $body_scoped"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
