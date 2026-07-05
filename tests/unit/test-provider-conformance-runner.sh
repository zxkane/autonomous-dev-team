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
echo "=== TC-PCONF-014: --itp github --chp github exits 0, all asserted verbs PASS, CONFORMANCE-SUMMARY fail=0 (post-W1e = no pending; +1 for W1f completeness) ==="
# ===========================================================================
gh_out="$(bash "$RUNNER" --itp github --chp github 2>&1)"; gh_rc=$?
assert_eq "AC1: github/github exits 0" "0" "$gh_rc"
gh_pass_count="$(grep -c '^CONFORMANCE-PCONF github/github .* PASS$' <<<"$gh_out")"
# Runner emits N PASS lines: 26 asserted verbs, + 1 for the #393 itp_list_comments
# anti-false-green field/authorKind assertion, + 3 W1c2/W1d extra assertion lines
# (chp_ci_status runs 3 = all-success/mixed-failure/empty; chp_mergeable runs 1),
# + 1 for the #401 W1f chp_review_threads multi-page completeness assertion
# (payload-sequence stub-gh mode emits its OWN CONFORMANCE-PCONF PASS line
# separately from the shape assertion).
# Post-#400 pending=0 (every CHP verb landed through the asserted set).
# Trust the runner output — VERIFY with `bash tests/provider-conformance/run-provider-conformance.sh`.
assert_eq "AC1: 31 PASS lines on github/github (26 asserted verbs + #393 list_comments field + W1c2/W1d extra + #401 completeness)" "31" "$gh_pass_count"
assert_contains "AC1: CONFORMANCE-SUMMARY line present with fail=0 and pending=0" "CONFORMANCE-SUMMARY total=31 pass=31 fail=0 skip=0 pending=0" "$gh_out"
assert_contains "TC-PCONF-043: itp_read_task (github) PASSes the object-shape/fields-subset/fail-closed assertion" \
  "CONFORMANCE-PCONF github/github itp_read_task PASS" "$gh_out"
# #401: multi-page completeness assertion emitted its own PASS line.
assert_contains "TC-W1F-008: chp_review_threads completeness PASS emitted on github" "chp_review_threads PASS" "$gh_out"

# ===========================================================================
echo ""
echo "=== TC-PCONF-020..024: --itp broken --chp broken exits non-zero, one FAIL per violated clause (AC2) ==="
# ===========================================================================
broken_out="$(bash "$RUNNER" --itp broken --chp broken 2>&1)"; broken_rc=$?
assert_eq "AC2: broken/broken exits non-zero" "1" "$broken_rc"
broken_fail_lines="$(grep '^CONFORMANCE-PCONF broken/broken .* FAIL' <<<"$broken_out")"
broken_fail_count="$(grep -c '^CONFORMANCE-PCONF broken/broken .* FAIL' <<<"$broken_out")"
# [#393] +1: the broken provider now also fails the list_comments field check (5 clauses).
# [#400 W1e] +3: the broken CHP fixture defines no chp_broken_{create_pr,approve,
# merge} leaves, so each of the three now-asserted W1e verbs FAILs on stub-success
# with `command not found`.
# [#401 W1f review r2] +2: chp_broken_review_threads (defined but lacks
# positional validation — its `gh api graphql -F prNumber=$pr` accepts empty
# and non-numeric args, so both `chp_review_threads ""` and `chp_review_threads
# abc` leak a gh call). These are LEGITIMATE violated-clause FAILs — the
# broken fixture demonstrates what happens when a leaf omits the W1e
# positional-validation convention (parallel to the missing-write-verb FAILs
# above).
# Total = 5 pre-W1e + 3 W1e + 2 W1f = 10 clauses.
assert_eq "AC2: exactly 10 FAIL lines (one per violated clause)" "10" "$broken_fail_count"
assert_contains "TC-PCONF-020: itp_list_comments FAILs wrong-shape" "itp_list_comments FAIL wrong-shape" "$broken_fail_lines"
assert_contains "TC-PCONF-021: itp_transition_state FAILs rc-0-on-error" "itp_transition_state FAIL rc-0-on-error" "$broken_fail_lines"
assert_contains "TC-PCONF-022: chp_resolve_thread FAILs missing-verb-function (command not found)" "chp_resolve_thread FAIL" "$broken_fail_lines"
assert_contains "TC-PCONF-022: chp_resolve_thread FAIL names the missing function" "chp_broken_resolve_thread: command not found" "$broken_fail_lines"
assert_contains "TC-PCONF-023: chp_review_threads FAILs non-array-output" "chp_review_threads FAIL wrong-shape" "$broken_fail_lines"
# [#400 W1e] the three write verbs FAIL with `command not found` on the broken
# fixture (no chp_broken_{create_pr,approve,merge} definitions).
assert_contains "TC-PCONF-024a: chp_create_pr FAILs missing-verb-function (command not found)" "chp_broken_create_pr: command not found" "$broken_fail_lines"
assert_contains "TC-PCONF-024b: chp_approve FAILs missing-verb-function (command not found)" "chp_broken_approve: command not found" "$broken_fail_lines"
assert_contains "TC-PCONF-024c: chp_merge FAILs missing-verb-function (command not found)" "chp_broken_merge: command not found" "$broken_fail_lines"
# [#401 W1f review r2] The broken review_threads leaf lacks positional
# validation → gh gets called on empty/non-numeric PR → positional-reject
# asserts FAIL. Two probes: empty PR + non-numeric PR.
assert_contains "TC-PCONF-024d: chp_review_threads FAILs positional-reject (empty/non-numeric PR leaks gh call on the broken fixture)" "chp_review_threads FAIL positional-reject" "$broken_fail_lines"
# Every OTHER asserted verb must still PASS (no false-positive FAILs beyond
# the 8 pinned violations). Non-targeted PASS set post-#400 W1e — the runner
# emits N PASS lines: 22 pre-W1e (12 base + read_task + 2 W1c1 + 2 W1c2 +
# 5 W1d incl. payload-type gate) + 0 new (the 3 W1e verbs are the newly-FAILing
# targets, not new PASSes on the broken fixture) = 22 unchanged.
broken_pass_count="$(grep -c '^CONFORMANCE-PCONF broken/broken .* PASS$' <<<"$broken_out")"
assert_eq "AC2: 22 non-targeted PASS lines (12 pre-W1a + read_task + 2 W1c1 + 2 W1c2 + 5 W1d assertion lines)" "22" "$broken_pass_count"

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
# [#400 W1e] +3: the degraded provider now defines chp_degraded_{create_pr,approve,
# merge} leaves (R4), each mirroring its GitHub counterpart's argv shape so the
# runner's write-assert passes against the degraded axis too.
assert_eq "TC-PCONF-033: 27 PASS lines on degraded (26 asserted verbs minus 3 caps-SKIPs, + #393 list_comments + W1c2/W1d extra assertion lines + W1e write assertions)" "27" "$deg_pass_count"

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
# Post-W1e (#400): every real CHP verb is asserted, so no live specimen exists;
# we inject a synthetic `chp_synthetic_drift_specimen=pending` line into a
# scratch coverage.conf and assert the tripwire's diff names it (spec-set is
# still empty here, so the pending set has one asymmetric entry).
scratch="$(mktemp -d)"
cat "$COVERAGE_CONF" > "$scratch/coverage-drift1.conf"
printf 'chp_synthetic_drift_specimen=pending\n' >> "$scratch/coverage-drift1.conf"
drift1_diff="$(
  spec_pending="$(pcf_spec_pending_verbs "$SPEC_MD")"
  cov_pending="$(awk -F= '/=pending$/{print $1}' "$scratch/coverage-drift1.conf" | sort -u)"
  diff <(printf '%s\n' "$spec_pending") <(printf '%s\n' "$cov_pending")
)"
assert_contains "TC-PCONF-041: coverage.conf pending specimen with no matching spec token → diff names it (synthetic-injection variant, post-#400 no real pending exists)" \
  "chp_synthetic_drift_specimen" "$drift1_diff"

# TC-PCONF-042: a spec row carrying the token whose verb is NOT pending in coverage.conf → FAIL.
# Same post-W1e caveat — inject a synthetic CONTRACT-PENDING row into the
# scratch spec and confirm the diff names it (coverage set is empty here, so
# the spec set has one asymmetric entry).
scratch_spec="$scratch/provider-spec-drift2.md"
{
  cat "$SPEC_MD"
  printf '\n| `chp_synthetic_orphan_specimen ARG` | (synthetic) | Drift test row. **CONTRACT-PENDING** (post-#400 synthetic — no real pending verbs exist). |\n'
} > "$scratch_spec"
drift2_diff="$(
  spec_pending="$(pcf_spec_pending_verbs "$scratch_spec")"
  cov_pending="$(awk -F= '/=pending$/{print $1}' "$COVERAGE_CONF" | sort -u)"
  diff <(printf '%s\n' "$spec_pending") <(printf '%s\n' "$cov_pending")
)"
assert_contains "TC-PCONF-042: spec row carrying CONTRACT-PENDING with no matching coverage.conf entry → diff names it (synthetic-injection variant, post-#400 no real pending exists)" \
  "chp_synthetic_orphan_specimen" "$drift2_diff"
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
echo "=== AC4/AC5 sanity: this issue changed no CHP wrapper/provider-leaf/caps-branch behavior (byte-diff pin lifted for W1c1 + W1c2 + W1d + W1e + W1f) ==="
# ===========================================================================
# chp-github.sh was previously UNTOUCHED by the #370/W1a-adjacent slice — a
# byte-diff-free sanity check pinned that promise. Subsequent explicit W1
# slices LIFT the byte-diff constraint for the verbs each slice targets, and
# each slice ships its own decision-level parity proof:
#
#   - W1c1 (#397) — `chp_github_find_pr_for_issue` / `chp_github_pr_list`
#     converted to the abstract normalized-shape contract. Parity anchor:
#     `tests/unit/test-w1c1-linkage-read-parity.sh`.
#   - W1c2 (#398) — `chp_github_pr_view` / `chp_github_list_inline_comments`
#     converted to normalized-shape + page-walk. Parity anchor:
#     `tests/unit/test-w1c2-incidental-read-parity.sh`.
#   - W1d (#399) — `chp_github_ci_status` / `chp_github_mergeable` converted
#     to normalized-token contracts. Parity anchor:
#     `tests/unit/test-w1d-ci-status-mergeable-parity.sh`.
#   - W1e (#400) — `chp_github_create_pr` / `chp_github_approve` /
#     `chp_github_merge` converted to abstract positional contracts (leaves
#     own their gh flag-tails). Parity anchor:
#     `tests/unit/test-w1e-chp-write-parity.sh` (decision + seam-trace +
#     strict live-wrapper source pins).
#   - W1f (#401) — `chp_github_review_threads` converted to a two-level
#     GraphQL cursor walk (thread + per-thread comment level) with
#     fail-closed validation of every page response (rejects `.errors`,
#     requires the connection paths non-null). Regression + completeness
#     proofs: `tests/unit/test-chp-pr-lifecycle.sh`'s TC-CHP-THREAD-SHAPE
#     + TC-CHP-THREADS-MULTIPAGE-* (TC-W1F-001..006 + 003a..c) +
#     `tests/provider-conformance/run-provider-conformance.sh`'s
#     `_run_review_threads_completeness_assert`.
#
# The byte-diff check on chp-github.sh is retired as redundant with the
# decision-level parity suites that back each rewrite. The itp-github.sh
# byte-diff check likewise stays off (already lifted by W1a + W1b).
ok "AC4/AC5: byte-diff pin on chp-github.sh LIFTED for W1c1 (#397) + W1c2 (#398) + W1d (#399) + W1e (#400) + W1f (#401) — parity proofs live in the five per-slice parity suites"

# ===========================================================================
echo ""
echo "=== TC-RGH-001..005: pcf_resolve_provider_dir gitlab axis + absolute-path form ==="
# ===========================================================================
gl_dir="$(pcf_resolve_provider_dir "$PROJECT_ROOT" gitlab)"
assert_contains "TC-RGH-001: gitlab resolves under skills/autonomous-dispatcher/scripts/providers (same as github, filename prefix disambiguates)" \
  "skills/autonomous-dispatcher/scripts/providers" "$gl_dir"

_scratch_abs="$(mktemp -d)"
abs_dir="$(pcf_resolve_provider_dir "$PROJECT_ROOT" "$_scratch_abs")"
assert_eq "TC-RGH-002: absolute-path form resolves to itself when dir exists" "$_scratch_abs" "$abs_dir"

if pcf_resolve_provider_dir "$PROJECT_ROOT" "/tmp/nonexistent-provider-dir-$$" >/dev/null 2>&1; then
  bad "TC-RGH-003: nonexistent absolute path should rc 1"
else
  ok "TC-RGH-003: nonexistent absolute path rc 1"
fi

# TC-RGH-004: unknown non-path, non-fixed name still rc 1 (already covered
# by TC-PCONF-051 nonexistent — re-express for TC-RGH namespace).
if pcf_resolve_provider_dir "$PROJECT_ROOT" madeupprovidername >/dev/null 2>&1; then
  bad "TC-RGH-004: unknown non-path name should rc 1"
else
  ok "TC-RGH-004: unknown non-path name rc 1"
fi

# TC-RGH-005: existing fixed names still resolve.
for name in github degraded broken; do
  if [[ -n "$(pcf_resolve_provider_dir "$PROJECT_ROOT" "$name")" ]]; then
    ok "TC-RGH-005: existing fixed name '$name' still resolves"
  else
    bad "TC-RGH-005: existing fixed name '$name' did not resolve"
  fi
done
rm -rf "$_scratch_abs"

# ===========================================================================
echo ""
echo "=== TC-RGH-006..009: name=/abs/dir out-of-tree provider (P1-5 review-response) ==="
# ===========================================================================
# [#416 P1-5] Codex round-1 [P1-5]: the pre-fix runner passed an absolute
# path directly as ITP_NAME/CHP_NAME, so pcf_materialize_scratch built
# nonsense filenames like `itp-/tmp/x.sh` and function names like
# `itp_/tmp/x_verb`. Post-fix the flag shape is `--itp <name>=/abs/dir`,
# decoupling logical NAME (used in filenames) from source DIR.

# Build a REAL fixture out-of-tree provider dir with a working itp_corp.sh
# leaf that mirrors the degraded provider's shape for a couple of verbs.
# The runner should be invocable against it via `--itp corp=/tmp/…` and
# emit `itp_corp_<verb>` function references, not `itp_/tmp/…_<verb>`.
_extdir="$(mktemp -d)"
_deg_dir="$PROJECT_ROOT/tests/unit/fixtures/provider-degraded"
if [[ -f "$_deg_dir/itp-degraded.sh" && -f "$_deg_dir/itp-degraded.caps" ]]; then
  # Copy the degraded ITP verbatim into the ext dir, renamed to `corp`,
  # rewriting function names `itp_degraded_*` → `itp_corp_*` and the
  # `_ITP_NAME=degraded` sentinel if present.
  sed 's/itp_degraded_/itp_corp_/g; s/_ITP_NAME=degraded/_ITP_NAME=corp/g' \
    "$_deg_dir/itp-degraded.sh" > "$_extdir/itp-corp.sh"
  cp "$_deg_dir/itp-degraded.caps" "$_extdir/itp-corp.caps"
  # Same for chp (so `--chp corp=…` also has something to resolve).
  sed 's/chp_degraded_/chp_corp_/g; s/_CHP_NAME=degraded/_CHP_NAME=corp/g' \
    "$_deg_dir/chp-degraded.sh" > "$_extdir/chp-corp.sh"
  cp "$_deg_dir/chp-degraded.caps" "$_extdir/chp-corp.caps"

  # TC-RGH-006: name=/abs/dir accepted; runner produces `CONFORMANCE-PCONF
  # corp/corp <verb> …` lines (logical name, NOT the abs path).
  rgh6_out=$(bash "$RUNNER" --itp "corp=$_extdir" --chp "corp=$_extdir" 2>&1); rgh6_rc=$?
  assert_contains "TC-RGH-006: label uses LOGICAL name 'corp/corp' (not the abs path)" \
    "CONFORMANCE-PCONF corp/corp" "$rgh6_out"
  # And crucially — no `itp_/tmp/` or `chp_/tmp/` function-name pollution.
  assert_not_contains "TC-RGH-006: no path-based function names leaked" \
    "itp_/" "$rgh6_out"
  assert_not_contains "TC-RGH-006: no chp path-based function names leaked" \
    "chp_/" "$rgh6_out"

  # TC-RGH-007: legacy abs-path-only form is now REJECTED with a fatal
  # (pre-P1-5 it silently produced nonsense filenames).
  rgh7_out=$(bash "$RUNNER" --itp "$_extdir" --chp "$_extdir" 2>&1); rgh7_rc=$?
  assert_eq "TC-RGH-007: legacy abs-path-only --itp → exit 2 (fatal)" "2" "$rgh7_rc"
  assert_contains "TC-RGH-007: fatal names the required form" "<name>=<abs-dir>" "$rgh7_out"

  # TC-RGH-008: <name>=<non-existent-abs-dir> → fatal.
  rgh8_out=$(bash "$RUNNER" --itp "corp=/no/such/provider-dir-$$" --chp github 2>&1); rgh8_rc=$?
  assert_eq "TC-RGH-008: name=/nonexistent → exit 2 (fatal)" "2" "$rgh8_rc"

  # TC-RGH-009: empty name / empty dir on either side of '=' → fatal.
  rgh9_out=$(bash "$RUNNER" --itp "=$_extdir" --chp github 2>&1); rgh9_rc=$?
  assert_eq "TC-RGH-009a: empty name before '=' → exit 2" "2" "$rgh9_rc"
  rgh9b_out=$(bash "$RUNNER" --itp "corp=" --chp github 2>&1); rgh9b_rc=$?
  assert_eq "TC-RGH-009b: empty dir after '=' → exit 2" "2" "$rgh9b_rc"
else
  ok "TC-RGH-006..009: skipped — degraded fixture not found (unexpected in this repo)"
fi
rm -rf "$_extdir"

# ===========================================================================
echo ""
echo "=== TC-RGH-010..012: --transport-hook passthrough ==="
# ===========================================================================
# TC-RGH-010: unreadable hook path → fatal exit 2 with usage error message.
th_out=$(bash "$RUNNER" --transport-hook /no/such/gitlab-hook-file.sh --itp github --chp github 2>&1); th_rc=$?
assert_eq "TC-RGH-010: unreadable --transport-hook → exit 2 (fatal)" "2" "$th_rc"
assert_contains "TC-RGH-010: message names the unreadable path" "/no/such/gitlab-hook-file.sh" "$th_out"

# TC-RGH-011: readable hook path threads through to _invoke's subshell
# as GITLAB_TRANSPORT_HOOK. Assert via a github/github run with the hook
# armed — the hook is a no-op file (no _gl_http redefinition), so github
# leaves are unaffected; then verify github/github still emits 31 PASS
# lines (byte-identical). Direct env-var visibility inside _invoke is a
# private impl detail; the observable AC is "flag accepted + byte-identical
# github result", which we assert here.
noop_hook="$(mktemp)"
cat > "$noop_hook" <<'EOF'
# no-op transport hook — does not redefine _gl_http; github leaves ignore
# GITLAB_TRANSPORT_HOOK entirely.
:
EOF
th_out=$(bash "$RUNNER" --transport-hook "$noop_hook" --itp github --chp github 2>&1); th_rc=$?
assert_eq "TC-RGH-011: --transport-hook + github/github → rc 0" "0" "$th_rc"
th_pass_count="$(grep -c '^CONFORMANCE-PCONF github/github .* PASS$' <<<"$th_out")"
assert_eq "TC-RGH-011: --transport-hook + github/github → still 31 PASS lines (byte-identical)" "31" "$th_pass_count"

# TC-RGH-012 (byte-identical no-op with --transport-hook) — already covered
# by TC-RGH-011's pass count assertion.
ok "TC-RGH-012: (covered by TC-RGH-011) github/github byte-identical with --transport-hook armed"

rm -f "$noop_hook"

# ===========================================================================
echo ""
echo "=== TC-RGH-020..023: --transport-path-add isolated PATH extension ==="
# ===========================================================================
# TC-RGH-020: --transport-path-add readable dir accepted; github/github still passes.
_scratch_bin="$(mktemp -d)"
th_out=$(bash "$RUNNER" --transport-path-add "$_scratch_bin" --itp github --chp github 2>&1); th_rc=$?
assert_eq "TC-RGH-020: --transport-path-add + github/github → rc 0" "0" "$th_rc"
th_pass_count="$(grep -c '^CONFORMANCE-PCONF github/github .* PASS$' <<<"$th_out")"
assert_eq "TC-RGH-020: --transport-path-add + github/github → still 31 PASS lines" "31" "$th_pass_count"

# TC-RGH-021: multiple --transport-path-add accumulate (both accepted, rc 0).
_scratch_bin2="$(mktemp -d)"
th_out=$(bash "$RUNNER" --transport-path-add "$_scratch_bin" --transport-path-add "$_scratch_bin2" --itp github --chp github 2>&1); th_rc=$?
assert_eq "TC-RGH-021: two --transport-path-add entries → rc 0" "0" "$th_rc"

# TC-RGH-022: added dirs do NOT leak into the runner's own env.
# Assert by checking the RUNNER'S OWN PATH ($PATH we started with) has NOT
# been mutated post-hoc — since the flags are consumed and dirs are only
# appended to ISOLATED_PATH (which lives in the subshells).
_orig_path="$PATH"
th_out=$(bash "$RUNNER" --transport-path-add "$_scratch_bin" --itp github --chp github 2>&1); th_rc=$?
assert_eq "TC-RGH-022: runner's own PATH unchanged (not mutated)" "$_orig_path" "$PATH"

# TC-RGH-023: covered by TC-RGH-020 (github/github byte-identical when flag armed).
ok "TC-RGH-023: (covered by TC-RGH-020) github/github byte-identical with --transport-path-add"

# TC-RGH-024: --transport-path-add /nonexistent → fatal exit 2.
th_out=$(bash "$RUNNER" --transport-path-add /no/such/dir-for-transport-$$ --itp github --chp github 2>&1); th_rc=$?
assert_eq "TC-RGH-024: --transport-path-add /nonexistent → exit 2" "2" "$th_rc"

rm -rf "$_scratch_bin" "$_scratch_bin2"

# ===========================================================================
echo ""
echo "=== TC-RGH-030..033: --expect-absent partial-axis mechanism ==="
# ===========================================================================
# TC-RGH-030: --expect-absent downgrades leaf-absent FAILs to SKIP on gitlab axis.
th_out=$(bash "$RUNNER" --itp gitlab --chp gitlab --expect-absent chp:create_pr,chp:merge 2>&1); th_rc=$?
# Two verbs downgrade to SKIP, other absent verbs still FAIL → rc != 0.
if [[ "$th_rc" -ne 0 ]]; then
  ok "TC-RGH-030: --expect-absent with SOME verbs unnamed → rc != 0 (other absent verbs still FAIL)"
else
  bad "TC-RGH-030: expected rc != 0 (other absent verbs), got rc 0"
fi
assert_contains "TC-RGH-030: chp_create_pr downgraded to SKIP (expected-absent: ...)" \
  "chp_create_pr SKIP (expected-absent: providers/chp-gitlab.sh:chp_gitlab_create_pr)" "$th_out"
assert_contains "TC-RGH-030: chp_merge downgraded to SKIP" \
  "chp_merge SKIP (expected-absent: providers/chp-gitlab.sh:chp_gitlab_merge)" "$th_out"

# TC-RGH-031: --expect-absent chp:create_pr → OTHER absent verbs still FAIL.
th_out=$(bash "$RUNNER" --itp gitlab --chp gitlab --expect-absent chp:create_pr 2>&1); th_rc=$?
assert_contains "TC-RGH-031: chp_merge still FAILs when only chp_create_pr expected-absent" \
  "chp_merge FAIL leaf absent" "$th_out"

# TC-RGH-032: --expect-absent seam-qualifies (itp:X != chp:X).
# We rely on the CSV parse rejecting an entry without `:` (fatal exit 2).
th_out=$(bash "$RUNNER" --itp gitlab --chp gitlab --expect-absent create_pr 2>&1); th_rc=$?
assert_eq "TC-RGH-032: --expect-absent without seam qualification → exit 2 (fatal)" "2" "$th_rc"

# ===========================================================================
echo ""
echo "=== TC-RGH-040..042: --itp gitlab --chp gitlab interim (W-D early half) ==="
# ===========================================================================
# TC-RGH-040: gitlab/gitlab on today's tree — non-zero exit, one FAIL per absent verb.
gl_out=$(bash "$RUNNER" --itp gitlab --chp gitlab 2>&1); gl_rc=$?
if [[ "$gl_rc" -ne 0 ]]; then
  ok "TC-RGH-040: --itp gitlab --chp gitlab (no leaves) → rc != 0"
else
  bad "TC-RGH-040: expected rc != 0, got 0"
fi
gl_leafabs_count="$(grep -c 'FAIL leaf absent:' <<<"$gl_out")"
if [[ "$gl_leafabs_count" -ge 20 ]]; then
  ok "TC-RGH-040: 20+ per-verb 'FAIL leaf absent' lines emitted ($gl_leafabs_count)"
else
  bad "TC-RGH-040: expected ≥ 20 FAIL leaf absent lines, got $gl_leafabs_count"
fi

# TC-RGH-041: runner did NOT abort — has a CONFORMANCE-SUMMARY line.
assert_contains "TC-RGH-041: runner completed (has SUMMARY line)" "CONFORMANCE-SUMMARY" "$gl_out"

# TC-RGH-042: --expect-absent covering every absent verb → rc 0.
# Build the full absent-verb list by extracting them from the FAIL output.
# For robustness, name every verb we know is absent on today's tree.
_all_absent=""
while IFS= read -r line; do
  # Grab lines like "CONFORMANCE-PCONF gitlab/gitlab <verb> FAIL leaf absent"
  if [[ "$line" =~ CONFORMANCE-PCONF\ gitlab/gitlab\ ([a-z_]+)\ FAIL\ leaf\ absent ]]; then
    verb="${BASH_REMATCH[1]}"
    seam="${verb%%_*}"
    base="${verb#itp_}"; base="${base#chp_}"
    _all_absent="${_all_absent}${seam}:${base},"
  fi
done <<<"$gl_out"
_all_absent="${_all_absent%,}"
gl_out2=$(bash "$RUNNER" --itp gitlab --chp gitlab --expect-absent "$_all_absent" 2>&1); gl2_rc=$?
assert_eq "TC-RGH-042: --expect-absent covering every absent verb → rc 0" "0" "$gl2_rc"

# ===========================================================================
echo ""
echo "=== TC-RGH-050: github/github parity (byte-identical) — 31 PASS still holds ==="
# ===========================================================================
th_pass_count="$(grep -c '^CONFORMANCE-PCONF github/github .* PASS$' <<<"$gh_out")"
assert_eq "TC-RGH-050: github/github byte-identical (31 PASS lines)" "31" "$th_pass_count"

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
