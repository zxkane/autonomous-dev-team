#!/bin/bash
# test-post-verdict.sh — issue #202 / INV-56.
#
# `scripts/post-verdict.sh` is the deterministic, wrapper-provided helper that
# review agents call to post their verdict comment, replacing each CLI's
# hand-rolled bare `gh issue comment` (which agy mis-escapes → comment never
# lands → dropped `unavailable`). The helper:
#   - composes the canonical AGENT verdict trailer itself (Review Session /
#     Review Agent, INV-40 / INV-20);
#   - guarantees the first-line phrasing the poller matches
#     (`Review PASSED` / `Review findings:`, lib-review-poll.sh);
#   - posts via the token-refresh proxy `gh` (NOT bare gh);
#   - exits non-zero on a failed post, echoes the comment URL on success;
#   - takes the body from a FILE (or stdin) so multi-line bodies with backticks
#     / quotes / `$()` can't be mangled by the agent's shell quoting.
#
# Strategy: build a sandbox scripts/ dir with a stub `gh` that records its argv
# and the composed --body to files, plus an autonomous.conf providing REPO.
# Run the real post-verdict.sh against the stub and assert on the captured body
# + exit codes.
#
# Run: bash tests/unit/test-post-verdict.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER_SRC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/post-verdict.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle' (should NOT appear)"
    echo "      haystack='$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected [$expected] got [$actual])"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Sandbox factory: a scripts/ dir holding autonomous.conf + a stub `gh`.
#   $1 = gh exit code (the stub returns this; non-zero simulates a post failure)
# Captures the --body the helper sends to /tmp body capture and the full argv.
# Echoes the sandbox dir path.
# ---------------------------------------------------------------------------
make_sandbox() {
  local gh_rc="${1:-0}"
  local sb; sb="$(mktemp -d)"
  cat > "$sb/autonomous.conf" <<'CONF'
REPO="owner/repo"
REPO_OWNER="owner"
REPO_NAME="repo"
CONF
  # Stub gh: record argv + the value of the --body flag, then succeed/fail.
  cat > "$sb/gh" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$sb/gh-argv.txt"
# Extract the value following --body (argv-safe: walk the args).
prev=""
for a in "\$@"; do
  if [[ "\$prev" == "--body" ]]; then printf '%s' "\$a" > "$sb/gh-body.txt"; fi
  prev="\$a"
done
if [[ "$gh_rc" -eq 0 ]]; then
  echo "https://github.com/owner/repo/issues/202#issuecomment-999"
  exit 0
fi
echo "gh: simulated post failure" >&2
exit 1
STUB
  chmod +x "$sb/gh"
  # The helper lives alongside the real `gh` symlink in the dispatcher scripts/
  # dir; copy it into the sandbox so its SCRIPT_DIR-relative `gh` lookup finds
  # the stub.
  cp "$HELPER_SRC" "$sb/post-verdict.sh"
  chmod +x "$sb/post-verdict.sh"
  printf '%s' "$sb"
}

# ---------------------------------------------------------------------------
echo "=== TC-PV: post-verdict.sh helper behavior ==="
# ---------------------------------------------------------------------------

# TC-PV-01: PASS verdict, body file → trailer appended.
SB=$(make_sandbox 0)
printf 'All checklist items verified, code quality good. No requirement drift.' > "$SB/body.md"
OUT=$(bash "$SB/post-verdict.sh" 202 pass "$SB/body.md" agy "sid-AAAA" 2>&1); RC=$?
BODY=$(cat "$SB/gh-body.txt" 2>/dev/null || echo "")
assert_eq "TC-PV-01a PASS exits 0" "0" "$RC"
assert_contains "TC-PV-01b body keeps the agent's text" "All checklist items verified" "$BODY"
assert_contains "TC-PV-01c body ends with Review Session trailer (backtick-wrapped sid)" 'Review Session: `sid-AAAA`' "$BODY"
assert_contains "TC-PV-01d body ends with Review Agent discriminator" "Review Agent: agy" "$BODY"
rm -rf "$SB"

# TC-PV-02: PASS body NOT starting with the canonical prefix → helper prepends it.
SB=$(make_sandbox 0)
printf 'everything looks great here' > "$SB/body.md"
bash "$SB/post-verdict.sh" 202 pass "$SB/body.md" claude "sid-BBBB" >/dev/null 2>&1
BODY=$(cat "$SB/gh-body.txt" 2>/dev/null || echo "")
FIRST_LINE=$(printf '%s\n' "$BODY" | head -1)
assert_contains "TC-PV-02 first line starts with 'Review PASSED'" "Review PASSED" "$FIRST_LINE"
rm -rf "$SB"

# TC-PV-03: FAIL body NOT starting with the canonical prefix → helper prepends it.
SB=$(make_sandbox 0)
printf '1. The widget is broken.' > "$SB/body.md"
bash "$SB/post-verdict.sh" 202 fail "$SB/body.md" codex "sid-CCCC" >/dev/null 2>&1
BODY=$(cat "$SB/gh-body.txt" 2>/dev/null || echo "")
FIRST_LINE=$(printf '%s\n' "$BODY" | head -1)
assert_contains "TC-PV-03 first line starts with 'Review findings:'" "Review findings:" "$FIRST_LINE"
rm -rf "$SB"

# TC-PV-04: PASS body ALREADY starts with the prefix → not duplicated.
SB=$(make_sandbox 0)
printf 'Review PASSED - looks good' > "$SB/body.md"
bash "$SB/post-verdict.sh" 202 pass "$SB/body.md" kiro "sid-DDDD" >/dev/null 2>&1
BODY=$(cat "$SB/gh-body.txt" 2>/dev/null || echo "")
COUNT=$(printf '%s\n' "$BODY" | grep -c 'Review PASSED')
assert_eq "TC-PV-04 'Review PASSED' appears exactly once (no double-prefix)" "1" "$COUNT"
rm -rf "$SB"

# TC-PV-05: FAIL body ALREADY starts with the prefix → not duplicated.
SB=$(make_sandbox 0)
printf 'Review findings:\n1. nope' > "$SB/body.md"
bash "$SB/post-verdict.sh" 202 fail "$SB/body.md" kiro "sid-EEEE" >/dev/null 2>&1
BODY=$(cat "$SB/gh-body.txt" 2>/dev/null || echo "")
COUNT=$(printf '%s\n' "$BODY" | grep -c 'Review findings:')
assert_eq "TC-PV-05 'Review findings:' appears exactly once" "1" "$COUNT"
rm -rf "$SB"

# TC-PV-06: gh post failure → helper exits non-zero.
SB=$(make_sandbox 1)
printf 'body' > "$SB/body.md"
bash "$SB/post-verdict.sh" 202 pass "$SB/body.md" agy "sid-FFFF" >/dev/null 2>&1; RC=$?
if [[ "$RC" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-PV-06 post failure → non-zero exit (rc=$RC)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PV-06 post failure did NOT cause non-zero exit"
  FAIL=$((FAIL + 1))
fi
rm -rf "$SB"

# TC-PV-07: success → exit 0 AND echo the comment URL.
SB=$(make_sandbox 0)
printf 'body' > "$SB/body.md"
OUT=$(bash "$SB/post-verdict.sh" 202 pass "$SB/body.md" agy "sid-GGGG" 2>/dev/null); RC=$?
assert_eq "TC-PV-07a success exits 0" "0" "$RC"
assert_contains "TC-PV-07b success echoes the comment URL" "issuecomment-999" "$OUT"
rm -rf "$SB"

# TC-PV-08: body via stdin ('-').
SB=$(make_sandbox 0)
printf 'streamed body text' | bash "$SB/post-verdict.sh" 202 pass - agy "sid-HHHH" >/dev/null 2>&1
BODY=$(cat "$SB/gh-body.txt" 2>/dev/null || echo "")
assert_contains "TC-PV-08a stdin body content posted" "streamed body text" "$BODY"
assert_contains "TC-PV-08b stdin body still gets the trailer" "Review Agent: agy" "$BODY"
rm -rf "$SB"

# TC-PV-09: multi-line body with backticks/quotes/$() preserved verbatim (the fix).
SB=$(make_sandbox 0)
cat > "$SB/body.md" <<'BODYEOF'
1. The `foo()` call uses "double quotes" and 'single quotes'.
2. There is a $(command substitution) literal and a $VAR reference.
3. A trailing backtick line: `code`
BODYEOF
bash "$SB/post-verdict.sh" 202 fail "$SB/body.md" agy "sid-IIII" >/dev/null 2>&1
BODY=$(cat "$SB/gh-body.txt" 2>/dev/null || echo "")
assert_contains "TC-PV-09a backticks preserved" 'The `foo()` call' "$BODY"
assert_contains "TC-PV-09b command-substitution literal preserved (not executed)" '$(command substitution)' "$BODY"
assert_contains "TC-PV-09c var reference preserved (not expanded)" '$VAR reference' "$BODY"
rm -rf "$SB"

# TC-PV-10: invalid issue number → exit 2, no gh call.
SB=$(make_sandbox 0)
printf 'body' > "$SB/body.md"
bash "$SB/post-verdict.sh" notanumber pass "$SB/body.md" agy "sid-JJJJ" >/dev/null 2>&1; RC=$?
assert_eq "TC-PV-10a invalid issue number exits 2" "2" "$RC"
if [[ ! -f "$SB/gh-argv.txt" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-PV-10b no gh call made on invalid issue number"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PV-10b gh was called despite invalid issue number"
  FAIL=$((FAIL + 1))
fi
rm -rf "$SB"

# TC-PV-11: invalid verdict → exit 2.
SB=$(make_sandbox 0)
printf 'body' > "$SB/body.md"
bash "$SB/post-verdict.sh" 202 maybe "$SB/body.md" agy "sid-KKKK" >/dev/null 2>&1; RC=$?
assert_eq "TC-PV-11 invalid verdict exits 2" "2" "$RC"
rm -rf "$SB"

# TC-PV-12: unreadable/missing body file → exit 2.
SB=$(make_sandbox 0)
bash "$SB/post-verdict.sh" 202 pass "$SB/does-not-exist.md" agy "sid-LLLL" >/dev/null 2>&1; RC=$?
assert_eq "TC-PV-12 missing body file exits 2" "2" "$RC"
rm -rf "$SB"

# TC-PV-13: exact trailer phrasing (poller + INV-40 attribution).
SB=$(make_sandbox 0)
printf 'Review PASSED - good' > "$SB/body.md"
bash "$SB/post-verdict.sh" 202 pass "$SB/body.md" "agy" "sid-MMMM" >/dev/null 2>&1
BODY=$(cat "$SB/gh-body.txt" 2>/dev/null || echo "")
# Both trailer lines must be present, each on its own line.
# here-strings (not `printf | grep -q`) to avoid a pipefail+SIGPIPE flake.
if grep -qF 'Review Session: `sid-MMMM`' <<<"$BODY" \
   && grep -qxF 'Review Agent: agy' <<<"$BODY"; then
  echo -e "  ${GREEN}PASS${NC}: TC-PV-13 exact trailer lines present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PV-13 trailer phrasing wrong"
  echo "      body='$BODY'"
  FAIL=$((FAIL + 1))
fi
rm -rf "$SB"

# TC-PV-14: verdict arg is case-insensitive.
SB=$(make_sandbox 0)
printf 'good' > "$SB/body.md"
bash "$SB/post-verdict.sh" 202 PASS "$SB/body.md" agy "sid-NNNN" >/dev/null 2>&1; RC=$?
BODY=$(cat "$SB/gh-body.txt" 2>/dev/null || echo "")
assert_eq "TC-PV-14a uppercase PASS accepted (exit 0)" "0" "$RC"
assert_contains "TC-PV-14b uppercase PASS still yields 'Review PASSED' first line" "Review PASSED" "$(printf '%s\n' "$BODY" | head -1)"
rm -rf "$SB"

# TC-PV-15: posts via `gh issue comment <n> --repo <REPO>` (the proxy form).
SB=$(make_sandbox 0)
printf 'good' > "$SB/body.md"
bash "$SB/post-verdict.sh" 202 pass "$SB/body.md" agy "sid-OOOO" >/dev/null 2>&1
ARGV=$(cat "$SB/gh-argv.txt" 2>/dev/null || echo "")
assert_contains "TC-PV-15a gh invoked with 'issue'" "issue" "$ARGV"
assert_contains "TC-PV-15b gh invoked with 'comment'" "comment" "$ARGV"
assert_contains "TC-PV-15c gh invoked against issue 202" "202" "$ARGV"
assert_contains "TC-PV-15d gh invoked with --repo owner/repo" "owner/repo" "$ARGV"
rm -rf "$SB"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
