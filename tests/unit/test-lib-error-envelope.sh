#!/bin/bash
# test-lib-error-envelope.sh — issue #231 / INV-72.
#
# Unit tests for skills/autonomous-dispatcher/scripts/lib-error.sh:
#   - error_envelope rendering (defaults, classes, doc, special chars)
#   - Clause E1 (remediation REQUIRED) / E3 (UPPER_SNAKE code) rejection
#   - the embedded `<!-- adt-error-envelope: {json} -->` marker validates
#     against docs/pipeline/schemas/error-envelope.schema.json (python3
#     jsonschema preferred, jq structural fallback — same dual-path as
#     test-adapter-spec-schemas.sh so it runs on bare CI either way)
#   - error_surface posts via a stubbed token-refresh `gh` proxy, and degrades
#     to log-only WITHOUT changing rc when the post fails / proxy is missing /
#     no issue is known (dispatcher-alert) / class is transient (regression pin)
#   - code-registry drift guard: every code emitted by a lib-error.sh caller in
#     the dispatcher scripts exists as a row in docs/pipeline/errors.md
#   - INV-72 exists in docs/pipeline/invariants.md
#
# Run: bash tests/unit/test-lib-error-envelope.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-error.sh"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
SCHEMA="$PROJECT_ROOT/docs/pipeline/schemas/error-envelope.schema.json"
ERRORS_DOC="$PROJECT_ROOT/docs/pipeline/errors.md"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
note() { echo -e "  ${YELLOW}NOTE${NC}: $1"; }

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$desc"; else
    bad "$desc"; echo "      needle='$needle'"; echo "      haystack='$haystack'"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then ok "$desc"; else
    bad "$desc — should NOT contain '$needle'"; fi
}
assert_rc() {
  local desc="$1" want="$2" got="$3"
  if [[ "$got" -eq "$want" ]]; then ok "$desc (rc=$got)"; else bad "$desc — want rc=$want got=$got"; fi
}

# Extract the JSON inside the `<!-- adt-error-envelope: {json} -->` marker
# without grep -P lookbehind (gh's RE2 / portability). sed strips the wrapper.
extract_marker_json() {
  printf '%s\n' "$1" | sed -n 's/.*<!-- adt-error-envelope: \(.*\) -->.*/\1/p' | head -1
}

# Strip the machine-readable marker line, leaving ONLY the human-readable block.
# Assertions on this catch a regression where the human bullets fail to render
# (e.g. the bash builtin `printf` rejecting a `-`-leading format string) — a
# failure the marker JSON would otherwise mask, since it duplicates every value.
human_block() {
  printf '%s\n' "$1" | grep -v 'adt-error-envelope:'
}

if [[ ! -f "$LIB" ]]; then
  echo -e "${RED}FATAL${NC}: lib-error.sh not found at $LIB"; exit 1
fi
# shellcheck disable=SC1090
source "$LIB"

# Backend detection (mirrors test-adapter-spec-schemas.sh).
HAVE_PY_JSONSCHEMA=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
  HAVE_PY_JSONSCHEMA=1
fi

validate_envelope_json() {
  # $1 = JSON string. rc 0 = valid, 1 = invalid. Uses python3 jsonschema when
  # available (full Clause E2 conditional), else a jq structural check. The
  # instance is passed as a FILE (not stdin) — stdin is the heredoc carrying the
  # python source, so reading the instance from stdin would corrupt the script.
  local json="$1"
  if [[ "$HAVE_PY_JSONSCHEMA" -eq 1 && -f "$SCHEMA" ]]; then
    local _inst; _inst="$(mktemp)"
    printf '%s' "$json" > "$_inst"
    python3 - "$SCHEMA" "$_inst" <<'PY'
import json, sys
from jsonschema import Draft7Validator
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
sys.exit(1 if list(Draft7Validator(schema).iter_errors(inst)) else 0)
PY
    local _rc=$?
    rm -f "$_inst"
    return $_rc
  fi
  # jq fallback: required keys present, code UPPER_SNAKE, remediation non-empty,
  # operator-actionable class never log-only (Clause E2).
  printf '%s' "$json" | jq -e '
    .schema_version == 1
    and (.code | test("^[A-Z][A-Z0-9_]*$"))
    and (.problem | length > 0)
    and (.cause | length > 0)
    and (.remediation | length > 0)
    and (["issue-comment","dispatcher-alert","log-only"] | index(.surface) != null)
    and ((.class // "config") as $c
         | if ($c == "transient") then true
           else (.surface != "log-only") end)
  ' >/dev/null 2>&1
  return $?
}

# ===========================================================================
echo "=== TC-ERR-ENVELOPE rendering ==="

# TC-ERR-ENVELOPE-001 — basic render, defaults.
OUT=$(error_envelope ADT_CFG_MISSING_KEY "PROJECT_ID not set" "conf missing PROJECT_ID" "Set PROJECT_ID in scripts/autonomous.conf")
assert_contains "001 human block has code"        "ADT_CFG_MISSING_KEY" "$OUT"
assert_contains "001 human block has remediation" "Set PROJECT_ID"      "$OUT"
assert_contains "001 has marker"                  "adt-error-envelope:"  "$OUT"
J=$(extract_marker_json "$OUT")
assert_contains "001 marker class default=config" '"class":"config"' "$J"
assert_contains "001 marker surface=issue-comment" '"surface":"issue-comment"' "$J"
assert_contains "001 marker schema_version=1"     '"schema_version":1' "$J"

# TC-ERR-ENVELOPE-008 — the HUMAN block (marker stripped) renders every bullet,
# and the render emits NO stderr noise. Regression pin: the bash builtin printf
# rejects a `-`-leading format ("printf: - : invalid option"), which silently
# drops the entire operator-facing bullet list while the marker JSON (asserted
# in 001) still carries the values — so 001 alone passes on a broken render.
HUMAN=$(human_block "$OUT")
assert_contains "008 human block bullet: Code"        '- **Code:** `ADT_CFG_MISSING_KEY`' "$HUMAN"
assert_contains "008 human block bullet: Class"       "- **Class:** config"                "$HUMAN"
assert_contains "008 human block bullet: Problem"     "- **Problem:** PROJECT_ID not set"   "$HUMAN"
assert_contains "008 human block bullet: Cause"       "- **Cause:** conf missing PROJECT_ID" "$HUMAN"
assert_contains "008 human block bullet: Remediation" "- **Remediation:** Set PROJECT_ID"   "$HUMAN"
ERR008=$(error_envelope ADT_CFG_MISSING_KEY "p" "c" "r" 2>&1 >/dev/null)
assert_not_contains "008 render emits no printf error" "invalid option" "$ERR008"
[[ -z "$ERR008" ]] && ok "008 render is stderr-clean" || bad "008 render emitted unexpected stderr: '$ERR008'"

# TC-ERR-ENVELOPE-002 — special chars survive jq, no shell eval.
NASTY='cause with `backticks`, "double quotes", $(echo SHOULD_NOT_RUN), and a trailing dollar $'
OUT2=$(error_envelope ADT_X "problem" "$NASTY" "remediate it")
J2=$(extract_marker_json "$OUT2")
if printf '%s' "$J2" | jq -e . >/dev/null 2>&1; then ok "002 marker JSON well-formed with special chars"; else bad "002 marker JSON malformed"; fi
CAUSE_BACK=$(printf '%s' "$J2" | jq -r '.cause' 2>/dev/null)
assert_contains "002 backticks round-trip"            '`backticks`'            "$CAUSE_BACK"
assert_contains "002 command-sub literal (not run)"   '$(echo SHOULD_NOT_RUN)' "$CAUSE_BACK"
assert_not_contains "002 command-sub did NOT execute" "SHOULD_NOT_RUN="        "$CAUSE_BACK"

# TC-ERR-ENVELOPE-003 — transient → log-only.
J3=$(extract_marker_json "$(error_envelope ADT_TRANS p c r "" transient)")
assert_contains "003 transient class"        '"class":"transient"' "$J3"
assert_contains "003 transient surface log"  '"surface":"log-only"' "$J3"

# TC-ERR-ENVELOPE-004 — doc field.
J4=$(extract_marker_json "$(error_envelope ADT_X p c r 'docs/pipeline/invariants.md#inv-72')")
assert_contains "004 doc field present" '"doc":"docs/pipeline/invariants.md#inv-72"' "$J4"
J4b=$(extract_marker_json "$(error_envelope ADT_X p c r)")
assert_not_contains "004 doc omitted when empty" '"doc"' "$J4b"

# TC-ERR-ENVELOPE-005 — embedded JSON validates against the schema (all classes).
echo "=== TC-ERR-ENVELOPE-005 schema conformance ==="
[[ "$HAVE_PY_JSONSCHEMA" -eq 1 ]] && note "using python3 jsonschema" || note "using jq structural fallback"
for cls in config auth quota transient; do
  CODE="ADT_X_$(printf '%s' "$cls" | tr '[:lower:]' '[:upper:]')"
  JX=$(extract_marker_json "$(error_envelope "$CODE" "p" "c" "operator action" "" "$cls")")
  if validate_envelope_json "$JX"; then ok "005 rendered $cls envelope validates"; else bad "005 rendered $cls envelope REJECTED"; fi
done

# TC-ERR-ENVELOPE-006 / 007 — Clause E3 / E1 rejection.
echo "=== TC-ERR-ENVELOPE-006/007 conformance rejection ==="
error_envelope "bad code" p c r >/dev/null 2>&1; assert_rc "006 lowercase/space code rejected" 1 $?
error_envelope "lower_case" p c r >/dev/null 2>&1; assert_rc "006 lowercase code rejected" 1 $?
error_envelope ADT_X p c "" >/dev/null 2>&1; assert_rc "007 empty remediation rejected" 1 $?

# ===========================================================================
echo "=== TC-ERR-ENVELOPE-009 error_peek_issue_arg (early non-destructive --issue scan) ==="
# Lets the wrappers' pre-arg-parse config validations surface ON THE ISSUE.
[[ "$(error_peek_issue_arg --issue 231)" == "231" ]] && ok "009 --issue 231 → 231" || bad "009 --issue 231"
[[ "$(error_peek_issue_arg --issue 7 --mode new)" == "7" ]] && ok "009 --issue among other args → 7" || bad "009 --issue among args"
[[ "$(error_peek_issue_arg --mode resume --issue 42 --session abc)" == "42" ]] && ok "009 --issue not first → 42" || bad "009 --issue not first"
[[ "$(error_peek_issue_arg --validate-config-only)" == "-" ]] && ok "009 no --issue → '-' sentinel" || bad "009 no --issue"
[[ "$(error_peek_issue_arg)" == "-" ]] && ok "009 empty argv → '-'" || bad "009 empty argv"
[[ "$(error_peek_issue_arg --issue notanumber)" == "-" ]] && ok "009 non-integer --issue → '-' (rejected)" || bad "009 non-integer issue"
[[ "$(error_peek_issue_arg --issue)" == "-" ]] && ok "009 dangling --issue (no value) → '-'" || bad "009 dangling --issue"

# ===========================================================================
echo "=== TC-ERR-ENVELOPE-009b error_envelope surface override (7th arg, P2 mechanism) ==="
# A valid override pins the marker surface (used by error_surface for alerts).
J9A=$(extract_marker_json "$(error_envelope ADT_X p c r "" config dispatcher-alert)")
assert_contains "009b dispatcher-alert override honored" '"surface":"dispatcher-alert"' "$J9A"
# A config-class envelope surfaced dispatcher-alert MUST be schema-valid (the
# schema's Clause E2 conditional permits config+dispatcher-alert; only log-only
# is restricted to transient). Validate it through the same backend as TC-005.
if validate_envelope_json "$J9A"; then ok "009b config+dispatcher-alert validates against schema"; else bad "009b config+dispatcher-alert REJECTED by schema"; fi
J9B=$(extract_marker_json "$(error_envelope ADT_X p c r "" config issue-comment)")
assert_contains "009b issue-comment override honored" '"surface":"issue-comment"' "$J9B"
# Clause E2: a log-only override on an operator-actionable class is IGNORED
# (kept at the class default issue-comment) — the schema would reject log-only.
J9C=$(extract_marker_json "$(error_envelope ADT_X p c r "" config log-only 2>/dev/null)")
assert_contains "009b log-only override rejected for config (Clause E2)" '"surface":"issue-comment"' "$J9C"
# An invalid override is ignored → class default.
J9D=$(extract_marker_json "$(error_envelope ADT_X p c r "" config garbage 2>/dev/null)")
assert_contains "009b invalid override ignored → class default" '"surface":"issue-comment"' "$J9D"

# ===========================================================================
echo "=== TC-ERR-ENVELOPE surfacing ==="
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/scripts"
CALLS="$TMPROOT/gh-calls.log"

make_stub_gh() {
  # $1 = exit code the stub returns
  cat > "$TMPROOT/scripts/gh" <<EOF
#!/bin/bash
{ echo "GH-CALL:"; printf '%s\\n' "\$@"; } >> "$CALLS"
echo "https://github.com/o/r/issues/231#issuecomment-1"
exit ${1:-0}
EOF
  chmod +x "$TMPROOT/scripts/gh"
}

# TC-ERR-ENVELOPE-010 — happy path post.
make_stub_gh 0; : > "$CALLS"
( set -euo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="zxkane/autonomous-dev-team"
  source "$LIB"
  error_surface 231 ADT_CFG_E2E_MODE_INVALID "invalid E2E_MODE" "E2E_MODE=foo" "Set E2E_MODE to none|browser|command"
) 2>"$TMPROOT/e10"; assert_rc "010 error_surface returns 0 on success" 0 $?
CALLBODY=$(cat "$CALLS")
assert_contains "010 gh issue comment invoked" "issue" "$CALLBODY"
assert_contains "010 posted body has code"        "ADT_CFG_E2E_MODE_INVALID" "$CALLBODY"
assert_contains "010 posted body has remediation" "Set E2E_MODE"             "$CALLBODY"
assert_contains "010 posted body has marker"      "adt-error-envelope:"      "$CALLBODY"
# P2: a posted (issue) envelope's marker reads surface=issue-comment.
E10J=$(extract_marker_json "$CALLBODY")
assert_contains "010 marker surface=issue-comment (P2)" '"surface":"issue-comment"' "$E10J"
# P1-1: the SUCCESS path ALSO logs the full envelope to stderr (the #231
# contract: same envelope to the wrapper log AND the issue), not just a short
# "surfaced envelope" confirmation line.
E10ERR=$(cat "$TMPROOT/e10")
assert_contains "010 success path logs full envelope to stderr (P1-1)" "adt-error-envelope:" "$E10ERR"
assert_contains "010 stderr envelope carries remediation (P1-1)"       "Set E2E_MODE"        "$E10ERR"

# TC-ERR-ENVELOPE-010b — missing REPO but REPO_OWNER/REPO_NAME present (the
# ADT_CFG_MISSING_KEY-for-REPO case): error_surface MUST fall back to
# ${REPO_OWNER}/${REPO_NAME} for `gh --repo`, NOT pass an empty --repo (which
# would fail outside a git checkout, before `cd "$PROJECT_DIR"`). P1-2 fix.
make_stub_gh 0; : > "$CALLS"
( set -euo pipefail
  unset REPO GITHUB_REPO
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO_OWNER=zxkane REPO_NAME=autonomous-dev-team
  source "$LIB"
  error_surface 231 ADT_CFG_MISSING_KEY "REPO unset" "REPO empty" "Set REPO in scripts/autonomous.conf"
) 2>"$TMPROOT/e10b"; assert_rc "010b missing-REPO fallback returns 0" 0 $?
CALL10B=$(cat "$CALLS")
assert_contains "010b fallback repo is zxkane/autonomous-dev-team (P1-2)" "zxkane/autonomous-dev-team" "$CALL10B"
# The stub records one arg per line; the line immediately after `--repo` must be
# the non-empty fallback repo (an empty --repo would leave that line blank).
REPO_ARG10B=$(awk '/^--repo$/{getline; print; exit}' "$CALLS")
if [[ "$REPO_ARG10B" == "zxkane/autonomous-dev-team" ]]; then
  ok "010b gh received --repo zxkane/autonomous-dev-team (not empty) (P1-2)"
else
  bad "010b gh --repo arg was '${REPO_ARG10B}', expected zxkane/autonomous-dev-team (P1-2)"
fi

# TC-ERR-ENVELOPE-011 — post FAILS → rc still 0, log-only degrade.
make_stub_gh 1
( set -euo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r"
  source "$LIB"
  error_surface 231 ADT_X p c r
) 2>"$TMPROOT/e11"; assert_rc "011 post-failure does not change rc" 0 $?
E11=$(cat "$TMPROOT/e11")
assert_contains "011 logs degradation to log-only" "degrading to log-only" "$E11"
assert_contains "011 envelope present on stderr"   "adt-error-envelope:"   "$E11"

# TC-ERR-ENVELOPE-012 — no project-side symlink (fresh install) → FALLBACK to
# the co-located gh-with-token-refresh.sh in lib-error.sh's own skill-tree dir,
# so the envelope STILL POSTS (the P1 fix) instead of degrading to log-only.
# We stand up a fake skill dir holding lib-error.sh (copy) + a stub
# gh-with-token-refresh.sh, source the COPY (so _LIB_ERROR_DIR resolves to the
# fake dir), and leave AUTONOMOUS_CONF_DIR unset to force the fallback branch.
FAKE_SKILL="$TMPROOT/skill"; mkdir -p "$FAKE_SKILL"
cp "$LIB" "$FAKE_SKILL/lib-error.sh"
FB_CALLS="$TMPROOT/fallback-calls.log"; : > "$FB_CALLS"
cat > "$FAKE_SKILL/gh-with-token-refresh.sh" <<EOF
#!/bin/bash
{ echo "FALLBACK-GH:"; printf '%s\\n' "\$@"; } >> "$FB_CALLS"
echo "https://github.com/o/r/issues/231#issuecomment-2"
exit 0
EOF
chmod +x "$FAKE_SKILL/gh-with-token-refresh.sh"
( set -euo pipefail
  unset AUTONOMOUS_CONF_DIR
  unset _LIB_ERROR_SOURCED   # allow re-source of the copy
  export REPO="o/r"
  # shellcheck disable=SC1090
  source "$FAKE_SKILL/lib-error.sh"
  error_surface 231 ADT_X p c r
) 2>"$TMPROOT/e12"; assert_rc "012 fresh-install fallback does not change rc" 0 $?
if [[ -s "$FB_CALLS" ]] && grep -q "ADT_X" "$FB_CALLS"; then
  ok "012 posts via gh-with-token-refresh.sh fallback (no symlink) — P1 fix"
else
  bad "012 did NOT post via fallback (P1 regression); stderr: $(cat "$TMPROOT/e12")"
fi
assert_not_contains "012 did NOT degrade to log-only" "degrading envelope" "$(cat "$TMPROOT/e12")"

# TC-ERR-ENVELOPE-012b — proxy TRULY unresolvable (no symlink AND no skill-tree
# fallback) → degrade to log-only, rc 0. Source a copy in a dir with NO
# gh-with-token-refresh.sh sibling.
BARE_SKILL="$TMPROOT/bare"; mkdir -p "$BARE_SKILL"
cp "$LIB" "$BARE_SKILL/lib-error.sh"
( set -euo pipefail
  unset AUTONOMOUS_CONF_DIR
  unset _LIB_ERROR_SOURCED
  export REPO="o/r"
  # shellcheck disable=SC1090
  source "$BARE_SKILL/lib-error.sh"
  error_surface 231 ADT_X p c r
) 2>"$TMPROOT/e12b"; assert_rc "012b unresolvable proxy does not change rc" 0 $?
assert_contains "012b degrades to log-only when proxy unresolvable" "not resolvable" "$(cat "$TMPROOT/e12b")"
assert_contains "012b envelope present on stderr" "adt-error-envelope:" "$(cat "$TMPROOT/e12b")"

# TC-ERR-ENVELOPE-013 — empty/'-' issue → dispatcher-alert, no post.
make_stub_gh 0; : > "$CALLS"
( set -euo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r"
  source "$LIB"
  error_surface - ADT_CFG_EXECUTION_BACKEND_INVALID "unknown EXECUTION_BACKEND" "EXECUTION_BACKEND=foo" "Set EXECUTION_BACKEND to local|remote-aws-ssm"
) 2>"$TMPROOT/e13"; assert_rc "013 dispatcher-alert returns 0" 0 $?
assert_contains "013 logs dispatcher-alert" "dispatcher-alert" "$(cat "$TMPROOT/e13")"
if [[ -s "$CALLS" ]]; then bad "013 gh MUST NOT be called for dispatcher-alert"; else ok "013 gh not called (dispatcher-alert)"; fi
# P2: the dispatcher-alert envelope's embedded marker MUST read
# surface=dispatcher-alert (NOT the class-default issue-comment).
E13J=$(extract_marker_json "$(cat "$TMPROOT/e13")")
assert_contains "013 marker surface=dispatcher-alert (P2)" '"surface":"dispatcher-alert"' "$E13J"
assert_not_contains "013 marker NOT mislabeled issue-comment (P2)" '"surface":"issue-comment"' "$E13J"

# TC-ERR-ENVELOPE-014 — transient → no post (regression pin).
make_stub_gh 0; : > "$CALLS"
( set -euo pipefail
  export AUTONOMOUS_CONF_DIR="$TMPROOT/scripts" REPO="o/r"
  source "$LIB"
  error_surface 231 ADT_TRANS p c r "" transient
) 2>"$TMPROOT/e14"; assert_rc "014 transient returns 0" 0 $?
if [[ -s "$CALLS" ]]; then bad "014 transient MUST NOT post a comment"; else ok "014 transient posts nothing (regression pin)"; fi

# ===========================================================================
echo "=== TC-ERR-ENVELOPE-020/021 code registry drift guard ==="
if [[ ! -f "$ERRORS_DOC" ]]; then
  bad "020 docs/pipeline/errors.md MISSING"
else
  ok "020 errors.md present"
  # Collect every code passed as the first arg to error_surface / error_envelope
  # in the dispatcher scripts. The call sites use the literal code token, e.g.
  #   error_surface "$ISSUE_NUMBER" ADT_CFG_MISSING_KEY "..." ...
  #   error_surface "$(error_peek_issue_arg "$@")" ADT_CFG_LAUNCHER_PARSE ...
  # The issue arg may be a literal ("$ISSUE_NUMBER" / -) OR a command
  # substitution containing spaces, so we can't anchor the code right after the
  # function name. Instead: take every line that calls error_surface/
  # error_envelope and pull the `ADT_<UPPER_SNAKE>` code token from it (codes
  # are the only ADT_-prefixed tokens on a call line). This is the docs-drift
  # guard the issue mandates and is robust to the issue-arg form.
  CODES=$(grep -rhoE 'error_(surface|envelope)[^A-Za-z0-9_].*' "$SCRIPTS_DIR" \
            | grep -oE 'ADT_[A-Z0-9_]+' | sort -u)
  if [[ -z "$CODES" ]]; then
    note "020 no error_surface/error_envelope call sites with literal codes found yet"
  fi
  MISSING=0
  while IFS= read -r code; do
    [[ -z "$code" ]] && continue
    # Skip helper-internal tokens that are not error codes.
    case "$code" in CODE|ADT_X|ADT_TRANS) continue ;; esac
    if grep -qE "\b${code}\b" "$ERRORS_DOC"; then
      ok "020 code documented: $code"
    else
      bad "020 code NOT in errors.md (drift): $code"
      MISSING=$((MISSING + 1))
    fi
  done <<< "$CODES"
  # Every code row in errors.md is UPPER_SNAKE.
  BADCODES=$(grep -oE '`[A-Z][A-Za-z0-9_]*`' "$ERRORS_DOC" | tr -d '`' | grep -vE '^[A-Z][A-Z0-9_]*$' || true)
  if [[ -z "$BADCODES" ]]; then ok "021 all errors.md codes are UPPER_SNAKE"; else note "021 non-UPPER_SNAKE backticked tokens (may be prose): $(echo "$BADCODES" | tr '\n' ' ')"; fi

  # REVERSE drift guard: every ADT_* code DOCUMENTED in the registry's table
  # rows MUST be EMITTED by a call site. Catches a documented-but-unwired code
  # (the exact gap that left ADT_CFG_LAUNCHER_PARSE silent pre-review): the
  # forward check (codes-in-scripts ⊆ registry) cannot see it. Scoped to the
  # `ADT_` family so the cross-referenced INV-owned codes named in the Notes
  # section (MODEL_UNKNOWN, AGY_QUOTA_EXHAUSTED, …) are not required to be wired
  # here — those belong to their owning invariants/lanes.
  REGISTRY_CODES=$(grep -oE '`ADT_[A-Z0-9_]+`' "$ERRORS_DOC" | tr -d '`' | sort -u)
  while IFS= read -r rcode; do
    [[ -z "$rcode" ]] && continue
    if echo "$CODES" | grep -qx "$rcode"; then
      ok "020-rev registry code is wired: $rcode"
    else
      bad "020-rev registry code documented but NEVER emitted (drift): $rcode"
    fi
  done <<< "$REGISTRY_CODES"
fi

# TC-ERR-ENVELOPE-022 — INV-72 present + cross-links.
echo "=== TC-ERR-ENVELOPE-022 INV-72 ==="
if grep -qE '^## INV-72:' "$INVARIANTS"; then ok "022 INV-72 defined"; else bad "022 INV-72 MISSING in invariants.md"; fi
if grep -qiE 'error-envelope|errors\.md' "$INVARIANTS"; then ok "022 invariants cross-links the envelope/registry"; else bad "022 invariants does not cross-link envelope/registry"; fi

# ===========================================================================
echo ""
echo "============================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "============================================"
[[ "$FAIL" -eq 0 ]]
