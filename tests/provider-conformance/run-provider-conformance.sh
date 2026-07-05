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
# [#416 W-D] --transport-hook <path> — an operator-owned GITLAB_TRANSPORT_HOOK
# file threaded into every per-verb _invoke subshell (below). Validated once
# here (readable regular file) or fatal. Empty = no hook.
TRANSPORT_HOOK=""
# [#416 W-D] --transport-path-add <dir> — additional dir(s) appended to the
# isolated PATH computed by pcf_isolated_path, so a transport hook's helper
# bins (curl, an auth gateway CLI, ...) resolve inside per-verb _invoke
# subshells despite the pcf-mandated PATH scrub. Multiple flags accumulate;
# the added dirs never leak into the runner's OWN env (only into _invoke).
TRANSPORT_PATH_ADD=()
# [#416 W-D] --expect-absent <seam:verb-csv> — seam-qualified list of verbs
# whose leaf-absent FAILs downgrade to `SKIP <verb> (expected-absent: ...)`.
# Format: `chp:create_pr,chp:merge` or `itp:list_by_state`. Seam qualification
# is load-bearing because ITP/CHP verb names can collide (`resolve_dep` vs
# `resolve_thread`). Accumulates across multiple flags.
declare -A EXPECT_ABSENT=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --itp) [[ $# -ge 2 ]] || { log "FATAL: --itp requires a value"; exit 2; }; ITP_NAME="$2"; shift 2 ;;
    --itp=*) ITP_NAME="${1#*=}"; shift ;;
    --chp) [[ $# -ge 2 ]] || { log "FATAL: --chp requires a value"; exit 2; }; CHP_NAME="$2"; shift 2 ;;
    --chp=*) CHP_NAME="${1#*=}"; shift ;;
    --transport-hook)
      [[ $# -ge 2 ]] || { log "FATAL: --transport-hook requires a value"; exit 2; }
      TRANSPORT_HOOK="$2"; shift 2 ;;
    --transport-hook=*) TRANSPORT_HOOK="${1#*=}"; shift ;;
    --transport-path-add)
      [[ $# -ge 2 ]] || { log "FATAL: --transport-path-add requires a value"; exit 2; }
      TRANSPORT_PATH_ADD+=("$2"); shift 2 ;;
    --transport-path-add=*) TRANSPORT_PATH_ADD+=("${1#*=}"); shift ;;
    --expect-absent)
      [[ $# -ge 2 ]] || { log "FATAL: --expect-absent requires a value"; exit 2; }
      # Split CSV; each entry is `seam:verb`.
      _ea_csv="$2"
      IFS=',' read -ra _ea_list <<< "$_ea_csv"
      for _ea in "${_ea_list[@]}"; do
        [[ -n "$_ea" ]] || continue
        # Sanity check: must contain `:`; verbs without seam qualification are
        # a usage error (per the "ITP/CHP name-collision safe" contract).
        [[ "$_ea" == *:* ]] || { log "FATAL: --expect-absent entry '$_ea' missing seam qualification (want 'itp:<verb>' or 'chp:<verb>')"; exit 2; }
        EXPECT_ABSENT["$_ea"]=1
      done
      shift 2 ;;
    --expect-absent=*)
      _ea_csv="${1#*=}"
      IFS=',' read -ra _ea_list <<< "$_ea_csv"
      for _ea in "${_ea_list[@]}"; do
        [[ -n "$_ea" ]] || continue
        [[ "$_ea" == *:* ]] || { log "FATAL: --expect-absent entry '$_ea' missing seam qualification"; exit 2; }
        EXPECT_ABSENT["$_ea"]=1
      done
      shift ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log "FATAL: unknown argument: $1"; exit 2 ;;
  esac
done

# Validate --transport-hook at startup (readable regular file, or empty).
if [[ -n "$TRANSPORT_HOOK" ]]; then
  if [[ ! -r "$TRANSPORT_HOOK" ]]; then
    log "FATAL: --transport-hook '$TRANSPORT_HOOK' is not readable"
    exit 2
  fi
fi

# Validate --transport-path-add entries (each must be an existing directory).
for _tpa in "${TRANSPORT_PATH_ADD[@]:-}"; do
  [[ -z "$_tpa" ]] && continue
  if [[ ! -d "$_tpa" ]]; then
    log "FATAL: --transport-path-add '$_tpa' is not an existing directory"
    exit 2
  fi
done

# [#416 P1-5] Decouple logical NAME from source DIR for out-of-tree providers.
# The flag value may be either:
#   `<name>`             — well-known name (github/gitlab/degraded/broken) OR
#                          absolute-path that becomes BOTH the name and the
#                          dir (legacy behavior — but see NOTE below).
#   `<name>=<abs-dir>`   — logical <name> (used for filenames + label output)
#                          + explicit source <abs-dir> (self-certifying
#                          out-of-tree provider). This is the codex round-1
#                          [P1-5] shape: pcf_materialize_scratch's
#                          itp-<name>.sh / chp-<name>.sh filenames use the
#                          LOGICAL name, so a path like `/tmp/x/y` no longer
#                          leaks into filenames or function names.
#
# NOTE on the bare absolute-path form (#416 R3/AC4): the pre-P1-5 shape
# `--itp /abs/dir` resolved dir=/abs/dir AND name=/abs/dir, producing
# nonsense filenames like `itp-/abs/dir.sh`. Post-P1-5 the bare form is
# SUPPORTED by deriving the logical name from the dir's own provider file
# (`<seam>-<name>.sh`): exactly ONE such file must exist in the dir, else
# fatal naming the ambiguity — the explicit `<name>=/abs/dir` form remains
# for multi-provider dirs.
_split_itp_chp() {
  local seam_flag="$1" raw="$2"
  local name dir
  if [[ "$raw" == *"="* ]]; then
    name="${raw%%=*}"
    dir="${raw#*=}"
  else
    name="$raw"
    dir=""   # dir empty → resolve via the fixed-table.
  fi
  # Bare absolute-path form: derive the logical name from the single
  # <seam>-<name>.sh provider file inside the dir (#416 R3/AC4).
  if [[ -z "$dir" && "$name" == /* ]]; then
    local abs_dir="$name" candidates=() f base
    if [[ ! -d "$abs_dir" ]]; then
      log "FATAL: --${seam_flag} '$raw' — directory not found"
      exit 2
    fi
    for f in "$abs_dir/${seam_flag}-"*.sh; do
      [[ -f "$f" ]] && candidates+=("$f")
    done
    if [[ ${#candidates[@]} -eq 0 ]]; then
      log "FATAL: --${seam_flag} '$raw' — no ${seam_flag}-<name>.sh provider file in the dir"
      exit 2
    fi
    if [[ ${#candidates[@]} -gt 1 ]]; then
      log "FATAL: --${seam_flag} '$raw' — multiple ${seam_flag}-*.sh files (ambiguous); use '--${seam_flag} <name>=<abs-dir>' to pick one"
      exit 2
    fi
    base="${candidates[0]##*/}"          # <seam>-<name>.sh
    name="${base#"${seam_flag}"-}"
    name="${name%.sh}"
    dir="$abs_dir"
  fi
  # Reject a NAME containing a slash (nothing legal here).
  if [[ "$name" == */* ]]; then
    log "FATAL: --${seam_flag} '$raw' — logical name '$name' must not contain '/'"
    exit 2
  fi
  # Reject an empty name / an empty dir (a stray `=`).
  if [[ -z "$name" ]]; then
    log "FATAL: --${seam_flag} '$raw' — empty name before '='"
    exit 2
  fi
  if [[ "$raw" == *"="* && -z "$dir" ]]; then
    log "FATAL: --${seam_flag} '$raw' — empty dir after '='"
    exit 2
  fi
  printf '%s\t%s\n' "$name" "$dir"
}

IFS=$'\t' read -r ITP_LOGICAL_NAME ITP_EXPLICIT_DIR < <(_split_itp_chp itp "$ITP_NAME")
IFS=$'\t' read -r CHP_LOGICAL_NAME CHP_EXPLICIT_DIR < <(_split_itp_chp chp "$CHP_NAME")

# Overwrite ITP_NAME / CHP_NAME with the logical name so all downstream
# code (label output, filenames, expect-absent leaf-name construction,
# per-verb SKIP/FAIL messages) sees the clean name — never the abs-path.
ITP_NAME="$ITP_LOGICAL_NAME"
CHP_NAME="$CHP_LOGICAL_NAME"

if [[ -n "$ITP_EXPLICIT_DIR" ]]; then
  # Explicit out-of-tree dir. Validate it via pcf_resolve_provider_dir's
  # absolute-path arm (checks existence + readability).
  ITP_SRC_DIR="$(pcf_resolve_provider_dir "$PROJECT_ROOT" "$ITP_EXPLICIT_DIR")" \
    || { log "FATAL: --itp '$ITP_NAME=$ITP_EXPLICIT_DIR' — dir does not exist or is not readable"; exit 2; }
else
  ITP_SRC_DIR="$(pcf_resolve_provider_dir "$PROJECT_ROOT" "$ITP_NAME")" \
    || { log "FATAL: unknown --itp provider '$ITP_NAME'"; exit 2; }
fi
if [[ -n "$CHP_EXPLICIT_DIR" ]]; then
  CHP_SRC_DIR="$(pcf_resolve_provider_dir "$PROJECT_ROOT" "$CHP_EXPLICIT_DIR")" \
    || { log "FATAL: --chp '$CHP_NAME=$CHP_EXPLICIT_DIR' — dir does not exist or is not readable"; exit 2; }
else
  CHP_SRC_DIR="$(pcf_resolve_provider_dir "$PROJECT_ROOT" "$CHP_NAME")" \
    || { log "FATAL: unknown --chp provider '$CHP_NAME'"; exit 2; }
fi

work_root=""
cleanup() { rm -rf "${work_root:-}" 2>/dev/null || true; }
trap cleanup EXIT

work_root="$(mktemp -d "${TMPDIR:-/tmp}/provider-conformance-XXXXXX")" || { log "FATAL: mktemp -d failed"; exit 2; }
SCRATCH_DIR="$work_root/providers"
STUB_DIR="$work_root/stub"
mkdir -p "$SCRATCH_DIR" "$STUB_DIR"

pcf_materialize_scratch "$SCRATCH_DIR" "$ITP_NAME" "$ITP_SRC_DIR" "$CHP_NAME" "$CHP_SRC_DIR"

ISOLATED_PATH="$(pcf_isolated_path "$STUB_DIR")"

# [#416 W-D] Append any --transport-path-add dirs to the isolated PATH used
# by per-verb _invoke subshells. Scoped: the additions apply ONLY to _invoke
# (via ISOLATED_PATH substitution below) — the runner's own PATH is
# untouched. Multiple --transport-path-add entries accumulate; a duplicate
# entry is silently de-duped.
if [[ "${#TRANSPORT_PATH_ADD[@]}" -gt 0 ]]; then
  for _tpa in "${TRANSPORT_PATH_ADD[@]}"; do
    [[ -z "$_tpa" ]] && continue
    if [[ ":$ISOLATED_PATH:" != *":$_tpa:"* ]]; then
      ISOLATED_PATH="${ISOLATED_PATH}:${_tpa}"
    fi
  done
fi

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
#
# Two payload-selection modes (invocation-count keyed, not argv-keyed — argv-
# keyed selection is a re-implementation of the leaf's own cursor logic and
# would defeat the completeness assertion):
#
#   $_PCF_GH_PAYLOAD          single canned payload file (legacy shape used
#                             by every existing verb assertion).
#   $_PCF_GH_PAYLOAD_SEQ      colon-separated list of payload files served
#                             in invocation order (payload #1 on first
#                             invocation, #2 on second, …, LAST cycled on
#                             exhaustion). Invocation-count state lives in
#                             $_PCF_GH_SEQ_STATE (a file the stub increments
#                             on each call). $_PCF_GH_PAYLOAD wins if BOTH
#                             are set (backward compatibility).
#
#   $_PCF_GH_FAIL_AT          "N" — force this invocation (1-indexed) to
#                             fail. Non-matching invocations honor
#                             $_PCF_GH_MODE. Drives the mid-walk-failure
#                             assertion for multi-page leaves.
#
# Legacy $_PCF_GH_MODE=fail forces ALL invocations to fail.
printf '%s\n' "$@" > "${_PCF_ARGV_FILE:?}"
for _a in "$@"; do
  case "$_a" in
    */labels/*) exit 1 ;;   # force the itp_provision_states existence probe not-found
  esac
done

_inv=0
if [[ -n "${_PCF_GH_SEQ_STATE:-}" && -f "$_PCF_GH_SEQ_STATE" ]]; then
  _inv=$(<"$_PCF_GH_SEQ_STATE")
fi
_inv=$((_inv + 1))
[[ -n "${_PCF_GH_SEQ_STATE:-}" ]] && printf '%s' "$_inv" > "$_PCF_GH_SEQ_STATE"

if [[ -n "${_PCF_GH_FAIL_AT:-}" && "$_PCF_GH_FAIL_AT" == "$_inv" ]]; then
  printf 'stub-gh: simulated failure at invocation %d (fail-at)\n' "$_inv" >&2
  exit 1
fi
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
if [[ -z "$_payload" && -n "${_PCF_GH_PAYLOAD_SEQ:-}" ]]; then
  # Pick the $_inv-th `:`-separated file (1-indexed; clamp to LAST on overflow).
  IFS=':' read -r -a _seq <<< "$_PCF_GH_PAYLOAD_SEQ"
  _n=${#_seq[@]}
  _idx=$((_inv - 1))
  (( _idx >= _n )) && _idx=$((_n - 1))
  _payload="${_seq[$_idx]}"
fi
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
  # [#416 W-D] Thread GITLAB_TRANSPORT_HOOK into the per-verb subshell despite
  # the `env -u` scrub. Only exported when non-empty so the github axis is
  # byte-identical to pre-#416 (empty env var != unset for hermetic reruns,
  # but the transport lib treats both identically via `${GITLAB_TRANSPORT_HOOK:-}`).
  local -a hook_env=()
  if [[ -n "$TRANSPORT_HOOK" ]]; then
    hook_env=( "GITLAB_TRANSPORT_HOOK=$TRANSPORT_HOOK" )
  fi
  # [#417 W-B / #418 review round 1] GitLab-provider config keys (spec §3.4).
  # Set when EITHER seam axis is gitlab — the mixed `--itp github --chp gitlab`
  # axis (the P3-3 interim topology) needs GITLAB_PROJECT/HOST/TOKEN for the
  # CHP leaves' config guard just as much as the full gitlab/gitlab axis.
  # BOT_LOGIN stays ITP-gitlab-scoped: it drives the authorKind=self arm, and
  # on a github ITP axis a set BOT_LOGIN that matches the github fixture's
  # `my-claw[bot]` author would flip those comments to `self` and break the
  # pre-existing itp_list_comments / itp_read_task assertions.
  # GITLAB_PROJECT is stored ALREADY-URL-ENCODED per §3.4; the hermetic
  # value here matches that shape. PAYLOADS is exported so a fixture
  # transport hook (tests/provider-conformance/fixtures/gitlab/hook.sh)
  # can path-serve fixtures without hard-coding the runner's payload dir.
  local -a gitlab_env=()
  if [[ "$ITP_NAME" == "gitlab" || "$CHP_NAME" == "gitlab" ]]; then
    gitlab_env=(
      "GITLAB_PROJECT=group%2Fproject"
      "GITLAB_HOST=gitlab.com"
      "GITLAB_TOKEN=stub-token"
    )
  fi
  if [[ "$ITP_NAME" == "gitlab" ]]; then
    gitlab_env+=( "BOT_LOGIN=my-claw-bot" )
  fi
  env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      ISSUE_PROVIDER="$ITP_NAME" CODE_HOST="$CHP_NAME" AUTONOMOUS_PROVIDERS_DIR="$SCRATCH_DIR" \
      REPO="o/r" REPO_OWNER="o" REPO_NAME="r" \
      PAYLOADS="$PAYLOADS" \
      PATH="$ISOLATED_PATH" \
      "${gitlab_env[@]}" \
      "${hook_env[@]}" \
      "${extra_env[@]}" \
  bash -c '
    set -euo pipefail
    source "'"$ITP_LIB"'" 2>/dev/null
    source "'"$CHP_LIB"'" 2>/dev/null
    '"$script"'
  '
}

# _run_positional_reject <verb> <invoke_snippet> — drive VERB with malformed
# positionals (empty / missing / non-numeric-where-required) under the stub
# `gh`. Assert rc≠0 (specifically rc==2 for the positional-validation gate)
# AND that gh was NEVER called (empty argv file) — the leaf's validation
# must fail-loud BEFORE dispatching. Used for the three W1e write verbs
# (chp_create_pr/approve/merge) whose positional-validation contract is
# documented in provider-spec.md §3.2. Returns 0/prints PASS or FAIL via
# emit(). (#400 review-response follow-up: without this the runner had a
# negative-space gap — an empty positional silently reached gh.)
_run_positional_reject() {
  local verb="$1" invoke_snippet="$2"
  local argv_file="$work_root/.argv-$verb-reject.json"
  local out rc
  out="$(_invoke _PCF_GH_MODE="ok" _PCF_ARGV_FILE="$argv_file" "$invoke_snippet" 2>&1)"; rc=$?
  # gh MUST NOT have been called (validation gate fires before dispatch).
  if [[ -f "$argv_file" ]]; then
    emit FAIL "$verb" "positional-reject: gh was called on malformed args (leaked argv: $(_recorded_argv "$argv_file"))"
    rm -f "$argv_file"
    return
  fi
  # rc must be non-zero (validation gate rejected the call).
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "positional-reject: rc 0 on malformed positional (should fail-loud)"
    return
  fi
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

# ---------------------------------------------------------------------------
# GitLab-axis assertion helpers (#417 W-B).
#
# The pre-existing `_run_*` helpers wire a github-stub `gh` (via _PCF_GH_MODE /
# _PCF_GH_PAYLOAD / _PCF_ARGV_FILE). The gitlab ITP leaves NEVER call `gh` —
# they route every request through `_gl_api`, which delegates to `_gl_http`.
# The FROZEN #416 transport contract makes `_gl_http` the sole override point
# (`GITLAB_TRANSPORT_HOOK`); a fixture hook lives at
# tests/provider-conformance/fixtures/gitlab/hook.sh and:
#   - serves payloads path-driven (with a per-invocation _PCF_GL_PAYLOAD
#     override), and
#   - records every invocation to _PCF_GL_ARGV_FILE as CALL/BODY blocks
#     (method + path + optional body JSON), for write-verb argv checks.
#
# The runner activates the hook by passing `--transport-hook <path>` on the
# command line, which _invoke re-exports as GITLAB_TRANSPORT_HOOK — the
# transport lib sources it once per per-verb subshell (spec §transport /
# [INV-113] / [INV-116]).
#
# _gl_success_mode <mode> — returns 0 (success) since the fixture hook has
# no failure mode of its own (HTTP status is per-invocation via _PCF_GL_STATUS).
# The fail path is simulated by unsetting GITLAB_TRANSPORT_HOOK (which makes
# the transport lib's preflight fail on missing GITLAB_TOKEN) or by pointing
# _PCF_GL_PAYLOAD at a garbage file. We keep the fail simulation cleaner: a
# dedicated fail-mode hook is unnecessary for a shape-check pass; the "fail"
# path uses a payload file with an HTTP 5xx status via _PCF_GL_STATUS.

# _run_gl_shape_assert <verb> <invoke_snippet> <payload_file> <check_ascending>
# — parallel of _run_shape_assert for the gitlab axis. Serves <payload_file>
# via the fixture transport hook; asserts JSON-array shape + optional sort
# order. The fail-path assertion is elided here because the leaf's fail-CLOSED
# gate on non-array payload IS the same code path exercised by
# tests/unit/test-itp-gitlab.sh; run-provider-conformance's job is to prove
# the leaves compose correctly through the REAL transport lib + a fixture
# hook, not to re-run every unit-test fail branch.
_run_gl_shape_assert() {
  local verb="$1" invoke_snippet="$2" payload_file="$3" check_ascending="${4:-0}"
  local argv_file="$work_root/.argv-gl-$verb.json"
  local out rc
  out="$(_invoke _PCF_GL_PAYLOAD="$payload_file" _PCF_GL_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"; rc=$?
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
  emit PASS "$verb"
}

# _run_gl_count_assert <verb> <invoke_snippet> <payload_file> — parallel of
# _run_count_assert; verifies bare-integer output. Fail path uses HTTP 500.
_run_gl_count_assert() {
  local verb="$1" invoke_snippet="$2" payload_file="$3"
  local argv_file="$work_root/.argv-gl-$verb.json"
  local out rc
  out="$(_invoke _PCF_GL_PAYLOAD="$payload_file" _PCF_GL_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "wrong-shape (non-zero rc on a valid payload: $rc, output: ${out:0:200})"
    return
  fi
  if ! [[ "$out" =~ ^[0-9]+$ ]]; then
    emit FAIL "$verb" "wrong-shape (output is not a bare non-negative integer: '${out:0:200}')"
    return
  fi
  out="$(_invoke _PCF_GL_STATUS="500" _PCF_GL_PAYLOAD="$payload_file" _PCF_GL_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (HTTP 500 but verb still returned 0)"
    return
  fi
  emit PASS "$verb"
}

# _run_gl_object_shape_assert <verb> <invoke_snippet> <payload_file> —
# parallel of _run_object_shape_assert; single-object leaf.
_run_gl_object_shape_assert() {
  local verb="$1" invoke_snippet="$2" payload_file="$3"
  local argv_file="$work_root/.argv-gl-$verb.json"
  local out rc
  out="$(_invoke _PCF_GL_PAYLOAD="$payload_file" _PCF_GL_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "wrong-shape (non-zero rc on a valid payload: $rc, output: ${out:0:200})"
    return
  fi
  if ! pcf_is_json_object "$out"; then
    emit FAIL "$verb" "wrong-shape (output is not a JSON object: ${out:0:200})"
    return
  fi
  # Labels normalized to name-string array.
  if ! jq -e 'has("labels") and (.labels | type == "array") and (.labels | all(type == "string"))' >/dev/null 2>&1 <<<"$out"; then
    emit FAIL "$verb" "labels not normalized to a name-string array: ${out:0:200}"
    return
  fi
  # Fail-CLOSED: HTTP 500 → non-zero rc.
  out="$(_invoke _PCF_GL_STATUS="500" _PCF_GL_PAYLOAD="$payload_file" _PCF_GL_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (HTTP 500 but verb still returned 0)"
    return
  fi
  emit PASS "$verb"
}

# _run_gl_write_assert <verb> <invoke_snippet> <method_needle> <path_needle> [body_needle] —
# parallel of _run_write_assert. Serves the default per-path fixture (single
# happy payload — the hook selects based on path substring), asserts rc 0
# AND that _PCF_GL_ARGV_FILE contains the expected HTTP method + path
# substring (and optional body substring); then re-invokes with HTTP 500 and
# asserts rc≠0.
_run_gl_write_assert() {
  local verb="$1" invoke_snippet="$2" method_needle="$3" path_needle="$4" body_needle="${5:-}"
  local argv_file="$work_root/.argv-gl-$verb.json"
  local out rc
  out="$(_invoke _PCF_GL_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "expected rc 0 on stub-success, got rc=$rc (output: ${out:0:200})"
    return
  fi
  local recorded=""
  [[ -f "$argv_file" ]] && recorded="$(cat "$argv_file")"
  if [[ -n "$method_needle" && "$recorded" != *"method=$method_needle"* ]]; then
    emit FAIL "$verb" "method mismatch (expected method=$method_needle, recorded: ${recorded:0:200})"
    return
  fi
  if [[ -n "$path_needle" && "$recorded" != *"$path_needle"* ]]; then
    emit FAIL "$verb" "path mismatch (expected substring '$path_needle', recorded: ${recorded:0:200})"
    return
  fi
  if [[ -n "$body_needle" && "$recorded" != *"$body_needle"* ]]; then
    emit FAIL "$verb" "body-needle mismatch (expected substring '$body_needle', recorded: ${recorded:0:200})"
    return
  fi
  rm -f "$argv_file"
  # HTTP 500 → leaf rc≠0.
  out="$(_invoke _PCF_GL_STATUS="500" _PCF_GL_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "rc-0-on-error (HTTP 500 but verb still returned 0)"
    return
  fi
  emit PASS "$verb"
}

# _run_gl_failsoft_assert <verb> <invoke_snippet> <expect_regex> — parallel
# of _run_failsoft_assert. Under HTTP 500 the leaf MUST return rc 0 (fail-
# SOFT contract) and stdout MUST match <expect_regex>.
_run_gl_failsoft_assert() {
  local verb="$1" invoke_snippet="$2" expect_regex="$3"
  local argv_file="$work_root/.argv-gl-$verb.json"
  local out rc
  out="$(_invoke _PCF_GL_STATUS="500" _PCF_GL_ARGV_FILE="$argv_file" "$invoke_snippet" 2>/dev/null)"; rc=$?
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

# _run_review_threads_completeness_assert — #401 / #347 W1f.
#
# Drives chp_review_threads through the payload-sequence stub-gh mode and
# asserts:
#   (a) a 2-page thread walk yields a MERGED M8 array of length 4 (all page-1
#       + page-2 threads present, in arrival order).
#   (b) a mid-walk failure (page 2 fails) yields rc != 0 with NO partial
#       stdout — fail-closed contract.
#
# Emits ONE additional CONFORMANCE-PCONF line for chp_review_threads
# ("PASS completeness" / "FAIL …") — the shape assertion has already emitted
# its own PASS/FAIL earlier in the case arm. Runs only for --chp github; the
# degraded provider is single-page-by-design (§3.2 cell / §4.4).
_run_review_threads_completeness_assert() {
  local verb="chp_review_threads"
  local argv_file="$work_root/.argv-$verb-mp.json"
  local seq_state="$work_root/.seq-$verb.state"
  local p1="$PAYLOADS/review-threads-multipage-p1.json"
  local p2="$PAYLOADS/review-threads-multipage-p2.json"
  local np1="$PAYLOADS/review-threads-nested-p1.json"
  local np2="$PAYLOADS/review-threads-nested-p2.json"
  [[ -f "$p1" && -f "$p2" && -f "$np1" && -f "$np2" ]] || {
    emit FAIL "$verb" "multi-page fixtures missing (expected $p1 + $p2 + $np1 + $np2)"
    return
  }

  # (a) Successful 2-page walk: length 4, arrival order preserved.
  : > "$seq_state"
  local out rc
  out="$(_invoke \
      _PCF_GH_MODE="ok" _PCF_ARGV_FILE="$argv_file" \
      _PCF_GH_PAYLOAD_SEQ="$p1:$p2" _PCF_GH_SEQ_STATE="$seq_state" \
      "$verb 42" 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "completeness: expected rc 0 on 2-page walk, got rc=$rc (out: ${out:0:200})"
    return
  fi
  if ! pcf_is_json_array "$out"; then
    emit FAIL "$verb" "completeness: 2-page walk did not produce a JSON array (out: ${out:0:200})"
    return
  fi
  local n; n=$(jq 'length' <<<"$out" 2>/dev/null || echo 0)
  if [[ "$n" != "4" ]]; then
    emit FAIL "$verb" "completeness: expected 4 merged threads, got $n (arrival-order merge failed; out: ${out:0:200})"
    return
  fi
  local order
  order=$(jq -r '[.[].thread_id] | join(",")' <<<"$out" 2>/dev/null || echo "")
  if [[ "$order" != "PRRT_P1_A,PRRT_P1_B,PRRT_P2_A,PRRT_P2_B" ]]; then
    emit FAIL "$verb" "completeness: arrival order violated (got: $order)"
    return
  fi

  # (b) Mid-walk failure: page 1 OK, page 2 FAILs → rc != 0, empty stdout.
  : > "$seq_state"
  out="$(_invoke \
      _PCF_GH_MODE="ok" _PCF_ARGV_FILE="$argv_file" \
      _PCF_GH_PAYLOAD_SEQ="$p1:$p2" _PCF_GH_SEQ_STATE="$seq_state" \
      _PCF_GH_FAIL_AT="2" \
      "$verb 42" 2>/dev/null)"; rc=$?
  if [[ "$rc" == "0" ]]; then
    emit FAIL "$verb" "completeness: mid-walk failure did not surface (rc=0; out: ${out:0:200})"
    return
  fi
  if [[ -n "${out//[[:space:]]/}" ]]; then
    emit FAIL "$verb" "completeness: mid-walk failure produced partial stdout (fail-closed violated; out: ${out:0:200})"
    return
  fi

  # (c) Nested comment-level completeness: page 1 (thread level) returns ONE
  # thread with comments.pageInfo.hasNextPage=true and 2 comment nodes; a
  # follow-up node(id:) query on page 2 returns 2 more comment nodes with
  # hasNextPage=false. The merged thread MUST carry all 4 comments — deleting
  # the leaf's comment-level walk would leave the thread with only 2.
  : > "$seq_state"
  out="$(_invoke \
      _PCF_GH_MODE="ok" _PCF_ARGV_FILE="$argv_file" \
      _PCF_GH_PAYLOAD_SEQ="$np1:$np2" _PCF_GH_SEQ_STATE="$seq_state" \
      "$verb 42" 2>&1)"; rc=$?
  if [[ "$rc" != "0" ]]; then
    emit FAIL "$verb" "nested-completeness: expected rc 0 on nested 2-page walk, got rc=$rc (out: ${out:0:200})"
    return
  fi
  if ! pcf_is_json_array "$out"; then
    emit FAIL "$verb" "nested-completeness: nested walk did not produce a JSON array (out: ${out:0:200})"
    return
  fi
  local nested_thread_count nested_comment_count nested_comment_order
  nested_thread_count=$(jq 'length' <<<"$out" 2>/dev/null || echo 0)
  if [[ "$nested_thread_count" != "1" ]]; then
    emit FAIL "$verb" "nested-completeness: expected 1 thread, got $nested_thread_count (out: ${out:0:200})"
    return
  fi
  nested_comment_count=$(jq '.[0].comments | length' <<<"$out" 2>/dev/null || echo 0)
  if [[ "$nested_comment_count" != "4" ]]; then
    emit FAIL "$verb" "nested-completeness: expected 4 merged comments in the thread (2 from page-1 + 2 from the node(id:) walk), got $nested_comment_count. Deleting the comment-level walk would leave 2. (out: ${out:0:200})"
    return
  fi
  nested_comment_order=$(jq -r '[.[0].comments[].id] | join(",")' <<<"$out" 2>/dev/null || echo "")
  if [[ "$nested_comment_order" != "300001,300002,300003,300004" ]]; then
    emit FAIL "$verb" "nested-completeness: comment arrival order violated (got: $nested_comment_order)"
    return
  fi

  emit PASS "$verb" "multi-page completeness (2-page thread walk + mid-walk fail-closed + nested comment-level walk)"
}

# ---------------------------------------------------------------------------
# Drive each ASSERTED verb per cap-map.conf.
# ---------------------------------------------------------------------------

# [#416 W-D] _seam_leaf_file <verb> — the provider-side leaf filename we
# expect a verb's implementation to live in. Used by the leaf-absent
# preflight below to name the file that should be added.
_seam_leaf_file() {
  local verb="$1"
  local seam; seam="$(_seam_for "$verb")"
  case "$seam" in
    itp) printf '%s\n' "providers/itp-${ITP_NAME}.sh" ;;
    chp) printf '%s\n' "providers/chp-${CHP_NAME}.sh" ;;
    *)   printf '%s\n' "providers/<unknown-seam>-${verb}" ;;
  esac
}

# [#416 W-D] _leaf_present <verb> — rc 0 iff the provider LEAF (not the
# always-defined shim) for the currently-selected provider exists. Drives
# the runner's own subshell of the seam libs and checks
# `declare -F <seam>_${NAME}_${verb}`. This is the same probe the shim's
# has-leaf gate uses; a false result here means the runner would abort
# under `set -e` when the shim dispatches to the absent leaf — we surface
# it FIRST as a per-verb FAIL / SKIP instead.
_leaf_present() {
  local verb="$1" seam name leaf
  seam="$(_seam_for "$verb")"
  case "$seam" in
    itp) name="$ITP_NAME" ;;
    chp) name="$CHP_NAME" ;;
    *)   return 1 ;;
  esac
  # Strip the seam prefix from the verb: `itp_list_by_state` -> `list_by_state`.
  local base="${verb#itp_}"
  base="${base#chp_}"
  leaf="${seam}_${name}_${base}"
  # Probe in an isolated subshell so a missing lib doesn't crash the runner.
  env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      ISSUE_PROVIDER="$ITP_NAME" CODE_HOST="$CHP_NAME" \
      AUTONOMOUS_PROVIDERS_DIR="$SCRATCH_DIR" PATH="$ISOLATED_PATH" \
  bash -c "
    source \"$ITP_LIB\" 2>/dev/null
    source \"$CHP_LIB\" 2>/dev/null
    declare -F ${leaf} >/dev/null 2>&1
  "
}

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

  # [#416 W-D] Leaf-absent preflight. If the provider LEAF for this verb is
  # not defined (e.g. --itp gitlab today on a tree where itp-gitlab.sh does
  # not yet exist), emit ONE clean per-verb FAIL / SKIP instead of letting
  # the shim's dispatch crash the runner under `set -e`.
  #
  # Exclusions:
  #   - The `broken` fixture is DELIBERATELY missing leaves as part of its
  #     contract (it exists to prove the runner FAILs a mis-shaped provider
  #     cleanly); skip the preflight there so the pre-#416 test-provider-
  #     conformance-runner expectations for `broken/broken` stay intact.
  #   - `chp_close_keyword` is a CALLER-SIDE render assertion (see
  #     `_run_close_keyword_assert` — no leaf dispatch), spec §4.4; the
  #     provider's `chp_${NAME}_close_keyword` leaf is intentionally absent.
  local _preflight_skip=0
  case "$verb" in chp_close_keyword) _preflight_skip=1 ;; esac
  if [[ "$ITP_NAME" != "broken" && "$CHP_NAME" != "broken" && "$_preflight_skip" -eq 0 ]]; then
    if ! _leaf_present "$verb"; then
      local seam; seam="$(_seam_for "$verb")"
      local ea_key="${seam}:${verb#itp_}"; ea_key="${ea_key/chp_/}"
      # Correct: strip only the LEADING itp_/chp_ from the verb name.
      local ea_verb="${verb#itp_}"; ea_verb="${ea_verb#chp_}"
      ea_key="${seam}:${ea_verb}"
      local leaf_file; leaf_file="$(_seam_leaf_file "$verb")"
      local leaf_name="${seam}_"
      case "$seam" in
        itp) leaf_name="itp_${ITP_NAME}_${ea_verb}" ;;
        chp) leaf_name="chp_${CHP_NAME}_${ea_verb}" ;;
      esac
      if [[ -n "${EXPECT_ABSENT[$ea_key]:-}" ]]; then
        # Downgrade to SKIP (expected-absent). Emit our own SKIP-shaped
        # line since the standard emit() format uses "SKIP (cap: X)" and
        # this is a distinct disposition.
        SKIP_N=$((SKIP_N + 1)); TOTAL=$((TOTAL + 1))
        printf 'CONFORMANCE-PCONF %s/%s %s SKIP (expected-absent: %s)\n' \
          "$ITP_NAME" "$CHP_NAME" "$verb" "$leaf_file:${leaf_name}"
        return
      fi
      # Genuine FAIL naming the absent leaf file:function.
      emit FAIL "$verb" "leaf absent: ${leaf_file}:${leaf_name}"
      return
    fi
  fi

  case "$verb" in
    itp_list_comments)
      case "$ITP_NAME" in
        gitlab)
          _run_gl_shape_assert "$verb" 'itp_list_comments 42' "$PAYLOADS/gitlab-notes-list.json" 1
          ;;
        *)
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
      esac
      ;;
    itp_transition_state)
      case "$ITP_NAME" in
        gitlab)
          # GitLab: SINGLE PUT with add_labels/remove_labels body ([INV-97],
          # spec §3.1). Assert method + path + both CSV keys in the body.
          _run_gl_write_assert "$verb" \
            'itp_transition_state 42 in-progress pending-review' \
            "PUT" "path=projects/group%2Fproject/issues/42" 'add_labels'
          ;;
        *)
          _run_write_assert "$verb" "issue edit 42 --repo o/r --remove-label in-progress --add-label pending-review" \
            "42 in-progress pending-review"
          ;;
      esac
      ;;
    itp_post_comment)
      case "$ITP_NAME" in
        gitlab)
          _run_gl_write_assert "$verb" \
            'itp_post_comment 42 hello' \
            "POST" "path=projects/group%2Fproject/issues/42/notes" '"body":"hello"'
          ;;
        *)
          _run_write_assert "$verb" "issue comment 42 --repo o/r --body hello" "42 hello"
          ;;
      esac
      ;;
    itp_edit_comment)
      case "$ITP_NAME" in
        gitlab)
          _run_gl_write_assert "$verb" \
            'itp_edit_comment 42 1001 hello' \
            "PUT" "path=projects/group%2Fproject/issues/42/notes/1001" '"body":"hello"'
          ;;
        *)
          _run_write_assert "$verb" "api -X PATCH repos/o/r/issues/comments/1" "42 1 hello"
          ;;
      esac
      ;;
    itp_mark_checkbox)
      case "$ITP_NAME" in
        gitlab)
          _run_gl_write_assert "$verb" \
            'itp_mark_checkbox 42 newbody' \
            "PUT" "path=projects/group%2Fproject/issues/42" '"description":"newbody"'
          ;;
        *)
          _run_write_assert "$verb" "api repos/o/r/issues/42" "42 newbody"
          ;;
      esac
      ;;
    itp_provision_states)
      case "$ITP_NAME" in
        gitlab)
          # GitLab: probe /labels/<name> (200 → skip) OR create → POST /labels.
          # The path-driven fixture hook returns HTTP 200 for the probe path,
          # so the leaf takes the [skip] branch. Assert the GET call reached
          # /labels/<name>.
          _run_gl_write_assert "$verb" \
            'itp_provision_states autonomous 0E8A16 desc' \
            "GET" "path=projects/group%2Fproject/labels/autonomous" ""
          ;;
        *)
          _run_write_assert "$verb" "label create name --repo o/r --color ededed --description d" \
            "name ededed d"
          ;;
      esac
      ;;
    itp_resolve_dep)
      case "$ITP_NAME" in
        gitlab)
          # Fail-SOFT under HTTP 500 → empty out-var, rc 0.
          _run_gl_failsoft_assert "$verb" \
            'itp_resolve_dep "group/project" 42 _out; printf "%s" "$_out"' '^$'
          ;;
        *)
          _run_failsoft_assert "$verb" 'itp_resolve_dep "o/r" 42 _out; printf "%s" "$_out"' '^$'
          ;;
      esac
      ;;
    itp_label_event_ts)
      case "$ITP_NAME" in
        gitlab)
          _run_gl_failsoft_assert "$verb" 'itp_label_event_ts 42 autonomous' '^$'
          ;;
        *)
          _run_failsoft_assert "$verb" 'itp_label_event_ts 42 autonomous' '^$'
          ;;
      esac
      ;;
    itp_list_by_state)
      case "$ITP_NAME" in
        gitlab)
          # Note: FIELDS_CSV omits `comments` here — including it would cause
          # the leaf to make a second per-issue notes fetch which the path-
          # driven hook serves as a notes fixture, redirecting the shape. The
          # `comments`-inclusive path is exercised in tests/unit/test-itp-gitlab.sh.
          _run_gl_shape_assert "$verb" \
            'itp_list_by_state open autonomous 100 number,title,labels' \
            "$PAYLOADS/gitlab-issues-list.json" number
          ;;
        *)
          _run_shape_assert "$verb" 'itp_list_by_state open autonomous 100 number,title,labels,comments' \
            "$PAYLOADS/issue-list-valid.json" number
          ;;
      esac
      ;;
    itp_count_by_state)
      case "$ITP_NAME" in
        gitlab)
          _run_gl_count_assert "$verb" \
            'itp_count_by_state open autonomous 100 in-progress' \
            "$PAYLOADS/gitlab-issues-list.json"
          ;;
        *)
          _run_count_assert "$verb" 'itp_count_by_state open autonomous 100 in-progress' \
            "$PAYLOADS/issue-list-valid.json"
          ;;
      esac
      ;;
    itp_list_forbidden_combos)
      case "$ITP_NAME" in
        gitlab)
          _run_gl_shape_assert "$verb" \
            'itp_list_forbidden_combos open autonomous 100' \
            "$PAYLOADS/gitlab-issues-list.json" number
          ;;
        *)
          _run_shape_assert "$verb" 'itp_list_forbidden_combos open autonomous 100' \
            "$PAYLOADS/issue-list-valid.json" number
          ;;
      esac
      ;;
    itp_read_task)
      case "$ITP_NAME" in
        gitlab)
          # NB: request only 'title,body,state,labels' — including `comments`
          # would trigger a second per-issue notes fetch which the path-
          # driven hook serves. Comments+read_task composition is proven in
          # tests/unit/test-itp-gitlab.sh (TC-WB-042).
          _run_gl_object_shape_assert "$verb" \
            'itp_read_task 42 title,body,state,labels' \
            "$PAYLOADS/gitlab-issue-view.json"
          ;;
        *)
          _run_object_shape_assert "$verb" 'itp_read_task 42 title,body,state,labels,comments' \
            "$PAYLOADS/issue-view-valid.json" "$PAYLOADS/comments-valid.json"
          ;;
      esac
      ;;
    chp_review_threads)
      _run_shape_assert "$verb" 'chp_review_threads 42' "$PAYLOADS/review-threads-valid.json" 0
      # #401 / #347 W1f — multi-page COMPLETENESS is asserted for --chp github
      # only (the degraded fixture is single-page-by-design; completeness is
      # per-provider per §3.2 cell + §4.4). Skip cleanly on any non-github CHP.
      if [[ "$CHP_NAME" == "github" ]]; then
        _run_review_threads_completeness_assert
      fi
      # Positional-validation gate (#401 review r2, W1e convention #400): PR
      # must be non-empty numeric — missing/empty/non-numeric → rc 2 + no gh
      # call. resolve-threads.sh (sole caller) sanitizes via `printf '%d'`, so
      # reaching the leaf with a bad arg is operator misuse (safe to validate
      # per the #400 caller-legitimacy rule).
      _run_positional_reject "$verb" 'chp_review_threads ""'
      _run_positional_reject "$verb" 'chp_review_threads abc'
      ;;
    chp_resolve_thread)
      case "$CHP_NAME" in
        gitlab)
          # GitLab: compound `<mr-iid>:<discussion-id>` decode (P3-3 M8 pin,
          # #419 R7) → PUT /merge_requests/:iid/discussions/:disc body
          # `{"resolved":true}`. Fixture discussion id is `disc-abc`.
          _run_gl_write_assert "$verb" \
            'chp_resolve_thread 42:disc-abc' \
            "PUT" "path=projects/group%2Fproject/merge_requests/42/discussions/disc-abc" \
            '"resolved":true'
          ;;
        *)
          _run_write_assert "$verb" "graphql -F threadId=TID" "TID"
          ;;
      esac
      # Positional-validation gate (#401 review r2): THREAD_ID must be
      # non-empty — resolve-threads.sh gates on `[ -n "$thread_id" ]`, so an
      # empty positional here is operator misuse.
      _run_positional_reject "$verb" 'chp_resolve_thread ""'
      ;;
    chp_request_changes)
      _run_write_assert "$verb" "pr review 42 --repo o/r --request-changes --body msg" "42 msg"
      ;;
    chp_reply_review_comment)
      case "$CHP_NAME" in
        gitlab)
          # GitLab: walk /discussions to resolve COMMENT_ID → discussion id,
          # then POST /discussions/:d/notes ([INV-96], #419 R6). Fixture
          # discussions contain note id 7000001 in discussion `disc-abc`.
          _run_gl_write_assert "$verb" \
            'chp_reply_review_comment 42 7000001 hello' \
            "POST" "path=projects/group%2Fproject/merge_requests/42/discussions/disc-abc/notes" \
            '"body":"hello"'
          ;;
        *)
          _run_write_assert "$verb" "api repos/o/r/pulls/42/comments -X POST" "42 1 hello"
          ;;
      esac
      ;;
    chp_create_pr)
      case "$CHP_NAME" in
        gitlab)
          # GitLab: GET /projects/:id to resolve default_branch, then POST
          # /merge_requests with `{source_branch, target_branch, title,
          # description, squash:true, remove_source_branch:true}` (#419 R2,
          # CONTRACT-FIXED W1e). Substring needle catches the POST regardless
          # of the preceding GET on the recorded argv trace.
          _run_gl_write_assert "$verb" \
            'chp_create_pr feat/x t b' \
            "POST" "path=projects/group%2Fproject/merge_requests" \
            '"source_branch":"feat/x"'
          ;;
        *)
          # W1e (#400): abstract positional contract — caller passes <head>
          # <title> <body>; the GitHub leaf owns `--head/--title/--body`.
          _run_write_assert "$verb" "pr create --repo o/r --head feat/x --title t --body b" \
            "feat/x t b"
          ;;
      esac
      # Positional-validation gate (#400 review r1): HEAD_BRANCH and TITLE
      # empty → rc≠0 + no gh call. BODY MAY be empty by design (caller
      # `drain_agent_pr_create` derives body from `tail -n +2/+3` yielding
      # "" on a title-only PR-create file — a legitimate GitHub create),
      # so empty-BODY is NOT rejected here.
      _run_positional_reject "$verb" 'chp_create_pr "" t b'
      _run_positional_reject "$verb" 'chp_create_pr feat/x "" b'
      ;;
    chp_approve)
      case "$CHP_NAME" in
        gitlab)
          # GitLab: TWO calls, ordering load-bearing (#419 R3). (1) POST
          # /approve — the load-bearing action. (2) POST /notes with the body
          # — diagnostic. The recorded argv contains BOTH; the substring
          # needle catches the /approve path AND the note-body payload.
          _run_gl_write_assert "$verb" \
            'chp_approve 42 msg' \
            "POST" "path=projects/group%2Fproject/merge_requests/42/approve" \
            ''
          ;;
        *)
          # W1e (#400): abstract positional contract — caller passes <pr>
          # <body>; the GitHub leaf owns `--approve --body`.
          _run_write_assert "$verb" "pr review 42 --repo o/r --approve --body msg" \
            "42 msg"
          ;;
      esac
      # Positional-validation gate: PR must be numeric, BODY must be non-empty.
      _run_positional_reject "$verb" 'chp_approve "" msg'
      _run_positional_reject "$verb" 'chp_approve abc msg'
      _run_positional_reject "$verb" 'chp_approve 42 ""'
      ;;
    chp_merge)
      case "$CHP_NAME" in
        gitlab)
          # GitLab: PUT /merge_requests/:pr/merge body
          # `{squash:true, should_remove_source_branch:true}` (#419 R4).
          _run_gl_write_assert "$verb" \
            'chp_merge 42' \
            "PUT" "path=projects/group%2Fproject/merge_requests/42/merge" \
            '"squash":true'
          ;;
        *)
          # W1e (#400): abstract positional contract — caller passes <pr>
          # only; merge strategy is contract-fixed (squash + delete).
          _run_write_assert "$verb" "pr merge 42 --repo o/r --squash --delete-branch" \
            "42"
          ;;
      esac
      # Positional-validation gate: PR must be non-empty numeric. This is the
      # highest-blast-radius verb — merging the wrong PR would be catastrophic
      # so we assert the reject explicitly.
      _run_positional_reject "$verb" 'chp_merge ""'
      _run_positional_reject "$verb" 'chp_merge abc'
      ;;
    chp_close_keyword)
      _run_close_keyword_assert
      ;;
    chp_file_url)
      # #419 R11 (P3-4): pure string render, NO HTTP — parallels
      # chp_close_keyword's render pattern. The GitHub leaf must return
      # `https://github.com/${REPO}/blob/${BRANCH}/${FILE_PATH}` byte-identically
      # to the pre-#419 upload-screenshot.sh:114 hardcode (REPO positional
      # HONORED). No gh call at all — the assertion drives the leaf directly
      # through the shim.
      _url_out="$(_invoke "chp_file_url 'owner/repo' 'screenshots' 'pr-42/TC-1.png'" 2>/dev/null)"
      if [[ "$CHP_NAME" == "github" ]]; then
        if [[ "$_url_out" == "https://github.com/owner/repo/blob/screenshots/pr-42/TC-1.png" ]]; then
          emit PASS "$verb"
        else
          emit FAIL "$verb" "github render mismatch: got '$_url_out' (expected 'https://github.com/owner/repo/blob/screenshots/pr-42/TC-1.png')"
        fi
      else
        # A non-github axis (degraded/broken/gitlab): the leaf either doesn't
        # exist (shim → WARN + rc 1) or renders a provider-specific URL. The
        # runner asserts the shim self-guards for degraded/broken (leaf-absent
        # → non-github WARN+rc1) so the caller's `|| fail` degrades cleanly.
        if [[ -z "$_url_out" ]]; then
          emit PASS "$verb" "shim self-guards on absent leaf (WARN + rc 1)"
        else
          emit PASS "$verb" "non-github axis rendered: $_url_out"
        fi
      fi
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
      # Payload-type gate (post-#399 review-round finding): a rc-0 JSON
      # OBJECT payload `{}` must be REJECTED, not misread as "no checks
      # configured" ("none"). Without the array-type gate the leaf's
      # `jq '[.[].state]'` iterates the object's (empty) values and
      # produces `[]` → bucket→`none` → silent fail-open. Drive the
      # object payload and assert rc≠0 with no partial stdout.
      _argv_file="$work_root/.argv-ci-obj.json"
      _out_obj="$(_invoke _PCF_GH_MODE="ok" _PCF_GH_PAYLOAD="$PAYLOADS/ci-status-object-payload.json" _PCF_ARGV_FILE="$_argv_file" 'chp_ci_status 42' 2>/dev/null)"; _rc_obj=$?
      if [[ "$_rc_obj" == "0" ]]; then
        emit FAIL "$verb" "payload-type gate missing: rc-0 object payload {} accepted (out: '${_out_obj:0:120}') — must reject non-array"
      else
        emit PASS "$verb"
      fi
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
