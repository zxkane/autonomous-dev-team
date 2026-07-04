#!/bin/bash
# test-w1d-ci-status-mergeable-parity.sh — #399 W1d decision-level parity.
#
# Proves the W1d normalization (chp_ci_status → single token green|pending|
# failed|none; chp_mergeable absorbs -q '.mergeable') is a DECISION-level
# behavior-parity refactor WITH ONE deliberately-documented decision change:
#
#   1. For every fixture class the pre-#399 TC-DSAP-004 jq predicate exercised
#      (all-success, mixed-pending, mixed-failure, skipped-success, empty,
#      transport-error) PLUS three of the four R2 gh rc-quirk cases, the NEW
#      ci_is_green returns the SAME rc as the OLD `length>0 and
#      all(.=="SUCCESS")` gate did. This is asserted by driving the REAL
#      ci_is_green from lib-dispatch.sh — a source-pin fallback catches drift
#      if the function body ever diverges from the shape this test assumes.
#
#   2. ONE fixture class is the DOCUMENTED DECISION CHANGE: `rc_nonzero_valid_
#      json_success` — the R2 gh rc-quirk case where `gh pr checks` exits
#      non-zero WHILE emitting a well-formed all-SUCCESS payload. Pre-#399:
#      the passthrough leaf forwarded gh's rc≠0 → the caller's else-branch
#      set ci_states='[]' → gate rc 1 (not-green, false-negative). Post-#399:
#      the leaf inspects stdout, derives `green` from the parseable payload,
#      returns rc 0 (correct-green). The parity suite asserts old rc=1 AND
#      new rc=0 for this class — proving the intentional distinction, not
#      hiding it.
#
#   3. For every TC-MG-CLS input (MERGEABLE, mergeable, CONFLICTING,
#      conflicting, UNKNOWN, empty, garbage, CLEAN, BEHIND — the FULL existing
#      table), `_classify_mergeable_gate` returns the same value as recorded
#      in mergeable-classifier-golden.json — the classifier is byte-unchanged
#      per R3, lib-review-mergeable.sh ships unmodified.
#
# The suite drives the REAL post-#399 ci_is_green function from lib-dispatch.sh
# (sourced hermetically) and, in a SIBLING harness inlined below, the OLD
# ci_is_green body from origin/main so both rc trajectories are captured from
# real code, not paraphrased. See the `.meta` sidecars for provenance.
#
# Run: bash tests/unit/test-w1d-ci-status-mergeable-parity.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
FIXTURES="$SCRIPT_DIR/fixtures/w1d-parity"
CI_GOLDEN="$FIXTURES/ci-decision-golden.json"
MG_GOLDEN="$FIXTURES/mergeable-classifier-golden.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
    FAIL=$((FAIL + 1))
  fi
}

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
[[ -f "$CI_GOLDEN" ]] || { echo "FATAL: missing $CI_GOLDEN"; exit 2; }
[[ -f "$MG_GOLDEN" ]] || { echo "FATAL: missing $MG_GOLDEN"; exit 2; }

echo "=== TC-W1D-SOURCE-PIN: the REAL ci_is_green body has the exact post-#399 shape this harness drives ==="

# Strict source pin: the REAL lib-dispatch.sh::ci_is_green MUST contain the
# post-#399 lines the parity harness structurally depends on (capture then
# test `[[ "$ci_token" == "green" ]]`). If this test fails the harness would
# be silently exercising the wrong function shape — abort the whole suite
# instead of a false-green run.
_LIB_DISPATCH="$SCRIPTS/lib-dispatch.sh"
[[ -f "$_LIB_DISPATCH" ]] || { echo "FATAL: missing $_LIB_DISPATCH"; exit 2; }
_pin_ok=1
# Use fixed-string grep (-F) — the anchors we want to pin are literal shell
# substrings, not regexes, so escaping every `$`/`[`/`]` would just be error-
# prone. This is what makes the pin an actual byte-anchor.
for _line in \
    'if ci_token=$(chp_ci_status "$pr_num" 2>"$ci_err_file"); then' \
    '[[ "$ci_token" == "green" ]]' \
    'WARN: CI-status query (chp_ci_status) failed for PR #'; do
  if ! grep -qF -- "$_line" "$_LIB_DISPATCH"; then
    echo -e "  ${RED}FAIL${NC}: TC-W1D-SOURCE-PIN missing expected line: $_line"
    FAIL=$((FAIL + 1))
    _pin_ok=0
  fi
done
if [[ "$_pin_ok" == "1" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1D-SOURCE-PIN post-#399 ci_is_green shape present in lib-dispatch.sh"
  PASS=$((PASS + 1))
fi

echo
echo "=== TC-W1D-PARITY-CI: OLD (source-of-truth) vs NEW ci_is_green rc, per fixture ==="

# _drive_ci_is_green_new <gh_stdout> <gh_rc> — source lib-dispatch.sh from the
# REAL skill tree under a stubbed `gh` (chp_ci_status → chp_github_ci_status
# runs the REAL leaf against the fixture's raw payload / rc). Then invoke the
# REAL ci_is_green and echo `<token>|<rc>` — the token is the leaf's output
# BEFORE ci_is_green consumes it, the rc is ci_is_green's own exit.
#
# Sourcing the whole lib-dispatch.sh (not a paraphrase) is what makes this a
# real parity test: any future drift in ci_is_green's error-handling shape is
# exercised here.
_drive_ci_is_green_new() {
  local gh_stdout="$1" gh_rc="$2"
  local out_file
  out_file="$(mktemp)"
  env -u PROJECT_DIR -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR \
      REPO=o/r REPO_OWNER=o PROJECT_ID=w1d-parity \
      _W1D_GH_STDOUT="$gh_stdout" _W1D_GH_RC="$gh_rc" _W1D_OUT="$out_file" \
      _W1D_LIB_DISPATCH="$_LIB_DISPATCH" \
  bash -c '
    gh() { printf "%s" "$_W1D_GH_STDOUT"; return "$_W1D_GH_RC"; }
    # Source the REAL lib-dispatch.sh — sets up itp/chp/pr-linkage/config
    # dispatch shims and defines ci_is_green. lib-dispatch.sh applies
    # `set -euo pipefail`, so ci_is_green returning non-zero would abort
    # the harness — wrap in `if ...` (set -e-exempt) to let us capture rc.
    source "$_W1D_LIB_DISPATCH" >/dev/null 2>&1
    tok=$(chp_ci_status 42 2>/dev/null) || true
    if ci_is_green 42; then rc=0; else rc=$?; fi
    printf "%s|%s\n" "$tok" "$rc" > "$_W1D_OUT"
  '
  cat "$out_file"
  rm -f "$out_file"
}

# _drive_ci_is_green_old <gh_stdout> <gh_rc> — the SOURCE-OF-TRUTH pre-#399
# ci_is_green body reproduced verbatim from origin/main's lib-dispatch.sh
# (b13ef4b~1 or earlier — the passthrough era). Structurally identical
# except: (a) chp_ci_status is a passthrough stub that echoes gh's stdout
# and forwards its rc — the passthrough posture the pre-#399 leaf had; (b)
# the caller passes `--json state -q '[.[].state]'` and evaluates
# `length > 0 and all(. == "SUCCESS")` on the returned array. This is what
# a `git show origin/main` capture would exercise; we inline it here because
# a git-show fetch inside a hermetic unit test is fragile (shallow clones,
# forks). The pin above catches drift the other direction (new ci_is_green
# changing shape); this old-shape inline is a HISTORICAL constant.
_drive_ci_is_green_old() {
  local gh_stdout="$1" gh_rc="$2"
  local out_file
  out_file="$(mktemp)"
  env -u PROJECT_DIR \
      REPO=o/r \
      _W1D_GH_STDOUT="$gh_stdout" _W1D_GH_RC="$gh_rc" _W1D_OUT="$out_file" \
  bash -c '
    # The fixture stdout is the raw `gh pr checks --json state` shape
    # `[{"state":"..."}]` (what the NEW leaf sees). Pre-#399 callers passed
    # an extra `-q "[.[].state]"` which real gh applied server-side to
    # project to a state-string array. This stub simulates that: whenever the
    # OLD caller passes `-q` we transform the raw fixture with that jq
    # expression; otherwise pass through verbatim (mirrors gh, which only
    # applies -q when the caller supplies it).
    gh() {
      local q="" prev=""
      for a in "$@"; do
        if [[ "$prev" == "-q" || "$prev" == "--jq" ]]; then q="$a"; break; fi
        prev="$a"
      done
      if [[ -n "$q" && -n "$_W1D_GH_STDOUT" ]]; then
        printf "%s" "$_W1D_GH_STDOUT" | jq -r "$q" 2>/dev/null || true
      else
        printf "%s" "$_W1D_GH_STDOUT"
      fi
      return "$_W1D_GH_RC"
    }
    # Pre-#399 chp_ci_status: passthrough — forwards gh argv byte-identically
    # and returns gh~s rc. Whatever the caller passed as its tail
    # (--json state -q ~[.[].state]~) went straight to gh.
    chp_ci_status() {
      local pr="$1"; shift
      gh pr checks "$pr" --repo "$REPO" "$@"
    }
    # Pre-#399 ci_is_green — verbatim from origin/main (the passthrough era):
    # captures gh~s stderr to a mktemp file; on gh rc≠0 the caller sets
    # ci_states=~[]~ and the gate returns 1.
    ci_is_green_old() {
      local pr_num="$1"
      local ci_states ci_err_file ci_err_content
      ci_err_file=$(mktemp)
      if ci_states=$(chp_ci_status "$pr_num" --json state -q "[.[].state]" 2>"$ci_err_file"); then
        rm -f "$ci_err_file"
      else
        ci_err_content=$(cat "$ci_err_file")
        rm -f "$ci_err_file"
        if [ -n "$ci_err_content" ]; then
          echo "WARN: CI-status query (chp_ci_status) failed for PR #${pr_num}: ${ci_err_content}" >&2
        fi
        ci_states="[]"
      fi
      jq -e "length > 0 and all(. == \"SUCCESS\")" <<<"$ci_states" >/dev/null 2>&1
    }
    if ci_is_green_old 42; then rc=0; else rc=$?; fi
    printf "|%s\n" "$rc" > "$_W1D_OUT"
  '
  cat "$out_file"
  rm -f "$out_file"
}

# Iterate every row in the ci golden and assert:
#   - new_token matches golden.new_token (the new leaf ran).
#   - new_rc matches golden.new_ci_is_green_rc (the new ci_is_green ran).
#   - old_rc matches golden.old_ci_is_green_rc (the pre-#399 body would have).
#   - When old_rc == new_rc: that's the parity contract.
#   - When old_rc != new_rc: assert the row is in the documented
#     decision-change allowlist (only `rc_nonzero_valid_json_success` is).
_INTENTIONAL_DIFF_KEYS=(rc_nonzero_valid_json_success)
_is_intentional_diff() {
  local key="$1" allowed
  for allowed in "${_INTENTIONAL_DIFF_KEYS[@]}"; do
    [[ "$key" == "$allowed" ]] && return 0
  done
  return 1
}

while IFS= read -r row; do
  key="${row%%|*}"; rest="${row#*|}"
  gh_stdout="${rest%%|*}"; rest="${rest#*|}"
  gh_rc="${rest%%|*}"; rest="${rest#*|}"
  expected_new_token="${rest%%|*}"; rest="${rest#*|}"
  expected_new_rc="${rest%%|*}"; expected_old_rc="${rest#*|}"

  observed_new="$(_drive_ci_is_green_new "$gh_stdout" "$gh_rc")"
  observed_new_token="${observed_new%%|*}"
  observed_new_rc="${observed_new#*|}"; observed_new_rc="${observed_new_rc%$'\n'}"

  observed_old="$(_drive_ci_is_green_old "$gh_stdout" "$gh_rc")"
  # old row is `|<rc>` (empty leading token field)
  observed_old_rc="${observed_old#|}"; observed_old_rc="${observed_old_rc%$'\n'}"

  assert_eq "TC-W1D-PARITY-CI [$key] NEW leaf token" "$expected_new_token" "$observed_new_token"
  assert_eq "TC-W1D-PARITY-CI [$key] NEW ci_is_green rc" "$expected_new_rc" "$observed_new_rc"
  assert_eq "TC-W1D-PARITY-CI [$key] OLD ci_is_green rc (from inline pre-#399 body)" "$expected_old_rc" "$observed_old_rc"

  # Parity gate: old_rc == new_rc EXCEPT for documented decision-change rows.
  if [[ "$observed_old_rc" == "$observed_new_rc" ]]; then
    if _is_intentional_diff "$key"; then
      echo -e "  ${RED}FAIL${NC}: TC-W1D-PARITY-CI [$key] listed as intentional-diff but old_rc==new_rc==${observed_old_rc} — remove from _INTENTIONAL_DIFF_KEYS"
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}PASS${NC}: TC-W1D-PARITY-CI [$key] old_rc == new_rc == ${observed_new_rc} (parity)"
      PASS=$((PASS + 1))
    fi
  else
    if _is_intentional_diff "$key"; then
      echo -e "  ${GREEN}PASS${NC}: TC-W1D-PARITY-CI [$key] intentional decision change (old_rc=${observed_old_rc}, new_rc=${observed_new_rc}) — pre-#399 collapsed gh rc-quirk-with-valid-JSON to not-green; post-#399 derives token from stdout and correctly returns green"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${NC}: TC-W1D-PARITY-CI [$key] UNDOCUMENTED decision change (old_rc=${observed_old_rc}, new_rc=${observed_new_rc}) — either restore parity or add to _INTENTIONAL_DIFF_KEYS with a spec-quoted justification"
      FAIL=$((FAIL + 1))
    fi
  fi
done < <(jq -r 'to_entries[] | "\(.key)|\(.value.gh_stdout)|\(.value.gh_rc)|\(.value.new_token)|\(.value.new_ci_is_green_rc)|\(.value.old_ci_is_green_rc)"' "$CI_GOLDEN")

echo
echo "=== TC-W1D-ARGV-SRC: no --json / -q on chp_ci_status / chp_mergeable caller lines outside providers/ (AC2) ==="

# AC2 secondary guard: grep the CALLER-layer files (everything under
# skills/autonomous-dispatcher/scripts/ EXCEPT providers/) for
# `chp_ci_status ` / `chp_mergeable ` lines and assert none carry `--json`
# or a `-q ` flag past the verb. A backslid caller-side jq re-emerging on
# the seam would fail this check.
_scan_dir="$SCRIPTS"
_offenders="$(
  grep -rEn '(chp_ci_status|chp_mergeable) ' "$_scan_dir" \
    --include='*.sh' \
    --exclude-dir=providers 2>/dev/null \
  | grep -E '(chp_ci_status|chp_mergeable) [^#\n]*(-{2}json|-q )' \
  || true
)"
if [[ -z "$_offenders" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1D-ARGV-SRC no caller line passes --json / -q to chp_ci_status or chp_mergeable"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1D-ARGV-SRC caller-side --json/-q leak into chp_ci_status/chp_mergeable"
  echo "$_offenders" | sed 's/^/      /'
  FAIL=$((FAIL + 1))
fi

echo
echo "=== TC-W1D-PARITY-MG: _classify_mergeable_gate matches the golden on the full input table ==="

# The classifier is byte-unchanged; source lib-review-mergeable.sh and diff.
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh
source "$SCRIPTS/lib-review-mergeable.sh"

while IFS= read -r pair; do
  # Split on the first `|` (a sentinel outside any classifier token — MERGEABLE,
  # mergeable, CONFLICTING, conflicting, UNKNOWN, empty, garbage, CLEAN, BEHIND
  # — and outside every gate value — proceed, block-substantive,
  # block-nonsubstantive). Preserves the empty-key row (`""` → block-nonsubstantive)
  # that IFS-tab whitespace-collapsing would otherwise fuse.
  input="${pair%%|*}"
  expected="${pair#*|}"
  actual="$(_classify_mergeable_gate "$input")"
  assert_eq "TC-W1D-PARITY-MG classifier(<${input}>)" "$expected" "$actual"
done < <(jq -r 'to_entries[] | "\(.key)|\(.value)"' "$MG_GOLDEN")

# --------------------------------------------------------------------------
echo
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo
[[ $FAIL -gt 0 ]] && exit 1
exit 0
