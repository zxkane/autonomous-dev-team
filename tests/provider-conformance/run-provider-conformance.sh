#!/bin/bash
# run-provider-conformance.sh — hermetic, provider-parameterized conformance
# runner for the ITP/CHP provider verbs (issue #370, #347 W2, INV-106).
#
#   bash tests/provider-conformance/run-provider-conformance.sh \
#     [--itp <name>] [--chp <name>]
#
# Both flags default to `github`; env fallbacks ITP_UNDER_TEST/CHP_UNDER_TEST
# apply when a flag is omitted (so a caller can pin the axes via env instead
# of argv). `--itp`/`--chp` are two INDEPENDENT selection axes — matching the
# repo's own ISSUE_PROVIDER/CODE_HOST split — because lib-issue-provider.sh
# and lib-code-host.sh each read the SHARED AUTONOMOUS_PROVIDERS_DIR env var
# at source time but look for differently-prefixed files (itp-<name>.{sh,caps}
# vs chp-<name>.{sh,caps}); this runner materializes ONE scratch provider dir
# per run containing symlinks for BOTH axes so a single AUTONOMOUS_PROVIDERS_DIR
# resolves them independently (see lib-provider-conformance.sh::pcf_materialize_scratch).
#
# WHAT IT DOES
# ------------
#   1. Resolve --itp/--chp to their source provider dirs (github / degraded /
#      broken — the fixed table in lib-provider-conformance.sh).
#   2. Materialize a scratch provider dir + an isolated-PATH stub `gh` (the
#      INV-74 discipline: stub dir + the dirs hosting bash/coreutils/jq/
#      grep/sed — the real `gh` NEVER resolvable).
#   3. For each ASSERTED verb (cap-map.conf), read its governing capability
#      through the public seam (itp_caps/chp_caps) BEFORE asserting: cap=0
#      -> SKIP (never FAIL, never silent); cap=1 or `-` -> assert for real.
#   4. Assert per the verb's documented shape (lib-provider-conformance.sh
#      has the pure helpers; this script drives them against a real `gh`
#      stub + the real dispatch libs, in an isolated subshell per verb so a
#      missing/broken leaf FAILs that one verb, never aborts the runner).
#   5. Report the CONTRACT-PENDING tripwire (coverage.conf `pending` set vs
#      provider-spec.md's CONTRACT-PENDING-tokened rows — a plain grep
#      set-diff, no markdown parsing).
#
# OUTPUT
# ------
#   CONFORMANCE-PCONF <itp>/<chp> <verb> PASS
#   CONFORMANCE-PCONF <itp>/<chp> <verb> FAIL <reason>
#   CONFORMANCE-PCONF <itp>/<chp> <verb> SKIP (cap: <name>)
#   CONFORMANCE-PCONF <itp>/<chp> <verb> PENDING (coverage.conf)
#   CONFORMANCE-COVERAGE PASS|FAIL <reason>
#   CONFORMANCE-SUMMARY total=N pass=N fail=N skip=N pending=N
# Non-zero exit on ANY FAIL (verb assertion or coverage tripwire).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$SCRIPT_DIR/lib-provider-conformance.sh"
COVERAGE_CONF="$SCRIPT_DIR/coverage.conf"
CAP_MAP_CONF="$SCRIPT_DIR/cap-map.conf"
SPEC_MD="$PROJECT_ROOT/docs/pipeline/provider-spec.md"
PAYLOADS="$SCRIPT_DIR/fixtures/payloads"
ITP_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-issue-provider.sh"
CHP_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-code-host.sh"
DEV_SH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

log() { printf '%s\n' "$*" >&2; }

[[ -f "$LIB" ]] || { log "FATAL: lib-provider-conformance.sh not found at $LIB"; exit 2; }
# shellcheck source=lib-provider-conformance.sh
source "$LIB"

command -v jq >/dev/null 2>&1 || { log "FATAL: jq is required to run the provider conformance suite"; exit 2; }

ITP_NAME="${ITP_UNDER_TEST:-github}"
CHP_NAME="${CHP_UNDER_TEST:-github}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --itp) [[ $# -ge 2 ]] || { log "FATAL: --itp requires a value"; exit 2; }; ITP_NAME="$2"; shift 2 ;;
    --itp=*) ITP_NAME="${1#*=}"; shift ;;
    --chp) [[ $# -ge 2 ]] || { log "FATAL: --chp requires a value"; exit 2; }; CHP_NAME="$2"; shift 2 ;;
    --chp=*) CHP_NAME="${1#*=}"; shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log "FATAL: unknown argument: $1"; exit 2 ;;
  esac
done

ITP_SRC_DIR="$(pcf_resolve_provider_dir "$PROJECT_ROOT" "$ITP_NAME")" \
  || { log "FATAL: unknown --itp provider '$ITP_NAME'"; exit 2; }
CHP_SRC_DIR="$(pcf_resolve_provider_dir "$PROJECT_ROOT" "$CHP_NAME")" \
  || { log "FATAL: unknown --chp provider '$CHP_NAME'"; exit 2; }

work_root=""
cleanup() { rm -rf "${work_root:-}" 2>/dev/null || true; }
trap cleanup EXIT

work_root="$(mktemp -d "${TMPDIR:-/tmp}/provider-conformance-XXXXXX")" || { log "FATAL: mktemp -d failed"; exit 2; }
SCRATCH_DIR="$work_root/providers"
STUB_DIR="$work_root/stub"
mkdir -p "$SCRATCH_DIR" "$STUB_DIR"

pcf_materialize_scratch "$SCRATCH_DIR" "$ITP_NAME" "$ITP_SRC_DIR" "$CHP_NAME" "$CHP_SRC_DIR"

ISOLATED_PATH="$(pcf_isolated_path "$STUB_DIR")"

# ---------------------------------------------------------------------------
# Stub `gh` — control-file driven (per-invocation success/fail), records the
# exact argv it received (ONE ARG PER LINE, the same shape
# test-itp-read-leaves.sh's recording `gh()` mock uses — the runner reads it
# back space-joined via `paste -sd' '`). Installed once; every verb assertion
# below (each its own subshell) sets $_PCF_GH_MODE ("ok"|"fail") and
# $_PCF_GH_PAYLOAD (a file path holding the RAW pre-transform JSON a real
# `gh` would emit) before invoking a verb. On success, if the recorded argv
# carries `-q` or `--jq`, the stub applies that filter to the payload with
# jq — mirroring `gh`'s own behavior — so a leaf's OWN jq transform (e.g.
# itp_github_list_comments' id-extraction/sort) is genuinely exercised, not
# bypassed. Without `-q`/`--jq` the raw payload is echoed verbatim.
#
# [#396 review r2] `itp_github_read_task` issues a SECOND, distinct `gh api`
# call (via `itp_github_list_comments`) when `comments` is requested — a
# different subcommand shape than the primary `gh issue view --json …`
# payload. `$_PCF_GH_COMMENTS_PAYLOAD` (a separate file path) serves that
# second call; unset/empty defaults to `[[]]` (an empty REST page set, valid
# --slurp input) so verbs that don't set it still see a well-shaped reply.
#
# The `itp_github_provision_states` existence PROBE (`gh api
# repos/.../labels/<name> --silent`) is a special case: it is FORCED to fail
# (not-found) regardless of $_PCF_GH_MODE, so the leaf deterministically
# takes its `gh label create` branch — the branch this suite's write-assert
# actually exercises. (The skip-branch is GitHub-specific behavior already
# pinned by test-itp-write-leaves.sh; out of scope for this focused verb
# conformance check.)
# ---------------------------------------------------------------------------
_STUB_GH="$STUB_DIR/gh"
cat > "$_STUB_GH" <<'STUB'
#!/bin/bash
# Hermetic stub for `gh` (provider-conformance verb replay).
printf '%s\n' "$@" > "${_PCF_ARGV_FILE:?}"
for _a in "$@"; do
  case "$_a" in
    */labels/*) exit 1 ;;   # force the itp_provision_states existence probe not-found
  esac
done
if [[ "${_PCF_GH_MODE:-ok}" == "fail" ]]; then
  printf 'stub-gh: simulated failure\n' >&2
  exit 1
fi
if [[ "${1:-}" == "api" && "${2:-}" == "--paginate" ]]; then
  # itp_read_task's nested itp_github_list_comments call needs a REST
  # page-set shape distinct from the primary `issue view` payload — served
  # from $_PCF_GH_COMMENTS_PAYLOAD when the caller sets it. Callers that
  # exercise itp_list_comments DIRECTLY (this IS its only gh call) keep
  # serving it from $_PCF_GH_PAYLOAD, so they need no change.
  _cpayload="${_PCF_GH_COMMENTS_PAYLOAD:-}"
  if [[ -n "$_cpayload" && -f "$_cpayload" ]]; then
    cat "$_cpayload"
  elif [[ -n "${_PCF_GH_PAYLOAD:-}" && -f "${_PCF_GH_PAYLOAD:-}" ]]; then
    cat "$_PCF_GH_PAYLOAD"
  else
    printf '[[]]'
  fi
  exit 0
fi
_payload="${_PCF_GH_PAYLOAD:-}"
[[ -n "$_payload" && -f "$_payload" ]] || { printf ''; exit 0; }
_q=""
_prev=""
for _a in "$@"; do
  if [[ "$_prev" == "-q" || "$_prev" == "--jq" ]]; then _q="$_a"; break; fi
  _prev="$_a"
done
if [[ -n "$_q" ]]; then
  "$_PCF_JQ_BIN" -r "$_q" < "$_payload"
else
  cat "$_payload"
fi
exit 0
STUB
chmod +x "$_STUB_GH"
export _PCF_JQ_BIN="$(command -v jq)"

# _recorded_argv <file> — one-arg-per-line -> single space-joined line
# (mirrors test-itp-read-leaves.sh's recorded_argv() helper).
_recorded_argv() { [[ -f "$1" ]] && paste -sd' ' "$1" || printf ''; }

# Some leaves (itp_github_label_event_ts) call `jq` directly (not through
# `gh`) to JSON-encode an arg. The real `jq` is reachable via the isolated
# PATH (pcf_isolated_path includes jq's dir), so those leaves work unmodified.

TOTAL=0; PASS_N=0; FAIL_N=0; SKIP_N=0; PENDING_N=0

emit() {
  local status="$1" verb="$2" reason="${3:-}"
  # Flatten embedded newlines (a captured leaf's multi-line JSON/error output)
  # so every CONFORMANCE-PCONF record is exactly one line — load-bearing for
  # any downstream grep/count over the runner's output (incl. this file's own
  # tripwire's "one FAIL line per violated clause" AC).
  reason="${reason//$'\n'/ }"
  TOTAL=$((TOTAL + 1))
  case "$status" in
    PASS) PASS_N=$((PASS_N + 1)); printf 'CONFORMANCE-PCONF %s/%s %s PASS\n' "$ITP_NAME" "$CHP_NAME" "$verb" ;;
    FAIL) FAIL_N=$((FAIL_N + 1)); printf 'CONFORMANCE-PCONF %s/%s %s FAIL %s\n' "$ITP_NAME" "$CHP_NAME" "$verb" "$reason" ;;
    SKIP) SKIP_N=$((SKIP_N + 1)); printf 'CONFORMANCE-PCONF %s/%s %s SKIP (cap: %s)\n' "$ITP_NAME" "$CHP_NAME" "$verb" "$reason" ;;
  esac
}

# _seam_for <verb> — echo "itp" or "chp" based on the verb's name prefix.
_seam_for() { case "$1" in itp_*) echo itp ;; chp_*) echo chp ;; esac; }

# _cap_read <verb> — read the verb's governing cap value through the public
# seam for the CURRENTLY SELECTED provider (ITP_NAME/CHP_NAME), or empty for
# governing cap `-`. rc 1 if the cap itself is unreadable (treated as "not
# gated" by the caller — an unreadable cap must never silently SKIP a verb
# that should be asserted).
_cap_read() {
  local verb="$1" cap="$2" seam
  [[ "$cap" == "-" ]] && return 1
  seam="$(_seam_for "$verb")"
  env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      ISSUE_PROVIDER="$ITP_NAME" CODE_HOST="$CHP_NAME" AUTONOMOUS_PROVIDERS_DIR="$SCRATCH_DIR" \
      PATH="$ISOLATED_PATH" \
  bash -c '
    source "'"$ITP_LIB"'" 2>/dev/null
    source "'"$CHP_LIB"'" 2>/dev/null
    '"${seam}"'_caps "'"$cap"'" 2>/dev/null
  '
}

# _invoke <extra_env...> <script> — run SCRIPT (the last arg) in a fresh bash
# under `set -euo pipefail`, with the given extra env vars exported and the
# isolated PATH + provider seam vars always set. The invoked VERB call MUST
# be the script's LAST statement so, under `set -e`, its own exit code
# becomes bash's own exit code — captured cleanly via `out=$(...); rc=$?`
# (the [INV-74]-style "echo RC=$? after the call" pattern is fragile here:
# under `set -e` a failing call aborts the script BEFORE that echo runs, so
# the marker never appears). `set -e` also makes this invocation faithfully
# match production (every real caller of an itp_*/chp_* verb — e.g.
# setup-labels.sh, lib-dispatch.sh — runs under `set -euo pipefail`), so an
# entangled function like itp_provision_states (whose OWN body does not
# propagate a failed `gh label create`'s rc past its trailing `echo` unless
# the caller aborts via `set -e`) is exercised the same way production
# exercises it — never a false FAIL from testing it bare.
_invoke() {
  local script="${*: -1}"
  local -a extra_env=("${@:1:$#-1}")
  env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      ISSUE_PROVIDER="$ITP_NAME" CODE_HOST="$CHP_NAME" AUTONOMOUS_PROVIDERS_DIR="$SCRATCH_DIR" \
      REPO="o/r" REPO_OWNER="o" REPO_NAME="r" \
      PATH="$ISOLATED_PATH" \
      "${extra_env[@]}" \
  bash -c '
    set -euo pipefail
    source "'"$ITP_LIB"'" 2>/dev/null
    source "'"$CHP_LIB"'" 2>/dev/null
    '"$script"'
  '
}

# _run_write_assert <verb> <argv_pattern> [extra_argv] — drive VERB once with
# the stub gh succeeding (assert rc 0 + argv matches ARGV_PATTERN, a
# fixed-string grep needle) and once with the stub failing (assert rc != 0,
# no partial stdout). Returns 0/prints PASS or FAIL via emit().
_run_write_assert() {
  local verb="$1" argv_needle="$2" extra_argv="${3:-}"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc

  out="$(_invoke _PCF_GH_MODE="ok" _PCF_ARGV_FILE="$argv_file" "$verb $extra_argv" 2>&1)"; rc=$?
  local recorded=""; recorded="$(_recorded_argv "$argv_file")"
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "expected rc 0 on stub-success, got rc=$rc (output: ${out:0:200})"
    return
  fi
  if [[ -n "$argv_needle" && "$recorded" != *"$argv_needle"* ]]; then
    emit FAIL "$verb" "argv-mismatch (expected substring '$argv_needle', recorded: $recorded)"
    return
  fi
  rm -f "$argv_file"

  out="$(_invoke _PCF_GH_MODE="fail" _PCF_ARGV_FILE="$argv_file" "$verb $extra_argv" 2>&1)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (stub gh failed but verb still returned 0)"
    return
  fi
  emit PASS "$verb"
}

# _run_failsoft_assert <verb> <invoke_snippet> <expect_regex> — drive VERB
# with the stub gh failing and assert rc 0 (fail-soft contract) + output
# matches EXPECT_REGEX (typically "^$" for empty).
_run_failsoft_assert() {
  local verb="$1" invoke_snippet="$2" expect_regex="$3"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc

  out="$(_invoke _PCF_GH_MODE="fail" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "fail-soft contract violated: expected rc 0 on stub-failure, got rc=$rc (output: ${out:0:200})"
    return
  fi
  if ! [[ "$out" =~ $expect_regex ]]; then
    emit FAIL "$verb" "fail-soft output mismatch (got: ${out:0:200})"
    return
  fi
  emit PASS "$verb"
}

# _run_shape_assert <verb> <invoke_snippet> <payload_file> <check_ascending> —
# invoke VERB with a VALID canned payload, assert JSON-array shape (+ ascending
# order when check_ascending is "createdAt" or "number"); then invoke with a
# MALFORMED payload and assert graceful (empty, no crash) output.
_run_shape_assert() {
  local verb="$1" invoke_snippet="$2" payload_file="$3" check_ascending="${4:-0}"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc

  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$payload_file" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "wrong-shape (non-zero rc on a valid payload: $rc, output: ${out:0:200})"
    return
  fi
  if ! pcf_is_json_array "$out"; then
    emit FAIL "$verb" "wrong-shape (output is not a JSON array: ${out:0:200})"
    return
  fi
  if [[ "$check_ascending" == "1" || "$check_ascending" == "createdAt" ]] && ! pcf_is_ascending_by_created_at "$out"; then
    emit FAIL "$verb" "not sorted ascending by createdAt"
    return
  fi
  if [[ "$check_ascending" == "number" ]] && ! pcf_is_ascending_by_number "$out"; then
    emit FAIL "$verb" "not sorted ascending by number"
    return
  fi

  # Malformed-JSON handling: same invoke, a payload that is NOT valid JSON.
  local malformed="$work_root/.malformed-$verb.json"
  printf '{ this is not json' > "$malformed"
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$malformed" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"
  # Graceful handling: the leaf must not emit a valid-looking array from
  # garbage input (empty output on rc 0, or a non-zero rc, are both graceful;
  # only a non-empty valid array is a real bug).
  if pcf_is_json_array "$out" && [[ -n "${out//[[:space:]]/}" ]] && [[ "$out" != "[]" ]]; then
    emit FAIL "$verb" "malformed-JSON input produced a non-empty array (should fail gracefully)"
    return
  fi
  emit PASS "$verb"
}

# _run_object_shape_assert <verb> <invoke_snippet> <payload_file> [comments_payload_file] —
# invoke VERB (which returns a single normalized OBJECT, not an array —
# itp_read_task, issue #396 W1b) with a VALID canned payload and assert
# JSON-object shape + rc 0; then invoke with a MALFORMED payload and assert
# graceful (empty rc≠0, fail-closed per R2) output — NOT the array leaves'
# "empty/[] is graceful" convention, since a single-task read has no
# empty-but-valid representation. [#396 review r2] `comments` is sourced via
# a SEPARATE `gh api` call (`itp_github_list_comments`); COMMENTS_PAYLOAD_FILE
# (a REST `--paginate --slurp` page-set shape) serves that call — defaults to
# an empty page set when omitted.
_run_object_shape_assert() {
  local verb="$1" invoke_snippet="$2" payload_file="$3" comments_payload_file="${4:-}"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc

  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$payload_file" _PCF_GH_COMMENTS_PAYLOAD="$comments_payload_file" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "wrong-shape (non-zero rc on a valid payload: $rc, output: ${out:0:200})"
    return
  fi
  if ! pcf_is_json_object "$out"; then
    emit FAIL "$verb" "wrong-shape (output is not a JSON object: ${out:0:200})"
    return
  fi
  if ! jq -e 'has("labels") and (.labels | type == "array") and (.labels | all(type == "string"))' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "labels not normalized to a name-string array: ${out:0:200}"
    return
  fi
  # Normalized-comments enforcement (#396 review r3): when `comments` is
  # requested, the INV-90 shape must actually hold — every element carries
  # {id, author, authorKind, body, createdAt}, authorKind ∈ self|bot|human,
  # ascending createdAt. Crucially, the REST comments fixture contains
  # `[bot]`-suffixed logins (`"type": "Bot"`); a provider regressing to a
  # GraphQL-style comments source (which strips the suffix and exposes no
  # author type) would classify them authorKind="human" and MUST fail here —
  # without this check a comments-normalization regression sails through and
  # AC5 is not enforced for the field that motivated review r2.
  if ! jq -e '
      has("comments") and (.comments | type == "array")
      and (.comments | all(
            (has("id") and has("author") and has("authorKind") and has("body") and has("createdAt"))
            and (.authorKind | IN("self","bot","human"))
          ))
      and ((.comments | map(.createdAt // "")) as $ts | $ts == ($ts | sort))
    ' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "comments not the INV-90 normalized array (keys/authorKind/ascending): ${out:0:300}"
    return
  fi
  # Bot-classification tripwire: the fixture's `[bot]` logins must classify
  # authorKind="bot" (REST-derived) — never "human" (the GraphQL-source
  # regression this assert exists to catch).
  if ! jq -e '[.comments[] | select(.author | tostring | endswith("[bot]"))] | length > 0 and all(.authorKind == "bot")' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "bot-suffixed comment authors not classified authorKind=bot (GraphQL-source regression): ${out:0:300}"
    return
  fi

  # Fields-subset: a body-only request must return EXACTLY {body}.
  local body_only
  body_only="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$payload_file" _PCF_ARGV_FILE="$argv_file" 'itp_read_task 42 body' 2>&1)"
  if [[ "$(jq -r 'keys_unsorted | join(",")' <<<"$body_only" 2>/dev/null)" != "body" ]]; then
    emit FAIL "$verb" "fields-subset violated: requesting 'body' did not return exactly {body} (got: ${body_only:0:200})"
    return
  fi

  # R2 fail-closed: stub gh fails -> leaf rc≠0, no partial output.
  local fail_rc
  _invoke _PCF_GH_MODE="fail" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" >/dev/null 2>&1; fail_rc=$?
  if [[ "$fail_rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (stub gh failed but verb still returned 0)"
    return
  fi

  # Malformed-JSON handling: fail-CLOSED (non-zero rc), unlike the array
  # leaves' empty/[] convention — a single-task read has no valid "empty" form.
  local malformed mal_rc
  malformed="$work_root/.malformed-$verb.json"
  printf '{ this is not json' > "$malformed"
  _invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$malformed" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" >/dev/null 2>/dev/null; mal_rc=$?
  if [[ "$mal_rc" == "0" ]]; then
    emit FAIL "$verb" "malformed-JSON input produced rc 0 (should fail-closed, non-zero rc)"
    return
  fi
  emit PASS "$verb"
}

# _run_count_assert <verb> <invoke_snippet> <payload_file> — invoke VERB (which
# returns a bare non-negative integer, not an array — itp_count_by_state) with
# a VALID canned payload and assert the output is a bare integer + rc 0; then
# invoke with the stub gh FAILING and assert rc != 0 (fail-closed, no partial
# output — the [M3] int-return distinction, spec §3.1).
_run_count_assert() {
  local verb="$1" invoke_snippet="$2" payload_file="$3"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc

  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$payload_file" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "wrong-shape (non-zero rc on a valid payload: $rc, output: ${out:0:200})"
    return
  fi
  if ! [[ "$out" =~ ^[0-9]+$ ]]; then
    emit FAIL "$verb" "wrong-shape (output is not a bare non-negative integer: '${out:0:200}')"
    return
  fi

  out="$(_invoke _PCF_GH_MODE="fail" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" 2>&1)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (stub gh failed but verb still returned 0)"
    return
  fi
  emit PASS "$verb"
}

# _run_pr_view_assert — chp_pr_view normalized-object assertion (#347 W1c2,
# #398). Invokes with a VALID payload; asserts (i) the output is a JSON object
# (top-level == "object"), (ii) it contains EXACTLY the requested fields (no
# more, no less — a subset projection contract), (iii) `comments`/`reviews`
# are ascending arrays with normalized keys, and (iv) fail-CLOSED on stub-gh
# failure (rc≠0, no partial output). The FIELDS_CSV under test covers every
# vocabulary branch the leaf normalizes (comments+reviews+closingIssueNumbers+
# a 1:1 field + body's null→"" fold) in ONE invocation.
_run_pr_view_assert() {
  local verb="chp_pr_view"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc payload="$PAYLOADS/pr-view-valid.json"

  # Success path — request every vocabulary-covered shape category at once.
  local fields='state,comments,reviews,closingIssueNumbers,body'
  local invoke="chp_pr_view 42 '$fields'"
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$payload" _PCF_ARGV_FILE="$argv_file" "$invoke" 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "wrong-shape (non-zero rc on a valid payload: $rc, output: ${out:0:200})"
    return
  fi
  local top; top="$(jq -r 'type' <<<"$out" 2>/dev/null)"
  if [[ "$top" != "object" ]]; then
    emit FAIL "$verb" "wrong-shape (top-level != object: type=$top, output: ${out:0:200})"
    return
  fi
  # Exact-key projection: keys(out) sorted MUST equal FIELDS_CSV sorted.
  local expected_keys got_keys
  expected_keys="$(printf '%s' "$fields" | tr ',' '\n' | sort -u | paste -sd',' -)"
  got_keys="$(jq -r 'keys | join(",")' <<<"$out" 2>/dev/null)"
  if [[ "$expected_keys" != "$got_keys" ]]; then
    emit FAIL "$verb" "field-subset projection mismatch (expected '$expected_keys', got '$got_keys')"
    return
  fi
  # comments/reviews normalization: ascending; expected leaf-side normalized
  # keys present on every element.
  if ! jq -e '(.comments | type == "array") and (.reviews | type == "array")' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "comments/reviews not arrays after normalization"
    return
  fi
  local comments_arr reviews_arr
  comments_arr="$(jq -c '.comments' <<<"$out")"
  reviews_arr="$(jq -c '.reviews'  <<<"$out")"
  if ! pcf_is_ascending_by_created_at "$comments_arr"; then
    emit FAIL "$verb" "comments[] not ascending by createdAt"
    return
  fi
  if ! jq -e '
      [.reviews[].submittedAt] as $ts
      | ($ts|length) as $n
      | ([range(0;$n-1) | ($ts[.] <= $ts[.+1])] | all)
    ' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "reviews[] not ascending by submittedAt"
    return
  fi
  # Comment shape: exactly id/author/body/createdAt keys (a "wrong-shape"
  # leaf that leaks GitHub internals would fail this).
  if ! jq -e '[.comments[] | (keys | sort) == ["author","body","createdAt","id"]] | all' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "comments[] element shape mismatch (expected {id,author,body,createdAt})"
    return
  fi
  if ! jq -e '[.reviews[] | (keys | sort) == ["author","state","submittedAt"]] | all' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "reviews[] element shape mismatch (expected {author,state,submittedAt})"
    return
  fi
  # closingIssueNumbers: int array folded from the GraphQL nodes shape.
  if ! jq -e '.closingIssueNumbers | type == "array" and (all(.[]?; type == "number"))' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "closingIssueNumbers not an int array"
    return
  fi
  # body: null in fixture → "" after normalization.
  local body_norm; body_norm="$(jq -r '.body' <<<"$out" 2>/dev/null)"
  if [[ "$body_norm" != "" ]]; then
    emit FAIL "$verb" "body null did not normalize to empty string (got: '$body_norm')"
    return
  fi

  # Fail-CLOSED: stub gh failing → verb rc≠0 with no partial stdout.
  out="$(_invoke _PCF_GH_MODE="fail" _PCF_ARGV_FILE="$argv_file" "$invoke" 2>&1)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (stub gh failed but verb still returned 0)"
    return
  fi

  # W1c2 online-review r1 (blocking): FIELDS_CSV MUST be validated against the
  # §3.2.1 vocabulary BEFORE gh is called. A GitHub-native field name (e.g.
  # `closingIssuesReferences`, the internal mapping target for the vocabulary's
  # `closingIssueNumbers`) or a bogus name must be REJECTED with rc≠0 — never
  # passed through. This certifies that a compliant provider cannot silently
  # accept GitHub-only names a non-GitHub backend would fail to deliver. Mirrors
  # W1c1's `_CHP_GITHUB_PR_FIELDS_SUPPORTED` gate posture.
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$payload" _PCF_ARGV_FILE="$argv_file" "chp_pr_view 42 closingIssuesReferences" 2>&1)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "vocabulary gate missing: raw gh-native name 'closingIssuesReferences' accepted (must be rejected — W1c2 online-review r1)"
    return
  fi
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$payload" _PCF_ARGV_FILE="$argv_file" "chp_pr_view 42 number,bogusField" 2>&1)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "vocabulary gate missing: unknown field 'bogusField' accepted (must be rejected — W1c2 online-review r1)"
    return
  fi
  emit PASS "$verb"
}

# _run_list_inline_comments_assert — chp_list_inline_comments normalized flat
# array assertion (#347 W1c2, #398). Invokes with a VALID single-page fixture;
# asserts (i) top-level is a JSON array, (ii) ascending by createdAt, (iii)
# `line` is the leaf-side `line // original_line // null` fold (originalLine
# ABSENT from element shape), (iv) element keys = {id,path,line,author,body,
# createdAt}, and (v) fail-CLOSED on any page failure. Multi-page completeness
# is proven by the parity suite tests/unit/test-w1c2-incidental-read-parity.sh
# (the runner's stub gh does not model multi-page today; W1c2 accepts that as
# W1f-shared work per R5).
_run_list_inline_comments_assert() {
  local verb="chp_list_inline_comments"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc payload="$PAYLOADS/inline-comments-valid.json"
  local invoke="chp_list_inline_comments 42"

  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$payload" _PCF_ARGV_FILE="$argv_file" "$invoke" 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "wrong-shape (non-zero rc on a valid payload: $rc, output: ${out:0:200})"
    return
  fi
  if ! pcf_is_json_array "$out"; then
    emit FAIL "$verb" "wrong-shape (output is not a JSON array: ${out:0:200})"
    return
  fi
  if ! pcf_is_ascending_by_created_at "$out"; then
    emit FAIL "$verb" "not sorted ascending by createdAt"
    return
  fi
  # Element shape: exactly {id,path,line,author,body,createdAt}, no original_line.
  if ! jq -e '[.[] | (keys | sort) == ["author","body","createdAt","id","line","path"]] | all' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "element shape mismatch (expected {id,path,line,author,body,createdAt}, no original_line)"
    return
  fi
  # leaf-side fold: a row whose input has {line:null, original_line: N} must
  # emerge with .line == N (originalLine folded in). Our fixture has such a row.
  if ! jq -e '[.[] | select(.body == "first in time — originalLine-only") | .line == 7] | any' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "line // original_line // null fold not applied at leaf"
    return
  fi
  # A row with both null must fold to null (caller renders // "N/A").
  if ! jq -e '[.[] | select(.body == "no line at all") | .line == null] | any' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "line fold to null missing on all-null row"
    return
  fi

  # Fail-CLOSED: stub gh failing → verb rc≠0.
  out="$(_invoke _PCF_GH_MODE="fail" _PCF_ARGV_FILE="$argv_file" "$invoke" 2>&1)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (stub gh failed but verb still returned 0)"
    return
  fi

  # Malformed page payload → fail-close (no partial-looking array smuggled).
  local malformed="$work_root/.malformed-$verb.json"
  printf '{ not json' > "$malformed"
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$malformed" _PCF_ARGV_FILE="$argv_file" "$invoke" 2>/dev/null)"
  if pcf_is_json_array "$out" && [[ -n "${out//[[:space:]]/}" ]] && [[ "$out" != "[]" ]]; then
    emit FAIL "$verb" "malformed-JSON page produced a non-empty array (should fail-CLOSED)"
    return
  fi

  # W1c2 online-review r2 (blocking): non-array page → fail-CLOSED, NEVER `[]`.
  # `gh api --paginate` returning ANY rc-0 JSON object (e.g. `{}` on an
  # unexpected shape, or `{"message":"..."}` on a permission failure that
  # gh's error path fell through) MUST reject — otherwise `add // []`
  # collapses it to `[]` rc 0, indistinguishable from a real zero-comment PR
  # and silently drops review feedback from autonomous-dev.sh's dev-resume
  # prompt. This certifies a compliant provider gates on `type == "array"`.
  local nonarr="$work_root/.nonarr-$verb.json"
  printf '%s' '{}' > "$nonarr"
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$nonarr" _PCF_ARGV_FILE="$argv_file" "$invoke" 2>/dev/null)"; rc=$?
  if [[ "$rc" == "0" || "$out" == "[]" ]]; then
    emit FAIL "$verb" "non-array-page gate missing: rc-0 '{}' page accepted (must be rejected — W1c2 online-review r2)"
    return
  fi
  # Also test the error-shaped object case explicitly.
  local errobj="$work_root/.errobj-$verb.json"
  printf '%s' '{"message":"Not Found"}' > "$errobj"
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$errobj" _PCF_ARGV_FILE="$argv_file" "$invoke" 2>/dev/null)"; rc=$?
  if [[ "$rc" == "0" || "$out" == "[]" ]]; then
    emit FAIL "$verb" "non-array-page gate missing: error-shaped object accepted (must be rejected — W1c2 online-review r2)"
    return
  fi
  emit PASS "$verb"
}

# _run_token_assert <verb> <invoke_snippet> <payload_file> <expected_token> —
# invoke VERB with a VALID canned payload (a raw `gh` JSON blob the stub-gh
# echoes verbatim, unless the leaf passes -q/--jq — see the stub-gh header)
# and assert stdout is exactly EXPECTED_TOKEN + rc 0; then invoke with the
# stub gh FAILING and assert rc≠0 (strict fail-closed per P2-3 review-round:
# rc-0-empty-stdout is a fail-open latch — a passthrough blindly emitting
# empty at rc 0 would slip past a lax check).
#
# W1d (#399): drives chp_ci_status / chp_mergeable end-to-end through their
# normalized-token contracts.
_run_token_assert() {
  local verb="$1" invoke_snippet="$2" payload_file="$3" expected_token="$4"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc

  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$payload_file" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "unexpected non-zero rc on valid payload: $rc (output: ${out:0:200})"
    return
  fi
  if [[ "$out" != "$expected_token" ]]; then
    emit FAIL "$verb" "token mismatch (expected '$expected_token', got '${out:0:200}')"
    return
  fi

  # Fail-closed (strict): stub gh returns rc≠0 with nothing on stdout — the
  # leaf MUST return rc≠0 too. Any rc 0 (even with empty stdout) is a
  # fail-open contract violation: chp_ci_status now returns rc≠0 on no
  # parseable JSON, and chp_mergeable now returns rc≠0 on empty / unknown
  # token, so both leaves have crisp non-zero rc on transport failure.
  out="$(_invoke _PCF_GH_MODE="fail" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "fail-closed violation: rc 0 on stub-failure (stdout: '${out:0:120}') — leaf must return rc≠0 on genuine transport failure"
    return
  fi
  emit PASS "$verb"
}

# _run_close_keyword_assert — render-only assertion (no gh call, no leaf
# dispatch — see provider-spec.md §4.4 / docs/designs/provider-conformance-runner.md).
_run_close_keyword_assert() {
  local verb="chp_close_keyword"
  [[ -f "$DEV_SH" ]] || { emit FAIL "$verb" "autonomous-dev.sh not found at $DEV_SH"; return; }
  local render='
    eval "$(sed -n "/^_render_close_keyword()/,/^}/p" "'"$DEV_SH"'")"
  '
  local closes related empty
  closes="$(bash -c "$render"'
    chp_caps() { case "$1" in merge_closes_issue) echo 1;; native_issue_pr_link) echo 0;; esac; }
    chp_has_leaf() { return 1; }
    _render_close_keyword 42
  ' 2>/dev/null)"
  related="$(bash -c "$render"'
    chp_caps() { case "$1" in merge_closes_issue) echo 0;; native_issue_pr_link) echo 0;; esac; }
    chp_has_leaf() { return 1; }
    _render_close_keyword 42
  ' 2>/dev/null)"
  empty="$(bash -c "$render"'
    chp_caps() { case "$1" in merge_closes_issue) echo 0;; native_issue_pr_link) echo 1;; esac; }
    chp_has_leaf() { return 1; }
    _render_close_keyword 42
  ' 2>/dev/null)"
  if [[ "$closes" != "Closes #42" ]]; then
    emit FAIL "$verb" "merge_closes_issue=1 branch: expected 'Closes #42', got '$closes'"
    return
  fi
  if [[ "$related" != "Related to #42" ]]; then
    emit FAIL "$verb" "merge_closes_issue=0+native_issue_pr_link=0 branch: expected 'Related to #42', got '$related'"
    return
  fi
  if [[ -n "$empty" ]]; then
    emit FAIL "$verb" "merge_closes_issue=0+native_issue_pr_link=1 branch: expected empty, got '$empty'"
    return
  fi
  emit PASS "$verb"
}

# _run_findpr_assert / _run_prlist_assert — W1c1 (#397) abstract-contract
# assertions for chp_find_pr_for_issue / chp_pr_list. Both verbs return a
# NORMALIZED JSON ARRAY projected to a FIELDS-CSV positional arg. The runner:
#   1. drives the verb against a canned PR-list payload with the stub gh
#      succeeding — asserts rc 0, output is an array, each element has the
#      normalized body-is-a-string contract (`body:null → body:""`) and the
#      closingIssueNumbers array-of-ints contract;
#   2. drives it again with the stub gh failing — asserts rc != 0 (fail-CLOSED,
#      no partial output).
# The [INV-86] close-linkage RESOLUTION jq is caller-side (`lib-pr-linkage.sh`)
# — this suite exercises the LEAF's contract, not the caller's selection.
_run_findpr_assert() {
  local verb="chp_find_pr_for_issue"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc

  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$PAYLOADS/pr-list-valid.json" _PCF_ARGV_FILE="$argv_file" 'chp_find_pr_for_issue 42 "number,body,headRefOid"' 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "expected rc 0 on stub-success, got rc=$rc (output: ${out:0:200})"
    return
  fi
  if ! pcf_is_json_array "$out"; then
    emit FAIL "$verb" "wrong-shape (output is not a JSON array: ${out:0:200})"
    return
  fi
  # body is a STRING (not null) for every element (the #148 normalization).
  if ! jq -e 'all(.[]; (.body | type == "string"))' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "body not normalized to string across all elements (found null): ${out:0:200}"
    return
  fi
  # closingIssueNumbers is an array of ints (the [INV-86] resolution key).
  if ! jq -e 'all(.[]; (.closingIssueNumbers | type == "array") and all(.closingIssueNumbers[]?; type == "number"))' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "closingIssueNumbers not normalized to array-of-ints: ${out:0:200}"
    return
  fi
  # FIELDS-CSV projection: every element MUST carry the requested caller fields
  # (`number`, `body`, `headRefOid`) AND the resolution keys.
  if ! jq -e 'all(.[]; has("number") and has("body") and has("headRefOid") and has("closingIssueNumbers") and has("headRefName"))' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "FIELDS-CSV projection missing a requested field: ${out:0:200}"
    return
  fi
  # VALUE assertion (P2-2, review r3 class): the pre-r3 helper only checked
  # shape — a provider returning fabricated empty `closingIssueNumbers:[]` and
  # blanked bodies for every element passed silently. Pin the actual values
  # against the fixture (pr-list-valid.json): PR#7's body carries #42, its
  # closingIssueNumbers flattens to [42]; PR#8's null body normalizes to ""
  # and its empty closingIssueNumbers stays [] — proving the leaf actually
  # walked the GraphQL envelope, not fabricated the shape.
  if ! jq -e '
    (length == 2) and
    (.[0].number == 7) and (.[1].number == 8) and
    (.[0].body == "Closes #42") and (.[1].body == "") and
    (.[0].closingIssueNumbers == [42]) and (.[1].closingIssueNumbers == []) and
    (.[0].headRefName == "feat/issue-42-thing") and (.[1].headRefName == "fix/other") and
    (.[0].headRefOid == "aaaa") and (.[1].headRefOid == "bbbb")
  ' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "fixture-values mismatch (fabricated shape?): ${out:0:200}"
    return
  fi

  # Fail-CLOSED on gh transport error.
  out="$(_invoke _PCF_GH_MODE="fail" _PCF_ARGV_FILE="$argv_file" 'chp_find_pr_for_issue 42 "number,body,headRefOid" 2>/dev/null' 2>&1)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (stub gh failed but verb still returned 0, W1c1 fail-CLOSED contract)"
    return
  fi
  emit PASS "$verb"
}

_run_prlist_assert() {
  local verb="chp_pr_list"
  local argv_file="$work_root/.argv-$verb.json"
  local out rc

  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$PAYLOADS/pr-list-valid.json" _PCF_ARGV_FILE="$argv_file" 'chp_pr_list open "body,number"' 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "expected rc 0 on stub-success, got rc=$rc (output: ${out:0:200})"
    return
  fi
  if ! pcf_is_json_array "$out"; then
    emit FAIL "$verb" "wrong-shape (output is not a JSON array: ${out:0:200})"
    return
  fi
  # body normalized to string (null → "").
  if ! jq -e 'all(.[]; (.body | type == "string"))' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "body not normalized to string across all elements: ${out:0:200}"
    return
  fi
  # Field-subset projection: `body` and `number` MUST be present in each element.
  if ! jq -e 'all(.[]; has("body") and has("number"))' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "FIELDS-CSV projection missing requested field (body/number): ${out:0:200}"
    return
  fi
  # VALUE assertion (P2-2, review r3 class): pin actual values against the
  # fixture — proves the leaf walked the GraphQL envelope, not fabricated
  # the shape. PR#7 body="Closes #42", PR#8 body normalizes null→"", order
  # is GraphQL-node order (descending createdAt in the leaf's ORDER BY but
  # the fixture's node array is authored to be 7,8 — the test asserts the
  # leaf preserves that order without reshuffling).
  if ! jq -e '
    (length == 2) and
    (.[0].number == 7) and (.[1].number == 8) and
    (.[0].body == "Closes #42") and (.[1].body == "")
  ' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "fixture-values mismatch (fabricated shape?): ${out:0:200}"
    return
  fi
  # Field-subset ONLY (P1-1 projection-only contract): the caller asked for
  # `body,number` — the response must NOT carry unrequested vocabulary members
  # like `closingIssueNumbers` / `headRefName` / `mergeable`.
  if jq -e 'any(.[]; has("closingIssueNumbers") or has("headRefName") or has("mergeable") or has("state") or has("createdAt") or has("headRefOid") or has("reviewDecision") or has("updatedAt") or has("mergedAt") or has("title") or has("reviews"))' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "projection-only violated (fabricated field beyond FIELDS=body,number): ${out:0:200}"
    return
  fi

  # Empty-match convention: the leaf emits `[]` (never null) — feed an empty
  # GraphQL envelope (nodes:[], hasNextPage:false) to prove it.
  local empty_pl="$work_root/.pr-list-empty.json"
  printf '%s' '{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}}}}' > "$empty_pl"
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$empty_pl" _PCF_ARGV_FILE="$argv_file" 'chp_pr_list open "body,number"' 2>&1)"; rc=$?
  if [[ "$rc" != "0" || "$out" != "[]" ]]; then
    emit FAIL "$verb" "empty match should emit '[]' rc 0; got rc=$rc out=${out:0:200}"
    return
  fi

  # STATE / FIELDS positional args are REQUIRED; missing them → rc != 0.
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_ARGV_FILE="$argv_file" 'chp_pr_list 2>/dev/null' 2>&1)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "missing STATE did not error"
    return
  fi

  # Fail-CLOSED on gh transport error.
  out="$(_invoke _PCF_GH_MODE="fail" _PCF_ARGV_FILE="$argv_file" 'chp_pr_list open "body,number" 2>/dev/null' 2>&1)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (stub gh failed but verb still returned 0)"
    return
  fi
  emit PASS "$verb"
}

# ---------------------------------------------------------------------------
# Drive each ASSERTED verb per cap-map.conf.
# ---------------------------------------------------------------------------
_assert_verb() {
  local verb="$1"
  local cap; cap="$(pcf_conf_value "$CAP_MAP_CONF" "$verb")" || cap="-"
  if [[ "$cap" != "-" ]]; then
    local val rc
    val="$(_cap_read "$verb" "$cap")"; rc=$?
    if [[ "$rc" -eq 0 && "$val" == "0" ]]; then
      emit SKIP "$verb" "$cap"
      return
    fi
  fi

  case "$verb" in
    itp_list_comments)
      _run_shape_assert "$verb" 'itp_list_comments 42' "$PAYLOADS/comments-valid.json" 1
      # [#393] anti-false-green: a payload in the WRONG source shape (e.g. the
      # pre-#393 GraphQL {comments:[…]} object) would pass the array+ascending
      # checks with every field null. Require non-null id/author/createdAt and
      # a REST-derived bot authorKind on the known fixture.
      local _lc_out
      _lc_out="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$PAYLOADS/comments-valid.json" _PCF_ARGV_FILE="$work_root/.argv-lc-393.json" 'itp_list_comments 42' 2>&1)"
      if jq -e '(length == 3) and all(.[]; .id != null and .author != null and .createdAt != null) and (.[0].authorKind == "bot") and (.[0].author == "my-claw[bot]")' >/dev/null 2>&1 <<<"$_lc_out"; then
        emit PASS "$verb" "non-null fields + REST authorKind derivation (#393)"
      else
        emit FAIL "$verb" "null fields or wrong authorKind — source-shape mismatch? (${_lc_out:0:160})"
      fi
      ;;
    itp_transition_state)
      _run_write_assert "$verb" "issue edit 42 --repo o/r --remove-label in-progress --add-label pending-review" \
        "42 in-progress pending-review"
      ;;
    itp_post_comment)
      _run_write_assert "$verb" "issue comment 42 --repo o/r --body hello" "42 hello"
      ;;
    itp_edit_comment)
      _run_write_assert "$verb" "api -X PATCH repos/o/r/issues/comments/1" "42 1 hello"
      ;;
    itp_mark_checkbox)
      _run_write_assert "$verb" "api repos/o/r/issues/42" "42 newbody"
      ;;
    itp_provision_states)
      _run_write_assert "$verb" "label create name --repo o/r --color ededed --description d" \
        "name ededed d"
      ;;
    itp_resolve_dep)
      _run_failsoft_assert "$verb" 'itp_resolve_dep "o/r" 42 _out; printf "%s" "$_out"' '^$'
      ;;
    itp_label_event_ts)
      _run_failsoft_assert "$verb" 'itp_label_event_ts 42 autonomous' '^$'
      ;;
    itp_list_by_state)
      _run_shape_assert "$verb" 'itp_list_by_state open autonomous 100 number,title,labels,comments' \
        "$PAYLOADS/issue-list-valid.json" number
      ;;
    itp_count_by_state)
      _run_count_assert "$verb" 'itp_count_by_state open autonomous 100 in-progress' \
        "$PAYLOADS/issue-list-valid.json"
      ;;
    itp_list_forbidden_combos)
      _run_shape_assert "$verb" 'itp_list_forbidden_combos open autonomous 100' \
        "$PAYLOADS/issue-list-valid.json" number
      ;;
    itp_read_task)
      _run_object_shape_assert "$verb" 'itp_read_task 42 title,body,state,labels,comments' \
        "$PAYLOADS/issue-view-valid.json" "$PAYLOADS/comments-valid.json"
      ;;
    chp_review_threads)
      _run_shape_assert "$verb" 'chp_review_threads 42' "$PAYLOADS/review-threads-valid.json" 0
      ;;
    chp_resolve_thread)
      _run_write_assert "$verb" "graphql -F threadId=TID" "TID"
      ;;
    chp_request_changes)
      _run_write_assert "$verb" "pr review 42 --repo o/r --request-changes --body msg" "42 msg"
      ;;
    chp_reply_review_comment)
      _run_write_assert "$verb" "api repos/o/r/pulls/42/comments -X POST" "42 1 hello"
      ;;
    chp_close_keyword)
      _run_close_keyword_assert
      ;;
    chp_find_pr_for_issue)
      # W1c1 (#397) abstract contract: normalized JSON array of candidates,
      # projected to FIELDS-CSV ∪ {number, closingIssueNumbers, headRefName}.
      # body → string (null → ""), closingIssueNumbers → int-array. Fail-CLOSED
      # on gh transport error (rc != 0, no partial output).
      _run_findpr_assert
      ;;
    chp_pr_list)
      # W1c1 (#397) abstract contract: normalized JSON array projected to
      # caller's FIELDS-CSV; body → string; empty match → `[]` (never null).
      # Self-guarding shim (leaf-absent → return 1); fail-CLOSED on transport
      # error / cap-hit.
      _run_prlist_assert
      ;;
    chp_pr_view)
      # W1c2 (#398) abstract contract: single normalized JSON object projected
      # to FIELDS-CSV per §3.2.1 vocabulary; supports every vocabulary field
      # (14 members). closingIssueNumbers folds BOTH flat and cursor shapes.
      # Capture-then-check fail-CLOSED (rc≠0 on gh failure / empty stdout /
      # non-object JSON, no partial output).
      _run_pr_view_assert
      ;;
    chp_list_inline_comments)
      # W1c2 (#398) abstract contract: one merged normalized flat array
      # `[{id,path,line,author,body,createdAt}]` ascending; leaf-side
      # `line // original_line // null` fold. Page-walk complete; fail-CLOSED
      # on any page fetch failure AND on rc-0 empty stdout.
      _run_list_inline_comments_assert
      ;;
    chp_ci_status)
      # W1d (#399): normalized-token leaf. Drive against three canned raw
      # `gh pr checks --json state` payloads (all-success, mixed-failure,
      # empty) and assert the leaf emits exactly `green`/`failed`/`none`.
      # The green-predicate is the normative half — a stub gh serving
      # all-success MUST yield `green`; a mixed-failure MUST yield `failed`
      # (rule 2 over rule 3); an empty array MUST yield `none`. Then a
      # stub-gh failure MUST fail-closed (leaf returns rc≠0).
      _run_token_assert "$verb" 'chp_ci_status 42' \
        "$PAYLOADS/ci-status-all-success.json" "green"
      _run_token_assert "$verb" 'chp_ci_status 42' \
        "$PAYLOADS/ci-status-mixed-failure.json" "failed"
      _run_token_assert "$verb" 'chp_ci_status 42' \
        "$PAYLOADS/ci-status-empty.json" "none"
      ;;
    chp_mergeable)
      # W1d (#399): absorbs `-q '.mergeable'` into the leaf. Drive against a
      # canned `{"mergeable":"MERGEABLE"}` payload — the stub gh applies the
      # leaf's own `-q '.mergeable'` filter, so the leaf emits exactly the
      # raw token `MERGEABLE`. Fail-closed: stub-fail → leaf rc≠0 (empty /
      # unknown / query failure all yield non-zero; the caller's
      # `|| echo ""` then maps to `_classify_mergeable_gate`'s
      # empty-string → block-nonsubstantive branch, exercised by the wrapper
      # tests, not this focused verb check).
      _run_token_assert "$verb" 'chp_mergeable 42' \
        "$PAYLOADS/mergeable-token.json" "MERGEABLE"
      ;;
    *)
      emit FAIL "$verb" "no assertion wired for this verb (runner bug)"
      ;;
  esac
}

main() {
  local verb
  while IFS= read -r verb; do
    [[ -n "$verb" ]] || continue
    local status; status="$(pcf_conf_value "$COVERAGE_CONF" "$verb")"
    if [[ "$status" == "pending" ]]; then
      PENDING_N=$((PENDING_N + 1))
      TOTAL=$((TOTAL + 1))
      printf 'CONFORMANCE-PCONF %s/%s %s PENDING (coverage.conf)\n' "$ITP_NAME" "$CHP_NAME" "$verb"
      continue
    fi
    _assert_verb "$verb"
  done < <(pcf_conf_keys "$COVERAGE_CONF")

  # CONTRACT-PENDING tripwire (R3): set-diff coverage.conf's `pending` set
  # against provider-spec.md's CONTRACT-PENDING-tokened rows. Plain grep, no
  # markdown parsing — each §3.1/§3.2 verb TABLE ROW is one physical line
  # starting with `| \`<verb>`; anchoring on that prefix (not just the bare
  # token) excludes prose elsewhere in the doc that merely MENTIONS the
  # token (e.g. this spec's own §10 checklist intro/footer).
  local spec_pending coverage_pending diff_out
  spec_pending="$(pcf_spec_pending_verbs "$SPEC_MD")"
  coverage_pending="$(pcf_conf_keys "$COVERAGE_CONF" | while IFS= read -r v; do
      [[ "$(pcf_conf_value "$COVERAGE_CONF" "$v")" == "pending" ]] && printf '%s\n' "$v"
    done | sort -u)"
  diff_out="$(diff <(printf '%s\n' "$spec_pending") <(printf '%s\n' "$coverage_pending") 2>/dev/null || true)"
  if [[ -z "$diff_out" ]]; then
    printf 'CONFORMANCE-COVERAGE PASS (spec CONTRACT-PENDING set == coverage.conf pending set, %d verbs)\n' \
      "$(printf '%s\n' "$spec_pending" | grep -c .)"
  else
    FAIL_N=$((FAIL_N + 1)); TOTAL=$((TOTAL + 1))
    printf 'CONFORMANCE-COVERAGE FAIL asymmetry between provider-spec.md CONTRACT-PENDING and coverage.conf pending:\n%s\n' "$diff_out"
  fi

  printf 'CONFORMANCE-SUMMARY total=%d pass=%d fail=%d skip=%d pending=%d\n' \
    "$TOTAL" "$PASS_N" "$FAIL_N" "$SKIP_N" "$PENDING_N"

  [[ "$FAIL_N" -eq 0 ]]
}

main "$@"
