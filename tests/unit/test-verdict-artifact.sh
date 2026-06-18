#!/bin/bash
# test-verdict-artifact.sh — issue #233 / INV-78.
#
# The verdict-artifact channel: review agents write a schema-validated verdict
# JSON file (the #229 verdict-artifact.schema.json) to a per-agent path the
# wrapper provisions; the wrapper reads + validates the artifact FIRST and only
# falls back to comment scraping (with a logged verdict-source=comment-fallback
# marker) when no artifact landed.
#
# Two pronged (the wrapper is too heavy to run end-to-end):
#   1. Pure-lib harness: source lib-review-artifact.sh and drive the classifier /
#      path provisioner / verdict mapper / schema-error helper over fixtures.
#   2. Source-of-truth greps against autonomous-review.sh: assert the wiring the
#      design requires (provision the path, inject it into the prompt, consume
#      artifacts first with the logged fallback marker, malformed → loud envelope,
#      treated-as-absent for the vote) without executing the wrapper.
#
# Backend: _classify_verdict_artifact mirrors test-adapter-spec-schemas.sh —
# prefer `python3 -m jsonschema` (full Draft-07), fall back to a jq structural
# check — so this suite runs on bare CI either way.
#
# Run: bash tests/unit/test-verdict-artifact.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISP="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
WRAPPER="$DISP/autonomous-review.sh"
ART_LIB="$DISP/lib-review-artifact.sh"
SCHEMA="$PROJECT_ROOT/docs/pipeline/schemas/verdict-artifact.schema.json"
EXAMPLES="$PROJECT_ROOT/docs/pipeline/schemas/examples"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_nonempty() {
  local desc="$1" actual="$2"
  if [[ -n "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (empty)"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Part 1: pure-lib classification / path / mapping
# ---------------------------------------------------------------------------
if [[ ! -f "$ART_LIB" ]]; then
  echo -e "  ${RED}FAIL${NC}: lib-review-artifact.sh not found at $ART_LIB"
  echo "=== Summary ==="; echo "  PASS: $PASS"; echo "  FAIL: $((FAIL + 1))"
  exit 1
fi
# shellcheck source=/dev/null
VERDICT_ARTIFACT_SCHEMA="$SCHEMA"
export VERDICT_ARTIFACT_SCHEMA
source "$ART_LIB"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# state = first line of _classify_verdict_artifact output
state_of() { _classify_verdict_artifact "$1" | head -n1; }

# TC-001 / TC-002 — valid PASS / FAIL goldens
assert_eq "TC-VERDICT-ARTIFACT-001 valid PASS golden → state valid" \
  "valid" "$(state_of "$EXAMPLES/verdict-artifact.golden.pass.json")"
assert_eq "TC-VERDICT-ARTIFACT-002 valid FAIL golden → state valid" \
  "valid" "$(state_of "$EXAMPLES/verdict-artifact.golden.fail.json")"

# TC-003 — absent file
assert_eq "TC-VERDICT-ARTIFACT-003 nonexistent path → state absent" \
  "absent" "$(state_of "$TMP/does-not-exist.json")"

# TC-004/005/006 — malformed negative fixtures
assert_eq "TC-VERDICT-ARTIFACT-004 no schema_version → malformed" \
  "malformed" "$(state_of "$EXAMPLES/verdict-artifact.negative.no-schema-version.json")"
assert_eq "TC-VERDICT-ARTIFACT-005 FAIL with empty blockingFindings → malformed" \
  "malformed" "$(state_of "$EXAMPLES/verdict-artifact.negative.fail-no-blocking.json")"
assert_eq "TC-VERDICT-ARTIFACT-006 blocking findings but verdict PASS → malformed" \
  "malformed" "$(state_of "$EXAMPLES/verdict-artifact.negative.blocking-but-pass.json")"

# TC-007 — non-JSON garbage
printf 'this is not json {{{' > "$TMP/garbage.json"
assert_eq "TC-VERDICT-ARTIFACT-007 garbage bytes → malformed" \
  "malformed" "$(state_of "$TMP/garbage.json")"

# TC-008 — empty file
: > "$TMP/empty.json"
assert_eq "TC-VERDICT-ARTIFACT-008 empty file → malformed" \
  "malformed" "$(state_of "$TMP/empty.json")"

# TC-009 — verdict mapping PASS→pass, FAIL→fail
assert_eq "TC-VERDICT-ARTIFACT-009a _verdict_from_artifact_json PASS→pass" \
  "pass" "$(_verdict_from_artifact_json "$(cat "$EXAMPLES/verdict-artifact.golden.pass.json")")"
assert_eq "TC-VERDICT-ARTIFACT-009b _verdict_from_artifact_json FAIL→fail" \
  "fail" "$(_verdict_from_artifact_json "$(cat "$EXAMPLES/verdict-artifact.golden.fail.json")")"

# TC-010 — schema-error helper echoes a non-empty one-line reason for malformed
assert_nonempty "TC-VERDICT-ARTIFACT-010 _artifact_schema_error non-empty for malformed" \
  "$(_artifact_schema_error "$EXAMPLES/verdict-artifact.negative.no-schema-version.json")"

# TC-011/012/013 — path provisioning
assert_eq "TC-VERDICT-ARTIFACT-011 path honors XDG_STATE_HOME" \
  "/xdg/state/autonomous-proj/runs/RID-1/verdict-codex.json" \
  "$(XDG_STATE_HOME=/xdg/state _verdict_artifact_path proj RID-1 codex)"
assert_eq "TC-VERDICT-ARTIFACT-012 path falls back to HOME/.local/state" \
  "/home/u/.local/state/autonomous-proj/runs/RID-1/verdict-agy.json" \
  "$(unset XDG_STATE_HOME; HOME=/home/u _verdict_artifact_path proj RID-1 agy)"
# Provisioner + reader agree: the same helper is the single source of truth.
P1="$(XDG_STATE_HOME=/x _verdict_artifact_path p r claude)"
P2="$(XDG_STATE_HOME=/x _verdict_artifact_path p r claude)"
assert_eq "TC-VERDICT-ARTIFACT-013 path helper is deterministic (no divergence)" "$P1" "$P2"

# TC-014 — only .tmp exists (rename not done) → final absent
cp "$EXAMPLES/verdict-artifact.golden.pass.json" "$TMP/verdict-x.json.tmp.123"
assert_eq "TC-VERDICT-ARTIFACT-014 only .tmp present, final missing → absent" \
  "absent" "$(state_of "$TMP/verdict-x.json")"

# TC-015 — read once: late write with a different verdict is ignored by a held snapshot.
# The classifier reads once and emits the snapshot; a caller that captured the
# state does not re-read. Model the contract: classify, capture, then mutate, and
# assert the captured value is stable (the lib does not re-stat).
cp "$EXAMPLES/verdict-artifact.golden.pass.json" "$TMP/verdict-late.json"
FIRST="$(state_of "$TMP/verdict-late.json")"
FIRST_V="$(_verdict_from_artifact_json "$(_classify_verdict_artifact "$TMP/verdict-late.json" | tail -n +2)")"
cp "$EXAMPLES/verdict-artifact.golden.fail.json" "$TMP/verdict-late.json"  # late write flips it
assert_eq "TC-VERDICT-ARTIFACT-015a first read state captured (valid)" "valid" "$FIRST"
assert_eq "TC-VERDICT-ARTIFACT-015b first read verdict captured (pass) — late write not retroactively applied" \
  "pass" "$FIRST_V"

# TC-038 — TRUE read-once: validation must derive from the SAME snapshot the
# state/verdict are read from ([P1] #1). Previously the classifier cat'd the bytes
# into _bytes but then validated $_path (a second disk read), so a rename landing
# between those two reads could flip valid↔malformed. We can't deterministically
# win that race in a test, but we CAN pin the structural guarantee: a single
# _classify_verdict_artifact call must NOT read the path more than once. Use a
# `cat` shim that counts reads of the target file.
_READ_COUNT_FILE="$TMP/read-count"
: > "$_READ_COUNT_FILE"
# Re-source the lib in a subshell with `cat` shimmed to tally reads of the artifact.
read_count_for() {
  local _f="$1"
  ( : > "$_READ_COUNT_FILE"
    cat() {
      local a; for a in "$@"; do
        [[ "$a" == "$_f" ]] && echo r >> "$_READ_COUNT_FILE"
      done
      command cat "$@"
    }
    export -f cat 2>/dev/null || true
    _classify_verdict_artifact "$_f" >/dev/null 2>&1
    wc -l < "$_READ_COUNT_FILE" | tr -d ' '
  )
}
cp "$EXAMPLES/verdict-artifact.golden.pass.json" "$TMP/verdict-once.json"
_READS=$(read_count_for "$TMP/verdict-once.json")
assert_eq "TC-VERDICT-ARTIFACT-038 classifier reads the artifact path exactly ONCE (true snapshot, [P1]#1)" \
  "1" "$_READS"

# TC-039 — identity binding ([P1] #2): a schema-valid artifact whose runId/agent do
# NOT match the wrapper-assigned session/agent MUST be rejected (malformed), so a
# buggy adapter copying example JSON or another agent's identifiers cannot cast a
# vote for this review slot. _classify_verdict_artifact takes optional
# <expected-run-id> <expected-agent>; when supplied, a mismatch → malformed.
# golden.pass has runId=01c9c077-… agent=claude.
GP="$EXAMPLES/verdict-artifact.golden.pass.json"
assert_eq "TC-VERDICT-ARTIFACT-039a matching runId+agent → valid" \
  "valid" "$(_classify_verdict_artifact "$GP" "01c9c077-febc-4cf3-a716-ee66ae584135" claude | head -n1)"
assert_eq "TC-VERDICT-ARTIFACT-039b mismatched runId → malformed (foreign session)" \
  "malformed" "$(_classify_verdict_artifact "$GP" "different-session-uuid" claude | head -n1)"
assert_eq "TC-VERDICT-ARTIFACT-039c mismatched agent → malformed (foreign agent identifiers)" \
  "malformed" "$(_classify_verdict_artifact "$GP" "01c9c077-febc-4cf3-a716-ee66ae584135" agy | head -n1)"
assert_eq "TC-VERDICT-ARTIFACT-039d no expected identity passed → identity check skipped (back-compat)" \
  "valid" "$(_classify_verdict_artifact "$GP" | head -n1)"
# The identity-mismatch reason is surfaced (loud, distinct from a generic schema error).
assert_grep_str() { local d="$1" hay="$2" needle="$3"; if [[ "$hay" == *"$needle"* ]]; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC}: $d"; echo "      haystack=[$hay]"; FAIL=$((FAIL+1)); fi; }
assert_grep_str "TC-VERDICT-ARTIFACT-039e identity-mismatch error names the mismatch" \
  "$(_artifact_schema_error "$GP" "different-session-uuid" claude)" "identity"

# TC-040 — jq fallback must enforce the FULL schema shape ([P1] #3), not just a few
# top-level fields. Force the jq backend (unset the schema so python is skipped on
# the [[ -f ]] gate; _validate_verdict_artifact_jq is also tested directly). Each
# of these is schema-INVALID and MUST be rejected by the jq fallback.
jq_state() { ( unset VERDICT_ARTIFACT_SCHEMA; _classify_verdict_artifact "$1" | head -n1 ); }
mk() { printf '%s' "$2" > "$TMP/$1.json"; }
mk bf-empty-obj  '{"schema_version":1,"verdict":"PASS","blockingFindings":{},"runId":"r","agent":"a"}'
mk nbf-string    '{"schema_version":1,"verdict":"PASS","nonBlockingFindings":"oops","runId":"r","agent":"a"}'
mk finding-no-title '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"detail":"no title"}],"runId":"r","agent":"a"}'
mk addl-prop     '{"schema_version":1,"verdict":"PASS","runId":"r","agent":"a","bogusExtra":true}'
mk finding-bad-line '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"x","line":-3}],"runId":"r","agent":"a"}'
for case in bf-empty-obj:blockingFindings-empty-object nbf-string:nonBlockingFindings-as-string \
            finding-no-title:finding-missing-title addl-prop:additional-property \
            finding-bad-line:finding-negative-line; do
  f="${case%%:*}"; desc="${case#*:}"
  assert_eq "TC-VERDICT-ARTIFACT-040 jq fallback rejects $desc → malformed" \
    "malformed" "$(_validate_verdict_artifact_jq "$TMP/$f.json" && echo valid || echo malformed)"
done
# And a genuinely valid artifact still passes the strengthened jq fallback.
assert_eq "TC-VERDICT-ARTIFACT-040z jq fallback still accepts a valid golden" \
  "valid" "$(_validate_verdict_artifact_jq "$EXAMPLES/verdict-artifact.golden.pass.json" && echo valid || echo malformed)"
assert_eq "TC-VERDICT-ARTIFACT-040y jq fallback still accepts a valid FAIL golden (findings array w/ title)" \
  "valid" "$(_validate_verdict_artifact_jq "$EXAMPLES/verdict-artifact.golden.fail.json" && echo valid || echo malformed)"

# --- [P1] #1 (#233 review round-4): human-facing body rendered from the artifact
GPASS_JSON="$(cat "$EXAMPLES/verdict-artifact.golden.pass.json")"
GFAIL_JSON="$(cat "$EXAMPLES/verdict-artifact.golden.fail.json")"
# TC-041 PASS body first line is the canonical `Review PASSED` prefix.
assert_grep_first() { local d="$1" pat="$2" body="$3"; if printf '%s' "$body" | head -n1 | grep -qE "$pat"; then echo -e "  ${GREEN}PASS${NC}: $d"; PASS=$((PASS+1)); else echo -e "  ${RED}FAIL${NC}: $d (first line: $(printf '%s' "$body" | head -n1))"; FAIL=$((FAIL+1)); fi; }
assert_grep_first "TC-VERDICT-ARTIFACT-041 PASS body first line matches '^Review PASSED'" \
  '^Review PASSED' "$(_verdict_body_from_artifact_json "$GPASS_JSON")"
# TC-042 FAIL body first line `Review findings:` AND contains the blocking title.
assert_grep_first "TC-VERDICT-ARTIFACT-042a FAIL body first line matches '^Review findings:'" \
  '^Review findings:' "$(_verdict_body_from_artifact_json "$GFAIL_JSON")"
assert_grep_str "TC-VERDICT-ARTIFACT-042b FAIL body lists the blocking finding title" \
  "$(_verdict_body_from_artifact_json "$GFAIL_JSON")" "Atomic-write contract not honored"
# TC-044 rendered FAIL body is NOT double-prefixed (exactly one leading 'Review findings:').
assert_eq "TC-VERDICT-ARTIFACT-044 FAIL body has exactly one leading 'Review findings:'" \
  "1" "$(_verdict_body_from_artifact_json "$GFAIL_JSON" | grep -c '^Review findings:')"
# TC-045 unmappable/empty input → non-empty deterministic classifiable body.
assert_nonempty "TC-VERDICT-ARTIFACT-045a empty-verdict input → non-empty body" \
  "$(_verdict_body_from_artifact_json '{}')"
assert_grep_first "TC-VERDICT-ARTIFACT-045b unmappable verdict → classifiable FAIL stub" \
  '^Review findings:' "$(_verdict_body_from_artifact_json '{"verdict":"???"}')"
# TC-048 _all_artifacts_landed: all present → 0; one missing/empty/.tmp-only → non-zero.
cp "$EXAMPLES/verdict-artifact.golden.pass.json" "$TMP/land-a.json"
cp "$EXAMPLES/verdict-artifact.golden.pass.json" "$TMP/land-b.json"
_all_artifacts_landed "$TMP/land-a.json" "$TMP/land-b.json" && _r=0 || _r=1
assert_eq "TC-VERDICT-ARTIFACT-048a all final files exist → landed (rc 0)" "0" "$_r"
_all_artifacts_landed "$TMP/land-a.json" "$TMP/missing.json" && _r=0 || _r=1
assert_eq "TC-VERDICT-ARTIFACT-048b one missing → not landed (rc 1)" "1" "$_r"
_all_artifacts_landed "$TMP/land-a.json" "" && _r=0 || _r=1
assert_eq "TC-VERDICT-ARTIFACT-048c empty-string arg → not landed (rc 1)" "1" "$_r"
cp "$EXAMPLES/verdict-artifact.golden.pass.json" "$TMP/land-c.json.tmp.99"
_all_artifacts_landed "$TMP/land-c.json" && _r=0 || _r=1
assert_eq "TC-VERDICT-ARTIFACT-048d only .tmp present, final missing → not landed (rc 1)" "1" "$_r"
_all_artifacts_landed && _r=0 || _r=1
assert_eq "TC-VERDICT-ARTIFACT-048e no args → not landed (rc 1)" "1" "$_r"

# TC-049 ([P1] #2, #233 round-5): _freeze_landed_artifact — first land freezes the
# bytes; a later DIFFERENT write is reported `duplicate` and IGNORED (the frozen
# snapshot keeps the first-landed bytes); an absent live file is a no-op.
cp "$EXAMPLES/verdict-artifact.golden.pass.json" "$TMP/fz.json"
assert_eq "TC-VERDICT-ARTIFACT-049a first land → frozen" \
  "frozen" "$(_freeze_landed_artifact "$TMP/fz.json" "$TMP/fz.json.landed")"
assert_eq "TC-VERDICT-ARTIFACT-049b steady (same bytes) → no output" \
  "" "$(_freeze_landed_artifact "$TMP/fz.json" "$TMP/fz.json.landed")"
cp "$EXAMPLES/verdict-artifact.golden.fail.json" "$TMP/fz.json"   # late rewrite (PASS→FAIL)
assert_eq "TC-VERDICT-ARTIFACT-049c post-land rewrite → duplicate (logged, ignored)" \
  "duplicate" "$(_freeze_landed_artifact "$TMP/fz.json" "$TMP/fz.json.landed")"
assert_eq "TC-VERDICT-ARTIFACT-049d frozen snapshot keeps the FIRST-landed bytes (PASS), not the rewrite (FAIL)" \
  "PASS" "$(jq -r .verdict "$TMP/fz.json.landed" 2>/dev/null)"
# The verdict resolved from the snapshot is the FIRST land (pass), not the rewrite.
assert_eq "TC-VERDICT-ARTIFACT-049e verdict from the frozen snapshot is the first land (pass)" \
  "pass" "$(_verdict_from_artifact_json "$(_classify_verdict_artifact "$TMP/fz.json.landed" | tail -n +2)")"
assert_eq "TC-VERDICT-ARTIFACT-049f absent live file → no-op (empty)" \
  "" "$(_freeze_landed_artifact "$TMP/does-not-exist.json" "$TMP/does-not-exist.landed")"

# ---------------------------------------------------------------------------
# Part 2: source-of-truth wiring in the wrapper
# ---------------------------------------------------------------------------
assert_grep "TC-VERDICT-ARTIFACT-W1 wrapper sources lib-review-artifact.sh" \
  'source "\$\{LIB_DIR\}/lib-review-artifact.sh"' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W2 wrapper provisions the per-agent artifact path (_verdict_artifact_path)" \
  '_verdict_artifact_path' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W3 wrapper exports VERDICT_ARTIFACT_PATH to the agent" \
  'VERDICT_ARTIFACT_PATH' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W4 prompt injects the artifact path + atomic-write (tmp+rename) instruction" \
  'rename|atomic|\.tmp' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W5 wrapper classifies the artifact first (_classify_verdict_artifact)" \
  '_classify_verdict_artifact' "$WRAPPER"
# Identity binding (#233 review round-2): the wrapper MUST pass the per-agent
# expected identity (session id + agent name) so a foreign-identity artifact
# cannot vote for this slot. Pin the call shape so a refactor can't silently drop
# the binding. The read target is the FROZEN snapshot ($_art_read, round-5 [P1] #2),
# not the live path — identity validates against the first-landed bytes.
assert_grep "TC-VERDICT-ARTIFACT-W5b wrapper binds artifact identity (_classify_verdict_artifact <snapshot> session-id agent-name)" \
  '_classify_verdict_artifact "\$_art_read" "\$\{AGENT_SESSION_IDS\[\$_i\]\}" "\$\{AGENT_NAMES\[\$_i\]\}"' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W5c malformed envelope reason also binds identity (_artifact_schema_error <snapshot> session-id agent-name)" \
  '_artifact_schema_error "\$_art_read" "\$\{AGENT_SESSION_IDS\[\$_i\]\}" "\$\{AGENT_NAMES\[\$_i\]\}"' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W6 logged verdict-source=artifact marker" \
  'verdict-source=artifact' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W7 logged verdict-source=comment-fallback marker" \
  'verdict-source=comment-fallback' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W8 malformed artifact surfaces a loud error envelope (emit_error_envelope/lib-error)" \
  'emit_error_envelope|lib-error\.sh|VERDICT_ARTIFACT_MALFORMED' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W9 prompt references the verdict artifact for the agent" \
  'verdict artifact|verdict-<agent>\.json|VERDICT_ARTIFACT_PATH' "$WRAPPER"

# Malformed artifact routes the all-unavailable terminal path to
# failed-non-substantive (re-dispatchable), NOT the rc-0 failed-substantive
# blocking branch. The durable signal is AGENT_VERDICT_SOURCES=artifact-malformed
# (a malformed prompt-echo exits rc 0, so the launch-rc scan misses it). The
# _any_nonsubstantive_drop initializer must OR-in that source.
assert_grep "TC-VERDICT-ARTIFACT-W12 malformed branch records the durable artifact-malformed source" \
  'AGENT_VERDICT_SOURCES\[\$_i\]="artifact-malformed"' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W13 _any_nonsubstantive_drop scans AGENT_VERDICT_SOURCES for artifact-malformed" \
  'AGENT_VERDICT_SOURCES\[\$_i\]:-\}" == "artifact-malformed"' "$WRAPPER"
# The codex stdout fallback is a SEPARATE resolution path from the comment poll
# loop; it must ALSO skip an artifact-malformed agent (Clause V1), else a codex
# member with a malformed artifact but clean stdout would be rescued to a
# pass/fail vote — a silent-PASS path the artifact channel forbids.
assert_grep "TC-VERDICT-ARTIFACT-W14 codex stdout fallback skips an artifact-malformed agent (Clause V1)" \
  'INV-78: codex member .* malformed verdict artifact' "$WRAPPER"

# [P1] #1 (#233 review round-4): the artifact `valid` branch populates
# AGENT_VERDICT_BODIES from the rendered artifact body so LATEST_COMMENT is
# non-empty (Reviewed-HEAD trailer posts; FAIL branch substantive) even when the
# agent's own comment never landed.
assert_grep "TC-VERDICT-ARTIFACT-W15 valid-artifact branch populates AGENT_VERDICT_BODIES via _verdict_body_from_artifact_json" \
  'AGENT_VERDICT_BODIES\[\$_i\]=.*_verdict_body_from_artifact_json' "$WRAPPER"
# [P1] #1 (#233 review round-5): EXACTLY ONE wrapper-owned AGGREGATE verdict comment
# posted from `AGGREGATE` (not a per-agent breadcrumb re-post). post-verdict.sh is
# called with the aggregate verdict + the representative agent/session.
assert_grep "TC-VERDICT-ARTIFACT-W16 wrapper posts ONE aggregate verdict comment from AGGREGATE via post-verdict.sh" \
  'post-verdict\.sh" "\$ISSUE_NUMBER" "\$AGGREGATE" "\$_agg_body_file"' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W17a aggregate post is gated on a deciding ARTIFACT-sourced agent (no double-post on the comment path)" \
  '_any_deciding_artifact == "true"|_any_deciding_artifact" == "true"' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W17b _any_deciding_artifact keys on source==artifact AND a pass/fail verdict" \
  'AGENT_VERDICT_SOURCES\[\$_i\]:-\}" == "artifact"' "$WRAPPER"
# The old per-agent breadcrumb re-post loop is GONE (it could miss reaped-before-post
# agents and emit contradictory per-agent comments).
assert_not_grep "TC-VERDICT-ARTIFACT-W17c the per-agent breadcrumb-gated re-post loop is removed" \
  'wrapper posting the artifact-derived verdict comment so comment-format' "$WRAPPER"
# [P1] #2 (#233 review round-4/5): the fan-out join observes artifact landing AND
# freezes the first-landed bytes (Clause VA5) so a hung agent doesn't hold a landed
# verdict hostage AND a duplicate later write can't replace the resolved verdict.
assert_grep "TC-VERDICT-ARTIFACT-W18 fan-out join observes artifact landing (_all_artifacts_landed) instead of a bare wait" \
  '_all_artifacts_landed' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W19 early-exit is gated on ALL artifacts landed (preserves INV-48 timeout-veto rc)" \
  'all artifacts landed|ALL artifacts? (have )?landed|INV-48.*preserv' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W20 observe loop freezes first-landed bytes (_freeze_landed_artifact / _freeze_pass)" \
  '_freeze_landed_artifact|_freeze_pass' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W21 resolution loop reads the FROZEN snapshot, not a re-read of the live path" \
  '_art_read="\$\{AGENT_ARTIFACT_SNAPSHOTS\[\$_i\]' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W22 a post-land duplicate write is logged (Clause VA5)" \
  'duplicate/late verdict-artifact write landed' "$WRAPPER"
# The per-run artifact dir is cleaned up after resolution (no accumulation), gated
# on a `.../runs/` leaf path so a misresolved root is never removed.
assert_grep "TC-VERDICT-ARTIFACT-W23 per-run artifact dir is cleaned up (rm -rf the runs/<run-id> leaf)" \
  'rm -rf "\$_art_run_dir"' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W23b cleanup only removes a runs/ leaf (defensive against a misresolved root)" \
  '_art_run_dir" == \*/runs/\*' "$WRAPPER"

# Render-format pins (machine consumers unchanged — these greps must still hold).
assert_grep "TC-VERDICT-ARTIFACT-W10 dispatcher trailer still emitted (emit_verdict_trailer passed)" \
  'emit_verdict_trailer "\$ISSUE_NUMBER" "\$REPO" "passed"' "$WRAPPER"
assert_grep "TC-VERDICT-ARTIFACT-W11 wrapper-rendered FAIL aggregate still starts 'Review findings:'" \
  'Review findings:' "$WRAPPER"

# ---------------------------------------------------------------------------
# Part 3: behavioral integration — artifact-first resolution + comment fallback +
# aggregation. The wrapper's resolution block is inline, so we reproduce its
# EXACT control flow here against the real libs (lib-review-artifact.sh seeds
# AGENT_VERDICTS from valid artifacts; lib-review-poll.sh skips already-resolved
# and artifact-malformed agents; lib-review-aggregate.sh collapses the vote). The
# "comment poll" is stubbed via _fetch_agent_verdict_body so no live GitHub is
# needed — and a COUNTER on it pins the zero-comment-poll AC.
# shellcheck source=/dev/null
source "$DISP/lib-review-aggregate.sh"
# shellcheck source=/dev/null
source "$DISP/lib-review-poll.sh"

# Stubs the harness controls. The fetcher runs inside the poll loop's `$(…)`
# command substitution (a subshell), so a shell-var counter would NOT propagate —
# record each fetch to a FILE and count its lines (COMMENT_FETCH_COUNT is derived
# from it in run_fleet). This pins the zero-poll AC correctly.
COMMENT_FETCH_LOG="$TMP/comment-fetches.log"
COMMENT_FETCH_COUNT=0
declare -A STUB_COMMENT_BODY=()    # agent → comment body the fallback would find
_fetch_agent_verdict_body() {
  printf '%s\n' "$1" >> "$COMMENT_FETCH_LOG"
  printf '%s' "${STUB_COMMENT_BODY[$1]:-}"
}
log() { :; }                        # silence wrapper log() the poll loop calls
error_surface() { ENVELOPE_EMITTED=1; ENVELOPE_AGENT="$2"; return 0; }  # capture malformed envelope

# run_fleet "<agent:artifact-fixture-or-none:comment-body>..." → echoes the
# aggregate; sets COMMENT_FETCH_COUNT + ENVELOPE_* as side effects. Mirrors the
# wrapper: provision artifact files, seed from valid artifacts, run the (stubbed)
# poll loop, terminal-sweep, aggregate.
run_fleet() {
  local spec rid agent fixture comment
  : > "$COMMENT_FETCH_LOG"
  ENVELOPE_EMITTED=0
  ENVELOPE_AGENT=""
  STUB_COMMENT_BODY=()
  AGENT_NAMES=(); AGENT_SESSION_IDS=(); AGENT_ARTIFACT_PATHS=()
  AGENT_VERDICTS=(); AGENT_VERDICT_BODIES=(); AGENT_VERDICT_SOURCES=()
  declare -gA AGENT_LAUNCH_RC=()
  local _run=$((++FLEET_RUN))
  local i=0
  for spec in "$@"; do
    agent="${spec%%:*}"; rest="${spec#*:}"
    fixture="${rest%%:*}"; comment="${rest#*:}"
    [[ "$comment" == "$rest" ]] && comment=""   # no comment field
    rid="run-${_run}-${i}"
    local dir="$TMP/state/autonomous-proj/runs/$rid"
    mkdir -p "$dir"
    local path="$dir/verdict-$agent.json"
    if [[ "$fixture" != "none" ]]; then cp "$EXAMPLES/$fixture" "$path"; fi
    AGENT_NAMES+=("$agent"); AGENT_SESSION_IDS+=("$rid"); AGENT_ARTIFACT_PATHS+=("$path")
    AGENT_VERDICTS+=(""); AGENT_VERDICT_BODIES+=(""); AGENT_VERDICT_SOURCES+=("")
    AGENT_LAUNCH_RC["$rid"]=0
    [[ -n "$comment" ]] && STUB_COMMENT_BODY["$agent"]="$comment"
    i=$((i + 1))
  done

  # --- artifact-first resolution (mirrors the wrapper block) ---
  local _i _art_out _art_state _art_json _art_verdict
  for _i in "${!AGENT_NAMES[@]}"; do
    _art_out=$(_classify_verdict_artifact "${AGENT_ARTIFACT_PATHS[$_i]}")
    _art_state="${_art_out%%$'\n'*}"
    case "$_art_state" in
      valid)
        _art_json="${_art_out#*$'\n'}"
        _art_verdict=$(_verdict_from_artifact_json "$_art_json")
        AGENT_VERDICTS[$_i]="$_art_verdict"; AGENT_VERDICT_SOURCES[$_i]="artifact"
        # [P1] #1 (#233 round-4): mirror the wrapper — populate the body from the artifact.
        AGENT_VERDICT_BODIES[$_i]="$(_verdict_body_from_artifact_json "$_art_json")" ;;
      malformed)
        AGENT_VERDICT_SOURCES[$_i]="artifact-malformed"
        error_surface "x" "${AGENT_NAMES[$_i]}" "p" "c" "r" "d" "config" ;;
    esac
  done
  # --- comment poll (stubbed) ---
  _VERDICT_POLL_ATTEMPTS=1; _VERDICT_POLL_INTERVAL_SECONDS=0
  _run_verdict_poll_loop
  # --- tag comment-fallback ---
  for _i in "${!AGENT_NAMES[@]}"; do
    [[ -n "${AGENT_VERDICTS[$_i]}" && -z "${AGENT_VERDICT_SOURCES[$_i]}" ]] && AGENT_VERDICT_SOURCES[$_i]="comment-fallback"
  done
  # --- terminal sweep ---
  for _i in "${!AGENT_NAMES[@]}"; do
    [[ -n "${AGENT_VERDICTS[$_i]}" ]] && continue
    AGENT_VERDICTS[$_i]=$(_classify_noverdict_agent "${AGENT_LAUNCH_RC[${AGENT_SESSION_IDS[$_i]}]:-1}")
  done
  # Derive the comment-fetch count from the log (the fetcher ran in a subshell).
  COMMENT_FETCH_COUNT=$(wc -l < "$COMMENT_FETCH_LOG" | tr -d ' ')
  # Set the aggregate as a GLOBAL (not echoed) so callers run run_fleet in the
  # current shell and can inspect AGENT_VERDICT_SOURCES / COMMENT_FETCH_COUNT
  # afterward — a `$(run_fleet …)` subshell would discard those arrays.
  FLEET_AGG=$(_aggregate_review_verdicts "${AGENT_VERDICTS[@]}")
}
FLEET_RUN=0
PASS_BODY="Review PASSED - looks good
Review Agent: x"
FAIL_BODY="Review findings:
1. bad
Review Agent: x"

echo ""
echo "=== Part 3: artifact-first resolution + fallback + aggregation ==="

# TC-020 / AC — all valid artifacts ⇒ ZERO comment-list calls.
run_fleet "claude:verdict-artifact.golden.pass.json:" "agy:verdict-artifact.golden.pass.json:"
assert_eq "TC-VERDICT-ARTIFACT-020a all-artifact fleet aggregate pass" "pass" "$FLEET_AGG"
assert_eq "TC-VERDICT-ARTIFACT-020b all-artifact fleet did ZERO comment polls" "0" "$COMMENT_FETCH_COUNT"
assert_eq "TC-VERDICT-ARTIFACT-020c source is artifact" "artifact" "${AGENT_VERDICT_SOURCES[0]}"

# TC-043/046/047 ([P1] #1, #233 round-4): an artifact-resolved agent now carries a
# rendered body, so LATEST_COMMENT is non-empty (Reviewed-HEAD trailer posts; FAIL
# branch substantive) even when the agent's own comment never landed — and the
# body round-trips through _classify_verdict_body to the same verdict.
run_fleet "claude:verdict-artifact.golden.pass.json:" "agy:verdict-artifact.golden.pass.json:"
assert_nonempty "TC-VERDICT-ARTIFACT-046a artifact-resolved agent has a non-empty rendered body" \
  "${AGENT_VERDICT_BODIES[0]}"
# Synthesize LATEST_COMMENT exactly as the wrapper does (concat non-empty bodies).
_LC=""
for _bi in "${!AGENT_NAMES[@]}"; do [[ -n "${AGENT_VERDICT_BODIES[$_bi]}" ]] && _LC+="${AGENT_VERDICT_BODIES[$_bi]}"$'\n\n'; done
assert_nonempty "TC-VERDICT-ARTIFACT-046b all-artifact PASS fleet → synthesized LATEST_COMMENT non-empty (Reviewed-HEAD trailer gate)" "$_LC"
assert_eq "TC-VERDICT-ARTIFACT-047 adding the body renderer did NOT introduce a comment poll (TC-020 still 0)" \
  "0" "$COMMENT_FETCH_COUNT"
# Round-trip: the rendered body classifies back to the artifact verdict.
assert_eq "TC-VERDICT-ARTIFACT-043a rendered PASS body → _classify_verdict_body=pass" \
  "pass" "$(_classify_verdict_body "${AGENT_VERDICT_BODIES[0]}")"
run_fleet "codex:verdict-artifact.golden.fail.json:"
assert_eq "TC-VERDICT-ARTIFACT-043b rendered FAIL body → _classify_verdict_body=fail" \
  "fail" "$(_classify_verdict_body "${AGENT_VERDICT_BODIES[0]}")"

# TC-017 — artifact wins over a conflicting comment.
run_fleet "claude:verdict-artifact.golden.pass.json:$FAIL_BODY"
assert_eq "TC-VERDICT-ARTIFACT-017a artifact PASS beats conflicting comment FAIL" "pass" "$FLEET_AGG"
assert_eq "TC-VERDICT-ARTIFACT-017b no comment poll when artifact valid" "0" "$COMMENT_FETCH_COUNT"

# TC-018 — no artifact, comment present ⇒ comment-fallback (and the comment WAS polled).
run_fleet "claude:none:$PASS_BODY"
assert_eq "TC-VERDICT-ARTIFACT-018a no-artifact + PASS comment → pass" "pass" "$FLEET_AGG"
assert_eq "TC-VERDICT-ARTIFACT-018b source is comment-fallback" "comment-fallback" "${AGENT_VERDICT_SOURCES[0]}"
assert_eq "TC-VERDICT-ARTIFACT-018c the no-artifact agent WAS comment-polled (≥1 fetch)" "1" "$COMMENT_FETCH_COUNT"

# TC-019 / TC-023 — malformed artifact, no comment ⇒ loud envelope + treated absent.
run_fleet "claude:verdict-artifact.negative.no-schema-version.json:"
assert_eq "TC-VERDICT-ARTIFACT-019a malformed-only fleet → all-unavailable (absent semantics)" "all-unavailable" "$FLEET_AGG"
assert_eq "TC-VERDICT-ARTIFACT-019b malformed emitted a loud envelope" "1" "$ENVELOPE_EMITTED"
assert_eq "TC-VERDICT-ARTIFACT-019c source recorded artifact-malformed" "artifact-malformed" "${AGENT_VERDICT_SOURCES[0]}"

# Malformed agent's comment is NOT consulted (Clause V1) even if it posted a PASS.
run_fleet "claude:verdict-artifact.negative.no-schema-version.json:$PASS_BODY"
assert_eq "TC-VERDICT-ARTIFACT-019d malformed artifact NOT overridden by a PASS comment" "all-unavailable" "$FLEET_AGG"
assert_eq "TC-VERDICT-ARTIFACT-019e malformed agent not comment-polled" "0" "$COMMENT_FETCH_COUNT"

# TC-021/022 — single-agent valid pass / fail.
run_fleet "claude:verdict-artifact.golden.pass.json:"
assert_eq "TC-VERDICT-ARTIFACT-021 single valid PASS → pass" "pass" "$FLEET_AGG"
run_fleet "codex:verdict-artifact.golden.fail.json:"
assert_eq "TC-VERDICT-ARTIFACT-022 single valid FAIL → fail" "fail" "$FLEET_AGG"

# TC-024/025 — multi valid combinations.
run_fleet "claude:verdict-artifact.golden.pass.json:" "agy:verdict-artifact.golden.pass.json:"
assert_eq "TC-VERDICT-ARTIFACT-024 valid PASS + valid PASS → pass" "pass" "$FLEET_AGG"
run_fleet "claude:verdict-artifact.golden.pass.json:" "codex:verdict-artifact.golden.fail.json:"
assert_eq "TC-VERDICT-ARTIFACT-025 valid PASS + valid FAIL → fail" "fail" "$FLEET_AGG"

# TC-026 — valid PASS + absent-with-comment-PASS (mixed channel) → pass.
run_fleet "claude:verdict-artifact.golden.pass.json:" "agy:none:$PASS_BODY"
assert_eq "TC-VERDICT-ARTIFACT-026a mixed artifact+comment → pass" "pass" "$FLEET_AGG"
assert_eq "TC-VERDICT-ARTIFACT-026b agy resolved via comment-fallback" "comment-fallback" "${AGENT_VERDICT_SOURCES[1]}"
assert_eq "TC-VERDICT-ARTIFACT-026c claude resolved via artifact" "artifact" "${AGENT_VERDICT_SOURCES[0]}"

# TC-027 — valid PASS + malformed (drop) → pass (1 deciding).
run_fleet "claude:verdict-artifact.golden.pass.json:" "agy:verdict-artifact.negative.no-schema-version.json:"
assert_eq "TC-VERDICT-ARTIFACT-027 valid PASS + malformed-drop → pass (1 deciding)" "pass" "$FLEET_AGG"

# TC-028 — malformed + absent-no-comment → all-unavailable.
run_fleet "claude:verdict-artifact.negative.no-schema-version.json:" "agy:none:"
assert_eq "TC-VERDICT-ARTIFACT-028 malformed + absent-no-comment → all-unavailable" "all-unavailable" "$FLEET_AGG"

# TC-029 — timeout-veto preserved: rc124 + no artifact ⇒ deciding FAIL (via the
# terminal sweep classifier, unchanged by #233).
assert_eq "TC-VERDICT-ARTIFACT-029 rc124 no-verdict → timed-out (deciding FAIL preserved)" \
  "timed-out" "$(_classify_noverdict_agent 124)"

# TC-031 — comment-fallback parity: a no-artifact fleet reaches the SAME aggregate
# as the legacy comment-only path would (pass+fail → fail; pass+pass → pass).
run_fleet "claude:none:$PASS_BODY" "agy:none:$FAIL_BODY"
assert_eq "TC-VERDICT-ARTIFACT-031a fallback parity pass+fail → fail" "fail" "$FLEET_AGG"
run_fleet "claude:none:$PASS_BODY" "agy:none:$PASS_BODY"
assert_eq "TC-VERDICT-ARTIFACT-031b fallback parity pass+pass → pass" "pass" "$FLEET_AGG"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
