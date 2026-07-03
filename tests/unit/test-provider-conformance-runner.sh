#!/bin/bash
# test-provider-conformance-runner.sh — issue #370, [INV-106].
#
# Drives tests/provider-conformance/run-provider-conformance.sh (the
# provider-parameterized conformance runner) and unit-tests its pure helper
# library. IDs: TC-PCONF-NNN, per docs/test-cases/provider-conformance-runner.md.
#
# Run: bash tests/unit/test-provider-conformance-runner.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PCONF_DIR="$PROJECT_ROOT/tests/provider-conformance"
RUNNER="$PCONF_DIR/run-provider-conformance.sh"
LIB="$PCONF_DIR/lib-provider-conformance.sh"
COVERAGE_CONF="$PCONF_DIR/coverage.conf"
SPEC_MD="$PROJECT_ROOT/docs/pipeline/provider-spec.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      needle='$n'"; echo "      haystack='${h:0:400}'"; fi; }
assert_not_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      should NOT contain: '$n'"; fi; }
assert_eq() { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then ok "$d"; else bad "$d"; echo "      expected='$e' actual='$a'"; fi; }

[[ -f "$RUNNER" ]] || { echo "FATAL: runner not found at $RUNNER"; exit 2; }
[[ -f "$LIB" ]]    || { echo "FATAL: lib not found at $LIB"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }
# shellcheck source=../../tests/provider-conformance/lib-provider-conformance.sh
source "$LIB"

# ===========================================================================
echo "=== TC-PCONF-014: --itp github --chp github exits 0, 13 PASS, CONFORMANCE-SUMMARY fail=0 ==="
# ===========================================================================
gh_out="$(bash "$RUNNER" --itp github --chp github 2>&1)"; gh_rc=$?
assert_eq "AC1: github/github exits 0" "0" "$gh_rc"
gh_pass_count="$(grep -c '^CONFORMANCE-PCONF github/github .* PASS$' <<<"$gh_out")"
assert_eq "AC1: 13 ASSERTED verbs PASS on github/github" "13" "$gh_pass_count"
assert_contains "AC1: CONFORMANCE-SUMMARY line present with fail=0" "CONFORMANCE-SUMMARY total=26 pass=13 fail=0 skip=0 pending=13" "$gh_out"

# ===========================================================================
echo ""
echo "=== TC-PCONF-020..024: --itp broken --chp broken exits non-zero, one FAIL per violated clause (AC2) ==="
# ===========================================================================
broken_out="$(bash "$RUNNER" --itp broken --chp broken 2>&1)"; broken_rc=$?
assert_eq "AC2: broken/broken exits non-zero" "1" "$broken_rc"
broken_fail_lines="$(grep '^CONFORMANCE-PCONF broken/broken .* FAIL' <<<"$broken_out")"
broken_fail_count="$(grep -c '^CONFORMANCE-PCONF broken/broken .* FAIL' <<<"$broken_out")"
assert_eq "AC2: exactly 4 FAIL lines (one per violated clause)" "4" "$broken_fail_count"
assert_contains "TC-PCONF-020: itp_list_comments FAILs wrong-shape" "itp_list_comments FAIL wrong-shape" "$broken_fail_lines"
assert_contains "TC-PCONF-021: itp_transition_state FAILs rc-0-on-error" "itp_transition_state FAIL rc-0-on-error" "$broken_fail_lines"
assert_contains "TC-PCONF-022: chp_resolve_thread FAILs missing-verb-function (command not found)" "chp_resolve_thread FAIL" "$broken_fail_lines"
assert_contains "TC-PCONF-022: chp_resolve_thread FAIL names the missing function" "chp_broken_resolve_thread: command not found" "$broken_fail_lines"
assert_contains "TC-PCONF-023: chp_review_threads FAILs non-array-output" "chp_review_threads FAIL wrong-shape" "$broken_fail_lines"
# Every OTHER asserted verb must still PASS (no false-positive FAILs beyond the 4).
broken_pass_count="$(grep -c '^CONFORMANCE-PCONF broken/broken .* PASS$' <<<"$broken_out")"
assert_eq "AC2: the 9 non-targeted verbs still PASS" "9" "$broken_pass_count"

# ===========================================================================
echo ""
echo "=== TC-PCONF-030..034: --itp degraded --chp degraded — caps-conditioned SKIP, zero unexpected FAIL (R4) ==="
# ===========================================================================
deg_out="$(bash "$RUNNER" --itp degraded --chp degraded 2>&1)"; deg_rc=$?
assert_eq "R4: degraded/degraded exits 0 (zero unexpected FAILs)" "0" "$deg_rc"
assert_contains "TC-PCONF-030: itp_edit_comment SKIPped, annotated with its cap" "itp_edit_comment SKIP (cap: edit_comment)" "$deg_out"
assert_contains "TC-PCONF-031: itp_mark_checkbox SKIPped, annotated with its cap" "itp_mark_checkbox SKIP (cap: body_checkbox)" "$deg_out"
assert_contains "TC-PCONF-032: chp_request_changes SKIPped, annotated with its cap" "chp_request_changes SKIP (cap: rest_request_changes)" "$deg_out"
deg_fail_count="$(grep -c '^CONFORMANCE-PCONF degraded/degraded .* FAIL' <<<"$deg_out")"
assert_eq "R4: zero FAIL on the degraded run" "0" "$deg_fail_count"
deg_skip_count="$(grep -c '^CONFORMANCE-PCONF degraded/degraded .* SKIP' <<<"$deg_out")"
assert_eq "TC-PCONF-034: exactly 3 SKIPs" "3" "$deg_skip_count"
deg_pass_count="$(grep -c '^CONFORMANCE-PCONF degraded/degraded .* PASS$' <<<"$deg_out")"
assert_eq "TC-PCONF-033: the 10 remaining ASSERTED verbs PASS" "10" "$deg_pass_count"

# ===========================================================================
echo ""
echo "=== independent axes: --itp github --chp degraded and --itp degraded --chp github both work (R1) ==="
# ===========================================================================
mix1="$(bash "$RUNNER" --itp github --chp degraded 2>&1)"; mix1_rc=$?
assert_eq "github/degraded exits 0" "0" "$mix1_rc"
assert_contains "github/degraded label reflects the mixed axes" "CONFORMANCE-PCONF github/degraded" "$mix1"
mix2="$(bash "$RUNNER" --itp degraded --chp github 2>&1)"; mix2_rc=$?
assert_eq "degraded/github exits 0" "0" "$mix2_rc"
assert_contains "degraded/github label reflects the mixed axes" "CONFORMANCE-PCONF degraded/github" "$mix2"

# ===========================================================================
echo ""
echo "=== ITP_UNDER_TEST/CHP_UNDER_TEST env fallback ==="
# ===========================================================================
env_out="$(ITP_UNDER_TEST=degraded CHP_UNDER_TEST=degraded bash "$RUNNER" 2>&1)"; env_rc=$?
assert_eq "env fallback selects degraded/degraded, exits 0" "0" "$env_rc"
assert_contains "env fallback labels output degraded/degraded" "CONFORMANCE-PCONF degraded/degraded" "$env_out"

# ===========================================================================
echo ""
echo "=== TC-PCONF-040..042: CONTRACT-PENDING tripwire (R3) ==="
# ===========================================================================
assert_contains "TC-PCONF-040: coverage tripwire PASSes against the real repo" "CONFORMANCE-COVERAGE PASS" "$gh_out"

# TC-PCONF-041: a coverage.conf pending verb whose spec row lacks the token → FAIL.
scratch="$(mktemp -d)"
sed 's/itp_read_task=pending/itp_read_task=asserted/' "$COVERAGE_CONF" > "$scratch/coverage-drift1.conf"
drift1_diff="$(
  spec_pending="$(pcf_spec_pending_verbs "$SPEC_MD")"
  cov_pending="$(awk -F= '/=pending$/{print $1}' "$scratch/coverage-drift1.conf" | sort -u)"
  diff <(printf '%s\n' "$spec_pending") <(printf '%s\n' "$cov_pending")
)"
assert_contains "TC-PCONF-041: coverage.conf missing a spec-tokened verb → diff names it" "itp_read_task" "$drift1_diff"

# TC-PCONF-042: a spec row carrying the token whose verb is NOT pending in coverage.conf → FAIL.
scratch_spec="$scratch/provider-spec-drift2.md"
sed '/`itp_count_by_state STATE/s/CONTRACT-PENDING//' "$SPEC_MD" > "$scratch_spec"
drift2_diff="$(
  spec_pending="$(pcf_spec_pending_verbs "$scratch_spec")"
  cov_pending="$(awk -F= '/=pending$/{print $1}' "$COVERAGE_CONF" | sort -u)"
  diff <(printf '%s\n' "$spec_pending") <(printf '%s\n' "$cov_pending")
)"
assert_contains "TC-PCONF-042: removing a spec token leaves coverage.conf with an orphaned pending verb → diff names it" "itp_count_by_state" "$drift2_diff"
rm -rf "$scratch"

# ===========================================================================
echo ""
echo "=== TC-PCONF-050..055: lib-provider-conformance.sh helper unit tests ==="
# ===========================================================================
# TC-PCONF-050
tmp_conf="$(mktemp)"
cat > "$tmp_conf" <<'EOF'
# a comment
foo=bar   # inline comment
baz=qux

empty_ignored_because_no_eq
EOF
assert_eq "TC-PCONF-050: pcf_conf_value reads a plain key" "bar" "$(pcf_conf_value "$tmp_conf" foo)"
assert_eq "TC-PCONF-050: pcf_conf_value reads a second key" "qux" "$(pcf_conf_value "$tmp_conf" baz)"
if pcf_conf_value "$tmp_conf" nonexistent >/dev/null 2>&1; then bad "TC-PCONF-050: nonexistent key should rc 1"; else ok "TC-PCONF-050: nonexistent key rc 1"; fi
keys="$(pcf_conf_keys "$tmp_conf")"
assert_eq "TC-PCONF-050: pcf_conf_keys lists both keys" "$(printf 'foo\nbaz')" "$keys"
rm -f "$tmp_conf"

# TC-PCONF-051
gh_dir="$(pcf_resolve_provider_dir "$PROJECT_ROOT" github)"
assert_contains "TC-PCONF-051: github resolves under skills/autonomous-dispatcher" "skills/autonomous-dispatcher/scripts/providers" "$gh_dir"
deg_dir="$(pcf_resolve_provider_dir "$PROJECT_ROOT" degraded)"
assert_contains "TC-PCONF-051: degraded resolves under tests/unit/fixtures" "tests/unit/fixtures/provider-degraded" "$deg_dir"
brk_dir="$(pcf_resolve_provider_dir "$PROJECT_ROOT" broken)"
assert_contains "TC-PCONF-051: broken resolves under tests/provider-conformance/fixtures" "tests/provider-conformance/fixtures/provider-broken" "$brk_dir"
if pcf_resolve_provider_dir "$PROJECT_ROOT" nonexistent >/dev/null 2>&1; then bad "TC-PCONF-051: unknown provider should rc 1"; else ok "TC-PCONF-051: unknown provider rc 1"; fi

# TC-PCONF-052
scratch2="$(mktemp -d)"
pcf_materialize_scratch "$scratch2" github "$gh_dir" degraded "$deg_dir"
if [[ -L "$scratch2/itp-github.sh" && -L "$scratch2/chp-degraded.sh" \
      && ! -e "$scratch2/itp-degraded.sh" && ! -e "$scratch2/chp-github.sh" ]]; then
  ok "TC-PCONF-052: scratch dir carries ONLY itp-github.* + chp-degraded.* (no cross-seam collision)"
else
  bad "TC-PCONF-052: scratch dir contents wrong: $(ls -la "$scratch2")"
fi
rm -rf "$scratch2"

# TC-PCONF-053
iso_path="$(pcf_isolated_path "/tmp/some-stub-dir")"
assert_contains "TC-PCONF-053: isolated PATH includes the stub dir" "/tmp/some-stub-dir" "$iso_path"
for tool in bash env jq grep sed; do
  tool_dir="$(dirname "$(command -v "$tool")")"
  assert_contains "TC-PCONF-053: isolated PATH includes $tool's dir" "$tool_dir" "$iso_path"
done

# TC-PCONF-054
if pcf_is_json_array '[1,2,3]'; then ok "TC-PCONF-054: pcf_is_json_array true for an array"; else bad "TC-PCONF-054: array should be true"; fi
if pcf_is_json_array '{"a":1}'; then bad "TC-PCONF-054: object should be false"; else ok "TC-PCONF-054: pcf_is_json_array false for an object"; fi
if pcf_is_json_array ''; then bad "TC-PCONF-054: empty text should be false"; else ok "TC-PCONF-054: pcf_is_json_array false for empty text"; fi

# TC-PCONF-055
asc='[{"createdAt":"2026-01-01T00:00:00Z"},{"createdAt":"2026-01-02T00:00:00Z"}]'
desc='[{"createdAt":"2026-01-02T00:00:00Z"},{"createdAt":"2026-01-01T00:00:00Z"}]'
if pcf_is_ascending_by_created_at "$asc"; then ok "TC-PCONF-055: ascending array is ascending"; else bad "TC-PCONF-055: ascending array should be true"; fi
if pcf_is_ascending_by_created_at "$desc"; then bad "TC-PCONF-055: descending array should be false"; else ok "TC-PCONF-055: descending array is not ascending"; fi
if pcf_is_ascending_by_created_at '[]'; then ok "TC-PCONF-055: empty array is trivially ascending"; else bad "TC-PCONF-055: empty array should be true"; fi

# ===========================================================================
echo ""
echo "=== AC4/AC5 sanity: this issue changed no wrapper/provider-leaf/caps-branch behavior ==="
# ===========================================================================
# itp-github.sh / chp-github.sh are UNTOUCHED by this PR (the design's explicit
# non-goal) — a byte-diff-free sanity check that this test file did not drift
# from that promise while iterating.
#
# Must NOT rely on the ambient checkout's 'origin/main' resolving: the
# hermetic-unit CI job (which runs this file via the tests/unit/test-*.sh loop)
# uses the DEFAULT (shallow, no origin/main) checkout — only the dedicated
# spec-drift job fetches with fetch-depth: 0 (see check-provider-cutover.sh's
# --require-trusted-ref, and TC-FINALBATCH-010 in test-provider-cutover.sh for
# the same CI-topology note). A hard FAIL here on an unresolvable ref would be a
# red herring unrelated to this PR's diff, so degrade to a SKIP instead.
gh_itp_leaf="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/itp-github.sh"
gh_chp_leaf="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-github.sh"
trusted_ref="${CUTOVER_TRUSTED_REF:-origin/main}"
if ! git -C "$PROJECT_ROOT" rev-parse --verify --quiet "$trusted_ref" >/dev/null 2>&1; then
  echo "  SKIP: AC4/AC5 unchanged-leaf check — trusted ref '$trusted_ref' not resolvable here (shallow/forked checkout)"
elif git -C "$PROJECT_ROOT" diff --quiet "$trusted_ref" -- "$gh_itp_leaf" "$gh_chp_leaf" 2>/dev/null; then
  ok "AC4/AC5: itp-github.sh/chp-github.sh unchanged vs $trusted_ref (no behavior change)"
else
  bad "AC4/AC5: itp-github.sh/chp-github.sh DIFFER from $trusted_ref — this issue must not change GitHub leaf behavior"
fi

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
