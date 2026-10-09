#!/bin/bash
# Fake-only token exchange tests. No network, signing, or private-key access.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/gh-app-token.sh"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gh-app-token-curl-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT
PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }

export TEST_FAKE_JWT='fixture.header.signature'
RESPONSE_SECRET='credential-response-sentinel'
EXPECTED_TOKEN='installation-token-fixture'
CASE_DIR=''
MODE=''

_generate_jwt() { printf '%s\n' "$TEST_FAKE_JWT"; }
openssl() { fail 'openssl must not run in this test' >&2; return 99; }

curl() {
  local count=0 arg previous='' phase=lookup stdin_config=false body
  if [[ -f "$CASE_DIR/count" ]]; then read -r count < "$CASE_DIR/count"; fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$CASE_DIR/count"
  printf '%s\0' "$@" > "$CASE_DIR/$count.args"
  for arg in "$@"; do
    if [[ "$previous" == --config && "$arg" == - ]]; then stdin_config=true; fi
    if [[ "$arg" == */access_tokens ]]; then phase=exchange; fi
    previous="$arg"
  done
  if [[ "$stdin_config" == true ]]; then
    cat > "$CASE_DIR/$count.stdin"
  else
    : > "$CASE_DIR/$count.stdin"
  fi
  if [[ "$phase" == lookup ]]; then body='{"id":7}'; else body="{\"token\":\"$EXPECTED_TOKEN\"}"; fi
  case "$MODE" in
    "$phase-http") printf '{"message":"%s","token":"%s"}\n403' "$RESPONSE_SECRET" "$EXPECTED_TOKEN" ;;
    "$phase-missing") printf '{"message":"%s"}\n200' "$RESPONSE_SECRET" ;;
    "$phase-invalid-json") printf '%s not JSON\n200' "$RESPONSE_SECRET" ;;
    "$phase-invalid-status") printf '%s\n%s' "$body" "$RESPONSE_SECRET" ;;
    "$phase-transport") printf '%s\n200' "$body"; return 28 ;;
    *) printf '%s\n%s' "$body" "$([[ "$phase" == lookup ]] && printf 200 || printf 201)" ;;
  esac
}

run_case() {
  MODE="$1"
  CASE_DIR="$TEST_DIR/$MODE"
  mkdir "$CASE_DIR"
  local permissions="${2:-}" rc
  if (trap - EXIT; get_gh_app_token 123 "$TEST_DIR/unused-fixture.pem" example-owner example-repo "$permissions") > "$CASE_DIR/stdout" 2> "$CASE_DIR/stderr"; then
    rc=0
  else
    rc=$?
  fi
  return "$rc"
}

check_request_contract() {
  python3 - "$CASE_DIR" "$1" <<'PY'
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
jwt = os.environ['TEST_FAKE_JWT']
assert (root / 'count').read_text().strip() == '2', 'expected exactly two requests'
for number in (1, 2):
    args = (root / f'{number}.args').read_bytes().decode().rstrip('\0').split('\0')
    assert all(jwt not in arg for arg in args), 'JWT must not appear in curl argv'
    assert args[0] == '-q', 'ignore ambient curl config before processing other options'
    assert args[args.index('--config') + 1] == '-', 'read credential config from stdin'
    assert (root / f'{number}.stdin').read_text().strip() == f'header = "Authorization: Bearer {jwt}"'
    connect = float(args[args.index('--connect-timeout') + 1])
    total = float(args[args.index('--max-time') + 1])
    assert 0 < connect <= total <= 60, 'both HTTP requests must be bounded'
    assert args[args.index('-H') + 1] == 'Accept: application/vnd.github+json'
    assert args[args.index('-w') + 1] == r'\n%{http_code}'
    if number == 1:
        assert 'https://api.github.com/repos/example-owner/example-repo/installation' in args
    else:
        assert args[args.index('-X') + 1] == 'POST'
        assert 'https://api.github.com/app/installations/7/access_tokens' in args
        assert args[args.index('-d') + 1] == sys.argv[2], 'repository/permission body changed'
PY
}

for mode in full scoped; do
  permissions=''
  expected='{"repositories":["example-repo"]}'
  if [[ "$mode" == scoped ]]; then
    permissions='{"pull_requests":"read","contents":"read"}'
    expected='{"repositories":["example-repo"],"permissions":{"contents":"read","pull_requests":"read"}}'
  fi
  if run_case "$mode" "$permissions"; then
    if [[ "$(< "$CASE_DIR/stdout")" == "$EXPECTED_TOKEN" && ! -s "$CASE_DIR/stderr" ]]; then
      pass "$mode token return semantics"
    else
      fail "$mode token return semantics"
    fi
  else
    fail "$mode exchange unexpectedly failed"
  fi
  if check_request_contract "$expected"; then pass "$mode safe bounded request contract"; else fail "$mode safe bounded request contract"; fi
done

for phase in lookup exchange; do
  for kind in http missing invalid-json invalid-status transport; do
    if run_case "$phase-$kind"; then
      fail "$phase-$kind must fail closed"
    elif [[ -s "$CASE_DIR/stdout" || ! -s "$CASE_DIR/stderr" ]]; then
      fail "$phase-$kind must return no token and a diagnostic"
    else
      pass "$phase-$kind fails closed"
    fi
    if grep -F -e "$RESPONSE_SECRET" -e "$EXPECTED_TOKEN" -e "$TEST_FAKE_JWT" "$CASE_DIR/stdout" "$CASE_DIR/stderr" >/dev/null; then
      fail "$phase-$kind exposed credential or response content"
    else
      pass "$phase-$kind sanitized diagnostics"
    fi
    if [[ "$phase" == lookup && "$(< "$CASE_DIR/count")" != 1 ]]; then
      fail "$phase-$kind continued to token exchange"
    fi
  done
done

printf '\nPASS: %s\nFAIL: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
