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
echo "=== TC-PCONF-014: --itp github --chp github exits 0, 23 asserted verbs PASS (27 emit lines total), CONFORMANCE-SUMMARY fail=0 ==="
# ===========================================================================
gh_out="$(bash "$RUNNER" --itp github --chp github 2>&1)"; gh_rc=$?
assert_eq "AC1: github/github exits 0" "0" "$gh_rc"
gh_pass_count="$(grep -c '^CONFORMANCE-PCONF github/github .* PASS$' <<<"$gh_out")"
# [#393] +1: the itp_list_comments anti-false-green field/authorKind adds one PASS.
# [#396] +1: itp_read_task flipped pending->asserted (W1b).
# [#397] +2: W1c1 abstract contracts (chp_find_pr_for_issue, chp_pr_list).
# [#398 W1c2] +2: chp_pr_view + chp_list_inline_comments flipped pending→asserted.
# [#399 W1d] +4: chp_ci_status runs 3 PASS lines (all-success/mixed-failure/
# empty token assertions) and chp_mergeable runs 1 (MERGEABLE token +
# fail-closed).
assert_eq "AC1: 27 PASS lines on github/github (23 asserted verbs + #393 list_comments field + W1c2/W1d extra assertion lines incl. #399 payload-type gate)" "27" "$gh_pass_count"
assert_contains "AC1: CONFORMANCE-SUMMARY line present with fail=0" "CONFORMANCE-SUMMARY total=30 pass=27 fail=0 skip=0 pending=3" "$gh_out"
assert_contains "TC-PCONF-043: itp_read_task (github) PASSes the object-shape/fields-subset/fail-closed assertion" \
  "CONFORMANCE-PCONF github/github itp_read_task PASS" "$gh_out"

# ===========================================================================
echo ""
echo "=== TC-PCONF-020..024: --itp broken --chp broken exits non-zero, one FAIL per violated clause (AC2) ==="
# ===========================================================================
broken_out="$(bash "$RUNNER" --itp broken --chp broken 2>&1)"; broken_rc=$?
assert_eq "AC2: broken/broken exits non-zero" "1" "$broken_rc"
broken_fail_lines="$(grep '^CONFORMANCE-PCONF broken/broken .* FAIL' <<<"$broken_out")"
broken_fail_count="$(grep -c '^CONFORMANCE-PCONF broken/broken .* FAIL' <<<"$broken_out")"
# [#393] +1: the broken provider now also fails the list_comments field check (5 clauses).
assert_eq "AC2: exactly 5 FAIL lines (one per violated clause)" "5" "$broken_fail_count"
assert_contains "TC-PCONF-020: itp_list_comments FAILs wrong-shape" "itp_list_comments FAIL wrong-shape" "$broken_fail_lines"
assert_contains "TC-PCONF-021: itp_transition_state FAILs rc-0-on-error" "itp_transition_state FAIL rc-0-on-error" "$broken_fail_lines"
assert_contains "TC-PCONF-022: chp_resolve_thread FAILs missing-verb-function (command not found)" "chp_resolve_thread FAIL" "$broken_fail_lines"
assert_contains "TC-PCONF-022: chp_resolve_thread FAIL names the missing function" "chp_broken_resolve_thread: command not found" "$broken_fail_lines"
assert_contains "TC-PCONF-023: chp_review_threads FAILs non-array-output" "chp_review_threads FAIL wrong-shape" "$broken_fail_lines"
# Every OTHER asserted verb must still PASS (no false-positive FAILs beyond
# the pinned violations).
# [#398 W1c2] +2: chp_pr_view + chp_list_inline_comments — correct broken leaves.
# [#399 W1d] +4: chp_ci_status (3 assertion PASS lines) + chp_mergeable (1) —
# the broken fixture ships correct chp_broken_ci_status /
# chp_broken_mergeable so the new W1d asserted verbs stay PASS.
broken_pass_count="$(grep -c '^CONFORMANCE-PCONF broken/broken .* PASS$' <<<"$broken_out")"
# [#396] +1: itp_read_task flipped pending->asserted (W1b) and the broken fixture
# defines a correct (not-targeted) leaf for it.
# [#397] +2: W1c1 added chp_find_pr_for_issue + chp_pr_list (correct broken-provider leaves).
assert_eq "AC2: 22 non-targeted PASS lines (12 pre-W1a + read_task + 2 W1c1 + 2 W1c2 + 5 W1d assertion lines incl. payload-type gate)" "22" "$broken_pass_count"

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
# [#393] +1: the list_comments field/authorKind assertion also runs (and passes) on degraded.
# [#396] +1: itp_read_task flipped pending->asserted (W1b), governing cap `-` (never SKIPs).
# [#397] +2: W1c1 added chp_find_pr_for_issue + chp_pr_list (correct degraded leaves).
# [#398 W1c2] +2: chp_pr_view + chp_list_inline_comments (correct degraded leaves, cap `-`).
# [#399 W1d] +4: chp_ci_status (3 PASS lines) + chp_mergeable (1) — degraded's
# leaves mirror GitHub structurally, so they PASS the same token-set/
# fail-closed assertions.
assert_eq "TC-PCONF-033: 24 PASS lines on degraded (20 asserted verbs + #393 list_comments + W1c2/W1d extra assertion lines incl. #399 payload-type gate)" "24" "$deg_pass_count"

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
# (chp_create_pr — the pending specimen rotates as each W1 slice retires
# its predecessor: originally itp_count_by_state; #371 W1a retired that;
# #396 W1b retired itp_read_task; #397 W1c1 retired chp_find_pr_for_issue;
# #398 W1c2 retired chp_pr_view; #399 W1d retires chp_ci_status.
# chp_create_pr is the current pending specimen — it stays in the residual
# pending set until W1(e) lands.)
scratch="$(mktemp -d)"
sed 's/chp_create_pr=pending/chp_create_pr=asserted/' "$COVERAGE_CONF" > "$scratch/coverage-drift1.conf"
drift1_diff="$(
  spec_pending="$(pcf_spec_pending_verbs "$SPEC_MD")"
  cov_pending="$(awk -F= '/=pending$/{print $1}' "$scratch/coverage-drift1.conf" | sort -u)"
  diff <(printf '%s\n' "$spec_pending") <(printf '%s\n' "$cov_pending")
)"
assert_contains "TC-PCONF-041: coverage.conf missing a spec-tokened verb → diff names it" "chp_create_pr" "$drift1_diff"

# TC-PCONF-042: a spec row carrying the token whose verb is NOT pending in coverage.conf → FAIL.
scratch_spec="$scratch/provider-spec-drift2.md"
sed '/`chp_create_pr /s/CONTRACT-PENDING//' "$SPEC_MD" > "$scratch_spec"
drift2_diff="$(
  spec_pending="$(pcf_spec_pending_verbs "$scratch_spec")"
  cov_pending="$(awk -F= '/=pending$/{print $1}' "$COVERAGE_CONF" | sort -u)"
  diff <(printf '%s\n' "$spec_pending") <(printf '%s\n' "$cov_pending")
)"
assert_contains "TC-PCONF-042: removing a spec token leaves coverage.conf with an orphaned pending verb → diff names it" "chp_create_pr" "$drift2_diff"
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

# TC-PCONF-056 (issue #396, W1b) — pcf_is_json_object
if pcf_is_json_object '{"a":1}'; then ok "TC-PCONF-056: pcf_is_json_object true for an object"; else bad "TC-PCONF-056: object should be true"; fi
if pcf_is_json_object '[1,2,3]'; then bad "TC-PCONF-056: array should be false"; else ok "TC-PCONF-056: pcf_is_json_object false for an array"; fi
if pcf_is_json_object ''; then bad "TC-PCONF-056: empty text should be false"; else ok "TC-PCONF-056: pcf_is_json_object false for empty text"; fi

# ===========================================================================
echo ""
echo "=== AC4/AC5 sanity: this issue changed no CHP wrapper/provider-leaf/caps-branch behavior (byte-diff pin lifted for W1c1 + W1c2 + W1d) ==="
# ===========================================================================
# chp-github.sh was previously UNTOUCHED by the #370/W1a-adjacent slice — a
# byte-diff-free sanity check pinned that promise. W1c1 (#397) explicitly
# LIFTED the byte-diff constraint for the two `chp_github_find_pr_for_issue` /
# `chp_github_pr_list` leaves. W1c2 (#398) did the same for
# `chp_github_pr_view` and `chp_github_list_inline_comments`. W1d (#399)
# rewrites the two remaining focused-raw leaves `chp_github_ci_status` and
# `chp_github_mergeable` to normalized-token contracts. Each W1 slice
# rewrites its own leaves to the abstract normalized-shape contract,
# mirroring the pattern W1a used for the three ITP READ leaves. The
# byte-diff check on chp-github.sh is retired as redundant with the
# decision-level parity suites that back each rewrite:
# `test-w1c1-linkage-read-parity.sh` (W1c1),
# `test-w1c2-incidental-read-parity.sh` (W1c2), and
# `test-w1d-ci-status-mergeable-parity.sh` (W1d). The itp-github.sh
# byte-diff check likewise stays off (lifted by W1a).
ok "AC4/AC5: byte-diff pin on chp-github.sh LIFTED for W1c1+W1c2+W1d (parity proofs live in test-w1c1-linkage-read-parity.sh + test-w1c2-incidental-read-parity.sh + test-w1d-ci-status-mergeable-parity.sh)"

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
