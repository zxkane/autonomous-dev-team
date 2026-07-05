#!/bin/bash
# test-lib-gitlab-transport.sh — issue #416, INV-116.
#
# Drives skills/autonomous-dispatcher/scripts/providers/lib-gitlab-transport.sh
# hermetically via a stubbed `curl` on an isolated PATH. TC IDs per
# docs/test-cases/w-a-gitlab-transport.md.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-lib-gitlab-transport.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/lib-gitlab-transport.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then ok "$d"; else bad "$d"; echo "      expected='$e' actual='$a'"; fi; }
assert_ne() { local d="$1" e="$2" a="$3"; if [[ "$e" != "$a" ]]; then ok "$d"; else bad "$d"; echo "      expected!='$e' actual='$a'"; fi; }
assert_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      needle='$n'"; echo "      haystack='${h:0:400}'"; fi; }
assert_rc_nonzero() { local d="$1" rc="$2"; if [[ "$rc" -ne 0 ]]; then ok "$d"; else bad "$d (rc was 0)"; fi; }

[[ -f "$LIB" ]] || { echo "FATAL: $LIB not found"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# Stub curl on the isolated PATH.
#
# The stub reads control-file env vars to decide what to emit:
#   _CURL_HEADER_FILE   — absolute path where the stub writes response headers
#                         (the header block for -D <file>; the stub finds -D
#                         in argv itself, but exposes the path for the driver
#                         to assert on).
#   _CURL_ARGV_FILE     — where to record argv (one arg per line, with a
#                         separator line `---` between invocations).
#   _CURL_STATUS_SEQ    — colon-separated HTTP statuses to serve, one per
#                         invocation (`200`, `200:200:404`, `429:429:200`).
#                         Missing = 200.
#   _CURL_BODY_SEQ      — colon-separated file paths, one per invocation,
#                         whose contents become the response body on stdout.
#                         Missing → empty body.
#   _CURL_HDR_EXTRA_SEQ — colon-separated file paths whose contents are
#                         APPENDED to the -D headers file after `HTTP/1.1
#                         <status>`. Encodes `x-next-page: 2` /
#                         `retry-after: 1` etc. Missing → no extra headers.
#   _CURL_INVOKE_STATE  — file holding the 1-indexed invocation count.
#                         Incremented on every call.
#   _CURL_RC            — if set, the stub exits with that rc AFTER writing
#                         (used to simulate a transport failure).
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/curl" <<'STUB'
#!/bin/bash
# Hermetic stub for `curl` (test-lib-gitlab-transport.sh).
set +e

# Update invocation counter first so seq indexing is correct even for the
# very first call.
_inv=0
if [[ -n "${_CURL_INVOKE_STATE:-}" && -f "$_CURL_INVOKE_STATE" ]]; then
  _inv=$(<"$_CURL_INVOKE_STATE")
fi
_inv=$((_inv + 1))
[[ -n "${_CURL_INVOKE_STATE:-}" ]] && printf '%s' "$_inv" > "$_CURL_INVOKE_STATE"

# Record argv (one arg per line, `---` marker between invocations).
if [[ -n "${_CURL_ARGV_FILE:-}" ]]; then
  {
    printf '%s\n' "--- invocation $_inv ---"
    for a in "$@"; do printf '%s\n' "$a"; done
  } >> "$_CURL_ARGV_FILE"
fi

# Find the -D argument (headers dump file).
_hdr_file=""
_prev=""
for a in "$@"; do
  if [[ "$_prev" == "-D" ]]; then _hdr_file="$a"; break; fi
  _prev="$a"
done

# Pick the status for this invocation.
_status="200"
if [[ -n "${_CURL_STATUS_SEQ:-}" ]]; then
  IFS=':' read -ra _stats <<< "$_CURL_STATUS_SEQ"
  _idx=$((_inv - 1))
  if (( _idx >= ${#_stats[@]} )); then _idx=$(( ${#_stats[@]} - 1 )); fi
  _status="${_stats[$_idx]}"
fi

# Write headers.
if [[ -n "$_hdr_file" ]]; then
  {
    printf 'HTTP/1.1 %s OK\r\n' "$_status"
    if [[ -n "${_CURL_HDR_EXTRA_SEQ:-}" ]]; then
      IFS=':' read -ra _hexs <<< "$_CURL_HDR_EXTRA_SEQ"
      _hidx=$((_inv - 1))
      if (( _hidx >= ${#_hexs[@]} )); then _hidx=$(( ${#_hexs[@]} - 1 )); fi
      _hextra="${_hexs[$_hidx]}"
      if [[ -n "$_hextra" && -f "$_hextra" ]]; then
        cat "$_hextra"
      fi
    fi
    printf '\r\n'
  } > "$_hdr_file"
fi

# Write body.
if [[ -n "${_CURL_BODY_SEQ:-}" ]]; then
  IFS=':' read -ra _bods <<< "$_CURL_BODY_SEQ"
  _bidx=$((_inv - 1))
  if (( _bidx >= ${#_bods[@]} )); then _bidx=$(( ${#_bods[@]} - 1 )); fi
  _body="${_bods[$_bidx]}"
  if [[ -n "$_body" && -f "$_body" ]]; then
    cat "$_body"
  fi
fi

exit "${_CURL_RC:-0}"
STUB
chmod +x "$STUB_DIR/curl"

# Stub sleep — records the duration to _SLEEP_LOG_FILE without actually
# sleeping (keeps the test fast even under a 429 test that requests many
# retries). The real bash `sleep` is not shadowed everywhere — bash may
# resolve `sleep` builtin-first in some builds — so we install this as a
# PATH shim; the transport lib uses bare `sleep` in a normal shell so PATH
# lookup wins.
cat > "$STUB_DIR/sleep" <<'STUB'
#!/bin/bash
if [[ -n "${_SLEEP_LOG_FILE:-}" ]]; then
  printf '%s\n' "$1" >> "$_SLEEP_LOG_FILE"
fi
exit 0
STUB
chmod +x "$STUB_DIR/sleep"

# Isolated PATH: our stubs + the essential real binaries lib-gitlab-transport
# needs (bash, jq, sed, awk, tr, cat, printf, mktemp, rm, head — all in
# coreutils/bin). Reuse the parent PATH's tool dirs so jq etc. still resolve.
ISOLATED_PATH="$STUB_DIR"
for tool in bash env jq awk sed grep tr cat printf mktemp rm head chmod dirname mkdir; do
  d=$(command -v "$tool" 2>/dev/null) || continue
  d=$(dirname "$d")
  [[ ":$ISOLATED_PATH:" == *":$d:"* ]] || ISOLATED_PATH="$ISOLATED_PATH:$d"
done

# _run_with_lib <body> — evaluate BODY in a fresh subshell under the
# isolated PATH, with lib-gitlab-transport.sh sourced. Returns rc + stdout
# via echo, stderr passthrough. Every test that drives _gl_api runs through
# this so the transport lib is exercised on a real fresh process.
_run_with_lib() {
  local body="$1"
  env -u PROJECT_DIR PATH="$ISOLATED_PATH" "GITLAB_TOKEN=${GITLAB_TOKEN:-}" "GITLAB_HOST=${GITLAB_HOST:-gitlab.com}" \
      "GITLAB_TRANSPORT_HOOK=${GITLAB_TRANSPORT_HOOK:-}" \
      "_CURL_ARGV_FILE=${_CURL_ARGV_FILE:-}" \
      "_CURL_STATUS_SEQ=${_CURL_STATUS_SEQ:-}" \
      "_CURL_BODY_SEQ=${_CURL_BODY_SEQ:-}" \
      "_CURL_HDR_EXTRA_SEQ=${_CURL_HDR_EXTRA_SEQ:-}" \
      "_CURL_INVOKE_STATE=${_CURL_INVOKE_STATE:-}" \
      "_CURL_RC=${_CURL_RC:-0}" \
      "_SLEEP_LOG_FILE=${_SLEEP_LOG_FILE:-}" \
      "GL_TRANSPORT_PAGE_CAP=${GL_TRANSPORT_PAGE_CAP:-50}" \
      "GL_TRANSPORT_MAX_RETRIES=${GL_TRANSPORT_MAX_RETRIES:-3}" \
      bash -c "source '$LIB'; $body"
}

# _reset_control — reset per-test control files (argv/invocation/sleep-log)
# so each test starts fresh.
_reset_control() {
  _CURL_ARGV_FILE="$WORK/curl-argv.log"; : > "$_CURL_ARGV_FILE"
  _CURL_INVOKE_STATE="$WORK/curl-inv"; : > "$_CURL_INVOKE_STATE"
  _SLEEP_LOG_FILE="$WORK/sleep-log"; : > "$_SLEEP_LOG_FILE"
  _CURL_STATUS_SEQ=""
  _CURL_BODY_SEQ=""
  _CURL_HDR_EXTRA_SEQ=""
  _CURL_RC=0
  export _CURL_ARGV_FILE _CURL_INVOKE_STATE _SLEEP_LOG_FILE \
         _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ _CURL_RC
  # Reset GITLAB_TOKEN/hook to defaults; each test overrides.
  unset GITLAB_TRANSPORT_HOOK
  export GITLAB_TOKEN="test-token"
  export GITLAB_HOST="gitlab.example"
}

# ===========================================================================
echo "=== TC-GLT-001..005: preflight fail-loud ==="
# ===========================================================================
_reset_control
unset GITLAB_TOKEN
export GITLAB_TOKEN=""
out=$(_run_with_lib '_gl_api /projects/1/issues/42' 2>&1); rc=$?
assert_rc_nonzero "TC-GLT-001: GITLAB_TOKEN unset + no hook → rc != 0" "$rc"
assert_contains "TC-GLT-001: message names GITLAB_TOKEN" "GITLAB_TOKEN" "$out"
# curl NEVER invoked (argv file has no `--- invocation` lines).
_curl_inv_count() { local n; n=$(grep -c '^--- invocation' "$1" 2>/dev/null); [[ -z "$n" ]] && n=0; printf '%s' "$n"; }
assert_eq "TC-GLT-001: no curl invocation" "0" "$(_curl_inv_count "$_CURL_ARGV_FILE")"

_reset_control
export GITLAB_TRANSPORT_HOOK="/no/such/gitlab-hook-file.sh"
out=$(_run_with_lib '_gl_api /projects/1/issues/42' 2>&1); rc=$?
assert_rc_nonzero "TC-GLT-002: unreadable hook path → rc != 0" "$rc"
assert_contains "TC-GLT-002: message names the unreadable path" "/no/such/gitlab-hook-file.sh" "$out"

# TC-GLT-003 (codex round-1 [P1-4]): a hook that does NOT redefine _gl_http
# must FAIL preflight, even though the default _gl_http is already defined
# by the lib. Pre-P1-4 the test masked this by `unset -f _gl_http` before
# the call — that mask is REMOVED now (the fix must not require an
# artificial pre-condition to fire). The preflight snapshots the pre-source
# body and requires the post-source body to differ.
_reset_control
hook_no_glhttp="$WORK/hook-no-glhttp.sh"
cat > "$hook_no_glhttp" <<'EOF'
# Hook that does NOT redefine _gl_http (defines an unrelated function only).
_some_unrelated_helper() { echo "helper"; }
EOF
export GITLAB_TRANSPORT_HOOK="$hook_no_glhttp"
# NOTE: no `unset -f _gl_http` — the default is left in place, matching
# the real-world condition the P1-4 fix targets.
out=$(_run_with_lib '_gl_api /projects/1/issues/42' 2>&1); rc=$?
assert_rc_nonzero "TC-GLT-003: hook that does NOT redefine _gl_http (default still in place) → rc != 0" "$rc"
assert_contains "TC-GLT-003: message names the hook path" "$hook_no_glhttp" "$out"
assert_contains "TC-GLT-003: message explains the no-op-hook failure" "did NOT redefine _gl_http" "$out"

# TC-GLT-003b (P1-4 regression): an empty hook file also fails preflight.
_reset_control
hook_empty="$WORK/hook-empty.sh"
: > "$hook_empty"
export GITLAB_TRANSPORT_HOOK="$hook_empty"
out=$(_run_with_lib '_gl_api /projects/1/issues/42' 2>&1); rc=$?
assert_rc_nonzero "TC-GLT-003b: empty hook file → rc != 0 (no-op hook rejected)" "$rc"
assert_contains "TC-GLT-003b: message names hook path" "$hook_empty" "$out"

# TC-GLT-004: preflight latched — 2 _gl_api calls emit preflight log once.
_reset_control
body_hello="$WORK/body-hello.json"; printf '{"iid":42}' > "$body_hello"
_CURL_BODY_SEQ="$body_hello:$body_hello"
export _CURL_BODY_SEQ
out=$(_run_with_lib '_gl_api /projects/1/issues/42 >/dev/null; _gl_api /projects/1/issues/43 >/dev/null' 2>&1); rc=$?
assert_eq "TC-GLT-004: 2 successful _gl_api calls, rc 0" "0" "$rc"
preflight_count=$(grep -c "gitlab-transport preflight OK" <<<"$out")
assert_eq "TC-GLT-004: preflight logged exactly ONCE (latched)" "1" "$preflight_count"
assert_eq "TC-GLT-004: 2 curl invocations" "2" "$(grep -c '^--- invocation' "$_CURL_ARGV_FILE")"

# TC-GLT-005: hook redefines _gl_http cleanly, curl NEVER invoked.
_reset_control
hook_ok="$WORK/hook-ok.sh"
cat > "$hook_ok" <<'EOF'
_gl_http() {
  local method="$1" path="$2" hdr="$3" body_json="${4:-}"
  printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
  printf '{"hooked":true,"path":"%s"}' "$path"
  return 0
}
EOF
export GITLAB_TRANSPORT_HOOK="$hook_ok"
out=$(_run_with_lib 'body=$(_gl_api /projects/1/issues/42); printf "%s" "$body"' 2>&1); rc=$?
assert_eq "TC-GLT-005: hook path — rc 0" "0" "$rc"
assert_contains "TC-GLT-005: body reflects hook output" '"hooked":true' "$out"
# curl NEVER invoked (argv file has no --- invocation line).
assert_eq "TC-GLT-005: curl not invoked (hook takes over)" "0" "$(_curl_inv_count "$_CURL_ARGV_FILE")"

# ===========================================================================
echo ""
echo "=== TC-GLT-010..018: _gl_http shape ==="
# ===========================================================================
# TC-GLT-010: GET returning 200 with a body.
_reset_control
body_ok="$WORK/body-ok.json"; printf '{"iid":42}' > "$body_ok"
_CURL_STATUS_SEQ="200"; _CURL_BODY_SEQ="$body_ok"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
out=$(_run_with_lib 'hdr="$(mktemp)"; body=$(_gl_http GET /projects/1/issues/42 "$hdr"); printf "%s\n---HDR---\n" "$body"; cat "$hdr"' 2>&1); rc=$?
assert_eq "TC-GLT-010: _gl_http rc 0 on 200" "0" "$rc"
assert_contains "TC-GLT-010: body on stdout" '"iid":42' "$out"
assert_contains "TC-GLT-010: HTTP/1.1 200 in header file" "HTTP/1.1 200" "$out"

# TC-GLT-011: 404 — rc 0 (transport succeeded), body on stdout.
_reset_control
body_404="$WORK/body-404.json"; printf '{"message":"404 Not Found"}' > "$body_404"
_CURL_STATUS_SEQ="404"; _CURL_BODY_SEQ="$body_404"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
out=$(_run_with_lib 'hdr="$(mktemp)"; body=$(_gl_http GET /projects/1/issues/999 "$hdr"); printf "%s\n---HDR---\n" "$body"; cat "$hdr"' 2>&1); rc=$?
assert_eq "TC-GLT-011: _gl_http rc 0 on 404 (transport ok)" "0" "$rc"
assert_contains "TC-GLT-011: 404 body on stdout" "404 Not Found" "$out"
assert_contains "TC-GLT-011: HTTP/1.1 404 in header file" "HTTP/1.1 404" "$out"

# TC-GLT-013: absolute URL used verbatim.
_reset_control
body_abs="$WORK/body-abs.json"; printf '{"abs":true}' > "$body_abs"
_CURL_STATUS_SEQ="200"; _CURL_BODY_SEQ="$body_abs"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
out=$(_run_with_lib 'hdr="$(mktemp)"; _gl_http GET "https://other.example/api/v4/projects/1?page=2" "$hdr" >/dev/null' 2>&1); rc=$?
assert_eq "TC-GLT-013: absolute URL rc 0" "0" "$rc"
assert_contains "TC-GLT-013: curl argv contains the exact absolute URL" "https://other.example/api/v4/projects/1?page=2" "$(cat "$_CURL_ARGV_FILE")"

# TC-GLT-014: PRIVATE-TOKEN header present in curl argv.
_reset_control
out=$(_run_with_lib 'hdr="$(mktemp)"; _gl_http GET /projects/1/issues/42 "$hdr" >/dev/null' 2>&1)
argv=$(cat "$_CURL_ARGV_FILE")
assert_contains "TC-GLT-014: curl argv contains PRIVATE-TOKEN header" "PRIVATE-TOKEN: test-token" "$argv"

# TC-GLT-015: POST with body-json — Content-Type + --data-binary.
_reset_control
out=$(_run_with_lib 'hdr="$(mktemp)"; _gl_http POST /projects/1/issues "$hdr" "{\"title\":\"t\"}" >/dev/null' 2>&1)
argv=$(cat "$_CURL_ARGV_FILE")
assert_contains "TC-GLT-015: curl argv contains -X POST" "POST" "$argv"
assert_contains "TC-GLT-015: curl argv contains Content-Type: application/json" "Content-Type: application/json" "$argv"
assert_contains "TC-GLT-015: curl argv contains --data-binary with body-json" '{"title":"t"}' "$argv"

# TC-GLT-016: curl transport rc != 0 → _gl_http rc != 0.
_reset_control
_CURL_RC=6
export _CURL_RC
out=$(_run_with_lib 'hdr="$(mktemp)"; _gl_http GET /projects/1/issues/42 "$hdr" >/dev/null' 2>&1); rc=$?
assert_rc_nonzero "TC-GLT-016: _gl_http rc != 0 on curl transport failure" "$rc"

# TC-GLT-017: paginated response headers x-next-page + x-total-pages preserved.
_reset_control
body_p1="$WORK/body-p1.json"; printf '[]' > "$body_p1"
hdr_extra_p1="$WORK/hdr-extra-p1.txt"; printf 'x-next-page: 2\r\nx-total-pages: 5\r\n' > "$hdr_extra_p1"
_CURL_STATUS_SEQ="200"; _CURL_BODY_SEQ="$body_p1"; _CURL_HDR_EXTRA_SEQ="$hdr_extra_p1"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ
out=$(_run_with_lib 'hdr="$(mktemp)"; _gl_http GET /projects/1/issues "$hdr" >/dev/null; cat "$hdr"' 2>&1)
assert_contains "TC-GLT-017: headers file records x-next-page: 2" "x-next-page: 2" "$out"
assert_contains "TC-GLT-017: headers file records x-total-pages: 5" "x-total-pages: 5" "$out"

# TC-GLT-018: Retry-After header preserved.
_reset_control
body_429="$WORK/body-429.json"; printf '{"message":"rate limited"}' > "$body_429"
hdr_extra_429="$WORK/hdr-extra-429.txt"; printf 'Retry-After: 3\r\n' > "$hdr_extra_429"
_CURL_STATUS_SEQ="429"; _CURL_BODY_SEQ="$body_429"; _CURL_HDR_EXTRA_SEQ="$hdr_extra_429"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ
out=$(_run_with_lib 'hdr="$(mktemp)"; _gl_http GET /projects/1/issues "$hdr" >/dev/null; cat "$hdr"' 2>&1)
assert_contains "TC-GLT-018: headers file records Retry-After: 3" "Retry-After: 3" "$out"

# ===========================================================================
echo ""
echo "=== TC-GLT-020..026: _gl_api pagination walk ==="
# ===========================================================================
# TC-GLT-020: single-page paginate → body as-is.
_reset_control
body_single="$WORK/body-single.json"; printf '[{"a":1}]' > "$body_single"
_CURL_STATUS_SEQ="200"; _CURL_BODY_SEQ="$body_single"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
out=$(_run_with_lib '_gl_api --paginate /projects/1/issues' 2>/dev/null); rc=$?
assert_eq "TC-GLT-020: single-page paginate rc 0" "0" "$rc"
# jq -s pretty-prints; assert semantic equality via jq itself (compact-form
# comparison), not exact byte-equal.
compact=$(jq -c . <<<"$out" 2>/dev/null)
assert_eq "TC-GLT-020: single-page paginate body (compact JSON equality)" '[{"a":1}]' "$compact"

# TC-GLT-021 + TC-GLT-022: 3-page walk merges into one array; next-page
# reconstruction on original path with page=N.
_reset_control
body_p1="$WORK/body-p1.json"; printf '[{"n":1}]' > "$body_p1"
body_p2="$WORK/body-p2.json"; printf '[{"n":2}]' > "$body_p2"
body_p3="$WORK/body-p3.json"; printf '[{"n":3}]' > "$body_p3"
hdr_p1="$WORK/hdr-p1.txt"; printf 'x-next-page: 2\r\n' > "$hdr_p1"
hdr_p2="$WORK/hdr-p2.txt"; printf 'x-next-page: 3\r\n' > "$hdr_p2"
hdr_p3="$WORK/hdr-p3.txt"; : > "$hdr_p3"
_CURL_STATUS_SEQ="200:200:200"
_CURL_BODY_SEQ="$body_p1:$body_p2:$body_p3"
_CURL_HDR_EXTRA_SEQ="$hdr_p1:$hdr_p2:$hdr_p3"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ
out=$(_run_with_lib '_gl_api --paginate /projects/1/issues' 2>/dev/null); rc=$?
assert_eq "TC-GLT-021: 3-page walk rc 0" "0" "$rc"
merged_n=$(jq -r 'map(.n) | join(",")' <<<"$out" 2>/dev/null)
assert_eq "TC-GLT-021: merged array is [1,2,3] in order" "1,2,3" "$merged_n"
argv=$(cat "$_CURL_ARGV_FILE")
# TC-GLT-022: verify page=2 in invocation #2 and page=3 in #3.
assert_contains "TC-GLT-022: invocation #2 curl argv contains page=2" "page=2" "$argv"
assert_contains "TC-GLT-022: invocation #3 curl argv contains page=3" "page=3" "$argv"

# TC-GLT-023: mid-walk failure — page 2 returns 500 → rc != 0, stdout empty.
_reset_control
body_p1="$WORK/body-p1.json"; printf '[{"n":1}]' > "$body_p1"
body_p2err="$WORK/body-p2err.json"; printf '{"message":"internal server error"}' > "$body_p2err"
hdr_p1="$WORK/hdr-p1.txt"; printf 'x-next-page: 2\r\n' > "$hdr_p1"
_CURL_STATUS_SEQ="200:500"
_CURL_BODY_SEQ="$body_p1:$body_p2err"
_CURL_HDR_EXTRA_SEQ="$hdr_p1:"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ
out=$(_run_with_lib '_gl_api --paginate /projects/1/issues' 2>/dev/null); rc=$?
assert_rc_nonzero "TC-GLT-023: mid-walk 500 → rc != 0" "$rc"
assert_eq "TC-GLT-023: fail-CLOSED, stdout empty" "" "$out"

# TC-GLT-024: cap-hit — GL_TRANSPORT_PAGE_CAP=2 but response advertises next-page:3.
_reset_control
body_p1="$WORK/body-p1.json"; printf '[{"n":1}]' > "$body_p1"
body_p2="$WORK/body-p2.json"; printf '[{"n":2}]' > "$body_p2"
hdr_p1="$WORK/hdr-p1.txt"; printf 'x-next-page: 2\r\n' > "$hdr_p1"
hdr_p2="$WORK/hdr-p2.txt"; printf 'x-next-page: 3\r\n' > "$hdr_p2"
_CURL_STATUS_SEQ="200:200"
_CURL_BODY_SEQ="$body_p1:$body_p2"
_CURL_HDR_EXTRA_SEQ="$hdr_p1:$hdr_p2"
GL_TRANSPORT_PAGE_CAP=2
export _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ GL_TRANSPORT_PAGE_CAP
out=$(_run_with_lib '_gl_api --paginate /projects/1/issues' 2>/dev/null); rc=$?
unset GL_TRANSPORT_PAGE_CAP
assert_rc_nonzero "TC-GLT-024: cap-hit → rc != 0" "$rc"
assert_eq "TC-GLT-024: cap-hit, stdout empty" "" "$out"

# TC-GLT-025: --max-items bounded read.
_reset_control
body_p1="$WORK/body-p1.json"; printf '[{"n":1},{"n":2},{"n":3}]' > "$body_p1"
body_p2="$WORK/body-p2.json"; printf '[{"n":4},{"n":5},{"n":6}]' > "$body_p2"
hdr_p1="$WORK/hdr-p1.txt"; printf 'x-next-page: 2\r\n' > "$hdr_p1"
hdr_p2="$WORK/hdr-p2.txt"; printf 'x-next-page: 3\r\n' > "$hdr_p2"
_CURL_STATUS_SEQ="200:200"
_CURL_BODY_SEQ="$body_p1:$body_p2"
_CURL_HDR_EXTRA_SEQ="$hdr_p1:$hdr_p2"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ
out=$(_run_with_lib '_gl_api --paginate --max-items 2 /projects/1/issues' 2>/dev/null); rc=$?
assert_eq "TC-GLT-025: --max-items 2 rc 0" "0" "$rc"
merged_len=$(jq 'length' <<<"$out" 2>/dev/null)
assert_eq "TC-GLT-025: array length == 2 (bounded)" "2" "$merged_len"

# ===========================================================================
echo ""
echo "=== TC-GLT-030..033: _gl_api 429 / Retry-After backoff ==="
# ===========================================================================
# TC-GLT-030: 429 twice with Retry-After: 1, third returns 200.
_reset_control
body_429="$WORK/body-429.json"; printf '{"m":"rl"}' > "$body_429"
body_ok="$WORK/body-ok.json"; printf '{"iid":42}' > "$body_ok"
hdr_429="$WORK/hdr-429.txt"; printf 'Retry-After: 1\r\n' > "$hdr_429"
hdr_ok="$WORK/hdr-ok.txt"; : > "$hdr_ok"
_CURL_STATUS_SEQ="429:429:200"
_CURL_BODY_SEQ="$body_429:$body_429:$body_ok"
_CURL_HDR_EXTRA_SEQ="$hdr_429:$hdr_429:$hdr_ok"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ
out=$(_run_with_lib '_gl_api /projects/1/issues/42' 2>/dev/null); rc=$?
assert_eq "TC-GLT-030: 429×2 → 200 rc 0" "0" "$rc"
assert_contains "TC-GLT-030: body on stdout after retries" '"iid":42' "$out"
sleep_count=$(wc -l < "$_SLEEP_LOG_FILE" 2>/dev/null | tr -d ' ')
assert_eq "TC-GLT-030: 2 sleep calls recorded" "2" "$sleep_count"

# TC-GLT-031: 429 exhausted.
_reset_control
body_429="$WORK/body-429.json"; printf '{"m":"rl"}' > "$body_429"
hdr_429="$WORK/hdr-429.txt"; printf 'Retry-After: 1\r\n' > "$hdr_429"
_CURL_STATUS_SEQ="429:429:429:429"
_CURL_BODY_SEQ="$body_429:$body_429:$body_429:$body_429"
_CURL_HDR_EXTRA_SEQ="$hdr_429:$hdr_429:$hdr_429:$hdr_429"
GL_TRANSPORT_MAX_RETRIES=3
export _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ GL_TRANSPORT_MAX_RETRIES
out=$(_run_with_lib '_gl_api /projects/1/issues/42' 2>/dev/null); rc=$?
assert_rc_nonzero "TC-GLT-031: 429 exhausted → rc != 0" "$rc"
assert_eq "TC-GLT-031: stdout empty" "" "$out"
unset GL_TRANSPORT_MAX_RETRIES

# TC-GLT-032: Retry-After: 90 capped at 60s.
_reset_control
body_429="$WORK/body-429.json"; printf '{"m":"rl"}' > "$body_429"
body_ok="$WORK/body-ok.json"; printf '{"iid":42}' > "$body_ok"
hdr_big="$WORK/hdr-big.txt"; printf 'Retry-After: 90\r\n' > "$hdr_big"
hdr_ok="$WORK/hdr-ok.txt"; : > "$hdr_ok"
_CURL_STATUS_SEQ="429:200"
_CURL_BODY_SEQ="$body_429:$body_ok"
_CURL_HDR_EXTRA_SEQ="$hdr_big:$hdr_ok"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ _CURL_HDR_EXTRA_SEQ
out=$(_run_with_lib '_gl_api /projects/1/issues/42' 2>/dev/null); rc=$?
assert_eq "TC-GLT-032: retry succeeds rc 0" "0" "$rc"
sleep_val=$(head -n1 "$_SLEEP_LOG_FILE" 2>/dev/null)
if [[ "$sleep_val" -le 60 ]]; then
  ok "TC-GLT-032: sleep capped at ≤ 60s (was $sleep_val)"
else
  bad "TC-GLT-032: sleep NOT capped (was $sleep_val)"
fi

# TC-GLT-033: non-429 5xx does NOT trigger the backoff retry loop.
_reset_control
body_500="$WORK/body-500.json"; printf '{"m":"internal"}' > "$body_500"
_CURL_STATUS_SEQ="503"
_CURL_BODY_SEQ="$body_500"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
out=$(_run_with_lib '_gl_api /projects/1/issues/42' 2>/dev/null); rc=$?
assert_rc_nonzero "TC-GLT-033: 5xx rc != 0" "$rc"
inv_count=$(grep -c '^--- invocation' "$_CURL_ARGV_FILE")
assert_eq "TC-GLT-033: only 1 curl invocation (no retry on non-429)" "1" "$inv_count"

# ===========================================================================
echo ""
echo "=== TC-GLT-040..045: HTTP-status channel + --tolerate-status ==="
# ===========================================================================
# TC-GLT-040: GL_API_STATUS set in calling shell via redirect (not $()).
_reset_control
body_ok="$WORK/body-ok.json"; printf '{"iid":42}' > "$body_ok"
_CURL_STATUS_SEQ="200"
_CURL_BODY_SEQ="$body_ok"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
out=$(_run_with_lib '_gl_api /projects/1/issues/42 > /dev/null; echo "STATUS=${GL_API_STATUS}"' 2>&1)
assert_contains "TC-GLT-040: GL_API_STATUS==200 after redirect-form call" "STATUS=200" "$out"

# TC-GLT-041: --status-out FILE captures status.
_reset_control
_CURL_STATUS_SEQ="200"; _CURL_BODY_SEQ="$body_ok"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
status_out="$WORK/status-out.txt"; : > "$status_out"
out=$(_run_with_lib "_gl_api --status-out '$status_out' /projects/1/issues/42 > /dev/null" 2>&1)
assert_eq "TC-GLT-041: --status-out contains 200" "200" "$(cat "$status_out")"

# TC-GLT-042: --tolerate-status 404 on a 404 → rc 0, body on stdout.
_reset_control
body_404="$WORK/body-404.json"; printf '{"message":"nf"}' > "$body_404"
_CURL_STATUS_SEQ="404"; _CURL_BODY_SEQ="$body_404"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
out=$(_run_with_lib '_gl_api --tolerate-status 404 /projects/1/issues/42' 2>/dev/null); rc=$?
assert_eq "TC-GLT-042: --tolerate-status 404 on 404 rc 0" "0" "$rc"
assert_contains "TC-GLT-042: 404 body on stdout" "nf" "$out"

# TC-GLT-043: --tolerate-status 404,409 on 409 → rc 0.
_reset_control
body_409="$WORK/body-409.json"; printf '{"message":"conflict"}' > "$body_409"
_CURL_STATUS_SEQ="409"; _CURL_BODY_SEQ="$body_409"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
out=$(_run_with_lib '_gl_api --tolerate-status 404,409 /projects/1/issues/42' 2>/dev/null); rc=$?
assert_eq "TC-GLT-043: --tolerate-status 404,409 on 409 rc 0" "0" "$rc"
assert_contains "TC-GLT-043: 409 body on stdout" "conflict" "$out"

# TC-GLT-044: --tolerate-status 404 on 500 → rc != 0.
_reset_control
body_500="$WORK/body-500.json"; printf '{"message":"boom"}' > "$body_500"
_CURL_STATUS_SEQ="500"; _CURL_BODY_SEQ="$body_500"
export _CURL_STATUS_SEQ _CURL_BODY_SEQ
out=$(_run_with_lib '_gl_api --tolerate-status 404 /projects/1/issues/42 >/dev/null; echo "STATUS=${GL_API_STATUS}"' 2>/dev/null)
assert_contains "TC-GLT-044: --tolerate-status 404 on 500 sets GL_API_STATUS=500" "STATUS=500" "$out"

# TC-GLT-045: transport failure (curl rc != 0) — not toleratable.
_reset_control
_CURL_RC=6
export _CURL_RC
out=$(_run_with_lib '_gl_api --tolerate-status 404 /projects/1/issues/42' 2>/dev/null); rc=$?
assert_rc_nonzero "TC-GLT-045: transport failure not toleratable" "$rc"

# ===========================================================================
echo ""
echo "=== TC-GLT-050..052: _gl_urlencode ==="
# ===========================================================================
_reset_control
enc=$(_run_with_lib "_gl_urlencode 'group/subgroup/project'" 2>/dev/null)
assert_eq "TC-GLT-050: group/subgroup/project → group%2Fsubgroup%2Fproject" "group%2Fsubgroup%2Fproject" "$enc"
enc=$(_run_with_lib "_gl_urlencode 'feature/foo bar'" 2>/dev/null)
assert_eq "TC-GLT-051: feature/foo bar → feature%2Ffoo%20bar" "feature%2Ffoo%20bar" "$enc"
enc=$(_run_with_lib "_gl_urlencode 'label with & ampersand'" 2>/dev/null)
assert_contains "TC-GLT-052: & → %26 in urlencode" "%26" "$enc"

# ===========================================================================
echo ""
echo "=== TC-GLT-060..063: override hook ==="
# ===========================================================================
_reset_control
hook_recorded="$WORK/hook-recorded.sh"
cat > "$hook_recorded" <<'EOF'
_gl_http() {
  local method="$1" path="$2" hdr="$3" body_json="${4:-}"
  printf 'HTTP/1.1 200 OK\r\n\r\n' > "$hdr"
  printf '[{"canned":true,"path":"%s"}]' "$path"
  return 0
}
_hook_private_helper() { echo "helper"; }
EOF
export GITLAB_TRANSPORT_HOOK="$hook_recorded"
out=$(_run_with_lib '_gl_api /projects/1/issues' 2>/dev/null); rc=$?
assert_eq "TC-GLT-060: hook path rc 0" "0" "$rc"
# hook body — assert via jq semantic equality, not raw string match (jq -s may
# pretty-print with `"canned": true` vs `"canned":true`).
if jq -e '.[0].canned == true' <<<"$out" >/dev/null 2>&1 || jq -e '.canned == true' <<<"$out" >/dev/null 2>&1; then
  ok "TC-GLT-060: hook body semantically carries canned:true"
else
  bad "TC-GLT-060: hook body missing canned:true (out: ${out:0:200})"
fi
assert_eq "TC-GLT-060: curl NEVER invoked (hook takes over)" "0" "$(_curl_inv_count "$_CURL_ARGV_FILE")"
# TC-GLT-061: private helper alongside is not rejected.
assert_eq "TC-GLT-061: private helper alongside → still rc 0" "0" "$rc"

# TC-GLT-063: hook + pagination — hook must produce multi-page shape via header.
# We simplify: assert that a paginate call over the hook returns the hook's body verbatim
# (no next-page header from the hook, so single-page merge yields the body as-is).
_reset_control
export GITLAB_TRANSPORT_HOOK="$hook_recorded"
out=$(_run_with_lib '_gl_api --paginate /projects/1/issues' 2>/dev/null); rc=$?
assert_eq "TC-GLT-063: hook + --paginate single-page rc 0" "0" "$rc"
if jq -e '(type == "array" and .[0].canned == true) or (type == "object" and .canned == true)' <<<"$out" >/dev/null 2>&1; then
  ok "TC-GLT-063: hook + --paginate body preserved (semantic canned:true)"
else
  bad "TC-GLT-063: hook + --paginate body missing canned:true (out: ${out:0:200})"
fi

# ===========================================================================
echo ""
echo "=== TC-GLT-070..071: set -e safety — transport failure inside _gl_api under set -euo pipefail (P1-3) ==="
# ===========================================================================
# [#416 P1-3] Codex round-1 [P1-3]: pre-fix, `_gl_http … > "$body_file"`
# inside `_do_request_with_backoff` was a bare simple command — under a
# caller's `set -euo pipefail` a curl-rc-non-zero transport failure aborts
# the CALLING shell before http_rc/`_record_status`/`--status-out`
# mirroring runs. Fix: `if ! _gl_http …; then http_rc=$?; else http_rc=0;
# fi` — bash `set -e` skips exit on tested commands, so the caller shell
# survives and `_gl_api` returns rc≠0 cleanly.

# TC-GLT-070: source lib + call _gl_api under set -euo pipefail; simulate
# transport failure (curl rc 6). The caller shell MUST reach the SURVIVED
# marker AFTER the failing _gl_api call.
_reset_control
_CURL_RC=6
export _CURL_RC

driver_p1_3="$WORK/driver-p1-3-strict.sh"
cat > "$driver_p1_3" <<DRV
#!/bin/bash
set -euo pipefail
source "$LIB"
_gl_api /projects/1/issues/42 > /dev/null 2>&1 && rc_captured=0 || rc_captured=\$?
printf 'rc_captured=%s\n' "\$rc_captured"
printf 'SURVIVED\n'
exit 0
DRV
out=$(env -u PROJECT_DIR PATH="$ISOLATED_PATH" "GITLAB_TOKEN=$GITLAB_TOKEN" "GITLAB_HOST=$GITLAB_HOST" \
      "_CURL_ARGV_FILE=$_CURL_ARGV_FILE" "_CURL_STATUS_SEQ=" "_CURL_BODY_SEQ=" "_CURL_HDR_EXTRA_SEQ=" \
      "_CURL_INVOKE_STATE=$_CURL_INVOKE_STATE" "_CURL_RC=6" "_SLEEP_LOG_FILE=$_SLEEP_LOG_FILE" \
      bash "$driver_p1_3" 2>&1); rc=$?
assert_eq "TC-GLT-070: caller shell SURVIVED under set -euo pipefail" "0" "$rc"
assert_contains "TC-GLT-070: reached the post-failure marker" "SURVIVED" "$out"
assert_contains "TC-GLT-070: _gl_api returned non-zero to the caller" "rc_captured=1" "$out"

# TC-GLT-071: same shape but with --status-out to prove the mirror-write
# path is reachable past the bare-command failure point.
_reset_control
_CURL_RC=6
export _CURL_RC
status_out_p1_3="$WORK/status-out-p1-3.txt"
: > "$status_out_p1_3"

driver_p1_3b="$WORK/driver-p1-3-status.sh"
cat > "$driver_p1_3b" <<DRV
#!/bin/bash
set -euo pipefail
source "$LIB"
_gl_api --status-out "$status_out_p1_3" /projects/1/issues/42 > /dev/null 2>&1 && rc_captured=0 || rc_captured=\$?
printf 'rc_captured=%s\n' "\$rc_captured"
printf 'SURVIVED\n'
exit 0
DRV
out=$(env -u PROJECT_DIR PATH="$ISOLATED_PATH" "GITLAB_TOKEN=$GITLAB_TOKEN" "GITLAB_HOST=$GITLAB_HOST" \
      "_CURL_ARGV_FILE=$_CURL_ARGV_FILE" "_CURL_STATUS_SEQ=" "_CURL_BODY_SEQ=" "_CURL_HDR_EXTRA_SEQ=" \
      "_CURL_INVOKE_STATE=$_CURL_INVOKE_STATE" "_CURL_RC=6" "_SLEEP_LOG_FILE=$_SLEEP_LOG_FILE" \
      bash "$driver_p1_3b" 2>&1); rc=$?
assert_eq "TC-GLT-071: caller SURVIVED with --status-out on transport failure" "0" "$rc"
assert_contains "TC-GLT-071: post-failure marker reached" "SURVIVED" "$out"
if [[ -f "$status_out_p1_3" ]]; then
  ok "TC-GLT-071: --status-out file exists (was reachable past the bare-command failure point)"
else
  bad "TC-GLT-071: --status-out file was never created (pre-P1-3 short-circuit?)"
fi

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
