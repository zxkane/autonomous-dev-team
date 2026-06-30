#!/bin/bash
# test-resume-selector-re2-compat.sh — engine-compat guard for the dev-resume
# findings selectors. Originally issue #188 (INV-57) round 2 (kiro): the selectors
# ran via `gh issue view … -q '<jq>'` under gh's Go-RE2 engine, which REJECTS
# look-behind `(?<!` at runtime, aborting the wrapper under `set -e`.
#
# Issue #296 B6 MOVED both reads to `itp_list_comments "$ISSUE" | jq -r '<jq>'` —
# the system jq's **Oniguruma** engine, NOT gh's RE2. The engine-compat concern is
# now twofold and this test guards BOTH:
#   1. The selectors must remain free of look-behind/look-ahead (a *consuming*
#      anchor design) — a regression to `(?<!` would have been an RE2-runtime
#      abort before, and is still the wrong design (the explicit boundary classes
#      are what make selection engine-equivalent).
#   2. RE2 and Oniguruma DIVERGE on `\b`/`\s`/`(?i)` for non-ASCII input. The
#      selector was rewritten (scoped `(?i:…)` + explicit ASCII boundary/whitespace
#      classes OUTSIDE the `(?i)` scope) so it selects IDENTICALLY in Oniguruma to
#      the old RE2 behavior. Part 2 proves that against the system jq (the engine
#      the wrapper now uses) across every divergence class.
#
# This test guards the boundary two ways:
#   1. STATIC (always runs, network-free, the CI-enforced guard): assert neither
#      migrated selector contains a look-behind/look-ahead (`(?<`, `(?=`, `(?!`),
#      both consuming anchors are present, and the `(?i)` is SCOPED (no bare
#      global `(?i)` that would leak into the ASCII boundary class).
#   2. REAL-ENGINE round-trip via the SYSTEM jq (Oniguruma): feed the ACTUAL
#      extracted token regex through the host jq and assert the divergence-class
#      booleans match the old RE2 selection. This always runs (jq is a hard dep of
#      the suite) and also asserts the host jq is >= 1.5 (Oniguruma).
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
# Part 1 — STATIC guard: the migrated resume selectors are engine-equivalent.
# ---------------------------------------------------------------------------
echo "=== TC-RE2-01..05: static — migrated resume selectors are engine-equivalent ==="

# Extract the resume findings selector lines. Post-#296-B6 the jq lives inside
# `itp_list_comments … | jq -r '<expr>'` (one line), distinctively carrying the
# `BLOCKING` token clause inside a `test(...)`. Both resume selectors reference it.
SELECTOR_LINES=$(grep -nE "test\(.*BLOCKING" "$WRAPPER" | grep -F -- 'itp_list_comments')
if [[ -z "$SELECTOR_LINES" ]]; then
  bad "TC-RE2-01 could not locate the migrated resume findings selectors (itp_list_comments | jq -r) in $WRAPPER"
else
  _n=$(echo "$SELECTOR_LINES" | grep -c .)
  ok "TC-RE2-01 located the migrated resume findings selector line(s) ($_n)"
fi

# Static guard: the OLD raw `gh issue view … --json comments` reads are GONE — both
# resume comment-reads route through itp_list_comments now (AC1 / false-green guard).
if grep -qE 'gh issue view "\$(ISSUE_NUMBER|issue_num)" --repo "\$REPO" --json comments' "$WRAPPER"; then
  bad "TC-RE2-01b a raw 'gh issue view … --json comments' resume read survives — not migrated"
  grep -nE 'gh issue view "\$(ISSUE_NUMBER|issue_num)" --repo "\$REPO" --json comments' "$WRAPPER" | sed 's/^/      /'
else
  ok "TC-RE2-01b no raw 'gh issue view … --json comments' resume read remains (both behind itp_list_comments)"
fi

# Look-behind/look-ahead must NOT appear (a *consuming* anchor design). RE2 DOES
# allow named captures `(?P<name>` / `(?<name>` with a following name char, but our
# selectors use none — any `(?<`, `(?=`, `(?!` here is the incompatible form.
if echo "$SELECTOR_LINES" | grep -qE '\(\?<[!=]|\(\?[=!]'; then
  bad "TC-RE2-02 a resume selector contains a look-behind/look-ahead — the consuming-anchor design regressed"
  echo "$SELECTOR_LINES" | sed 's/^/      /'
else
  ok "TC-RE2-02 no look-behind/look-ahead in the resume selectors (consuming-anchor design intact)"
fi

# Positive: BOTH consuming anchors are present (so the NON-BLOCKING / BLOCKINGS
# guards survive) — left `(^|[^A-Za-z-])BLOCKING` and right `($|[^A-Za-z0-9_])`.
if echo "$SELECTOR_LINES" | grep -qF '(^|[^A-Za-z-])BLOCKING'; then
  ok "TC-RE2-03 the left consuming anchor '(^|[^A-Za-z-])BLOCKING' is present (NON-BLOCKING guard)"
else
  bad "TC-RE2-03 expected the left consuming anchor '(^|[^A-Za-z-])BLOCKING'"
fi
if echo "$SELECTOR_LINES" | grep -qF ')($|[^A-Za-z0-9_])'; then
  ok "TC-RE2-04 the right consuming boundary '($|[^A-Za-z0-9_])' is present (BLOCKINGS guard)"
else
  bad "TC-RE2-04 expected the right consuming boundary '($|[^A-Za-z0-9_])'"
fi

# The `(?i)` MUST be SCOPED (`(?i:…)`), never a bare global `(?i)` — a global
# case-fold would leak into the ASCII boundary class `[^A-Za-z0-9_]` and exclude
# Unicode simple-fold chars (K U+212A / ſ U+017F), diverging from RE2's ASCII \b.
if echo "$SELECTOR_LINES" | grep -qE 'test\("\(\?i\)'; then
  bad "TC-RE2-05 a selector uses a bare global '(?i)' — it leaks into the ASCII boundary class (Unicode-fold divergence). Use scoped '(?i:…)'."
  echo "$SELECTOR_LINES" | sed 's/^/      /'
elif echo "$SELECTOR_LINES" | grep -qF '(?i:'; then
  ok "TC-RE2-05 the '(?i)' is scoped '(?i:…)' (boundary/whitespace classes stay explicit ASCII outside the fold)"
else
  bad "TC-RE2-05 expected a scoped '(?i:…)' case-insensitive group in the selectors"
fi

# ---------------------------------------------------------------------------
# Part 2 — REAL-ENGINE round-trip via the SYSTEM jq (Oniguruma — what the
# wrapper now actually uses). Always runs; jq is a hard dependency of the suite.
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RE2-06..0E: system jq (Oniguruma) compiles + selects per the old RE2 behavior ==="

# Host jq >= 1.5 assertion (Oniguruma): the migrated reads run under the host jq.
JQ_VER=$(jq --version 2>/dev/null | sed -E 's/^jq-?//')
JQ_MAJOR=${JQ_VER%%.*}
JQ_REST=${JQ_VER#*.}
JQ_MINOR=${JQ_REST%%.*}
[[ "$JQ_MAJOR" =~ ^[0-9]+$ ]] || JQ_MAJOR=0
[[ "$JQ_MINOR" =~ ^[0-9]+$ ]] || JQ_MINOR=0
if (( JQ_MAJOR > 1 || (JQ_MAJOR == 1 && JQ_MINOR >= 5) )); then
  ok "TC-RE2-06 host jq is >= 1.5 (Oniguruma): jq-$JQ_VER"
else
  bad "TC-RE2-06 host jq is < 1.5 (got '$JQ_VER') — the migrated Oniguruma selectors need jq >= 1.5"
fi

# Extract the EXACT token regex baked into the wrapper (kept in sync automatically
# — pulled from the live selector, not hardcoded). It is the first alternation
# inside the `test("…")` token clause: `(?i:(^|[^A-Za-z-])BLOCKING)($|[^A-Za-z0-9_])|(?i:\[P1\])`.
# The selector stores it jq-escaped (`\\[`); unescape one backslash level for a
# standalone jq `test()` (the wrapper's outer `'…'` already consumed one level).
TOKEN_RE=$(grep -F 'itp_list_comments' "$WRAPPER" \
  | grep -oE 'test\("\(\?i:\(\^\|\[\^A-Za-z-\]\)BLOCKING\)[^"]*"\)' \
  | head -1 | sed -E 's/^test\("//; s/"\)$//')
# Collapse the doubled backslashes (jq-string-literal level) to single (regex level).
TOKEN_RE=${TOKEN_RE//\\\\/\\}
if [[ -z "$TOKEN_RE" ]]; then
  bad "TC-RE2-07 could not extract the token regex from the migrated selector"
else
  ok "TC-RE2-07 extracted the live token regex: $TOKEN_RE"
fi

oni() { # oni <subject> <regex> → true|false  (system jq / Oniguruma)
  jq -rn --arg s "$1" --arg re "$2" '$s | test($re)'
}

NBSP=$'\xc2\xa0'; KELVIN=$'\xe2\x84\xaa'; LONGS=$'\xc5\xbf'; ACCENT=$'\xc3\xa9'; CJK=$'\xe4\xb8\xad'

assert_oni() { # assert_oni <desc> <subject> <expected true|false>
  local desc="$1" subj="$2" exp="$3" got
  got=$(oni "$subj" "$TOKEN_RE")
  [[ "$got" == "$exp" ]] && ok "$desc (got $got)" || bad "$desc (expected $exp, got '$got')"
}

if [[ -n "$TOKEN_RE" ]]; then
  assert_oni "TC-RE2-08 '[P1] BLOCKING' matches"          '[P1] BLOCKING: data race' true
  assert_oni "TC-RE2-09 '[BLOCKING] …' matches"           '[BLOCKING] missing validation' true
  assert_oni "TC-RE2-0A 'NON-BLOCKING' does NOT match"    'remaining items are NON-BLOCKING' false
  assert_oni "TC-RE2-0B 'BLOCKINGS' does NOT match"       'the BLOCKINGS were resolved' false
  assert_oni "TC-RE2-0C BLOCKING+U+212A KELVIN matches"   "BLOCKING${KELVIN}suffix" true
  assert_oni "TC-RE2-0C BLOCKING+U+017F long-s matches"   "BLOCKING${LONGS}suffix" true
  assert_oni "TC-RE2-0C BLOCKING+é matches"               "BLOCKING${ACCENT}suffix" true
  assert_oni "TC-RE2-0C BLOCKING+中 matches"              "BLOCKING${CJK}suffix" true
  assert_oni "TC-RE2-0D lowercase 'blocking' matches"     'a blocking concern' true
  assert_oni "TC-RE2-0E lowercase '[p1]' matches"         'see [p1] marker' true
fi

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL + SKIP)) (${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}, ${YELLOW}${SKIP} skip${NC})"
echo "==============================================="
[ "$FAIL" -eq 0 ]
