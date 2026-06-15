#!/bin/bash
# test-conformance-runner.sh — unit tests for the standalone conformance runner
# (issue #230, INV-73).
#
# Covers:
#   - lib-conformance.sh pure helpers: _conf_field / _conf_expect_field,
#     _conf_project (the four-axis projection), _conf_axis_diff.
#   - run-conformance.sh integration (hermetic, stub-CLI): happy path, --adapter
#     / --mode filtering, expect-mismatch FAIL with axis diff, malformed-manifest
#     loud reject, hermeticity (PATH isolation; stdin-fed contract; stub records
#     argv/stdin), empty-set loud.
#
# Run: bash tests/unit/test-conformance-runner.sh
# Hermetic — no network, no credentials, no real CLIs.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONF_DIR="$PROJECT_ROOT/tests/conformance"
LIB="$CONF_DIR/lib-conformance.sh"
RUNNER="$CONF_DIR/run-conformance.sh"
FIXTURES="$CONF_DIR/fixtures"
CI="$PROJECT_ROOT/.github/workflows/ci.yml"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:400}'"
    FAIL=$((FAIL + 1))
  fi
}
assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

for f in "$LIB" "$RUNNER"; do
  [[ -f "$f" ]] || { echo -e "  ${RED}FAIL${NC}: $f not found"; echo "  FAIL: $((FAIL + 1))"; exit 1; }
done

# shellcheck source=../../tests/conformance/lib-conformance.sh
source "$LIB"

# ---------------------------------------------------------------------------
echo "=== TC-CONFORMANCE-00x: lib-conformance pure helpers ==="
# ---------------------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/m.json" <<'JSON'
{
  "schema_version": 1,
  "adapter": "codex",
  "mode": "review",
  "input": { "promptBytes": 4096, "model": "gpt-5-codex", "env": {} },
  "command": { "argv": ["codex","review","<prompt>"], "stdinSha256": "8d5f160c37601126891ca948763644da51003a074e073ed69458744398235155", "rc": 1, "stdout": "", "stderr": "stream error: Reconnecting..." },
  "expect": { "providerClass": "transient", "verdictState": "absent", "vote": "drop", "retryable": true }
}
JSON

# TC-CONFORMANCE-001 — top-level field extraction
assert_eq "TC-CONFORMANCE-001a _conf_field adapter" "codex" "$(_conf_field "$TMP/m.json" adapter)"
assert_eq "TC-CONFORMANCE-001b _conf_field mode" "review" "$(_conf_field "$TMP/m.json" mode)"
assert_eq "TC-CONFORMANCE-001c _conf_field command.rc (nested)" "1" "$(_conf_field "$TMP/m.json" command.rc)"
assert_eq "TC-CONFORMANCE-001d _conf_field missing → empty" "" "$(_conf_field "$TMP/m.json" nope)"

# TC-CONFORMANCE-002 — expect axis extraction
assert_eq "TC-CONFORMANCE-002a providerClass" "transient" "$(_conf_expect_field "$TMP/m.json" providerClass)"
assert_eq "TC-CONFORMANCE-002b vote" "drop" "$(_conf_expect_field "$TMP/m.json" vote)"
assert_eq "TC-CONFORMANCE-002c retryable" "true" "$(_conf_expect_field "$TMP/m.json" retryable)"

# TC-CONFORMANCE-003/004/005 — axis diff
assert_eq "TC-CONFORMANCE-003 identical tuples → empty diff" "" \
  "$(_conf_axis_diff "none|valid|pass|false" "none|valid|pass|false")"
assert_eq "TC-CONFORMANCE-004 one axis differs → names only that axis" \
  "vote: expected=pass actual=drop" \
  "$(_conf_axis_diff "none|valid|pass|false" "none|valid|drop|false")"
diff5="$(_conf_axis_diff "none|valid|pass|false" "quota|absent|drop|false")"
assert_contains "TC-CONFORMANCE-005a multi-diff names providerClass" "providerClass: expected=none actual=quota" "$diff5"
assert_contains "TC-CONFORMANCE-005b multi-diff names verdictState" "verdictState: expected=valid actual=absent" "$diff5"
assert_contains "TC-CONFORMANCE-005c multi-diff names vote" "vote: expected=pass actual=drop" "$diff5"

# TC-CONFORMANCE-006..012 — the projection (classifier output → four axes)
assert_eq "TC-CONFORMANCE-006 quota token → quota/absent/drop/false" \
  "quota|absent|drop|false" \
  "$(_conf_project agy review UNAVAILABLE "quota-exhausted:Resets in 33h48m45s" 0)"
assert_eq "TC-CONFORMANCE-007 stream-error → transient/absent/drop/TRUE" \
  "transient|absent|drop|true" \
  "$(_conf_project codex review UNAVAILABLE "stream-error:5/5" 1)"
assert_eq "TC-CONFORMANCE-008 config-error → config/absent/drop/false" \
  "config|absent|drop|false" \
  "$(_conf_project codex review FAIL "config-error:-s" 2)"
assert_eq "TC-CONFORMANCE-008b auth-failed → auth/absent/drop/false" \
  "auth|absent|drop|false" \
  "$(_conf_project kiro review FAIL "auth-failed" 1)"
assert_eq "TC-CONFORMANCE-009 PASS review → none/valid/pass/false" \
  "none|valid|pass|false" \
  "$(_conf_project claude review PASS "" 0)"
assert_eq "TC-CONFORMANCE-010 review no-verdict + rc124 → timeout-veto" \
  "none|absent|timeout-veto|false" \
  "$(_conf_project claude review FAIL "" 124)"
assert_eq "TC-CONFORMANCE-010b review no-verdict + rc137 → timeout-veto" \
  "none|absent|timeout-veto|false" \
  "$(_conf_project claude review FAIL "" 137)"
assert_eq "TC-CONFORMANCE-011 review no-verdict + rc0 → drop" \
  "none|absent|drop|false" \
  "$(_conf_project claude review FAIL "" 0)"
assert_eq "TC-CONFORMANCE-012a dev-new always not-applicable (even on PASS)" \
  "none|valid|not-applicable|false" \
  "$(_conf_project claude dev-new PASS "" 0)"
assert_eq "TC-CONFORMANCE-012b e2e-browser not-applicable" \
  "none|absent|not-applicable|false" \
  "$(_conf_project claude e2e-browser FAIL "" 0)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CONFORMANCE-02x: runner integration (hermetic, stub-CLI) ==="
# ---------------------------------------------------------------------------

# TC-CONFORMANCE-020 — happy path on the committed promoted fixture set.
full_out="$(env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"; full_rc=$?
assert_eq "TC-CONFORMANCE-020a full suite exits 0" "0" "$full_rc"
assert_contains "TC-CONFORMANCE-020b agy quota fixture PASS" \
  "CONFORMANCE agy/review/agy-quota-exhausted PASS" "$full_out"
# All-pass: every considered fixture PASSes (fail=0) and total==pass. Asserted on
# the summary shape rather than a pinned count so adding a fixture doesn't require
# touching this line — the count grows as the promoted set does.
conf_summary="$(printf '%s\n' "$full_out" | grep -oE 'CONFORMANCE-SUMMARY total=[0-9]+ pass=[0-9]+ fail=[0-9]+')"
conf_total="$(printf '%s' "$conf_summary" | sed -E 's/.*total=([0-9]+).*/\1/')"
conf_pass="$(printf '%s' "$conf_summary" | sed -E 's/.*pass=([0-9]+).*/\1/')"
if [[ "$conf_summary" == *"fail=0" && -n "$conf_total" && "$conf_total" == "$conf_pass" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-020c summary all-pass ($conf_summary)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-020c summary all-pass — got '$conf_summary'"; FAIL=$((FAIL + 1))
fi

# TC-CONFORMANCE-021 — --adapter filter
codex_out="$(env -u PROJECT_DIR bash "$RUNNER" --adapter codex 2>/dev/null)"
assert_contains "TC-CONFORMANCE-021a codex filter shows codex" "CONFORMANCE codex/review/codex-review-clean PASS" "$codex_out"
if [[ "$codex_out" == *"CONFORMANCE agy/"* || "$codex_out" == *"CONFORMANCE claude/"* ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-021b codex filter leaked a non-codex fixture"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-021b codex filter excludes non-codex"; PASS=$((PASS + 1))
fi

# TC-CONFORMANCE-022 — --mode filter
devnew_out="$(env -u PROJECT_DIR bash "$RUNNER" --mode dev-new 2>/dev/null)"
assert_contains "TC-CONFORMANCE-022a dev-new filter" "CONFORMANCE claude/dev-new/claude-dev-new PASS" "$devnew_out"
assert_contains "TC-CONFORMANCE-022b dev-new filter total=1" "CONFORMANCE-SUMMARY total=1" "$devnew_out"

# TC-CONFORMANCE-023 — expect-mismatch → FAIL with axis diff
MM=$(mktemp -d)
jq '.expect.vote="pass"' "$FIXTURES/agy-quota-exhausted.json" > "$MM/agy-flip.json"
mm_out="$(CONFORMANCE_FIXTURE_DIR="$MM" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"; mm_rc=$?
assert_contains "TC-CONFORMANCE-023a mismatch → FAIL + readable diff" \
  "FAIL vote: expected=pass actual=drop" "$mm_out"
assert_eq "TC-CONFORMANCE-023b mismatch → nonzero exit" "1" "$mm_rc"
rm -rf "$MM"

# TC-CONFORMANCE-024/025 — malformed manifest loud reject
BAD=$(mktemp -d)
jq 'del(.expect)' "$FIXTURES/claude-happy-path.json" > "$BAD/no-expect.json"
bad_out="$(CONFORMANCE_FIXTURE_DIR="$BAD" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"; bad_rc=$?
assert_contains "TC-CONFORMANCE-024a missing-expect → schema-invalid FAIL" "FAIL schema-invalid" "$bad_out"
assert_eq "TC-CONFORMANCE-024b malformed → nonzero exit" "1" "$bad_rc"
rm -f "$BAD/no-expect.json"
jq '.command.stdinSha256="not-a-real-sha"' "$FIXTURES/claude-happy-path.json" > "$BAD/bad-sha.json"
sha_out="$(CONFORMANCE_FIXTURE_DIR="$BAD" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"
assert_contains "TC-CONFORMANCE-025 bad stdinSha256 (not 64-hex) → schema-invalid" "FAIL schema-invalid" "$sha_out"
rm -f "$BAD/bad-sha.json"
# TC-CONFORMANCE-025b — unknown top-level key rejected by BOTH validators (the
# schema's `additionalProperties:false`). Pins that the jq fallback agrees with
# python jsonschema so a stray key FAILs on any fork, not only a jsonschema CI.
jq '.unexpectedTopLevelKey="surprise"' "$FIXTURES/claude-happy-path.json" > "$BAD/extra-key.json"
extra_out="$(CONFORMANCE_FIXTURE_DIR="$BAD" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"; extra_rc=$?
assert_contains "TC-CONFORMANCE-025b unknown top-level key → schema-invalid" "FAIL schema-invalid" "$extra_out"
assert_eq "TC-CONFORMANCE-025c unknown key → nonzero exit" "1" "$extra_rc"
# The jq fallback path MUST also reject it (force it by disabling jsonschema). The
# runner gates on `python3 -c 'import jsonschema'`; once that probe fails it sets
# _HAVE_PY_JSONSCHEMA=0 and NEVER calls python3 again on the validate path, so a
# PATH-shadow python3 that simply fails the import is sufficient to exercise the
# jq branch. (Stub binaries via PATH injection mirror the runner's own hermetic
# stub pattern.)
NOPY=$(mktemp -d)
cat > "$NOPY/python3" <<'PYSTUB'
#!/bin/bash
# Force the runner's jsonschema probe to fail → jq fallback. python3 is not
# invoked again on the validate path after the probe fails.
exit 1
PYSTUB
chmod +x "$NOPY/python3"
jqfb_out="$(CONFORMANCE_FIXTURE_DIR="$BAD" PATH="$NOPY:$PATH" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"
assert_contains "TC-CONFORMANCE-025d jq fallback also rejects unknown key" "FAIL schema-invalid" "$jqfb_out"

# TC-CONFORMANCE-025e..k — the jq fallback enforces the SAME nested required
# fields/types as fixture-manifest.schema.json (PR #244 [P1] #1). Before the fix
# the fallback only checked top-level objects + a few command/expect fields, so a
# manifest missing a schema-required NESTED field (e.g. input.promptBytes) PASSed
# under the fallback while python jsonschema would reject it. Each case below is
# run through the jq-fallback path (python3 shadowed → import fails) and MUST
# `FAIL schema-invalid`. These pin the fail-closed-on-the-same-malformed-manifest
# guarantee the finding requires.
jqfb_reject() { # <desc> <jq-mutation>
  local desc="$1" mut="$2" d out
  d=$(mktemp -d)
  jq "$mut" "$FIXTURES/agy-quota-exhausted.json" > "$d/x.json"   # has a files{} entry
  out="$(CONFORMANCE_FIXTURE_DIR="$d" PATH="$NOPY:$PATH" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"
  assert_contains "$desc" "FAIL schema-invalid" "$out"
  rm -rf "$d"
}
jqfb_reject "TC-CONFORMANCE-025e jq fallback rejects missing input.promptBytes" 'del(.input.promptBytes)'
jqfb_reject "TC-CONFORMANCE-025f jq fallback rejects missing input.model"       'del(.input.model)'
jqfb_reject "TC-CONFORMANCE-025g jq fallback rejects non-string input.env value" '.input.env.X = 5'
jqfb_reject "TC-CONFORMANCE-025h jq fallback rejects negative promptBytes"       '.input.promptBytes = -1'
jqfb_reject "TC-CONFORMANCE-025i jq fallback rejects unknown nested key (input.bogus)" '.input.bogus = "x"'
jqfb_reject "TC-CONFORMANCE-025j jq fallback rejects non-string argv element"    '.command.argv = ["agy",5]'
jqfb_reject "TC-CONFORMANCE-025k jq fallback rejects bad files.<k>.role enum"    '.files.agyLog.role = "bogus"'
# files:null — the schema's `type:object` rejects an explicit null; a bare
# `.files == null` jq check could not tell key-absent (valid) from present-null
# (invalid), so the validator uses `has("files")`. Pins the agreement.
jqfb_reject "TC-CONFORMANCE-025n jq fallback rejects an explicit files:null"     '.files = null'
# files.<k>.role / .sha256 are OPTIONAL but, WHEN PRESENT, must be strings — the
# Draft-07 schema has no "null" in their type. A bare `(.value.role == null) or …`
# check wrongly ACCEPTED an explicit `role: null` / `sha256: null` (PR #244 [P1]
# #2); the validator now uses `has("role")` / `has("sha256")` to distinguish
# absent (valid) from explicit-null (invalid). These pin that agreement.
jqfb_reject "TC-CONFORMANCE-025o jq fallback rejects explicit files.<k>.role:null"   '.files.agyLog.role = null'
jqfb_reject "TC-CONFORMANCE-025p jq fallback rejects explicit files.<k>.sha256:null" '.files.agyLog.sha256 = null'
jqfb_reject "TC-CONFORMANCE-025q jq fallback rejects non-string files.<k>.sha256"    '.files.agyLog.sha256 = 5'

# TC-CONFORMANCE-025l — the SAME valid fixture that the fallback rejects-when-broken
# must still PASS the fallback when well-formed (no false-positive reject from the
# tightened validator). Run the full promoted set through the jq fallback path.
fallback_full="$(PATH="$NOPY:$PATH" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"; fallback_rc=$?
assert_eq "TC-CONFORMANCE-025l jq fallback ACCEPTS the full valid promoted set (exit 0)" "0" "$fallback_rc"
assert_contains "TC-CONFORMANCE-025m jq fallback path still PASSes a valid fixture" \
  "CONFORMANCE agy/review/agy-quota-exhausted PASS" "$fallback_full"
rm -rf "$NOPY"
rm -rf "$BAD"

# TC-CONFORMANCE-026 — hermeticity: a fixture whose stub binary cannot be
# materialized fails loud (never reaches a real CLI). Simulate by pointing the
# stub-dir-bound write at a read-only location is brittle; instead assert the
# guard exists AND that an unknown adapter (no stub branch) still never resolves
# to a real CLI. We use the resolved-path guard: stage a fixture and confirm the
# runner's classification subshell asserts the stub is the resolution.
assert_grep "TC-CONFORMANCE-026a runner has a stub-missing loud-fail guard" \
  '__ERR__:stub-missing' "$RUNNER"
assert_grep "TC-CONFORMANCE-026b runner has a hermeticity-breach guard (resolved != stub)" \
  'hermeticity-breach' "$RUNNER"

# TC-CONFORMANCE-027 — stub records stdin (argv/stdin recording); the runner
# asserts the prompt reached the stub over the INV-34 channel.
assert_grep "TC-CONFORMANCE-027a stub records stdin to .stdin" \
  'cat > "\$stub_dir/.stdin"|\.stdin' "$RUNNER"
assert_grep "TC-CONFORMANCE-027b runner fails loud when stdin not fed" \
  'stdin-not-fed' "$RUNNER"

# TC-CONFORMANCE-028 — PATH is the stub sandbox only (real CLI shadowed). Prove
# by replicating the runner's isolated PATH and resolving a stubbed binary.
STUBP=$(mktemp -d); printf '#!/bin/bash\n' > "$STUBP/claude"; chmod +x "$STUBP/claude"
CU="$(dirname "$(command -v env)")"
resolved="$( PATH="$STUBP:$CU" bash -c 'command -v claude' )"
assert_eq "TC-CONFORMANCE-028 isolated PATH resolves claude to the stub, not a system CLI" \
  "$STUBP/claude" "$resolved"
rm -rf "$STUBP"

# TC-CONFORMANCE-029 — empty / no-match fixture set is loud (exit 2), not a pass.
EMPTY=$(mktemp -d)
empty_out="$(CONFORMANCE_FIXTURE_DIR="$EMPTY" env -u PROJECT_DIR bash "$RUNNER" 2>&1)"; empty_rc=$?
assert_eq "TC-CONFORMANCE-029a empty fixture dir → exit 2" "2" "$empty_rc"
assert_contains "TC-CONFORMANCE-029b empty fixture dir → loud FATAL" "no fixtures matched" "$empty_out"
rm -rf "$EMPTY"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CONFORMANCE-03x: command.argv / command.stdinSha256 are LOAD-BEARING (PR #244 [P1]) ==="
# ---------------------------------------------------------------------------
# The PR #244 [P1] finding: the runner used to invoke the stub argv-less and only
# check non-empty stdin, then classify canned stdout — so a fixture's
# `command.argv` set to garbage and `command.stdinSha256` set to an all-zero hash
# STILL reported PASS (the manifest fields were not load-bearing). The fix drives
# the REAL dispatch path (run_agent / resume_agent / _run_codex_review) with the
# stub on PATH; the stub records the argv it was launched with and the stdin it
# received, and the runner asserts BOTH against the manifest before classifying.
# These tests pin that the two fields now FAIL the fixture when corrupted — the
# exact regression scenario the reviewer described.

# TC-CONFORMANCE-030 — garbage command.argv → loud FAIL argv-mismatch (NOT a PASS).
LB=$(mktemp -d)
jq '.command.argv=["claude","GARBAGE","--nonsense"]' "$FIXTURES/claude-dev-new.json" > "$LB/argv-garbage.json"
argv_out="$(CONFORMANCE_FIXTURE_DIR="$LB" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"; argv_rc=$?
assert_contains "TC-CONFORMANCE-030a garbage argv → FAIL argv-mismatch" \
  "FAIL argv-mismatch" "$argv_out"
assert_eq "TC-CONFORMANCE-030b garbage argv → nonzero exit (not a silent PASS)" "1" "$argv_rc"
if [[ "$argv_out" == *"PASS"* ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-030c garbage argv must NOT report PASS"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-030c garbage argv reports no PASS"; PASS=$((PASS + 1))
fi
rm -rf "$LB"

# TC-CONFORMANCE-031 — a single dropped/altered flag in command.argv FAILs too
# (the assertion is per-element + length, not a coarse "is the binary right").
LB=$(mktemp -d)
# Drop the trailing `--output-format json` pair → length mismatch with the real argv.
jq '.command.argv=["claude","--session-id","<uuid>","--name","conformance","--permission-mode","<permission-mode>","--model","sonnet","-p"]' \
  "$FIXTURES/claude-dev-new.json" > "$LB/argv-short.json"
short_out="$(CONFORMANCE_FIXTURE_DIR="$LB" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"
assert_contains "TC-CONFORMANCE-031 dropped argv flag → FAIL argv-mismatch" \
  "FAIL argv-mismatch" "$short_out"
rm -rf "$LB"

# TC-CONFORMANCE-032 — corrupted command.stdinSha256 → loud FAIL stdin-sha-mismatch.
LB=$(mktemp -d)
jq '.command.stdinSha256="0000000000000000000000000000000000000000000000000000000000000000"' \
  "$FIXTURES/claude-dev-new.json" > "$LB/sha-zero.json"
sha_out="$(CONFORMANCE_FIXTURE_DIR="$LB" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"; sha_rc=$?
assert_contains "TC-CONFORMANCE-032a all-zero stdinSha256 → FAIL stdin-sha-mismatch" \
  "FAIL stdin-sha-mismatch" "$sha_out"
assert_eq "TC-CONFORMANCE-032b all-zero stdinSha256 → nonzero exit (not a silent PASS)" "1" "$sha_rc"
if [[ "$sha_out" == *"PASS"* ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-032c all-zero stdinSha256 must NOT report PASS"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-032c all-zero stdinSha256 reports no PASS"; PASS=$((PASS + 1))
fi
rm -rf "$LB"

# TC-CONFORMANCE-033 — a codex review fixture (prompt-in-argv) whose stdinSha256
# is flipped to a NON-empty hash FAILs: codex review carries the prompt as an argv
# positional, so the stub reads NO stdin → empty-string hash; a fixture claiming a
# stdin-fed hash there is a regression the assertion must catch.
LB=$(mktemp -d)
jq '.command.stdinSha256="d5c930c8f8082ce538446ac727a28c19d83bbdb927fae14e2a72af7444cfd25e"' \
  "$FIXTURES/codex-review-clean.json" > "$LB/codex-wrong-sha.json"
codex_sha_out="$(CONFORMANCE_FIXTURE_DIR="$LB" env -u PROJECT_DIR bash "$RUNNER" 2>/dev/null)"
assert_contains "TC-CONFORMANCE-033 codex review with a non-empty stdinSha256 → FAIL stdin-sha-mismatch" \
  "FAIL stdin-sha-mismatch" "$codex_sha_out"
rm -rf "$LB"

# TC-CONFORMANCE-034 — the runner drives the REAL invocation primitives (the
# structural guarantee behind argv/stdin being load-bearing): it calls run_agent
# and _run_codex_review, not a synthesized stub invocation.
assert_grep "TC-CONFORMANCE-034a runner drives run_agent (real dispatch path)" \
  'run_agent ' "$RUNNER"
assert_grep "TC-CONFORMANCE-034b runner drives _run_codex_review for codex review" \
  '_run_codex_review ' "$RUNNER"
assert_grep "TC-CONFORMANCE-034c stub records launched argv to .argv.json" \
  '\.argv\.json' "$RUNNER"
assert_grep "TC-CONFORMANCE-034d runner asserts command.argv (load-bearing)" \
  'argv-mismatch' "$RUNNER"
assert_grep "TC-CONFORMANCE-034e runner asserts command.stdinSha256 (load-bearing)" \
  'stdin-sha-mismatch' "$RUNNER"

# TC-CONFORMANCE-035 — ENV HERMETICITY (PR #244 [P1] #1): the classification must
# depend ONLY on the fixture's input.env, never on the operator's inherited
# environment. With operator-facing vars set in the CALLER's env
# (AGENT_DEV_EXTRA_ARGS / AGENT_REVIEW_EXTRA_ARGS / AGENT_LAUNCHER / *_LAUNCHER /
# AUTONOMOUS_CONF), an empty-env fixture must STILL pass — the runner scrubs them
# to a baseline before sourcing lib-agent.sh. Before the fix, an inherited
# AGENT_DEV_EXTRA_ARGS appended extra argv → argv-mismatch (and a launcher routed
# the dispatch off the isolated PATH → stdin-not-fed). These run the REAL promoted
# set with the leak vars exported, so they exercise the scrub end-to-end.
env_leak_out="$(AGENT_DEV_EXTRA_ARGS='--bogus' env -u PROJECT_DIR bash "$RUNNER" --adapter claude --mode dev-new 2>/dev/null)"
assert_contains "TC-CONFORMANCE-035a inherited AGENT_DEV_EXTRA_ARGS does NOT leak (claude dev-new still PASS)" \
  "CONFORMANCE claude/dev-new/claude-dev-new PASS" "$env_leak_out"
launcher_leak_out="$(AGENT_LAUNCHER='cc' env -u PROJECT_DIR bash "$RUNNER" --adapter kiro 2>/dev/null)"
assert_contains "TC-CONFORMANCE-035b inherited AGENT_LAUNCHER does NOT route off the stub PATH (kiro still PASS)" \
  "CONFORMANCE kiro/review/kiro-happy-path PASS" "$launcher_leak_out"
# The heaviest case: ALL operator vars set at once → the full promoted run must
# stay all-PASS (exit 0), identical to a clean environment.
heavy_leak_rc=0
AGENT_DEV_EXTRA_ARGS='--x' AGENT_REVIEW_EXTRA_ARGS='--y' AGENT_LAUNCHER='cc' \
  AGENT_DEV_LAUNCHER='cc' AGENT_REVIEW_LAUNCHER='cc' AUTONOMOUS_CONF='/tmp/nonexistent-conformance.conf' \
  env -u PROJECT_DIR bash "$RUNNER" >/dev/null 2>&1 || heavy_leak_rc=$?
assert_eq "TC-CONFORMANCE-035c full run is env-hermetic under a heavy operator-var leak (exit 0)" "0" "$heavy_leak_rc"
# A fixture that GENUINELY wants an operator var still gets it via input.env (the
# scrub runs BEFORE the input.env apply), so codex-cli-error's -s flag survives.
assert_contains "TC-CONFORMANCE-035d input.env still re-enables a var after the scrub (codex-cli-error PASS)" \
  "CONFORMANCE codex/review/codex-cli-error PASS" "$full_out"
# Source-of-truth: the runner scrubs the operator surface BEFORE sourcing the lib.
assert_grep "TC-CONFORMANCE-035e runner zeroes operator AGENT_*_EXTRA_ARGS/LAUNCHER to a baseline" \
  'AGENT_DEV_EXTRA_ARGS=""' "$RUNNER"

# TC-CONFORMANCE-035f..h — CONF-DISCOVERY HERMETICITY (PR #244 [P1], codex review
# dc696d40): scrubbing AUTONOMOUS_CONF alone is NOT enough. lib-agent.sh's
# load_autonomous_conf has THREE discovery branches — AUTONOMOUS_CONF (file),
# then AUTONOMOUS_CONF_DIR/autonomous.conf, then PROJECT_DIR/scripts/autonomous.conf
# — all read at SOURCE time. A caller with AUTONOMOUS_CONF_DIR (or PROJECT_DIR)
# pointing at a real project conf containing AGENT_DEV_EXTRA_ARGS='--bogus' would
# still splice --bogus into an empty-env fixture's argv → argv-mismatch. The runner
# must scrub BOTH AUTONOMOUS_CONF_DIR and PROJECT_DIR inside the classification
# subshell (NOT rely on the caller's `env -u PROJECT_DIR`). These deliberately do
# NOT pass `env -u PROJECT_DIR` and DO point the conf-discovery vars at a poisoned
# conf, so they exercise the in-runner scrub end-to-end (they FAIL pre-fix).
POISON_CONF_DIR="$(mktemp -d)"
# A PROJECT_DIR-shaped tree: <root>/scripts/autonomous.conf (branch 3).
POISON_PROJECT_DIR="$(mktemp -d)"
# Re-register the EXIT trap to clean ALL temp dirs. `trap … EXIT` REPLACES (not
# appends), so this must restate the line-72 `$TMP` cleanup or it would leak.
trap 'rm -rf "$TMP" "$POISON_CONF_DIR" "$POISON_PROJECT_DIR"' EXIT
cat > "$POISON_CONF_DIR/autonomous.conf" <<'CONF'
# Poisoned operator conf — must NEVER influence a conformance run.
AGENT_DEV_EXTRA_ARGS='--bogus'
AGENT_REVIEW_EXTRA_ARGS='--bogus'
CONF
mkdir -p "$POISON_PROJECT_DIR/scripts"
cp "$POISON_CONF_DIR/autonomous.conf" "$POISON_PROJECT_DIR/scripts/autonomous.conf"

# 035f — AUTONOMOUS_CONF_DIR leak (branch 2). NOTE: no `env -u PROJECT_DIR`.
confdir_leak_out="$(AUTONOMOUS_CONF_DIR="$POISON_CONF_DIR" bash "$RUNNER" --adapter claude --mode dev-new 2>/dev/null)"
assert_contains "TC-CONFORMANCE-035f inherited AUTONOMOUS_CONF_DIR conf does NOT leak (claude dev-new still PASS)" \
  "CONFORMANCE claude/dev-new/claude-dev-new PASS" "$confdir_leak_out"
# 035g — PROJECT_DIR leak (branch 3). NOTE: no `env -u PROJECT_DIR` — the runner
# itself must neutralize it.
projdir_leak_out="$(PROJECT_DIR="$POISON_PROJECT_DIR" bash "$RUNNER" --adapter claude --mode dev-new 2>/dev/null)"
assert_contains "TC-CONFORMANCE-035g inherited PROJECT_DIR conf does NOT leak (claude dev-new still PASS)" \
  "CONFORMANCE claude/dev-new/claude-dev-new PASS" "$projdir_leak_out"
# 035h — the heaviest conf-discovery leak: BOTH conf-discovery vars poisoned, no
# `env -u PROJECT_DIR` → the full promoted run must stay all-PASS (exit 0).
confdisc_heavy_rc=0
AUTONOMOUS_CONF_DIR="$POISON_CONF_DIR" PROJECT_DIR="$POISON_PROJECT_DIR" \
  bash "$RUNNER" >/dev/null 2>&1 || confdisc_heavy_rc=$?
assert_eq "TC-CONFORMANCE-035h full run is conf-discovery-hermetic under poisoned CONF_DIR+PROJECT_DIR (exit 0)" "0" "$confdisc_heavy_rc"
# Source-of-truth: the runner points ALL THREE conf-discovery vars at the
# conf-free $no_conf_dir (NOT empty string — `""` would let the
# `${AUTONOMOUS_CONF_DIR:-$_LIB_AGENT_DIR}` default leak; see the runner comment).
# Grep the actual export lines (435-437), not the explanatory comment, so the
# assertion fails if any of the three scrubs is removed.
assert_grep "TC-CONFORMANCE-035i runner points AUTONOMOUS_CONF at a conf-free path" \
  'export AUTONOMOUS_CONF="\$no_conf_dir/' "$RUNNER"
assert_grep "TC-CONFORMANCE-035j runner points AUTONOMOUS_CONF_DIR at the conf-free dir" \
  'export AUTONOMOUS_CONF_DIR="\$no_conf_dir"' "$RUNNER"
assert_grep "TC-CONFORMANCE-035k runner points PROJECT_DIR at the conf-free dir" \
  'export PROJECT_DIR="\$no_conf_dir"' "$RUNNER"

# TC-CONFORMANCE-035l..o — REMAINING argv/LAUNCH KNOBS (PR #244 [P1], codex review
# fff5f671): lib-agent.sh reads more operator knobs at source time than the
# EXTRA_ARGS / launcher / conf surface. Two reach argv/launch and break an
# empty-env fixture when inherited: KIRO_AGENT_NAME (spliced into kiro argv as
# `--agent <name>` → argv-mismatch) and AGENT_TIMEOUT (the `timeout(1)` duration;
# a bogus value makes the launch never run → stdin-not-fed). The runner now resets
# both (+ AGENT_PERMISSION_MODE, defense-in-depth) to the lib defaults BEFORE
# sourcing. These supply a poisoned value WITHOUT `env -u`-ing it, so they exercise
# the in-runner reset end-to-end (035l/m proven to FAIL pre-fix).
kironame_leak_out="$(KIRO_AGENT_NAME='other' env -u PROJECT_DIR bash "$RUNNER" --adapter kiro 2>/dev/null)"
assert_contains "TC-CONFORMANCE-035l inherited KIRO_AGENT_NAME does NOT leak into kiro argv (still PASS)" \
  "CONFORMANCE kiro/review/kiro-happy-path PASS" "$kironame_leak_out"
timeout_leak_rc=0
AGENT_TIMEOUT='bogus' env -u PROJECT_DIR bash "$RUNNER" --adapter agy >/dev/null 2>&1 || timeout_leak_rc=$?
assert_eq "TC-CONFORMANCE-035m inherited AGENT_TIMEOUT=bogus does NOT break the launch (agy still exit 0)" "0" "$timeout_leak_rc"
# Heaviest: all the newly-reset knobs poisoned at once → full run stays all-PASS.
knob_heavy_rc=0
KIRO_AGENT_NAME='other' AGENT_TIMEOUT='bogus' AGENT_PERMISSION_MODE='plan' \
  env -u PROJECT_DIR bash "$RUNNER" >/dev/null 2>&1 || knob_heavy_rc=$?
assert_eq "TC-CONFORMANCE-035n full run is hermetic under a heavy argv/launch-knob leak (exit 0)" "0" "$knob_heavy_rc"
# Source-of-truth: the runner resets the knobs to the lib defaults.
assert_grep "TC-CONFORMANCE-035o runner resets KIRO_AGENT_NAME + AGENT_TIMEOUT to lib defaults" \
  'export KIRO_AGENT_NAME="autonomous-dev"' "$RUNNER"

# TC-CONFORMANCE-036 — CODEX DROP-REASON IS rc-GATED (PR #244 [P1], codex review
# fff5f671): the runner must pass the fixture's launch rc into
# _classify_codex_drop_reason, which gates the config-error bucket on rc == 2
# (clap's parse-error exit). A transient codex fixture (rc 1) whose capture merely
# QUOTES a clap line must fall through to stream-error (transient), NOT be
# mislabeled config — matching production (autonomous-review.sh passes the rc).
assert_grep "TC-CONFORMANCE-036a runner passes \$rc into _classify_codex_drop_reason" \
  '_classify_codex_drop_reason "\$scan_file" "\$rc"' "$RUNNER"
# The promoted regression fixture: rc 1 + quoted clap line ⇒ transient (NOT config).
qclap_out="$(env -u PROJECT_DIR bash "$RUNNER" --adapter codex 2>/dev/null)"
assert_contains "TC-CONFORMANCE-036b codex rc1 quoted-clap fixture classifies transient (PASS, not config)" \
  "CONFORMANCE codex/review/codex-quoted-clap-nonconfig PASS" "$qclap_out"
# Load-bearing proof: WITHOUT the rc the classifier returns config-error; WITH rc 1
# it returns stream-error. Source the classifier and assert the gate directly.
qclap_scan="$(mktemp)"
jq -r '.command.stderr' "$FIXTURES/codex-quoted-clap-nonconfig.json" > "$qclap_scan"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-codex.sh
source "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-codex.sh" 2>/dev/null
assert_eq "TC-CONFORMANCE-036c classifier WITHOUT rc mislabels config (pre-fix behavior)" \
  "config-error:-s" "$(_classify_codex_drop_reason "$qclap_scan")"
assert_contains "TC-CONFORMANCE-036d classifier WITH rc 1 falls through to stream-error (the fix)" \
  "stream-error" "$(_classify_codex_drop_reason "$qclap_scan" 1)"
rm -f "$qclap_scan"

# TC-CONFORMANCE-037 — CODEX STUB DOES NOT HANG ON A NON-EOF STDIN (PR #244 [P1],
# codex review 1c29ba19): the hermetic stub unconditionally `cat > .stdin` to
# record the [INV-34] channel, but the codex review path carries the prompt as an
# argv positional and pipes no stdin. On a CI runner stdin is already EOF so `cat`
# returns instantly; from a local TTY the codex stub would block forever (rc 124).
# The runner now feeds the codex dispatch `</dev/null`. Drive the REAL codex run
# with a NON-EOF stdin (a fifo with an open writer feeding no data — a TTY proxy):
# pre-fix this hangs to the `timeout`; post-fix it returns rc 0 because the codex
# dispatch's own `</dev/null` shields the stub regardless of the runner's stdin.
# Scope to a SINGLE transient codex fixture (rc 1 → exercises the re-run loop, the
# exact path where the stub-stdin block manifests) so the test is fast + has a wide
# timeout margin — running the full --adapter codex set (5 fixtures, 3 with re-run
# loops) risked a flaky 124 under CI load (reviewer note).
CDX1=$(mktemp -d)
cp "$FIXTURES/codex-stream-error.json" "$CDX1/codex-stream-error.json"
hang_fifo="$(mktemp -u)"; mkfifo "$hang_fifo"
sleep 60 > "$hang_fifo" &  # open writer, no data → readers block (TTY proxy)
hang_writer=$!
hang_rc=0
timeout 60s env -u PROJECT_DIR CONFORMANCE_FIXTURE_DIR="$CDX1" bash "$RUNNER" --adapter codex < "$hang_fifo" >/dev/null 2>&1 || hang_rc=$?
kill "$hang_writer" 2>/dev/null || true
rm -f "$hang_fifo"
assert_eq "TC-CONFORMANCE-037a codex stub does NOT hang on a non-EOF (TTY-proxy) stdin (exit 0, not 124)" "0" "$hang_rc"
# Source-of-truth: the codex review dispatch redirects /dev/null on stdin.
assert_grep "TC-CONFORMANCE-037b runner feeds /dev/null to the codex review dispatch" \
  '_run_codex_review .* </dev/null' "$RUNNER"

# TC-CONFORMANCE-038 — CODEX REVIEW CONTROL ENV IS RESET (PR #244 [P1], codex
# review 1c29ba19): `_run_codex_review` reads CODEX_REVIEW_MAX_RERUNS (default 3)
# and AGENT_REVIEW_TIMEOUT (default 1h) at CALL time, so an inherited value
# changes a codex fixture's runtime despite being absent from input.env. An
# inherited `CODEX_REVIEW_MAX_RERUNS=100000` makes a transient (rc≠0) fixture
# re-run 100000× → hang. The runner resets both to lib defaults before input.env.
# Supply the poisoned value WITHOUT putting it in any fixture → the run must stay
# deterministic (exit 0), not blow the timeout. Proven to time out (124) pre-fix.
# Same single-fixture scoping as 037 for a wide timeout margin under CI load.
maxreruns_rc=0
timeout 60s env -u PROJECT_DIR CONFORMANCE_FIXTURE_DIR="$CDX1" CODEX_REVIEW_MAX_RERUNS=100000 bash "$RUNNER" --adapter codex </dev/null >/dev/null 2>&1 || maxreruns_rc=$?
rm -rf "$CDX1"
assert_eq "TC-CONFORMANCE-038a inherited CODEX_REVIEW_MAX_RERUNS does NOT leak into the codex run (exit 0, not 124)" "0" "$maxreruns_rc"
# Source-of-truth: the runner resets the codex review controls.
assert_grep "TC-CONFORMANCE-038b runner resets CODEX_REVIEW_MAX_RERUNS + AGENT_REVIEW_TIMEOUT to defaults" \
  'export CODEX_REVIEW_MAX_RERUNS="3"' "$RUNNER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CONFORMANCE-04x: promoted-fixture coverage (the E2E tier) ==="
# ---------------------------------------------------------------------------
# TC-CONFORMANCE-041 — the two load-bearing rc mappings are pinned as PROMOTED
# fixtures (PR #244 [P1] #2): BOTH `124/137 + no verdict ⇒ timeout-veto` AND
# `0 + no provider + no verdict ⇒ drop` must exist as fixtures the full
# conformance run exercises, so a regression in EITHER mapping is caught — not
# just an assertion on a single rc-124 fixture's JSON.

# rc 124 ⇒ timeout-veto (the original).
assert_grep "TC-CONFORMANCE-041a timeout-veto fixture (rc 124 ⇒ timeout-veto)" \
  '"vote": *"timeout-veto"' "$FIXTURES/claude-timeout-veto.json"
assert_grep "TC-CONFORMANCE-041b timeout-veto fixture has rc 124" \
  '"rc": *124' "$FIXTURES/claude-timeout-veto.json"
assert_contains "TC-CONFORMANCE-041c rc124 timeout-veto fixture passes the full run" \
  "CONFORMANCE claude/review/claude-timeout-veto PASS" "$full_out"

# rc 137 ⇒ timeout-veto (the SIGKILL half — was unpinned before #244 [P1] #2).
assert_grep "TC-CONFORMANCE-041d rc137 timeout-veto fixture exists" \
  '"rc": *137' "$FIXTURES/claude-timeout-veto-sigkill.json"
if [[ "$(jq -r '.command.rc' "$FIXTURES/claude-timeout-veto-sigkill.json")" == "137" \
   && "$(jq -r '.expect.vote' "$FIXTURES/claude-timeout-veto-sigkill.json")" == "timeout-veto" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-041e rc137 fixture maps to timeout-veto"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-041e rc137 fixture must map rc 137 → timeout-veto"; FAIL=$((FAIL + 1))
fi
assert_contains "TC-CONFORMANCE-041f rc137 timeout-veto fixture passes the full run" \
  "CONFORMANCE claude/review/claude-timeout-veto-sigkill PASS" "$full_out"

# rc 0 + no provider + no verdict ⇒ drop (was unpinned before #244 [P1] #2).
if [[ "$(jq -r '.command.rc' "$FIXTURES/claude-rc0-noverdict-drop.json")" == "0" \
   && "$(jq -r '.expect.providerClass' "$FIXTURES/claude-rc0-noverdict-drop.json")" == "none" \
   && "$(jq -r '.expect.verdictState' "$FIXTURES/claude-rc0-noverdict-drop.json")" == "absent" \
   && "$(jq -r '.expect.vote' "$FIXTURES/claude-rc0-noverdict-drop.json")" == "drop" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-041g rc0 fixture maps to none/absent/drop (no-verdict drop)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-041g rc0 fixture must map rc 0 + no provider + no verdict → drop"; FAIL=$((FAIL + 1))
fi
# The rc0-drop fixture's stdout must NOT echo the nonce placeholder (else it would
# classify PASS instead of exercising the no-verdict drop path).
if [[ "$(jq -r '.command.stdout' "$FIXTURES/claude-rc0-noverdict-drop.json")" != *"<NONCE>"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-041h rc0-drop fixture stdout carries no <NONCE> (verdict genuinely absent)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-041h rc0-drop fixture must not echo the nonce"; FAIL=$((FAIL + 1))
fi
assert_contains "TC-CONFORMANCE-041i rc0 no-verdict drop fixture passes the full run" \
  "CONFORMANCE claude/review/claude-rc0-noverdict-drop PASS" "$full_out"

# TC-CONFORMANCE-042 — ≥2 manifests per fan-out CLI.
for a in claude codex kiro agy; do
  n=0
  for f in "$FIXTURES"/*.json; do [[ "$(jq -r .adapter "$f")" == "$a" ]] && n=$((n+1)); done
  if [[ "$n" -ge 2 ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-042 $a has $n manifests (>=2)"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-042 $a has only $n manifests (<2)"; FAIL=$((FAIL + 1))
  fi
done

# TC-CONFORMANCE-040 — the codex transient retryable=true mapping (the one
# fixture where retryable diverges from false) round-trips green.
assert_contains "TC-CONFORMANCE-040 codex stream-error fixture passes (transient/retryable)" \
  "CONFORMANCE codex/review/codex-stream-error PASS" "$full_out"

# TC-CONFORMANCE-045 — combined-stream fidelity. The runner must recover the
# per-CLI provider token off the SAME combined stdout+stderr view the production
# _smoke_classify uses (lib-agent-smoke.sh:296-310), not stderr only. This fixture
# carries the codex stream-error ladder on STDOUT with EMPTY stderr; an err-only
# recovery would yield provider=none/retryable=false and FAIL it, while the
# production classifier (combined view) yields transient/true. Pins INV-73's
# "drives TODAY's classifier, not a narrower copy" promise.
assert_contains "TC-CONFORMANCE-045 codex stream-error-on-stdout passes (combined-stream fidelity)" \
  "CONFORMANCE codex/review/codex-stream-error-stdout PASS" "$full_out"
# The fixture must actually put the signal on stdout with empty stderr — else it
# would not exercise the combined-view path the test is meant to pin.
if [[ "$(jq -r '.command.stderr' "$FIXTURES/codex-stream-error-stdout.json")" == "" \
   && "$(jq -r '.command.stdout' "$FIXTURES/codex-stream-error-stdout.json")" == *"Reconnecting"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-045b stdout-stream fixture has the ladder on stdout, empty stderr"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-045b stdout-stream fixture stream-placement wrong"; FAIL=$((FAIL + 1))
fi

# TC-CONFORMANCE-044 — agy auth-only log path (no quota signal) classifies
# `auth/absent/drop/false`, distinct from the quota fixture whose log carries
# BOTH 429 and 401 yet must classify `quota` (quota takes precedence in
# _classify_agy_drop_reason). The auth-only fixture pins the precedence boundary:
# the auth branch is only ever reached when the quota signal is absent.
assert_contains "TC-CONFORMANCE-044a agy auth-failed fixture passes (auth/absent/drop/false)" \
  "CONFORMANCE agy/review/agy-auth-failed PASS" "$full_out"
# The auth-only log must NOT contain a quota marker (else it would classify
# quota, not auth — the boundary the fixture is supposed to pin).
if grep -qF 'RESOURCE_EXHAUSTED' "$FIXTURES/files/agy-auth-log.fixture" 2>/dev/null \
   || grep -qF 'Individual quota reached' "$FIXTURES/files/agy-auth-log.fixture" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-044b agy auth-only log leaked a quota marker"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-044b agy auth-only log carries no quota marker"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CONFORMANCE-05x: wiring / regression ==="
# ---------------------------------------------------------------------------
# TC-CONFORMANCE-050 — parse + (best-effort) shellcheck.
if bash -n "$RUNNER" 2>/dev/null; then echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-050a runner parses"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-050a runner parse"; FAIL=$((FAIL+1)); fi
if bash -n "$LIB" 2>/dev/null; then echo -e "  ${GREEN}PASS${NC}: TC-CONFORMANCE-050b lib parses"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC}: TC-CONFORMANCE-050b lib parse"; FAIL=$((FAIL+1)); fi

# TC-CONFORMANCE-051 — CI wires the conformance runner as an always-on step.
assert_grep "TC-CONFORMANCE-051 CI invokes run-conformance.sh" \
  'run-conformance\.sh' "$CI"

# TC-CONFORMANCE-052 — the runner drives the REAL classifier (not a re-impl).
assert_grep "TC-CONFORMANCE-052a runner sources lib-agent-smoke.sh" \
  'lib-agent-smoke\.sh' "$RUNNER"
assert_grep "TC-CONFORMANCE-052b runner calls _smoke_classify" \
  '_smoke_classify' "$RUNNER"

# TC-CONFORMANCE-053 — INV-73 exists; adapter-spec cross-links the runner.
assert_grep "TC-CONFORMANCE-053a INV-73 added to invariants.md" \
  '^## INV-73' "$INVARIANTS"
assert_grep "TC-CONFORMANCE-053b ShellCheck job includes the runner" \
  'run-conformance\.sh' "$CI"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
