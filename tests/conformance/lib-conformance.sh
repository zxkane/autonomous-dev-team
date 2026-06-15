#!/bin/bash
# lib-conformance.sh — pure helpers for the standalone conformance runner
# (issue #230, INV-74). Carries the manifest field extraction, the four-axis
# PROJECTION (classifier output → AdapterResult axes), and the axis-diff so the
# runner (run-conformance.sh) is a thin orchestrator and these decisions are
# unit-testable in isolation — mirroring the lib-review-*.sh split.
#
# WHY a separate lib
# ------------------
# The runner replays a fixture's recorded process result through the REAL
# classification path (lib-agent-smoke.sh::_smoke_classify + the per-CLI
# _classify_<cli>_drop_reason scrapers — TODAY's monolithic logic, by design:
# pin current behavior so the later adapter extraction must preserve it). The
# pieces that are NOT the production classifier — turning a manifest into inputs,
# turning the classifier's `STATE|reason`/token into the spec's four axes, and
# diffing against the fixture's `expect{}` — are pure functions that need no
# stub CLI / temp dirs, so they live here and are tested directly.
#
# All helpers are rc-0-always / fail-safe: the runner sources them under
# `set -uo pipefail`, and a malformed manifest must surface as a loud FAIL
# (axis/schema diff), never abort the process mid-fixture.
#
# No jq dependency is forced: `_conf_field` prefers jq when present (robust JSON
# parsing) and falls back to a minimal grep/sed extractor for the flat scalar
# fields the manifest schema uses, so the lib is usable in a jq-less environment
# the same way the scrapers are grep-only.

# ---------------------------------------------------------------------------
# _conf_have_jq — rc 0 iff jq is on PATH. Cached in _CONF_HAVE_JQ on first call.
# ---------------------------------------------------------------------------
_CONF_HAVE_JQ="${_CONF_HAVE_JQ:-}"
_conf_have_jq() {
  if [[ -z "$_CONF_HAVE_JQ" ]]; then
    if command -v jq >/dev/null 2>&1; then _CONF_HAVE_JQ=1; else _CONF_HAVE_JQ=0; fi
  fi
  [[ "$_CONF_HAVE_JQ" == "1" ]]
}

# _conf_field <manifest-file> <jq-path>
#
# Echo a scalar field from the manifest. <jq-path> is a jq path WITHOUT the
# leading dot for the grep fallback's sake (e.g. `adapter`, `mode`,
# `command.rc`). Echoes empty for a missing field; rc 0 always.
#
# Prefers jq (`jq -r '.<path> // empty'`). Falls back to a flat grep extractor
# that handles the one-level and `command.<key>` / `input.<key>` two-level
# scalar fields the manifest uses — sufficient because the runner only reads
# scalars through this helper (arrays/objects are read via jq-only paths in the
# runner, which hard-requires jq for materialization).
_conf_field() {
  local file="${1:-}" path="${2:-}"
  [[ -n "$file" && -f "$file" && -r "$file" && -n "$path" ]] || { printf ''; return 0; }
  if _conf_have_jq; then
    jq -r --arg p "$path" '
      ($p | split(".")) as $parts
      | reduce $parts[] as $k (.; if . == null then null else .[$k] end)
      | if . == null then "" else (. | tostring) end
    ' "$file" 2>/dev/null || printf ''
    return 0
  fi
  # jq-less fallback: extract a "<lastkey>": <scalar> pair. Good enough for the
  # flat scalar reads; the runner gates materialization on jq being present.
  local key="${path##*.}"
  grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|-?[0-9]+|true|false)" "$file" 2>/dev/null \
    | head -1 \
    | sed -E "s/\"${key}\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"$//" || printf ''
  return 0
}

# _conf_expect_field <manifest-file> <axis>
#
# Echo one `expect.<axis>` value (`providerClass`|`verdictState`|`vote`|
# `retryable`). Thin wrapper over _conf_field for readability at call sites.
_conf_expect_field() {
  _conf_field "${1:-}" "expect.${2:-}"
}

# _conf_project <agent> <mode> <smoke-state> <scraper-token> <rc>
#
# THE PROJECTION. Map the REAL classifier's output onto the spec's four axes,
# echoing one line `providerClass|verdictState|vote|retryable`. This is the
# only place the §4.4 derivation is reproduced for the projection; it mirrors
# the schema's conditionals exactly so a fixture's `expect{}` (authored against
# the schema) lines up with what the classifier produces.
#
# Inputs:
#   <agent>         — claude|codex|kiro|agy (the adapter under test).
#   <mode>          — dev-new|dev-resume|review|e2e-browser.
#   <smoke-state>   — PASS|FAIL|UNAVAILABLE (the STATE half of _smoke_classify's
#                     `STATE|reason`). Drives the verdict-present axis.
#   <scraper-token> — the per-CLI _classify_<cli>_drop_reason token (e.g.
#                     `quota-exhausted:Resets in 33h48m45s`, `stream-error:5/5`,
#                     `config-error:-s`, `auth-failed`, or empty). Drives the
#                     provider-class axis. Empty for a clean/PASS run.
#   <rc>            — the recorded process exit code. Splits timeout-veto (124/
#                     137) from drop on a review no-verdict.
#
# Derivation (review mode):
#   PASS                      → none / valid / pass / false
#   scraper quota-exhausted*  → quota / absent / drop / false
#   scraper auth-failed       → auth / absent / drop / false
#   scraper config-error*     → config / absent / drop / false
#   scraper stream-error*     → transient / absent / drop / TRUE (retryable)
#   no signal, rc 124/137     → none / absent / timeout-veto / false
#   no signal, other rc       → none / absent / drop / false
# Non-review modes (dev-new/dev-resume/e2e-browser) always vote not-applicable
# (the provider/verdict axes still reflect the run; PASS ⇒ valid, else absent).
#
# rc 0 always.
_conf_project() {
  # <agent> ($1) is part of the documented 5-arg contract and the slot callers
  # pass positionally, but today's §4.4 derivation is agent-independent (it keys
  # on mode/state/token/rc only) — so it is intentionally read but never branched
  # on. shellcheck disable=SC2034: the reserved slot is deliberate, not dead.
  # shellcheck disable=SC2034
  local agent="${1:-}" mode="${2:-}" state="${3:-}" token="${4:-}" rc="${5:-0}"
  local provider verdict vote retryable

  # --- provider + verdict-present axes (mode-independent) ---
  if [[ "$state" == "PASS" ]]; then
    provider="none"; verdict="valid"
  else
    verdict="absent"
    case "$token" in
      quota-exhausted*) provider="quota" ;;
      auth-failed)      provider="auth" ;;
      config-error*)    provider="config" ;;
      stream-error*)    provider="transient" ;;
      *)                provider="none" ;;
    esac
  fi

  # --- retryable axis (spec §4.2: transient retryable; everything else not) ---
  if [[ "$provider" == "transient" ]]; then retryable="true"; else retryable="false"; fi

  # --- voteEligibility axis (spec §4.4 derivation) ---
  case "$mode" in
    review)
      if [[ "$verdict" == "valid" ]]; then
        # A valid verdict decides pass/fail; the FAIL signal is a [P1] review,
        # surfaced by the classifier as a non-PASS state with NO drop-reason
        # token (a substantive FAIL, not an unavailable drop).
        if [[ "$state" == "PASS" ]]; then vote="pass"; else vote="fail"; fi
      elif [[ "$provider" != "none" ]]; then
        # A classified provider failure removes the agent from the vote.
        vote="drop"
      elif [[ "$rc" == "124" || "$rc" == "137" ]]; then
        # No verdict + killed by the wall-clock cap ⇒ deciding FAIL (INV-48).
        vote="timeout-veto"
      else
        # No verdict, not timed out, no provider signal ⇒ unavailable drop.
        vote="drop"
      fi
      ;;
    *)
      # dev-new / dev-resume / e2e-browser do not vote.
      vote="not-applicable"
      ;;
  esac

  printf '%s|%s|%s|%s\n' "$provider" "$verdict" "$vote" "$retryable"
  return 0
}

# _conf_axis_diff <expected-tuple> <actual-tuple>
#
# Both args are `providerClass|verdictState|vote|retryable` tuples. Echo a
# human-readable, single-line diff naming ONLY the axes that differ, e.g.
#   vote: expected=pass actual=drop
# (multiple differing axes are separated by `; `). Echoes empty when the tuples
# are identical (a PASS). rc 0 always.
_conf_axis_diff() {
  local exp="${1:-}" act="${2:-}"
  local -a names=(providerClass verdictState vote retryable)
  local -a ev av
  IFS='|' read -r -a ev <<<"$exp"
  IFS='|' read -r -a av <<<"$act"
  local i diff=""
  for i in 0 1 2 3; do
    if [[ "${ev[$i]:-}" != "${av[$i]:-}" ]]; then
      diff+="${names[$i]}: expected=${ev[$i]:-} actual=${av[$i]:-}; "
    fi
  done
  printf '%s' "${diff%; }"
  return 0
}
