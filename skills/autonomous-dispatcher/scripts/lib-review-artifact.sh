#!/bin/bash
# lib-review-artifact.sh — INV-78 verdict-artifact channel for the review wrapper
# (issue #233).
#
# Background. A review agent's PASS/FAIL verdict has, until now, traveled to the
# wrapper through a GitHub COMMENT: the wrapper polls the issue comments, matches
# the agent's verdict by actor + time-window + the `Review Session:` (INV-20) /
# `Review Agent:` (INV-40) trailers, and classifies the first line
# (`Review PASSED` / `Review findings:`, lib-review-poll.sh::_classify_verdict_body).
# That comment-as-channel is the root of a long incident tail — double-posts,
# silent non-posts (the agy INV-56 bug), narration false-convergence
# (codex INV-51/53), and comment-propagation lag (INV-43 poll-budget scaling).
#
# This lib makes the wrapper read the verdict as a typed FILE — the adapter-spec
# v1 verdict artifact (#229 / INV-66, §5), conforming to
# docs/pipeline/schemas/verdict-artifact.schema.json. The agent writes the
# artifact atomically (tmp + rename) to a per-agent path the wrapper provisions;
# the wrapper reads + validates it FIRST and only falls back to comment scraping
# (with a logged `verdict-source=comment-fallback` marker) when no artifact
# landed. An artifact file has no actor ambiguity and no propagation delay, and
# schema validation makes a malformed verdict a LOUD, distinct state (never a
# silent absent — Clause V1).
#
# This change moves the verdict CHANNEL, NOT the absence model: a no-artifact
# agent (`absent`) keeps today's bounded-retry/drop semantics (INV-43/INV-48 via
# the comment fallback + the post-window sweep). Removal of the comment fallback
# is deferred to #228 metrics (when fallback rate is ~0 across the fleet).
#
# Pure + sourceable (mirrors lib-review-poll.sh / lib-review-aggregate.sh) so the
# classification is unit-testable in isolation, without spawning the wrapper.
#
# Validation backend mirrors tests/unit/test-adapter-spec-schemas.sh: prefer
# `python3 -m jsonschema` (full Draft-07 — incl. the FAIL⇔≥1-blocking
# conditionals), fall back to a `jq` structural check, so the lib runs on bare CI
# (ci.yml's ubuntu-latest) either way.

# _verdict_artifact_dir <project> <run-id>
#
# Echoes the per-agent-run artifact DIRECTORY:
#   ${XDG_STATE_HOME:-$HOME/.local/state}/autonomous-<project>/runs/<run-id>
#
# Single source of truth for the path so the provisioner (which mkdir's it +
# exports VERDICT_ARTIFACT_PATH) and the reader (which classifies it) can never
# diverge. XDG-state base mirrors lib-config.sh::pid_dir_for_project so artifacts
# live alongside the pipeline's other per-run state, not in world-readable /tmp.
_verdict_artifact_dir() {
  local _project="$1" _run_id="$2"
  local _base="${XDG_STATE_HOME:-$HOME/.local/state}"
  printf '%s/autonomous-%s/runs/%s\n' "$_base" "$_project" "$_run_id"
}

# _verdict_artifact_path <project> <run-id> <agent>
#
# Echoes the per-agent verdict artifact FILE path:
#   <dir>/verdict-<agent>.json
# (Clause VA4 identity: <run-id> is the minted Review Session UUID, INV-20; the
# per-agent name keeps a multi-codex fleet's files distinct under one run dir.)
_verdict_artifact_path() {
  local _project="$1" _run_id="$2" _agent="$3"
  printf '%s/verdict-%s.json\n' "$(_verdict_artifact_dir "$_project" "$_run_id")" "$_agent"
}

# _verdict_artifact_schema_file — resolve the verdict-artifact JSON Schema.
# Honors an explicit VERDICT_ARTIFACT_SCHEMA override (tests + the conformance
# runner set it), else resolves it relative to this lib
# (…/scripts → ../../../docs/pipeline/schemas).
# Echoes the path (may not exist — callers degrade to the jq structural check).
#
# PACKAGING NOTE (deployed skill): the schema lives under the repo's `docs/`
# tree, OUTSIDE `skills/autonomous-dispatcher/`. `npx skills add` copies only the
# skill directory, so on a packaged install (the lib sourced from
# ~/.agents/skills/autonomous-dispatcher/scripts/) `../../../docs/...` does NOT
# resolve and `[[ -f "$_schema" ]]` is false → _classify_verdict_artifact uses the
# `jq` structural fallback (not the python Draft-07 path) for the whole fleet.
# This is BY DESIGN and not a degradation: _validate_verdict_artifact_jq enforces
# every LOAD-BEARING rule the schema's negative fixtures pin (schema_version==1,
# verdict ∈ {PASS,FAIL}, the FAIL⇔≥1-blocking both-directions conditional, and
# non-empty runId/agent). The richer python path is exercised IN CI (where the
# repo `docs/` tree is present) by the unit + conformance suites, which set
# VERDICT_ARTIFACT_SCHEMA explicitly. An operator who wants the full Draft-07
# graph live in prod can `export VERDICT_ARTIFACT_SCHEMA=<path-to-schema>`.
_verdict_artifact_schema_file() {
  if [[ -n "${VERDICT_ARTIFACT_SCHEMA:-}" ]]; then
    printf '%s\n' "$VERDICT_ARTIFACT_SCHEMA"
    return 0
  fi
  local _dir
  _dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  printf '%s/../../../docs/pipeline/schemas/verdict-artifact.schema.json\n' "$_dir"
}

# _verdict_artifact_have_py — 0/echo if python3 + jsonschema are importable.
_verdict_artifact_have_py() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1
}

# _validate_verdict_artifact_py <schema> <instance> — rc 0 valid / 1 rejected /
# 2 error (unreadable JSON). Full Draft-07 (mirrors test-adapter-spec-schemas.sh).
_validate_verdict_artifact_py() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    from jsonschema import Draft7Validator
    schema = json.load(open(sys.argv[1]))
    inst = json.load(open(sys.argv[2]))
except Exception:
    sys.exit(2)
errs = list(Draft7Validator(schema).iter_errors(inst))
sys.exit(1 if errs else 0)
PY
}

# _validate_verdict_artifact_jq <instance> — rc 0 valid / 1 rejected / 2 error.
# Structural fallback when python3-jsonschema is unavailable. Cannot run the full
# Draft-07 conditional graph, but enforces the load-bearing rules the spec's
# negative fixtures pin:
#   - well-formed JSON object;
#   - required keys present: schema_version, verdict, runId, agent;
#   - schema_version == 1;
#   - verdict ∈ {PASS, FAIL};
#   - FAIL ⇔ ≥1 blocking finding (both directions): FAIL+empty-blocking rejected,
#     PASS+non-empty-blocking rejected;
#   - runId / agent non-empty strings.
_validate_verdict_artifact_jq() {
  local _inst="$1"
  jq -e '
    (type == "object")
    and has("schema_version") and (.schema_version == 1)
    and has("runId")  and (.runId  | type == "string" and length >= 1)
    and has("agent")  and (.agent  | type == "string" and length >= 1)
    and has("verdict") and ((.verdict == "PASS") or (.verdict == "FAIL"))
    and (((.blockingFindings // []) | length) as $n
         | (if .verdict == "FAIL" then $n >= 1 else $n == 0 end))
  ' "$_inst" >/dev/null 2>&1
  local _rc=$?
  # jq rc 0 = the predicate held (valid); rc 1 = predicate false OR jq parse
  # error (malformed JSON). Both map to "not valid" here — rejected.
  [[ "$_rc" -eq 0 ]] && return 0
  return 1
}

# _classify_verdict_artifact <path>
#
# The §4.3 `verdict.state`. Reads the file ONCE (Clause VA5: a write that lands
# after this read is never observed — the caller captures this snapshot and does
# not re-stat). Echoes:
#
#   valid\n<canonical-json>   — schema-pass; line 1 is the state, line 2..N is the
#                               compact canonical JSON for the caller to map.
#   malformed                 — the file exists but fails schema validation
#                               (Clause V1: caller treats this as absent FOR THE
#                               VOTE but surfaces it loudly — never a silent PASS).
#   absent                    — no file at <path> (the rename hasn't landed, or the
#                               agent never wrote one). A bare `<path>.tmp*` is NOT
#                               the read target, so a torn read is impossible.
#
# Pure w.r.t. the wrapper's globals; touches only the filesystem (one read).
_classify_verdict_artifact() {
  local _path="$1"
  if [[ -z "$_path" || ! -f "$_path" ]]; then
    printf 'absent\n'
    return 0
  fi
  # Read once into memory — the snapshot the verdict is derived from. A later
  # write to the same path replaces the bytes on disk but not this snapshot.
  local _bytes
  _bytes="$(cat -- "$_path" 2>/dev/null || true)"
  if [[ -z "${_bytes//[[:space:]]/}" ]]; then
    printf 'malformed\n'   # empty / whitespace-only file is not a verdict
    return 0
  fi

  local _schema _valid_rc
  _schema="$(_verdict_artifact_schema_file)"
  if _verdict_artifact_have_py && [[ -f "$_schema" ]]; then
    _validate_verdict_artifact_py "$_schema" "$_path"
    _valid_rc=$?
    # rc 2 (unreadable/garbage JSON) is treated as malformed, same as rc 1.
    [[ "$_valid_rc" -eq 0 ]] || { printf 'malformed\n'; return 0; }
  elif command -v jq >/dev/null 2>&1; then
    if ! _validate_verdict_artifact_jq "$_path"; then
      printf 'malformed\n'; return 0
    fi
  else
    # No validation backend at all — extremely unlikely on the dispatcher box (jq
    # is a hard dep). Fail safe: cannot certify the artifact, so treat as
    # malformed rather than trusting unverified bytes (Clause V1 fail-safe).
    printf 'malformed\n'; return 0
  fi

  # Valid — emit the state then the compact canonical JSON for the caller.
  printf 'valid\n'
  if command -v jq >/dev/null 2>&1; then
    jq -c . <<<"$_bytes" 2>/dev/null || printf '%s\n' "$_bytes"
  else
    printf '%s\n' "$_bytes"
  fi
}

# _verdict_from_artifact_json <canonical-json>
#
# Maps a VALIDATED artifact's `verdict` field onto the _aggregate_review_verdicts
# token vocabulary: PASS→pass, FAIL→fail. Echoes empty on anything else (defensive
# — only ever called on a `valid` artifact, where the schema already constrained
# the field to PASS/FAIL).
_verdict_from_artifact_json() {
  local _json="$1" _v=""
  if command -v jq >/dev/null 2>&1; then
    _v="$(jq -r '.verdict // empty' <<<"$_json" 2>/dev/null || true)"
  fi
  case "$_v" in
    PASS) printf 'pass\n' ;;
    FAIL) printf 'fail\n' ;;
    *)    printf '\n' ;;
  esac
}

# _artifact_schema_error <path>
#
# Echoes a SINGLE-LINE, sanitized human summary of why <path> failed validation —
# for the malformed-verdict error envelope (#231). Best-effort: returns the first
# python3-jsonschema error message when available, else a generic jq-derived
# reason, else a bare "schema validation failed". Never multi-line (the envelope
# is a single operator-facing field); control chars are stripped.
_artifact_schema_error() {
  local _path="$1" _schema _msg=""
  _schema="$(_verdict_artifact_schema_file)"
  if _verdict_artifact_have_py && [[ -f "$_schema" ]]; then
    _msg="$(python3 - "$_schema" "$_path" <<'PY' 2>/dev/null || true
import json, sys
try:
    from jsonschema import Draft7Validator
    schema = json.load(open(sys.argv[1]))
    inst = json.load(open(sys.argv[2]))
except Exception as e:
    print(f"unreadable artifact JSON: {e}")
    sys.exit(0)
errs = sorted(Draft7Validator(schema).iter_errors(inst), key=lambda e: list(e.path))
if errs:
    print(errs[0].message)
PY
)"
  fi
  if [[ -z "$_msg" ]]; then
    # jq-derived best-effort reason (when python is unavailable).
    if command -v jq >/dev/null 2>&1; then
      if ! jq -e . "$_path" >/dev/null 2>&1; then
        _msg="not well-formed JSON"
      elif ! jq -e 'has("schema_version") and (.schema_version == 1)' "$_path" >/dev/null 2>&1; then
        _msg="missing or non-1 schema_version"
      elif ! jq -e '(.verdict == "PASS") or (.verdict == "FAIL")' "$_path" >/dev/null 2>&1; then
        _msg="verdict not in {PASS, FAIL}"
      else
        _msg="FAIL/blockingFindings consistency violated (FAIL needs >=1 blocking finding; PASS needs none)"
      fi
    fi
  fi
  [[ -n "$_msg" ]] || _msg="schema validation failed"
  # Single line, no control chars (the envelope field is one line).
  printf '%s\n' "$_msg" | tr -d '\r' | tr '\n' ' ' | sed -e 's/[[:cntrl:]]//g' -e 's/  */ /g' -e 's/ *$//'
}
