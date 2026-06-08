#!/bin/bash
# test-resume-selector-re2-compat.sh — issue #188 (INV-57) review round 2 (kiro).
#
# The dev-resume findings selectors run via `gh issue view ... -q '<jq>'`. `gh --jq`
# uses Go's RE2 engine, which has NO look-behind/look-ahead. An earlier cut used
# `test("(?i)(?<![A-Za-z-])BLOCKING\\b|\\[P1\\]")`; RE2 REJECTS `(?<!` at runtime
# (`invalid regular expression … invalid named capture`), so:
#   - emit_post_approval_findings_block's findings query failed → `if !` → returned
#     0, emitting nothing → the INV-57 override was permanently dead at runtime;
#   - the REVIEW_COMMENTS=$(gh …) assignment exited non-zero → under `set -euo
#     pipefail` the resume branch ABORTED before the agent ran.
#
# The bug slipped past test-resume-review-comments-filter.sh / -post-approval-findings
# because those stub `gh` as a shell script that shells out to the SYSTEM `jq` binary
# (jq 1.6+, Oniguruma/PCRE — DOES support look-behind). The tests exercised the right
# semantics through the WRONG engine.
#
# This test guards the engine boundary two ways:
#   1. STATIC (always runs, network-free, the CI-enforced guard): assert neither `-q`
#      selector in autonomous-dev.sh contains an RE2-incompatible look-behind/look-ahead
#      construct (`(?<`, `(?=`, `(?!`). This is the deterministic regression catch.
#   2. REAL-ENGINE round-trip (best-effort): if the real `gh` binary is available AND a
#      trivial `gh api /rate_limit --jq` round-trip works (token present), feed the
#      ACTUAL extracted regexes through `gh --jq` to prove RE2 both COMPILES them and
#      yields the right boolean. Skipped (not failed) when gh/network/auth is absent so
#      a tokenless CI run still passes on the static guard alone.
#
# Run: bash tests/unit/test-resume-selector-re2-compat.sh

set -uo pipefail

PASS=0
FAIL=0
SKIP=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
skip() { echo -e "  ${YELLOW}SKIP${NC}: $1"; SKIP=$((SKIP + 1)); }

# ---------------------------------------------------------------------------
# Part 1 — STATIC guard: no RE2-incompatible construct in the resume selectors.
# ---------------------------------------------------------------------------
echo "=== TC-RE2-01..03: static — resume -q selectors are RE2-compatible ==="

# Extract the resume findings selector lines. The jq lives on the `-q '<expr>'`
# continuation line (the wrapper splits `gh issue view … \` from its `-q '…'`), so we
# match the jq line directly by its distinctive `BLOCKING` token clause inside a
# `test(...)`. Every resume findings selector references it.
SELECTOR_LINES=$(grep -nE "test\(.*BLOCKING" "$WRAPPER" | grep -F -- '-q ')
if [[ -z "$SELECTOR_LINES" ]]; then
  bad "TC-RE2-01 could not locate the resume findings selectors in $WRAPPER"
else
  ok "TC-RE2-01 located the resume findings selector line(s)"
fi

# RE2 rejects look-behind `(?<!` `(?<=` and look-ahead `(?=` `(?!`. (RE2 DOES allow
# named captures `(?P<name>` / `(?<name>` with a following name char, but our selectors
# use none — any `(?<`, `(?=`, `(?!` here is the incompatible form.)
if echo "$SELECTOR_LINES" | grep -qE '\(\?<[!=]|\(\?[=!]'; then
  bad "TC-RE2-02 a resume selector contains an RE2-incompatible look-behind/look-ahead — gh --jq will reject it at runtime"
  echo "$SELECTOR_LINES" | sed 's/^/      /'
else
  ok "TC-RE2-02 no look-behind/look-ahead in the resume selectors (RE2-safe)"
fi

# Positive: the RE2-compatible consuming anchor IS present (so we didn't accidentally
# drop the NON-BLOCKING guard while removing the look-behind).
if echo "$SELECTOR_LINES" | grep -qF '(^|[^A-Za-z-])BLOCKING'; then
  ok "TC-RE2-03 the RE2-compatible consuming anchor '(^|[^A-Za-z-])BLOCKING' is present"
else
  bad "TC-RE2-03 expected the consuming anchor '(^|[^A-Za-z-])BLOCKING' (the NON-BLOCKING guard)"
fi

# ---------------------------------------------------------------------------
# Part 2 — REAL-ENGINE round-trip via the actual `gh` binary (best-effort).
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RE2-04..07: real gh --jq (Go RE2) compiles + behaves (best-effort) ==="

# Resolve a real gh: prefer the project-vendored wrapper (token-refresh), fall back to
# PATH gh. Probe with a trivial, side-effect-free, jq-bearing call.
GH_BIN=""
if [[ -x "$PROJECT_ROOT/scripts/gh" ]]; then
  GH_BIN="$PROJECT_ROOT/scripts/gh"
elif command -v gh >/dev/null 2>&1; then
  GH_BIN="$(command -v gh)"
fi

# The exact token regex baked into the wrapper (kept in sync with autonomous-dev.sh).
TOKEN_RE='(?i)(^|[^A-Za-z-])BLOCKING\b|\[P1\]'

# `gh api --jq` has no native jq --arg, so we build the jq program as string literals.
# To avoid shell/jq quoting mangling `\b` and the brackets, the subject and regex are
# string-escaped by the SYSTEM jq first (escaping is engine-neutral), then the resulting
# program is run by GH's jq (Go RE2) for the actual test() — so RE2 is what compiles it.
gh_re2() { # gh_re2 <subject> <regex> → true|false|<empty on RE2 compile error>
  local subj="$1" re="$2"
  # jq string-escape both via the system jq (escaping only — engine-neutral), then
  # feed the resulting jq program to gh's jq (RE2) for the actual test().
  local sj rj prog
  # -r (raw output) so the @json-encoded literal is NOT re-quoted by the outer jq.
  sj=$(jq -rn --arg s "$subj" '$s|@json') || return 1
  rj=$(jq -rn --arg r "$re" '$r|@json') || return 1
  prog="${sj} | test(${rj})"
  bash "$GH_BIN" api /rate_limit --jq "$prog" 2>/dev/null
}

re2_available=0
if [[ -n "$GH_BIN" ]] && [[ "$(gh_re2 'x' 'x')" == "true" ]]; then
  re2_available=1
fi

if [[ "$re2_available" -eq 1 ]]; then
  # TC-RE2-04 — RE2 COMPILES the token regex (a probe that does not match → "false",
  # NOT empty; empty/non-"false" means RE2 rejected the pattern at compile time).
  if [[ "$(gh_re2 'probe' "$TOKEN_RE")" == "false" ]]; then
    ok "TC-RE2-04 gh --jq (RE2) compiles the token regex"
  else
    bad "TC-RE2-04 gh --jq (RE2) failed to compile the token regex (look-behind regression?)"
  fi
  # TC-RE2-05 — '[P1] BLOCKING' matches.
  [[ "$(gh_re2 '[P1] BLOCKING: data race' "$TOKEN_RE")" == "true" ]] \
    && ok "TC-RE2-05 '[P1] BLOCKING' matches under RE2" \
    || bad "TC-RE2-05 '[P1] BLOCKING' should match under RE2"
  # TC-RE2-06 — '[BLOCKING]' (bracketed, the real review format) matches.
  [[ "$(gh_re2 '[BLOCKING] missing validation' "$TOKEN_RE")" == "true" ]] \
    && ok "TC-RE2-06 '[BLOCKING] ...' matches under RE2" \
    || bad "TC-RE2-06 '[BLOCKING] ...' should match under RE2"
  # TC-RE2-07 — 'NON-BLOCKING' does NOT match.
  [[ "$(gh_re2 'remaining items are NON-BLOCKING' "$TOKEN_RE")" == "false" ]] \
    && ok "TC-RE2-07 'NON-BLOCKING' does NOT match under RE2" \
    || bad "TC-RE2-07 'NON-BLOCKING' must not match under RE2"
else
  skip "TC-RE2-04..07 real gh --jq round-trip (gh binary or token/network unavailable) — static guard (Part 1) still enforces RE2-compatibility"
fi

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL + SKIP)) (${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}, ${YELLOW}${SKIP} skip${NC})"
echo "==============================================="
[ "$FAIL" -eq 0 ]
