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

# _verdict_body_lane_dir <project> <agent> <issue>
#
# [INV-100] (#355): mints and echoes THIS agent's per-lane scratch DIRECTORY for
# the comment-fallback verdict body — `/tmp/review-<project>-<agent>-<issue>-
# XXXXXX` (mktemp -d). Single source of truth so the fan-out loop's real
# provisioning call and build_review_prompt's legacy-caller self-provisioning
# fallback can never diverge (they previously did — two independently
# hand-rolled mktemp templates with two different fallback chains, one of
# which fell back to an UNTEMPLATED `mktemp -d` whose `/tmp/tmp.XXXXXXXXXX`
# result didn't match the wrapper's own `/tmp/review-*-*-*-??????` cleanup
# glob — a permanently-orphaned dir on that failure path). The only fallback
# here is the bare `/tmp` sentinel, which the cleanup glob already excludes by
# construction (it requires the `review-` prefix), so every branch is either
# glob-matched-and-reaped or knowingly-excluded-and-never-touched — no
# in-between shape that silently orphans.
_verdict_body_lane_dir() {
  local _project="${1:-noproject}" _agent="${2:-agent}" _issue="${3:-0}"
  mktemp -d "/tmp/review-${_project}-${_agent}-${_issue}-XXXXXX" 2>/dev/null || printf '/tmp\n'
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
# Structural fallback when python3-jsonschema is unavailable (the packaged-skill
# default, since the JSON Schema lives outside the skill tree). [P1] #3 (#233
# review): this MUST enforce the FULL schema shape, not just a few top-level
# fields — otherwise a schema-invalid payload (e.g. PASS with `blockingFindings`
# as an object, a finding without `title`, an unknown top-level key) would be
# accepted as `valid` in the default deployment, suppressing the malformed
# envelope. The checks below mirror verdict-artifact.schema.json
# (additionalProperties:false at every level, the finding shape, the typed
# evidence sub-objects, and the FAIL⇔≥1-blocking both-directions conditional):
#   - well-formed JSON object;
#   - ONLY the schema's known top-level keys (additionalProperties:false);
#   - required: schema_version==1, verdict ∈ {PASS,FAIL}, runId/agent non-empty
#     strings; model (if present) a string;
#   - blockingFindings / nonBlockingFindings (if present) are ARRAYS of findings,
#     each an object with a non-empty string `title`, only the known finding keys,
#     and (if present) detail:string / file:string / line:integer>=0;
#   - evidence (if present) an object with only acCoverage / e2eReport, where
#     acCoverage is an object of "pass"|"fail" values and e2eReport.gate ∈
#     {pass,fail,skipped,not-run};
#   - FAIL ⇔ ≥1 blocking finding (both directions).
_validate_verdict_artifact_jq() {
  local _inst="$1"
  jq -e '
    # --- finding shape (shared by blocking + non-blocking) ---
    # INV-92 (#298): five OPTIONAL per-finding classification fields ride the
    # finding object (actionable_by_dev_agent / requires_human /
    # requires_privileged_token / blocking_for_merge : boolean;
    # recommended_next_owner : enum). They are in the allow-list AND type/enum
    # checked here — a malformed classification (non-boolean, bad enum) is a
    # malformed artifact, not silently accepted (Clause V1). Absent ⇒ legacy
    # behavior (this `is_finding` still accepts a {title}-only finding).
    #
    # Issue #449 (R1) [P1 codex review finding]: "severity" (OPTIONAL,
    # P0|P1|P2|P3) is the per-finding severity tag the ratchet reads. Without
    # it in BOTH the allow-list and its own enum check, a non-codex agent
    # that follows the new prompt and writes "severity" into its artifact
    # fails additionalProperties:false on the packaged (schema-less) jq
    # fallback path -- the artifact is downgraded to "malformed" and that
    # vote is lost entirely instead of feeding the severity ratchet.
    def is_finding:
      (type == "object")
      and (has("title") and (.title | type == "string") and ((.title | length) >= 1))
      and ((keys - ["title","detail","file","line","severity","actionable_by_dev_agent","requires_human","requires_privileged_token","blocking_for_merge","recommended_next_owner"]) | length == 0)
      and ((has("detail") | not) or (.detail | type == "string"))
      and ((has("file")   | not) or (.file   | type == "string"))
      and ((has("line")   | not) or (.line   | (type == "number") and (. == floor) and (. >= 0)))
      and ((has("severity") | not) or (.severity | IN("P0","P1","P2","P3")))
      and ((has("actionable_by_dev_agent")   | not) or (.actionable_by_dev_agent   | type == "boolean"))
      and ((has("requires_human")            | not) or (.requires_human            | type == "boolean"))
      and ((has("requires_privileged_token") | not) or (.requires_privileged_token | type == "boolean"))
      and ((has("blocking_for_merge")        | not) or (.blocking_for_merge        | type == "boolean"))
      and ((has("recommended_next_owner")    | not) or (.recommended_next_owner    | IN("dev_agent","human","maintainer")));
    def is_finding_array:
      (type == "array") and (all(.[]; is_finding));
    def is_ac_coverage:
      (type == "object") and (all(.[]; . == "pass" or . == "fail"));
    def is_e2e_report:
      (type == "object")
      and ((keys - ["gate","mode","summary"]) | length == 0)
      and (has("gate") and (.gate | IN("pass","fail","skipped","not-run")))
      and ((has("mode")    | not) or (.mode    | IN("command","browser")))
      and ((has("summary") | not) or (.summary | type == "string"));
    def is_evidence:
      (type == "object")
      and ((keys - ["acCoverage","e2eReport"]) | length == 0)
      and ((has("acCoverage") | not) or (.acCoverage | is_ac_coverage))
      and ((has("e2eReport")  | not) or (.e2eReport  | is_e2e_report));

    (type == "object")
    # additionalProperties:false at the top level.
    and ((keys - ["schema_version","verdict","blockingFindings","nonBlockingFindings","evidence","runId","agent","model"]) | length == 0)
    and has("schema_version") and (.schema_version == 1)
    and has("runId")  and (.runId  | type == "string" and length >= 1)
    and has("agent")  and (.agent  | type == "string" and length >= 1)
    and ((has("model") | not) or (.model | type == "string"))
    and has("verdict") and ((.verdict == "PASS") or (.verdict == "FAIL"))
    and ((has("blockingFindings")    | not) or (.blockingFindings    | is_finding_array))
    and ((has("nonBlockingFindings") | not) or (.nonBlockingFindings | is_finding_array))
    and ((has("evidence") | not) or (.evidence | is_evidence))
    # FAIL ⇔ ≥1 blocking finding (both directions). Guard the length on an ARRAY
    # only — a non-array blockingFindings is already rejected by is_finding_array
    # above, so here `// []` just defaults an ABSENT key.
    and (((.blockingFindings // []) | length) as $n
         | (if .verdict == "FAIL" then $n >= 1 else $n == 0 end))
  ' "$_inst" >/dev/null 2>&1
  local _rc=$?
  # jq rc 0 = the predicate held (valid); rc 1 = predicate false OR jq parse
  # error (malformed JSON). Both map to "not valid" here — rejected.
  [[ "$_rc" -eq 0 ]] && return 0
  return 1
}

# _classify_verdict_artifact <path> [<expected-run-id> [<expected-agent>]]
#
# The §4.3 `verdict.state`. Echoes:
#
#   valid\n<canonical-json>   — schema-pass (AND identity-match when expected
#                               run-id/agent are supplied); line 1 is the state,
#                               line 2..N is the compact canonical JSON.
#   malformed                 — the file exists but fails schema validation, OR
#                               its `.runId`/`.agent` do not match the expected
#                               identity (Clause V1: caller treats this as absent
#                               FOR THE VOTE but surfaces it loudly — never a
#                               silent PASS).
#   absent                    — no file at <path> (the rename hasn't landed, or the
#                               agent never wrote one). A bare `<path>.tmp*` is NOT
#                               the read target, so a torn read is impossible.
#
# TRUE read-once ([P1] #1, #233 review): the bytes are cat'd ONCE into an
# in-memory snapshot, that snapshot is written to a private temp file, and BOTH
# the schema validation and the identity check run against the SNAPSHOT — never a
# second read of `$_path`. So a rename that lands after the first `cat` cannot
# flip the result (it is simply never observed). Clause VA5.
#
# Identity binding ([P1] #2, #233 review): when <expected-run-id> and/or
# <expected-agent> are supplied (the wrapper passes the per-agent session id +
# CLI name), a schema-valid artifact whose `.runId`/`.agent` do NOT equal them is
# classified `malformed` — a buggy adapter that copies example JSON or writes
# another agent's identifiers cannot cast a vote for THIS review slot. Omitting
# the expected args skips the identity check (back-compat; pure-schema callers).
#
# Pure w.r.t. the wrapper's globals; touches only the filesystem (one read of the
# target + one private temp-file write/read of the snapshot).
_classify_verdict_artifact() {
  local _path="$1" _expect_run="${2:-}" _expect_agent="${3:-}"
  if [[ -z "$_path" || ! -f "$_path" ]]; then
    printf 'absent\n'
    return 0
  fi
  # Read once into memory — the snapshot the verdict is derived from. Every
  # subsequent check reads THIS snapshot, never `$_path` again.
  local _bytes
  _bytes="$(cat -- "$_path" 2>/dev/null || true)"
  if [[ -z "${_bytes//[[:space:]]/}" ]]; then
    printf 'malformed\n'   # empty / whitespace-only file is not a verdict
    return 0
  fi

  # Materialize the snapshot to a private temp file so the validators (which take
  # a FILE arg) see exactly the bytes we read — not a possibly-renamed `$_path`.
  local _snap
  _snap="$(mktemp "${TMPDIR:-/tmp}/verdict-snap-XXXXXX" 2>/dev/null || true)"
  if [[ -z "$_snap" ]]; then
    # mktemp failed (full /tmp etc.) — cannot guarantee a stable snapshot to
    # validate. Fail safe: malformed rather than re-reading the racy path.
    printf 'malformed\n'; return 0
  fi
  # Local cleanup of the snapshot regardless of return path.
  printf '%s' "$_bytes" > "$_snap" 2>/dev/null || { rm -f "$_snap" 2>/dev/null; printf 'malformed\n'; return 0; }

  local _schema _valid_rc _ok=1
  _schema="$(_verdict_artifact_schema_file)"
  if _verdict_artifact_have_py && [[ -f "$_schema" ]]; then
    # Self-guard the rc capture: a malformed/rejected artifact is the COMMON case
    # (py exits 1/2), and a bare `cmd; rc=$?` would abort under `set -e` BEFORE the
    # capture if this function were ever called as a bare statement (today every
    # call site uses `$(...)`, which suppresses it — but don't depend on that).
    # `|| _valid_rc=$?` preserves the true rc without tripping errexit.
    _valid_rc=0
    _validate_verdict_artifact_py "$_schema" "$_snap" || _valid_rc=$?
    # rc 2 (unreadable/garbage JSON) is treated as malformed, same as rc 1.
    [[ "$_valid_rc" -eq 0 ]] || _ok=0
  elif command -v jq >/dev/null 2>&1; then
    _validate_verdict_artifact_jq "$_snap" || _ok=0
  else
    # No validation backend at all — extremely unlikely on the dispatcher box (jq
    # is a hard dep). Fail safe: cannot certify the artifact, so treat as
    # malformed rather than trusting unverified bytes (Clause V1 fail-safe).
    _ok=0
  fi

  # Identity binding ([P1] #2): a schema-valid artifact must ALSO carry the
  # runId/agent the wrapper assigned to this slot. Checked against the SAME
  # snapshot. Only applied when the expected values were supplied.
  if [[ "$_ok" -eq 1 ]] && command -v jq >/dev/null 2>&1; then
    local _got_run _got_agent
    _got_run="$(jq -r '.runId // empty'  "$_snap" 2>/dev/null || true)"
    _got_agent="$(jq -r '.agent // empty' "$_snap" 2>/dev/null || true)"
    if [[ -n "$_expect_run"   && "$_got_run"   != "$_expect_run"   ]]; then _ok=0; fi
    if [[ -n "$_expect_agent" && "$_got_agent" != "$_expect_agent" ]]; then _ok=0; fi
  fi

  if [[ "$_ok" -ne 1 ]]; then
    rm -f "$_snap" 2>/dev/null
    printf 'malformed\n'; return 0
  fi

  # Valid — emit the state then the compact canonical JSON (from the SNAPSHOT).
  printf 'valid\n'
  if command -v jq >/dev/null 2>&1; then
    jq -c . "$_snap" 2>/dev/null || printf '%s\n' "$_bytes"
  else
    printf '%s\n' "$_bytes"
  fi
  rm -f "$_snap" 2>/dev/null
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

# _verdict_body_from_artifact_json <canonical-json>
#
# Renders the HUMAN-FACING verdict comment body from a VALIDATED artifact ([P1] #1,
# #233 review round-4). This is the body that populates AGENT_VERDICT_BODIES so the
# wrapper's own rendering paths work when the artifact is the ONLY successful
# channel (the agent's post-verdict.sh comment failed/never landed): LATEST_COMMENT
# becomes non-empty → the Reviewed-HEAD trailer (INV-04) posts and the FAIL branch
# takes the substantive path; and the wrapper can re-post this body via
# post-verdict.sh so the comment-format machine consumers (dispatcher INV-03/06/07,
# dev-resume `Review findings:` parser) keep working.
#
# The FIRST LINE matches exactly what lib-review-poll.sh::_classify_verdict_body
# and post-verdict.sh key on, so a body fed back through post-verdict.sh is NOT
# double-prefixed:
#   PASS → `Review PASSED - …` + optional AC-coverage + non-blocking advisories.
#   FAIL → `Review findings:` + the decision-gate line + a numbered blocking list
#          (`1. **[BLOCKING] <title>** — <detail> (file:line)`), mirroring the
#          wording the wrapper's other FAIL comments use.
#
# Pure (no globals, no API, no _fetch — preserves the zero-comment-poll AC). jq is
# guarded; on no-jq / parse failure it falls back to a minimal-but-classifiable
# deterministic body so it is NEVER empty and NEVER aborts under `set -e`.
_verdict_body_from_artifact_json() {
  local _json="$1" _verdict="" _body=""
  if command -v jq >/dev/null 2>&1; then
    _verdict="$(jq -r '.verdict // empty' <<<"$_json" 2>/dev/null || true)"
  fi

  if [[ "$_verdict" == "PASS" ]]; then
    _body="Review PASSED - verdict from artifact (INV-78); all blocking checks clear."
    if command -v jq >/dev/null 2>&1; then
      # Append a compact AC-coverage line + any non-blocking advisories (best-effort).
      local _ac _nb
      _ac="$(jq -r '
        (.evidence.acCoverage // {}) | to_entries
        | map("- \(.key): \(.value)") | .[]' <<<"$_json" 2>/dev/null || true)"
      [[ -n "$_ac" ]] && _body="${_body}"$'\n\n'"Acceptance criteria coverage:"$'\n'"${_ac}"
      _nb="$(jq -r '
        (.nonBlockingFindings // [])
        | map("- " + .title + (if .file then " (" + .file + (if .line then ":" + (.line|tostring) else "" end) + ")" else "" end)) | .[]' <<<"$_json" 2>/dev/null || true)"
      [[ -n "$_nb" ]] && _body="${_body}"$'\n\n'"Non-blocking advisories:"$'\n'"${_nb}"
    fi
  elif [[ "$_verdict" == "FAIL" ]]; then
    local _findings="" _n=0
    if command -v jq >/dev/null 2>&1; then
      _n="$(jq -r '(.blockingFindings // []) | length' <<<"$_json" 2>/dev/null || echo 0)"
      [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
      _findings="$(jq -r '
        (.blockingFindings // [])
        | to_entries
        | map(
            "\(.key + 1). "
            # Issue #449 (R1): render the OPTIONAL severity field inline as a
            # [P0]-[P3] tag, the SAME token shape the codex/generic free-form
            # paths already emit, so the wrapper severity filter
            # (lib-review-severity.sh _review_extract_highest_severity),
            # which scans this rendered body verbatim, can score an
            # artifact-sourced finding exactly like a free-form one. An
            # absent severity renders NO tag (an untagged finding -- the
            # filter treats that as none, which always blocks, matching
            # this array own pre-#449 unconditional-block behavior).
            + (if .value.severity then "[" + .value.severity + "] " else "" end)
            + "**[BLOCKING] \(.value.title)**"
            + (if .value.detail then " — " + .value.detail else "" end)
            + (if .value.file then " (" + .value.file + (if .value.line then ":" + (.value.line|tostring) else "" end) + ")" else "" end)
            # INV-92 (#298): surface the recommended owner for humans when the
            # agent marked the finding non-actionable by the dev agent (absent
            # field ⇒ dev_agent, so no annotation in the common case).
            + (if (.value.recommended_next_owner // "dev_agent") != "dev_agent" then " [next owner: " + .value.recommended_next_owner + "]" else "" end)
          ) | .[]' <<<"$_json" 2>/dev/null || true)"
    fi
    _body="Review findings:"$'\n\n'"Findings->Decision Gate: ${_n} blocking finding(s) -- FAIL."
    [[ -n "$_findings" ]] && _body="${_body}"$'\n\n'"${_findings}"
  else
    # Unmappable verdict — never silently approve; emit a classifiable FAIL stub.
    _body="Review findings:"$'\n\n'"Findings->Decision Gate: review FAILED (artifact verdict unmappable)."
  fi

  # Single trailing newline normalization; strip stray CRs (the body is posted as
  # a comment, multi-line is fine, but no carriage returns).
  printf '%s\n' "$_body" | tr -d '\r'
}

# _all_artifacts_landed <path...>
#
# Returns 0 iff EVERY argument is a non-empty path STRING that exists as a regular file
# ([P1] #2, #233 review round-4). This is the rename-LAND completion signal: the
# fan-out join early-exits when all per-agent verdict artifacts have landed, so a
# verdict that already landed is not held hostage by an agent that hangs in
# post-verdict.sh / teardown until the wall-clock cap. A bare `<path>.tmp` does
# NOT count (we check the final path only — same no-torn-read guarantee as
# _classify_verdict_artifact). An empty-string arg (an agent with no provisioned
# path) makes it return non-zero — we cannot claim "all landed" when a slot has no
# target. Pure: only `[[ -f ]]` stats, no command substitution, no `set -e` hazard.
_all_artifacts_landed() {
  [[ "$#" -gt 0 ]] || return 1
  local _p
  for _p in "$@"; do
    [[ -n "$_p" && -f "$_p" ]] || return 1
  done
  return 0
}

# _freeze_landed_artifact <live-path> <snapshot-path>
#
# Clause VA5 first-land freeze ([P1] #2, #233 review round-5). The observe loop
# calls this every round for each agent. Behavior:
#   - live file absent → no-op (rc 0); the artifact hasn't landed yet.
#   - live present, snapshot ABSENT → copy the live bytes to the snapshot ONCE
#     (the FIRST land wins) and echo `frozen` on stdout.
#   - live present, snapshot ALREADY exists → the first land is already frozen.
#     If the live bytes now DIFFER from the frozen snapshot, a duplicate/late `mv`
#     landed AFTER first-land: echo `duplicate` (the caller logs it once) and do
#     NOT re-copy — the first-landed bytes remain authoritative. If identical,
#     echo nothing (steady state).
# Best-effort + rc-0-always: every `cp`/`cmp` is guarded so a transient FS error
# (full disk, unlink race) can NEVER abort the caller under `set -euo pipefail`
# (which would strand the issue in `reviewing`). A failed copy simply leaves the
# snapshot absent → the resolution loop falls back to reading the live path
# (today's behavior for that one agent), never a crash.
_freeze_landed_artifact() {
  local _live="$1" _snap="$2"
  [[ -n "$_live" && -n "$_snap" && -f "$_live" ]] || return 0
  if [[ ! -f "$_snap" ]]; then
    ( umask 077; cp -- "$_live" "$_snap" ) 2>/dev/null || true
    [[ -f "$_snap" ]] && printf 'frozen\n'
    return 0
  fi
  # Snapshot already taken — detect a post-land rewrite.
  if ! cmp -s -- "$_live" "$_snap" 2>/dev/null; then
    printf 'duplicate\n'
  fi
  return 0
}

# _artifact_schema_error <path> [<expected-run-id> [<expected-agent>]]
#
# Echoes a SINGLE-LINE, sanitized human summary of why <path> failed validation —
# for the malformed-verdict error envelope (#231). Best-effort: returns the first
# python3-jsonschema error message when available, else a generic jq-derived
# reason, else a bare "schema validation failed". Never multi-line (the envelope
# is a single operator-facing field); control chars are stripped.
#
# Identity ([P1] #2): when expected run-id/agent are supplied AND the artifact is
# otherwise schema-valid but its `.runId`/`.agent` mismatch, the reason names the
# IDENTITY mismatch (the schema validator would report no error) so the operator
# sees the real cause (a foreign-identity vote attempt), not a generic message.
_artifact_schema_error() {
  local _path="$1" _expect_run="${2:-}" _expect_agent="${3:-}" _schema _msg=""
  _schema="$(_verdict_artifact_schema_file)"
  # Identity mismatch first ([P1] #2): if expected run-id/agent were supplied and
  # the artifact carries DIFFERENT values, the schema validators find no error, so
  # name the identity mismatch explicitly (a foreign-identity vote attempt).
  if [[ ( -n "$_expect_run" || -n "$_expect_agent" ) ]] && command -v jq >/dev/null 2>&1; then
    local _gr _ga
    _gr="$(jq -r '.runId // empty'  "$_path" 2>/dev/null || true)"
    _ga="$(jq -r '.agent // empty' "$_path" 2>/dev/null || true)"
    if [[ -n "$_expect_run" && "$_gr" != "$_expect_run" ]]; then
      _msg="identity mismatch: artifact runId='${_gr}' != expected '${_expect_run}'"
    elif [[ -n "$_expect_agent" && "$_ga" != "$_expect_agent" ]]; then
      _msg="identity mismatch: artifact agent='${_ga}' != expected '${_expect_agent}'"
    fi
  fi
  if [[ -z "$_msg" ]] && _verdict_artifact_have_py && [[ -f "$_schema" ]]; then
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
