#!/bin/bash
# test-check-shell-idioms.sh — issue #477, [INV-130] shell-idiom ratchet gate
# unit tests (TC-IDIOM-NNN).
#
# Drives check-shell-idioms.sh against SCRATCH fixture trees via the
# --scan-root/--baseline path-override flags (mirrors test-provider-cutover.sh's
# scratch-copy pattern). The committed repo tree and the real
# shell-idioms-baseline.json are never modified by the mutating cases below.
# Credential-free (bash + jq + coreutils), no network.
#
# Run: bash tests/unit/test-check-shell-idioms.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
CHECK="$SCRIPTS/check-shell-idioms.sh"
REAL_BASELINE="$SCRIPTS/shell-idioms-baseline.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A fresh scratch skills/ root per test. Args: name, followed by "relpath<TAB>content"
# lines on stdin (one heredoc per file, separated by a line of exactly "---").
# Simpler: callers just mkdir/cat directly; this only allocates the root dir.
fresh_root() {
  local d="$WORK/scratch.$1"
  rm -rf "$d"; mkdir -p "$d/skills"
  printf '%s' "$d/skills"
}

# Write a scratch script file. Args: root, relpath, content (via stdin).
write_script() {
  local root="$1"
  local rel="$2"
  local path="$root/$rel"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}

# ---------------------------------------------------------------------------
echo "=== Group A: Rule J (jq nullable-.body guard) — TC-IDIOM-001..006 ==="
# ---------------------------------------------------------------------------

R="$(fresh_root A001)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if echo "$out" | jq -e '."foo/bar.sh".jq_unguarded == 1' >/dev/null 2>&1; then
  ok "TC-IDIOM-001: unguarded .body|test( flagged (1 occurrence)"
else
  bad "TC-IDIOM-001: unguarded .body|test( NOT flagged as expected: $out"
fi

R="$(fresh_root A002)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | type == "string") | select(.body | test("x"))')
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-002: guard on the same line (immediately adjacent) suppresses the flag"
else
  bad "TC-IDIOM-002: expected empty baseline, got: $out"
fi

R="$(fresh_root A003)"
{
  echo '#!/bin/bash'
  echo 'set -euo pipefail'
  echo ''
  echo 'select(.body | type == "string")'
  for i in $(seq 1 14); do echo "filler_$i=1"; done
  echo 'select(.body | test("x"))'
} | write_script "$R" foo/bar.sh
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-003: guard exactly 15 lines away (within window) suppresses the flag"
else
  bad "TC-IDIOM-003: expected empty baseline (guard within window), got: $out"
fi

R="$(fresh_root A004)"
{
  echo '#!/bin/bash'
  echo 'set -euo pipefail'
  echo ''
  echo 'select(.body | type == "string")'
  for i in $(seq 1 19); do echo "filler_$i=1"; done
  echo 'select(.body | test("x"))'
} | write_script "$R" foo/bar.sh
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if echo "$out" | jq -e '."foo/bar.sh".jq_unguarded == 1' >/dev/null 2>&1; then
  ok "TC-IDIOM-004: guard 20 lines away (outside window) still flags the occurrence"
else
  bad "TC-IDIOM-004: expected the occurrence to be flagged (guard too far), got: $out"
fi

R="$(fresh_root A005)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  a=$(jq -r 'select(.body | test("x"))')
  b=$(jq -r 'select(.body | contains("x"))')
  c=$(jq -r 'select(.body | startswith("x"))')
  d=$(jq -r 'select(.body | endswith("x"))')
  e=$(jq -r '.body | sub("x"; "y")')
  f=$(jq -r '.body | gsub("x"; "y")')
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if echo "$out" | jq -e '."foo/bar.sh".jq_unguarded == 6' >/dev/null 2>&1; then
  ok "TC-IDIOM-005: all six ops (test/contains/startswith/endswith/sub/gsub) counted (6 occurrences)"
else
  bad "TC-IDIOM-005: expected 6 unguarded occurrences, got: $out"
fi

R="$(fresh_root A006)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.title | test("x"))')
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-006: .title (non-.body field) is NOT flagged — Rule J is .body-scoped only"
else
  bad "TC-IDIOM-006: expected .title to be out of scope, got: $out"
fi

# ---------------------------------------------------------------------------
echo "=== Group B: Rule S (swallow justification) — TC-IDIOM-007..013 ==="
# ---------------------------------------------------------------------------

R="$(fresh_root B007)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true  # rationale: best-effort cleanup
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-007: same-line trailing comment justifies the swallow"
else
  bad "TC-IDIOM-007: expected justified (empty baseline), got: $out"
fi

R="$(fresh_root B008)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  # best-effort cleanup, failure here is non-fatal
  noop1
  noop2
  cmd1 || true
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-008: comment exactly 3 lines above justifies the swallow"
else
  bad "TC-IDIOM-008: expected justified (empty baseline), got: $out"
fi

R="$(fresh_root B009)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  # best-effort cleanup, failure here is non-fatal
  noop1
  noop2
  noop3
  cmd1 || true
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if echo "$out" | jq -e '."foo/bar.sh".swallow_unjustified == 1' >/dev/null 2>&1; then
  ok "TC-IDIOM-009: comment 4 lines above (outside lookback) leaves it unjustified"
else
  bad "TC-IDIOM-009: expected unjustified flag, got: $out"
fi

R="$(fresh_root B010)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || echo "swallowed"
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if echo "$out" | jq -e '."foo/bar.sh".swallow_unjustified == 1' >/dev/null 2>&1; then
  ok "TC-IDIOM-010: unjustified '|| echo' variant is flagged"
else
  bad "TC-IDIOM-010: expected unjustified flag, got: $out"
fi

R="$(fresh_root B011)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || echo "swallowed"  # deliberate: log and continue
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-011: '|| echo' with a trailing comment is justified"
else
  bad "TC-IDIOM-011: expected justified (empty baseline), got: $out"
fi

R="$(fresh_root B012)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  # see foo || true above for the historical rationale
  noop
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-012: a swallow token appearing only inside a comment line is not counted at all"
else
  bad "TC-IDIOM-012: expected no occurrence counted, got: $out"
fi

R="$(fresh_root B013)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || echoinvalid
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-013: '|| echoinvalid' (not a real echo token) is not flagged"
else
  bad "TC-IDIOM-013: expected no match (word-boundary), got: $out"
fi

# ---------------------------------------------------------------------------
echo "=== Group C: baseline reconciliation — TC-IDIOM-014..020 ==="
# ---------------------------------------------------------------------------

R="$(fresh_root C014)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 1}}' > "$WORK/c014-baseline.json"
if bash "$CHECK" --scan-root "$R" --baseline "$WORK/c014-baseline.json" >/dev/null 2>&1; then
  ok "TC-IDIOM-014: discovered count == baseline count → PASS"
else
  bad "TC-IDIOM-014: expected PASS when counts match"
fi

R="$(fresh_root C015)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
  y=$(jq -r 'select(.body | contains("y"))')
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 1, "swallow_unjustified": 0}}' > "$WORK/c015-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/c015-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -Eq 'foo/bar\.sh:[0-9]+' <<<"$out" && grep -q 'Rule J' <<<"$out"; then
  ok "TC-IDIOM-015: jq_unguarded exceeding baseline FAILs, names file:line + matched text"
else
  bad "TC-IDIOM-015: expected FAIL naming file:line (rc=$rc): $out"
fi

R="$(fresh_root C016)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
  cmd2 || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 1}}' > "$WORK/c016-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/c016-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -Eq 'foo/bar\.sh:[0-9]+' <<<"$out" && grep -q 'Rule S' <<<"$out"; then
  ok "TC-IDIOM-016: swallow_unjustified exceeding baseline FAILs, names file:line + matched text"
else
  bad "TC-IDIOM-016: expected FAIL naming file:line (rc=$rc): $out"
fi

R="$(fresh_root C017)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true  # justified now
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 3}}' > "$WORK/c017-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/c017-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qi 'notice' <<<"$out" && grep -qi 'regenerat' <<<"$out"; then
  ok "TC-IDIOM-017: count below baseline PASSes with a regeneration notice"
else
  bad "TC-IDIOM-017: expected PASS + regeneration notice (rc=$rc): $out"
fi

R="$(fresh_root C018)"
write_script "$R" foo/newfile.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
}
EOF
echo '{}' > "$WORK/c018-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/c018-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'foo/newfile.sh' <<<"$out"; then
  ok "TC-IDIOM-018: a NEW file absent from baseline with a violation FAILs"
else
  bad "TC-IDIOM-018: expected FAIL for new file with violation (rc=$rc): $out"
fi

R="$(fresh_root C019)"
write_script "$R" foo/newfile.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  echo clean
}
EOF
echo '{}' > "$WORK/c019-baseline.json"
if bash "$CHECK" --scan-root "$R" --baseline "$WORK/c019-baseline.json" >/dev/null 2>&1; then
  ok "TC-IDIOM-019: a NEW file absent from baseline with zero violations PASSes"
else
  bad "TC-IDIOM-019: expected PASS for clean new file"
fi

R="$(fresh_root C020)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo clean
EOF
echo '{"foo/removed.sh": {"jq_unguarded": 0, "swallow_unjustified": 2}}' > "$WORK/c020-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/c020-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'foo/removed.sh' <<<"$out" && grep -qi 'notice\|shrank' <<<"$out"; then
  ok "TC-IDIOM-020: baseline entry for a file no longer present does not crash, PASSes, and is actually reconciled as a shrink (not silently dropped)"
else
  bad "TC-IDIOM-020: expected PASS + a shrink notice naming foo/removed.sh, got rc=$rc: $out"
fi

# ---------------------------------------------------------------------------
echo "=== Group D: scan scope — TC-IDIOM-021..022 ==="
# ---------------------------------------------------------------------------

R="$(fresh_root D021)"
write_script "$R" tests/fixture.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-021: a violation under tests/ is excluded from the scan entirely"
else
  bad "TC-IDIOM-021: expected tests/ to be excluded, got: $out"
fi

R="$(fresh_root D022)"
write_script "$R" a/b/c/nested.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if echo "$out" | jq -e '."a/b/c/nested.sh".swallow_unjustified == 1' >/dev/null 2>&1; then
  ok "TC-IDIOM-022: a violation in a normal nested subdirectory IS included (recursive scan)"
else
  bad "TC-IDIOM-022: expected nested file to be scanned, got: $out"
fi

# ---------------------------------------------------------------------------
echo "=== Group E: --require-trusted-ref fail-closed posture — TC-IDIOM-023..026 ==="
# ---------------------------------------------------------------------------

GITROOT="$WORK/gitfixture"
git init -q "$GITROOT"
git -C "$GITROOT" config user.email test@test.com
git -C "$GITROOT" config user.name test
mkdir -p "$GITROOT/skills/foo"
write_script "$GITROOT" skills/foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  echo clean
}
EOF
git -C "$GITROOT" add -A
git -C "$GITROOT" commit -q -m init

out="$(cd "$GITROOT" && bash "$CHECK" --scan-root "$GITROOT/skills" --require-trusted-ref --trusted-ref no-such-ref-xyz 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "TC-IDIOM-023: --require-trusted-ref with an unresolvable ref FAILs closed"
else
  bad "TC-IDIOM-023: expected FAIL closed on unresolvable ref, got rc=$rc: $out"
fi

out="$(cd "$GITROOT" && bash "$CHECK" --scan-root "$GITROOT/skills" --require-trusted-ref --trusted-ref HEAD --trusted-baseline-path skills/foo/absent-baseline.json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "TC-IDIOM-024: --require-trusted-ref with a resolvable ref but no baseline file FAILs closed"
else
  bad "TC-IDIOM-024: expected FAIL closed on missing baseline at ref, got rc=$rc: $out"
fi

bash "$CHECK" --scan-root "$GITROOT/skills" --write-baseline > "$GITROOT/skills/foo/baseline.json"
git -C "$GITROOT" add -A
git -C "$GITROOT" commit -q -m "add baseline"
out="$(cd "$GITROOT" && bash "$CHECK" --scan-root "$GITROOT/skills" --require-trusted-ref --trusted-ref HEAD --trusted-baseline-path skills/foo/baseline.json 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
  ok "TC-IDIOM-025: --require-trusted-ref with a valid matching baseline PASSes"
else
  bad "TC-IDIOM-025: expected PASS, got rc=$rc: $out"
fi

if bash "$CHECK" >/dev/null 2>&1; then
  ok "TC-IDIOM-026: default mode against the REAL committed baseline PASSes (load-bearing)"
else
  bad "TC-IDIOM-026: default mode against the real repo baseline unexpectedly FAILs"
fi

# ---------------------------------------------------------------------------
echo "=== Group F: --write-baseline determinism — TC-IDIOM-027..028 ==="
# ---------------------------------------------------------------------------

R="$(fresh_root F027)"
write_script "$R" b/two.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
write_script "$R" a/one.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd2 || echo "y"
}
EOF
out1="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
out2="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out1" = "$out2" ]; then
  ok "TC-IDIOM-027: --write-baseline is byte-identical across repeated runs (sorted keys)"
else
  bad "TC-IDIOM-027: expected deterministic output, got mismatch:\n$out1\n---\n$out2"
fi

R="$(fresh_root F028)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
bash "$CHECK" --scan-root "$R" --write-baseline > "$WORK/f028-baseline.json"
if bash "$CHECK" --scan-root "$R" --baseline "$WORK/f028-baseline.json" >/dev/null 2>&1; then
  ok "TC-IDIOM-028: --write-baseline output round-trips as an accepted --baseline (generator ⇄ checker consistent)"
else
  bad "TC-IDIOM-028: expected the freshly generated baseline to make the checker PASS"
fi

# ---------------------------------------------------------------------------
echo "=== Group G: infra / usage — TC-IDIOM-029..031 ==="
# ---------------------------------------------------------------------------

R="$(fresh_root G029)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
echo hi
EOF
NOJQ_DIR="$WORK/nojq-path"
mkdir -p "$NOJQ_DIR"
for b in bash sed grep find sort cut mktemp cat awk tr; do
  real="$(command -v "$b" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$NOJQ_DIR/$b"
done
out="$(PATH="$NOJQ_DIR" bash "$CHECK" --scan-root "$R" --write-baseline 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qi 'jq' <<<"$out"; then
  ok "TC-IDIOM-029: jq unavailable → exit 2, error names jq"
else
  bad "TC-IDIOM-029: expected exit 2 naming jq, got rc=$rc: $out"
fi

out="$(bash "$CHECK" --totally-unknown-flag 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "TC-IDIOM-030: unknown CLI flag → exit 2"
else
  bad "TC-IDIOM-030: expected exit 2 for unknown flag, got rc=$rc"
fi

R="$(fresh_root G031)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
echo hi
EOF
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/does-not-exist-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "TC-IDIOM-031: missing baseline in default (non-strict) mode → exit 2 (usage/env, not a strict FAIL)"
else
  bad "TC-IDIOM-031: expected exit 2 for missing baseline, got rc=$rc: $out"
fi

# ---------------------------------------------------------------------------
echo "=== Group H: Rule S word-boundary regression + strict-mode growth — TC-IDIOM-032..033 ==="
# ---------------------------------------------------------------------------

# TC-IDIOM-032: regression pin for a bug caught in review — the alternation
# (true|echo\>) only bounded the `echo` branch, leaving bare `true`
# unanchored so it prefix-matched `truex`/`trueish` etc. The fix wraps the
# WHOLE alternation in a single POSIX word-end boundary. `truex` must NOT be
# treated as the `true` swallow token.
R="$(fresh_root H032)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || truex
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-032: '|| truex' (not the bare 'true' token) is not flagged — regression pin for the unbounded-alternation bug"
else
  bad "TC-IDIOM-032: expected no match ('truex' is not 'true'), got: $out"
fi

# TC-IDIOM-033: the load-bearing property of --require-trusted-ref (flagged
# in review as untested) — strict mode reads the BASELINE from the trusted
# ref but scans the WORKING TREE, so a working-tree-only violation added
# past a clean trusted baseline must FAIL. This is the exact same-PR
# self-ratification bypass the mode exists to close.
GITROOT2="$WORK/gitfixture2"
git init -q "$GITROOT2"
git -C "$GITROOT2" config user.email test@test.com
git -C "$GITROOT2" config user.name test
mkdir -p "$GITROOT2/skills/foo"
write_script "$GITROOT2" skills/foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  echo clean
}
EOF
bash "$CHECK" --scan-root "$GITROOT2/skills" --write-baseline > "$GITROOT2/skills/foo/baseline.json"
git -C "$GITROOT2" add -A
git -C "$GITROOT2" commit -q -m "clean baseline"
# Dirty the WORKING TREE only (not committed) with a new violation.
write_script "$GITROOT2" skills/foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  echo clean
  cmd1 || true
}
EOF
out="$(cd "$GITROOT2" && bash "$CHECK" --scan-root "$GITROOT2/skills" --require-trusted-ref --trusted-ref HEAD --trusted-baseline-path skills/foo/baseline.json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'bar.sh' <<<"$out"; then
  ok "TC-IDIOM-033: --require-trusted-ref FAILs when the WORKING TREE adds a violation past a clean committed trusted baseline (closes the self-ratification bypass)"
else
  bad "TC-IDIOM-033: expected FAIL on working-tree growth vs trusted baseline, got rc=$rc: $out"
fi

# TC-IDIOM-034: regression pin for a review-flagged false negative — the
# original boundary required whitespace-or-EOL after true/echo, so the most
# common real-world swallow shapes (paren/semicolon/brace-terminated, e.g.
# `x=$(cmd || true)`) were never detected at all (confirmed ~130 such sites
# tree-wide). The fix widens the boundary to any non-word character.
R="$(fresh_root H034)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  a=$(cmd1 || true)
  b=$(cmd2 || echo "fallback")
  cmd3 || true;
  { cmd4 || true; }
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if echo "$out" | jq -e '."foo/bar.sh".swallow_unjustified == 4' >/dev/null 2>&1; then
  ok "TC-IDIOM-034: paren/semicolon/brace-terminated swallows are flagged — regression pin for the whitespace-only-boundary false negative"
else
  bad "TC-IDIOM-034: expected 4 unjustified swallow occurrences, got: $out"
fi

# TC-IDIOM-035: regression pin — a baseline value that is valid JSON but
# does not match the expected {"<path>": {"jq_unguarded": N, ...}} shape
# (e.g. a string where a number is expected) must FAIL loud (exit 2 in
# default mode), not silently exempt that file from the ratchet. Prior to
# the fix, `set -uo pipefail` (no `-e`) absorbed the resulting jq/arithmetic
# errors into a false PASS.
R="$(fresh_root H035)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
  y=$(jq -r 'select(.body | contains("y"))')
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": "N/A", "swallow_unjustified": 0}}' > "$WORK/h035-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/h035-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "TC-IDIOM-035: a baseline entry with a non-numeric field FAILs loud (exit 2) instead of silently exempting the file"
else
  bad "TC-IDIOM-035: expected exit 2 for malformed baseline entry, got rc=$rc: $out"
fi

# TC-IDIOM-036: the same malformed-baseline shape under --require-trusted-ref
# must FAIL CLOSED (exit 1), not silently PASS — the exact strict-mode
# self-ratification bypass this schema check exists to prevent.
GITROOT3="$WORK/gitfixture3"
git init -q "$GITROOT3"
git -C "$GITROOT3" config user.email test@test.com
git -C "$GITROOT3" config user.name test
mkdir -p "$GITROOT3/skills/foo"
write_script "$GITROOT3" skills/foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  rm -rf "$STUFF" 2>/dev/null || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": "CORRUPTED"}}' > "$GITROOT3/skills/foo/baseline.json"
git -C "$GITROOT3" add -A
git -C "$GITROOT3" commit -q -m "malformed baseline"
out="$(cd "$GITROOT3" && bash "$CHECK" --scan-root "$GITROOT3/skills" --require-trusted-ref --trusted-ref HEAD --trusted-baseline-path skills/foo/baseline.json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "TC-IDIOM-036: a malformed trusted baseline FAILs closed under --require-trusted-ref instead of silently exempting the file"
else
  bad "TC-IDIOM-036: expected FAIL closed on malformed trusted baseline, got rc=$rc: $out"
fi

# ---------------------------------------------------------------------------
echo "=== Group J: forward-window direction, invalid-JSON baseline, cross-engine parity — TC-IDIOM-037..039 ==="
# ---------------------------------------------------------------------------

# TC-IDIOM-037: Group A only tested the guard BEFORE the match (backward
# window). Rule J's window is symmetric (+/-15) — pin the forward direction
# too, so a `hi = n + window` off-by-one regression is caught.
R="$(fresh_root J037)"
{
  echo '#!/bin/bash'
  echo 'set -euo pipefail'
  echo ''
  echo 'select(.body | test("x"))'
  for i in $(seq 1 14); do echo "filler_$i=1"; done
  echo 'select(.body | type == "string")'
} | write_script "$R" foo/bar.sh
out="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
if [ "$out" = "{}" ]; then
  ok "TC-IDIOM-037: a guard 15 lines AFTER the match (forward window direction) also suppresses the flag"
else
  bad "TC-IDIOM-037: expected empty baseline (forward guard within window), got: $out"
fi

# TC-IDIOM-038: invalid JSON (not just "file absent") in the working-tree
# baseline is a distinct exit-2 usage/env error, never a false PASS.
R="$(fresh_root J038)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo clean
EOF
printf '{not valid json' > "$WORK/j038-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/j038-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "TC-IDIOM-038: invalid JSON in the working-tree baseline (file present, unparseable) → exit 2, distinct from a missing-file baseline"
else
  bad "TC-IDIOM-038: expected exit 2 for invalid-JSON baseline, got rc=$rc: $out"
fi

# TC-IDIOM-039: cross-engine parity — the Rule S detector must produce
# IDENTICAL results whether the system `awk` resolves to gawk or mawk (the
# whole point of the TC-IDIOM-032/034 boundary fix). Skips gracefully if
# mawk isn't installed on the runner rather than failing the suite on a
# packaging difference unrelated to this script's correctness.
if command -v mawk >/dev/null 2>&1; then
  R="$(fresh_root J039)"
  write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  a=$(cmd1 || true)
  b=$(cmd2 || echo "fallback")
  cmd3 || truex
  cmd4 || echoinvalid
}
EOF
  MAWK_DIR="$WORK/mawk-path"
  mkdir -p "$MAWK_DIR"
  ln -sf "$(command -v mawk)" "$MAWK_DIR/awk"
  out_gawk="$(bash "$CHECK" --scan-root "$R" --write-baseline)"
  out_mawk="$(PATH="$MAWK_DIR:$PATH" bash "$CHECK" --scan-root "$R" --write-baseline)"
  if [ "$out_gawk" = "$out_mawk" ] && echo "$out_gawk" | jq -e '."foo/bar.sh".swallow_unjustified == 2' >/dev/null 2>&1; then
    ok "TC-IDIOM-039: Rule S detection is byte-identical under gawk vs mawk (2 real swallows, 'truex'/'echoinvalid' excluded on both)"
  else
    bad "TC-IDIOM-039: gawk/mawk output mismatch or wrong count — gawk=[$out_gawk] mawk=[$out_mawk]"
  fi
else
  ok "TC-IDIOM-039: skipped — mawk not installed on this runner (portability claim not exercisable here)"
fi

# ---------------------------------------------------------------------------
echo "=== Group K: empty-scan-root sanity check (silent-failure-hunter finding) — TC-IDIOM-040..042 ==="
# ---------------------------------------------------------------------------

# TC-IDIOM-040/041: a --scan-root that doesn't exist (or exists but has zero
# *.sh files) must FAIL, not trivially PASS. Without this check, EVERY
# baseline entry looks like a shrink against an empty discovery — the exact
# silent-degrade-to-pass gap flagged in review, defeating the ratchet with
# zero real coverage even under --require-trusted-ref.
NONEXISTENT="$WORK/definitely-does-not-exist-$$"
out="$(bash "$CHECK" --scan-root "$NONEXISTENT" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "TC-IDIOM-040: a nonexistent --scan-root FAILs (exit 2), not a trivial PASS"
else
  bad "TC-IDIOM-040: expected exit 2 for nonexistent scan root, got rc=$rc: $out"
fi

GITROOT4="$WORK/gitfixture4"
git init -q "$GITROOT4"
git -C "$GITROOT4" config user.email test@test.com
git -C "$GITROOT4" config user.name test
mkdir -p "$GITROOT4/skills"
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 5}}' > "$GITROOT4/baseline.json"
git -C "$GITROOT4" add -A
git -C "$GITROOT4" commit -q -m "baseline, no scripts"
out="$(cd "$GITROOT4" && bash "$CHECK" --scan-root "$GITROOT4/skills" --require-trusted-ref --trusted-ref HEAD --trusted-baseline-path baseline.json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "TC-IDIOM-041: an empty (zero-*.sh) scan root under --require-trusted-ref FAILs closed rather than treating every baseline entry as a shrink"
else
  bad "TC-IDIOM-041: expected FAIL closed on an empty scan root, got rc=$rc: $out"
fi

# TC-IDIOM-042: the sanity check must NOT trip on a scan root that genuinely
# HAS *.sh files with zero violations — only "no .sh files scanned at all" is
# the failure condition, not "no violations found."
R="$(fresh_root K042)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail
echo clean
EOF
if bash "$CHECK" --scan-root "$R" >/dev/null 2>&1; then
  ok "TC-IDIOM-042: a scan root with real (clean) *.sh files still PASSes normally — the check is scoped to zero-files, not zero-violations"
else
  bad "TC-IDIOM-042: expected a clean-but-nonempty scan root to PASS"
fi

# ---------------------------------------------------------------------------
echo "=== Group L: non-integer numeric baseline values (review finding) — TC-IDIOM-043..045 ==="
# ---------------------------------------------------------------------------

# TC-IDIOM-043: a baseline count that is a valid jq `number` but NOT an
# integer (e.g. 1.5) must FAIL loud (exit 2 in default mode), not silently
# exempt the file. Prior to the fix, the schema check only asserted
# `type == "number"`, so 1.5 passed schema validation and then broke the
# `[ -gt ]`/`[ -lt ]` integer comparisons downstream — which degrade to a
# silent false PASS under `set -uo pipefail` (no `-e`).
R="$(fresh_root L043)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
  y=$(jq -r 'select(.body | contains("y"))')
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 1.5, "swallow_unjustified": 0}}' > "$WORK/l043-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/l043-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ]; then
  ok "TC-IDIOM-043: a non-integer numeric baseline field (1.5) FAILs loud (exit 2) instead of silently exempting the file"
else
  bad "TC-IDIOM-043: expected exit 2 for non-integer baseline field, got rc=$rc: $out"
fi

# TC-IDIOM-044: the same non-integer shape under --require-trusted-ref must
# FAIL CLOSED (exit 1), not silently PASS.
GITROOT5="$WORK/gitfixture5"
git init -q "$GITROOT5"
git -C "$GITROOT5" config user.email test@test.com
git -C "$GITROOT5" config user.name test
mkdir -p "$GITROOT5/skills/foo"
write_script "$GITROOT5" skills/foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  rm -rf "$STUFF" 2>/dev/null || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 2.7}}' > "$GITROOT5/skills/foo/baseline.json"
git -C "$GITROOT5" add -A
git -C "$GITROOT5" commit -q -m "non-integer baseline"
out="$(cd "$GITROOT5" && bash "$CHECK" --scan-root "$GITROOT5/skills" --require-trusted-ref --trusted-ref HEAD --trusted-baseline-path skills/foo/baseline.json 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  ok "TC-IDIOM-044: a non-integer trusted baseline field FAILs closed under --require-trusted-ref instead of silently exempting the file"
else
  bad "TC-IDIOM-044: expected FAIL closed on non-integer trusted baseline field, got rc=$rc: $out"
fi

# TC-IDIOM-045: an integer-VALUED number written in exponent notation (e.g.
# 1e2 == 100) is schema-valid (it IS an integer), but naive jq string
# interpolation renders it as "1E+2" — which then fails the same integer
# comparisons. This must reconcile normally (as a shrink notice, matching the
# real discovered count), not error out.
R="$(fresh_root L045)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 1e2, "swallow_unjustified": 0}}' > "$WORK/l045-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/l045-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! grep -qi "integer expected" <<<"$out"; then
  ok "TC-IDIOM-045: an exponent-notation integer baseline value (1e2) reconciles cleanly, no 'integer expected' error"
else
  bad "TC-IDIOM-045: expected clean PASS for exponent-notation integer baseline, got rc=$rc: $out"
fi

# ---------------------------------------------------------------------------
echo "=== Group M: missing option-argument usage errors (review finding) — TC-IDIOM-046..049 ==="
# ---------------------------------------------------------------------------

# TC-IDIOM-046..049: each value-taking option, given with no following value
# (i.e. as the last argument), must FAIL with the documented exit-2 usage
# error, not die on an unbound `$2` under `set -u` (which exited 1 and looked
# like an internal shell crash rather than a handled usage error).
for opt in --scan-root --baseline --trusted-ref --trusted-baseline-path; do
  out="$(bash "$CHECK" "$opt" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && ! grep -qi "unbound variable" <<<"$out"; then
    ok "TC-IDIOM-046..049: '$opt' with no value exits 2 (usage error), not an unbound-variable crash"
  else
    bad "TC-IDIOM-046..049: expected exit 2 for '$opt' with no value, got rc=$rc: $out"
  fi
done

# ---------------------------------------------------------------------------
echo "=== Group N: baseline counts too large for bash comparisons (review finding) — TC-IDIOM-050..052 ==="
# ---------------------------------------------------------------------------

# TC-IDIOM-050: a baseline count that IS an integer per the (. == (.|floor))
# check, but exceeds 2^53 (9007199254740992, the largest integer jq's
# IEEE-754 doubles represent exactly), must FAIL loud (exit 2 in default
# mode) rather than silently exempt the file. Prior to this fix, `1e20`
# passed the integer check, then `floor` rendered it as "1e+20" — which
# broke the downstream `[ -gt ]`/`[ -lt ]` comparisons and, under
# `set -uo pipefail` (no `-e`), silently PASSed instead of failing.
R="$(fresh_root N050)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  echo "$1" || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 1e20}}' > "$WORK/n050-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/n050-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi "integer expected" <<<"$out"; then
  ok "TC-IDIOM-050: an out-of-range exponent-notation baseline value (1e20) FAILs loud (exit 2), not a silent PASS via 'integer expected'"
else
  bad "TC-IDIOM-050: expected exit 2 for out-of-range baseline field, got rc=$rc: $out"
fi

# TC-IDIOM-051: a PLAIN-DECIMAL integer literal just past bash's int64
# ceiling (9223372036854775808 == INT64_MAX + 1) is also rejected. jq's
# `floor` rounds this to "9223372036854776000" when rendered, which ALSO
# overflows `[ -gt ]`/`[ -lt ]` — so a digits-only string check alone would
# not have caught this; the fix bounds the numeric VALUE at 2^53.
R="$(fresh_root N051)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  echo "$1" || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 9223372036854775808, "swallow_unjustified": 0}}' > "$WORK/n051-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/n051-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi "integer expected" <<<"$out"; then
  ok "TC-IDIOM-051: a plain-decimal baseline value past bash's int64 ceiling FAILs loud (exit 2), not a silent PASS via 'integer expected'"
else
  bad "TC-IDIOM-051: expected exit 2 for int64-overflow baseline field, got rc=$rc: $out"
fi

# TC-IDIOM-052: the same out-of-range shape under --require-trusted-ref must
# FAIL CLOSED (exit 1), not silently PASS.
GITROOT6="$WORK/gitfixture6"
git init -q "$GITROOT6"
git -C "$GITROOT6" config user.email test@test.com
git -C "$GITROOT6" config user.name test
mkdir -p "$GITROOT6/skills/foo"
write_script "$GITROOT6" skills/foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  echo "$1" || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 9223372036854775808}}' > "$GITROOT6/skills/foo/baseline.json"
git -C "$GITROOT6" add -A
git -C "$GITROOT6" commit -q -m "out-of-range baseline"
out="$(cd "$GITROOT6" && bash "$CHECK" --scan-root "$GITROOT6/skills" --require-trusted-ref --trusted-ref HEAD --trusted-baseline-path skills/foo/baseline.json 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && ! grep -qi "integer expected" <<<"$out"; then
  ok "TC-IDIOM-052: an out-of-range trusted baseline field FAILs closed (exit 1) under --require-trusted-ref instead of silently exempting the file"
else
  bad "TC-IDIOM-052: expected FAIL closed (exit 1) on out-of-range trusted baseline field, got rc=$rc: $out"
fi

# ---------------------------------------------------------------------------
echo "=== Group O: mktemp/scratch-write failures must fail closed (review finding) — TC-IDIOM-053..055 ==="
# ---------------------------------------------------------------------------

# A PATH dir whose 'mktemp' always fails (simulates e.g. an unavailable
# TMPDIR), with every other tool the checker needs left as a real symlink —
# mirrors TC-IDIOM-029's fake-PATH pattern but breaks only mktemp. The list
# below is every external binary check-shell-idioms.sh invokes ANYWHERE in
# its control flow (including dirname/wc, used before the mktemp guard is
# even reached) — an incomplete list would make the checker die on a missing
# tool for an unrelated reason and reach exit 2 for the WRONG reason, which
# would pass this assertion by accident rather than by exercising the fix
# (caught in review). `command -v` is resolved via an absolute-PATH bash
# subshell so it reports a real filesystem path even if the CALLING shell has
# a shell-function/alias override for the same name (e.g. some `grep`/`find`
# wrappers).
FAKE_MKTEMP_DIR="$WORK/fake-mktemp-path"
mkdir -p "$FAKE_MKTEMP_DIR"
cat > "$FAKE_MKTEMP_DIR/mktemp" <<'EOF'
#!/bin/bash
echo "mktemp: simulated failure" >&2
exit 1
EOF
chmod +x "$FAKE_MKTEMP_DIR/mktemp"
for b in bash sed grep find sort cut cat awk tr jq git dirname wc; do
  real="$(PATH="/usr/bin:/bin" command -v "$b" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$FAKE_MKTEMP_DIR/$b"
done

# TC-IDIOM-053: a failing mktemp in default mode must exit 2 (infra error)
# and must NOT print "shell-idioms-guard: PASS". Prior to this fix, the
# three `DISC_TMP="$(mktemp)"`-style assignments were unchecked, so under
# `set -uo pipefail` (no `-e`) the empty-path redirects/cut calls were
# silently ignored and the checker printed PASS with exit 0 — a violation
# that exists in the scanned tree would never be reported.
R="$(fresh_root O053)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
echo '{}' > "$WORK/o053-baseline.json"
out="$(PATH="$FAKE_MKTEMP_DIR" bash "$CHECK" --scan-root "$R" --baseline "$WORK/o053-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi "shell-idioms-guard: PASS" <<<"$out"; then
  ok "TC-IDIOM-053: a failing mktemp in default mode exits 2 (infra error), not a silent PASS"
else
  bad "TC-IDIOM-053: expected exit 2 and no PASS output for a failing mktemp, got rc=$rc: $out"
fi

# TC-IDIOM-054: the same failure under --require-trusted-ref must ALSO exit
# non-zero — this is a scratch-space allocation failure, not a ratchet
# violation, so the documented contract is exit 2 (infra error) even in
# strict mode, not the strict-mode exit-1 fail-closed path.
GITROOT7="$WORK/gitfixture7"
git init -q "$GITROOT7"
git -C "$GITROOT7" config user.email test@test.com
git -C "$GITROOT7" config user.name test
mkdir -p "$GITROOT7/skills/foo"
write_script "$GITROOT7" skills/foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  echo "$1" || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 1}}' > "$GITROOT7/skills/foo/baseline.json"
git -C "$GITROOT7" add -A
git -C "$GITROOT7" commit -q -m "clean baseline"
out="$(cd "$GITROOT7" && PATH="$FAKE_MKTEMP_DIR" bash "$CHECK" --scan-root "$GITROOT7/skills" --require-trusted-ref --trusted-ref HEAD --trusted-baseline-path skills/foo/baseline.json 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi "shell-idioms-guard: PASS" <<<"$out"; then
  ok "TC-IDIOM-054: a failing mktemp under --require-trusted-ref exits 2 (infra error), not a silent PASS"
else
  bad "TC-IDIOM-054: expected exit 2 and no PASS output for a failing mktemp in strict mode, got rc=$rc: $out"
fi

# TC-IDIOM-055: a healthy mktemp (baseline/no fake PATH) is unaffected by
# this fix — a normal PASS still exits 0 and still prints the PASS line.
R="$(fresh_root O055)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
echo hi
EOF
echo '{}' > "$WORK/o055-baseline.json"
out="$(bash "$CHECK" --scan-root "$R" --baseline "$WORK/o055-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && grep -qi "shell-idioms-guard: PASS" <<<"$out"; then
  ok "TC-IDIOM-055: a clean tree with a healthy mktemp still exits 0 and prints PASS (no regression from the mktemp-check fix)"
else
  bad "TC-IDIOM-055: expected exit 0 and PASS output for a clean tree, got rc=$rc: $out"
fi

# ---------------------------------------------------------------------------
echo "=== Group P: current-tree infra-failure hardening (issue #482) — TC-IDIOM-056..065 ==="
# ---------------------------------------------------------------------------
#
# Round-5 residual findings from #480's (INV-130) review loop, split out at
# operator takeover: three narrow infra-failure paths where the checker could
# print PASS (exit 0) without having actually run the ratchet comparison.

# TC-IDIOM-056: an awk that cannot execute (simulated via a fake PATH stub
# exiting 1) during discover_counts' Rule J detector call must exit 2, never
# a silent PASS. Prior to the fix, the failed awk made the `| wc -l` see
# empty input, which still printed "0" — read as "file is clean."
FAKE_AWK_DIR="$WORK/fake-awk-path"
mkdir -p "$FAKE_AWK_DIR"
cat > "$FAKE_AWK_DIR/awk" <<'EOF'
#!/bin/bash
echo "awk: simulated failure" >&2
exit 1
EOF
chmod +x "$FAKE_AWK_DIR/awk"
for b in bash sed grep find sort cut mktemp cat tr jq git dirname wc; do
  real="$(PATH="/usr/bin:/bin" command -v "$b" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$FAKE_AWK_DIR/$b"
done

R="$(fresh_root P056)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
echo '{}' > "$WORK/p056-baseline.json"
out="$(PATH="$FAKE_AWK_DIR" bash "$CHECK" --scan-root "$R" --baseline "$WORK/p056-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi "shell-idioms-guard: PASS" <<<"$out"; then
  ok "TC-IDIOM-056: a failing awk detector during the current-tree scan exits 2 (infra error), not a silent PASS"
else
  bad "TC-IDIOM-056: expected exit 2 and no PASS output for a failing awk detector, got rc=$rc: $out"
fi

# TC-IDIOM-057: the same failing-awk scenario under --write-baseline must
# also exit 2, and must emit NO baseline JSON on stdout. Stdout and stderr
# are captured SEPARATELY (review finding, round 1) — a combined-stream
# assertion (`out != "{}"`) would pass even if an implementation emitted a
# clean "{}" on stdout alongside an error line on stderr, which does not
# verify the actual requirement ("no baseline JSON is emitted").
R="$(fresh_root P057)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
STDOUT_FILE="$WORK/p057-stdout"
STDERR_FILE="$WORK/p057-stderr"
PATH="$FAKE_AWK_DIR" bash "$CHECK" --scan-root "$R" --write-baseline >"$STDOUT_FILE" 2>"$STDERR_FILE"; rc=$?
if [ "$rc" -eq 2 ] && [ ! -s "$STDOUT_FILE" ]; then
  ok "TC-IDIOM-057: a failing awk detector under --write-baseline exits 2 with EMPTY stdout — no baseline JSON emitted on the failure path"
else
  bad "TC-IDIOM-057: expected exit 2 and empty stdout, got rc=$rc stdout=[$(cat "$STDOUT_FILE")] stderr=[$(cat "$STDERR_FILE")]"
fi

# TC-IDIOM-058: a healthy awk (no fake PATH) is unaffected by the fix — a
# normal PASS still exits 0.
R="$(fresh_root P058)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
echo hi
EOF
echo '{}' > "$WORK/p058-baseline.json"
if bash "$CHECK" --scan-root "$R" --baseline "$WORK/p058-baseline.json" >/dev/null 2>&1; then
  ok "TC-IDIOM-058: a clean tree with a healthy awk detector still PASSes (no regression from the detector-failure check)"
else
  bad "TC-IDIOM-058: expected PASS for a clean tree with a healthy awk detector"
fi

# TC-IDIOM-059: a partial file-union build. The reconciliation phase reads
# DISC_TMP and BASE_TMP via two SEPARATE `cut -f1` calls, each checked (fixed
# from a single `{ cut ...; cut ...; }` GROUP, whose exit status is only its
# LAST command's — a failing FIRST cut was invisible to a `||` guard on the
# group). Drive the real checker end-to-end with a fake `cut` that fails only
# on its first invocation (DISC_TMP is always cut first in the reconciliation
# phase, so this deterministically simulates "the discovered-counts read
# failed") and succeeds on every subsequent call: the checker must exit 2,
# never silently treat the discovered side of the union as empty.
FAKE_CUT_DIR="$WORK/fake-cut-first-fails-path"
mkdir -p "$FAKE_CUT_DIR"
REAL_CUT="$(PATH="/usr/bin:/bin" command -v cut)"
CUT_CALL_COUNT_FILE="$WORK/p059-cut-call-count"
rm -f "$CUT_CALL_COUNT_FILE"
cat > "$FAKE_CUT_DIR/cut" <<EOF
#!/bin/bash
n=0
[ -f "$CUT_CALL_COUNT_FILE" ] && n="\$(cat "$CUT_CALL_COUNT_FILE")"
n=\$((n + 1))
echo "\$n" > "$CUT_CALL_COUNT_FILE"
if [ "\$n" -eq 1 ]; then
  echo "cut: simulated failure on first invocation (DISC_TMP read)" >&2
  exit 1
fi
exec "$REAL_CUT" "\$@"
EOF
chmod +x "$FAKE_CUT_DIR/cut"
for b in bash sed grep find sort mktemp cat awk tr jq git dirname wc; do
  real="$(PATH="/usr/bin:/bin" command -v "$b" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$FAKE_CUT_DIR/$b"
done

R="$(fresh_root P059)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 1}}' > "$WORK/p059-baseline.json"
out="$(PATH="$FAKE_CUT_DIR" bash "$CHECK" --scan-root "$R" --baseline "$WORK/p059-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi "shell-idioms-guard: PASS" <<<"$out"; then
  ok "TC-IDIOM-059: a failing first cut (simulated DISC_TMP read failure) during the file-union build exits 2, not a silent PASS — regression pin for the combined-cut-group bug"
else
  bad "TC-IDIOM-059: expected exit 2 and no PASS output for a failing file-union read, got rc=$rc: $out"
fi

# TC-IDIOM-060: a healthy `cut` (no fake PATH) is unaffected by the fix — a
# normal PASS still exits 0, proving the two-separate-cut rewrite doesn't
# regress the ordinary reconciliation path.
R="$(fresh_root P060)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
}
EOF
echo '{"foo/bar.sh": {"jq_unguarded": 0, "swallow_unjustified": 1}}' > "$WORK/p060-baseline.json"
if bash "$CHECK" --scan-root "$R" --baseline "$WORK/p060-baseline.json" >/dev/null 2>&1; then
  ok "TC-IDIOM-060: a healthy file-union build (matching baseline) still PASSes (no regression from the separate-cut fix)"
else
  bad "TC-IDIOM-060: expected PASS for a healthy file-union build"
fi

# TC-IDIOM-061: a *.sh path containing a literal tab is rejected loudly
# (exit 2, naming the offending path) rather than silently corrupting the
# tab-delimited "<file>\t<jq>\t<swallow>" count table and bypassing the
# ratchet for that file. The path must be SHELL-ESCAPED in the message
# (review finding, round 1) — asserting merely on the static word "tab" in
# the surrounding message text would pass even against the pre-fix raw
# interpolation (that prose also contains "tab"), so this checks for the
# `printf %q` escaped rendering of the literal tab byte itself
# (`$'...\t...'`-style), which only appears if the path was actually
# escaped rather than interpolated raw.
R="$(fresh_root P061)"
TAB_REL="$(printf 'foo/a\tb.sh')"
write_script "$R" "$TAB_REL" <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  cmd1 || true
}
EOF
out="$(bash "$CHECK" --scan-root "$R" --write-baseline 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && grep -qF "\$'" <<<"$out"; then
  ok "TC-IDIOM-061: a .sh path containing a literal tab is rejected loudly (exit 2, error names the SHELL-ESCAPED tab), never PASS"
else
  bad "TC-IDIOM-061: expected exit 2 naming the tab, got rc=$rc: $out"
fi

# TC-IDIOM-062: Rule S detector failure AFTER Rule J succeeds for the same
# file (review finding, round 1: TC-IDIOM-056 only ever failed on awk's
# FIRST invocation, so it exercised Rule J alone — Rule S's independent
# `|| { ...; exit 2; }` guard at check-shell-idioms.sh's discover_counts was
# never actually driven). A stateful stub: real awk on the 1st invocation
# (Rule J succeeds normally), simulated failure on the 2nd (Rule S) —
# discover_counts calls rule_j_unguarded_lines_in then
# rule_s_unjustified_lines_in per file, so with exactly one scanned file
# this deterministically targets Rule S's call.
FAKE_AWK_DIR2="$WORK/fake-awk-second-call-fails-path"
mkdir -p "$FAKE_AWK_DIR2"
REAL_AWK="$(PATH="/usr/bin:/bin" command -v awk)"
AWK_CALL_COUNT_FILE="$WORK/p062-awk-call-count"
rm -f "$AWK_CALL_COUNT_FILE"
cat > "$FAKE_AWK_DIR2/awk" <<EOF
#!/bin/bash
n=0
[ -f "$AWK_CALL_COUNT_FILE" ] && n="\$(cat "$AWK_CALL_COUNT_FILE")"
n=\$((n + 1))
echo "\$n" > "$AWK_CALL_COUNT_FILE"
if [ "\$n" -eq 2 ]; then
  echo "awk: simulated failure on 2nd invocation (Rule S detector)" >&2
  exit 1
fi
exec "$REAL_AWK" "\$@"
EOF
chmod +x "$FAKE_AWK_DIR2/awk"
for b in bash sed grep find sort cut mktemp cat tr jq git dirname wc; do
  real="$(PATH="/usr/bin:/bin" command -v "$b" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$FAKE_AWK_DIR2/$b"
done

R="$(fresh_root P062)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
echo '{}' > "$WORK/p062-baseline.json"
out="$(PATH="$FAKE_AWK_DIR2" bash "$CHECK" --scan-root "$R" --baseline "$WORK/p062-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi "shell-idioms-guard: PASS" <<<"$out"; then
  ok "TC-IDIOM-062: Rule S detector failure AFTER Rule J succeeds (stateful 2nd-call failure) exits 2, not a silent PASS"
else
  bad "TC-IDIOM-062: expected exit 2 and no PASS output for a Rule-S-only detector failure, got rc=$rc: $out"
fi

# TC-IDIOM-063: the detector-count pipeline exits 0 but emits EMPTY count
# text (a corrupted `wc` build, distinct from TC-IDIOM-056/062's "awk exits
# non-zero" shape) — the digits-only `case "$jq_n" in ''|*[!0-9]*)` re-check
# must catch this, since pipefail's exit-status check alone would not (the
# pipeline's last stage, `tr -d ' '`, still exits 0 on empty input).
FAKE_WC_EMPTY_DIR="$WORK/fake-wc-empty-path"
mkdir -p "$FAKE_WC_EMPTY_DIR"
cat > "$FAKE_WC_EMPTY_DIR/wc" <<'EOF'
#!/bin/bash
# Simulate a corrupted wc: consume stdin, exit 0, print nothing.
cat >/dev/null
exit 0
EOF
chmod +x "$FAKE_WC_EMPTY_DIR/wc"
for b in bash sed grep find sort cut mktemp cat awk tr jq git dirname; do
  real="$(PATH="/usr/bin:/bin" command -v "$b" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$FAKE_WC_EMPTY_DIR/$b"
done

R="$(fresh_root P063)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
echo '{}' > "$WORK/p063-baseline.json"
out="$(PATH="$FAKE_WC_EMPTY_DIR" bash "$CHECK" --scan-root "$R" --baseline "$WORK/p063-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi "shell-idioms-guard: PASS" <<<"$out"; then
  ok "TC-IDIOM-063: an empty detector-count output (wc exits 0, prints nothing) exits 2, not a silent PASS"
else
  bad "TC-IDIOM-063: expected exit 2 and no PASS output for an empty detector count, got rc=$rc: $out"
fi

# TC-IDIOM-064: the detector-count pipeline exits 0 but emits NON-NUMERIC
# count text (a different corrupted-wc shape than TC-IDIOM-063's empty-output
# case) — must also be caught by the digits-only re-check, not misread as a
# count of 0 or silently ignored by an arithmetic comparison.
FAKE_WC_GARBAGE_DIR="$WORK/fake-wc-garbage-path"
mkdir -p "$FAKE_WC_GARBAGE_DIR"
cat > "$FAKE_WC_GARBAGE_DIR/wc" <<'EOF'
#!/bin/bash
# Simulate a corrupted wc: consume stdin, exit 0, print non-numeric garbage.
cat >/dev/null
echo "not-a-number"
exit 0
EOF
chmod +x "$FAKE_WC_GARBAGE_DIR/wc"
for b in bash sed grep find sort cut mktemp cat awk tr jq git dirname; do
  real="$(PATH="/usr/bin:/bin" command -v "$b" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$FAKE_WC_GARBAGE_DIR/$b"
done

R="$(fresh_root P064)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
echo '{}' > "$WORK/p064-baseline.json"
out="$(PATH="$FAKE_WC_GARBAGE_DIR" bash "$CHECK" --scan-root "$R" --baseline "$WORK/p064-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! grep -qi "shell-idioms-guard: PASS" <<<"$out"; then
  ok "TC-IDIOM-064: a non-numeric detector-count output (wc exits 0, prints garbage) exits 2, not a silent PASS"
else
  bad "TC-IDIOM-064: expected exit 2 and no PASS output for a non-numeric detector count, got rc=$rc: $out"
fi

# TC-IDIOM-065: regression pin for the round-1 review finding — a detected
# regression (discover_counts already succeeded and found cur_jq > base_jq)
# whose LATER diagnostic re-run (the second, separate awk invocation used
# only to enumerate offending line numbers for the error message) itself
# fails must still be reported as a failure, never a silent PASS. Targets
# ONLY awk invocations carrying `-v rule_re=` (i.e. the two detector
# functions, not field_or_zero's unrelated awk program) and fails the 3rd
# such call: #1 = discover_counts' Rule J (real, finds 1 line), #2 =
# discover_counts' Rule S (real, finds 0 lines, so no Rule S growth/re-run
# below), #3 = the reconciliation loop's Rule J diagnostic re-run (fails).
FAKE_AWK_DIR3="$WORK/fake-awk-detector-3rd-call-fails-path"
mkdir -p "$FAKE_AWK_DIR3"
REAL_AWK="$(PATH="/usr/bin:/bin" command -v awk)"
DETECTOR_CALL_COUNT_FILE="$WORK/p065-detector-call-count"
rm -f "$DETECTOR_CALL_COUNT_FILE"
cat > "$FAKE_AWK_DIR3/awk" <<EOF
#!/bin/bash
is_detector=0
for a in "\$@"; do
  case "\$a" in
    rule_re=*) is_detector=1 ;;
  esac
done
if [ "\$is_detector" -eq 1 ]; then
  n=0
  [ -f "$DETECTOR_CALL_COUNT_FILE" ] && n="\$(cat "$DETECTOR_CALL_COUNT_FILE")"
  n=\$((n + 1))
  echo "\$n" > "$DETECTOR_CALL_COUNT_FILE"
  if [ "\$n" -eq 3 ]; then
    echo "awk: simulated failure on detector call #3 (diagnostic re-run)" >&2
    exit 1
  fi
fi
exec "$REAL_AWK" "\$@"
EOF
chmod +x "$FAKE_AWK_DIR3/awk"
for b in bash sed grep find sort cut mktemp cat tr jq git dirname wc; do
  real="$(PATH="/usr/bin:/bin" command -v "$b" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$FAKE_AWK_DIR3/$b"
done

R="$(fresh_root P065)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
echo '{}' > "$WORK/p065-baseline.json"
out="$(PATH="$FAKE_AWK_DIR3" bash "$CHECK" --scan-root "$R" --baseline "$WORK/p065-baseline.json" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && ! grep -qi "shell-idioms-guard: PASS" <<<"$out"; then
  ok "TC-IDIOM-065: a failing diagnostic re-run on an already-detected regression is reported as a failure, not a silent PASS — regression pin for the ignored-process-substitution-status bug"
else
  bad "TC-IDIOM-065: expected non-zero exit and no PASS output when the diagnostic re-run fails on a real regression, got rc=$rc: $out"
fi

# TC-IDIOM-066: regression pin for the round-2 review finding — when a
# detector fails under --write-baseline, discover_counts's own detector-
# failure branch calls `exit 2` directly (to propagate the failure per R1),
# which terminates the whole process immediately rather than returning to
# the `discover_counts > "$DISC_OUT" || { ...; }` call site. A cleanup
# handler living only in that `||` branch therefore never runs, leaking the
# DISC_OUT scratch file. Uses a scoped, otherwise-empty TMPDIR so any file
# left behind by the failing run is directly observable.
FAKE_AWK_DIR4="$WORK/fake-awk-write-baseline-leak-path"
mkdir -p "$FAKE_AWK_DIR4"
cat > "$FAKE_AWK_DIR4/awk" <<'EOF'
#!/bin/bash
echo "awk: simulated failure" >&2
exit 1
EOF
chmod +x "$FAKE_AWK_DIR4/awk"
for b in bash sed grep find sort cut mktemp cat tr jq git dirname wc rm; do
  real="$(PATH="/usr/bin:/bin" command -v "$b" 2>/dev/null)"
  [ -n "$real" ] && ln -sf "$real" "$FAKE_AWK_DIR4/$b"
done

R="$(fresh_root P066)"
write_script "$R" foo/bar.sh <<'EOF'
#!/bin/bash
set -euo pipefail

foo() {
  x=$(jq -r 'select(.body | test("x"))')
}
EOF
SCOPED_TMPDIR="$WORK/p066-tmpdir"
mkdir -p "$SCOPED_TMPDIR"
PATH="$FAKE_AWK_DIR4" TMPDIR="$SCOPED_TMPDIR" bash "$CHECK" --scan-root "$R" --write-baseline >/dev/null 2>&1; rc=$?
leftover="$(ls -A "$SCOPED_TMPDIR" 2>/dev/null)"
if [ "$rc" -eq 2 ] && [ -z "$leftover" ]; then
  ok "TC-IDIOM-066: a failing detector under --write-baseline leaves no scratch file behind — regression pin for the discover_counts-internal-exit-2 leak"
else
  bad "TC-IDIOM-066: expected exit 2 and an empty scratch TMPDIR, got rc=$rc leftover=[$leftover]"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
