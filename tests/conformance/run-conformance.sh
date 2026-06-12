#!/bin/bash
# run-conformance.sh — standalone, HERMETIC conformance runner for the agent-CLI
# adapter contract (issue #230, INV-73). Replays per-adapter × per-mode fixture
# manifests (docs/pipeline/schemas/fixture-manifest.schema.json, #229) against
# the CURRENT classification logic using STUB CLIs — no network, no credentials,
# no real agent CLIs. Runs on any fork's plain GitHub-hosted CI.
#
#   bash tests/conformance/run-conformance.sh [--adapter X] [--mode Y]
#
# WHAT IT DOES, per fixture
# -------------------------
#   1. Schema-validate the manifest (loud reject on malformed — python jsonschema
#      when available, else a jq structural fallback, mirroring #229's test).
#   2. Materialize the fixture:
#        - stage any `files{}` (logs/sidecars) into a per-fixture temp root;
#        - install a STUB CLI named after the adapter on an ISOLATED PATH that
#          emits the recorded command.{rc,stdout,stderr}, writes any `--log-file`
#          it is handed with the staged log, and RECORDS the bytes it received on
#          stdin (so the runner can assert the prompt actually reached the stub
#          over the INV-34 stdin-fed-prompt channel — see step 3; NOT a
#          byte-compare against command.stdinSha256, which is the recorded prompt
#          identity, not the live nonce'd prompt the runner feeds).
#   3. Invoke the stub ONCE over the production [INV-34] stdin channel (the runner
#      feeds it the live-nonce'd smoke prompt and asserts the bytes reached the
#      stub's stdin), then classify the RECORDED command.{rc,stdout,stderr} with
#      the REAL classifier — _smoke_classify (lib-agent-smoke.sh) + the per-CLI
#      _classify_<cli>_drop_reason scrapers. This is TODAY's monolithic
#      drop-reason / verdict-state / vote logic, by design (issue Design
#      Considerations): pin current behavior so the later adapter extraction
#      (#232) must preserve it. (The classifier is the contract under test; the
#      runner does not re-enter run_agent's full launch path — it replays the
#      recorded process result the way run_agent would have captured it.)
#   4. Project the classifier output onto the four AdapterResult axes
#      (lib-conformance.sh::_conf_project) and DIFF against the manifest's
#      `expect{}`.
#
# OUTPUT
# ------
#   CONFORMANCE <adapter>/<mode>/<name> PASS
#   CONFORMANCE <adapter>/<mode>/<name> FAIL <axis-diff | reason>
#   CONFORMANCE-SUMMARY total=N pass=N fail=N
# Non-zero exit on ANY fail (incl. a malformed manifest or a stub that could not
# be materialized — a fixture that cannot run is a FAIL, never a silent skip).
#
# HERMETICITY (the load-bearing guarantee)
# ----------------------------------------
# Each fixture's classification runs with PATH = <stub-dir> ONLY (plus the
# coreutils dir that hosts `timeout`/`env`/`cat`, discovered once up-front). The
# real claude/codex/kiro/agy are NEVER on it. A fixture whose stub binary is
# missing fails LOUD (`FAIL stub-missing`), never falls through to a real CLI.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_CONF="$SCRIPT_DIR/lib-conformance.sh"
LIB_SMOKE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh"
SCHEMA="$PROJECT_ROOT/docs/pipeline/schemas/fixture-manifest.schema.json"
# FIXTURE_DIR overridable for the unit tests (a synthetic fixture dir); default
# the committed promoted-fixture set.
FIXTURE_DIR="${CONFORMANCE_FIXTURE_DIR:-$SCRIPT_DIR/fixtures}"

log() { printf '%s\n' "$*" >&2; }

# Global so the EXIT trap (set in main) can reference it safely under `set -u`.
work_root=""

# --adapter / --mode filters (empty = all).
FILTER_ADAPTER=""
FILTER_MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --adapter) FILTER_ADAPTER="${2:-}"; shift 2 ;;
    --adapter=*) FILTER_ADAPTER="${1#*=}"; shift ;;
    --mode) FILTER_MODE="${2:-}"; shift 2 ;;
    --mode=*) FILTER_MODE="${1#*=}"; shift ;;
    -h|--help)
      grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) log "FATAL: unknown argument: $1"; exit 2 ;;
  esac
done

[[ -f "$LIB_CONF" ]]  || { log "FATAL: lib-conformance.sh not found at $LIB_CONF"; exit 2; }
[[ -f "$LIB_SMOKE" ]] || { log "FATAL: lib-agent-smoke.sh not found at $LIB_SMOKE"; exit 2; }
[[ -f "$SCHEMA" ]]    || { log "FATAL: fixture-manifest schema not found at $SCHEMA"; exit 2; }

# shellcheck source=lib-conformance.sh
source "$LIB_CONF"

# jq is REQUIRED for materialization (argv arrays, files{} objects). The grep
# fallback in lib-conformance only covers flat scalar reads; the runner reads
# nested arrays/objects, so a jq-less environment cannot run the suite.
command -v jq >/dev/null 2>&1 || { log "FATAL: jq is required to run the conformance suite"; exit 2; }

# ---------------------------------------------------------------------------
# Coreutils dir — the stub PATH must still expose `timeout`/`env`/`cat`/`mktemp`
# etc. that run_agent and the classifier use. Discover the dir hosting `env`
# (a coreutils member) once; the stub PATH is <stub-dir>:<coreutils-dir> so the
# adapter binaries themselves can ONLY resolve to the stub.
# ---------------------------------------------------------------------------
_COREUTILS_DIR="$(dirname "$(command -v env)")"

# ---------------------------------------------------------------------------
# Schema validation — python jsonschema (full Draft-07) when available, else a
# jq structural fallback (required keys + enum membership + the stdinSha256
# pattern). Mirrors tests/unit/test-adapter-spec-schemas.sh so the runner stays
# green in plain CI with or without `jsonschema` installed. rc 0 valid, 1 reject.
# ---------------------------------------------------------------------------
_HAVE_PY_JSONSCHEMA=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema' >/dev/null 2>&1; then
  _HAVE_PY_JSONSCHEMA=1
fi

_validate_manifest() {
  local file="$1"
  if [[ "$_HAVE_PY_JSONSCHEMA" -eq 1 ]]; then
    python3 - "$SCHEMA" "$file" <<'PY'
import json, sys
from jsonschema import Draft7Validator
schema = json.load(open(sys.argv[1]))
inst = json.load(open(sys.argv[2]))
sys.exit(1 if list(Draft7Validator(schema).iter_errors(inst)) else 0)
PY
    return $?
  fi
  # jq fallback: well-formed JSON + required keys + enum membership + the
  # stdinSha256 64-hex pattern + the four expect axes present. Also enforces the
  # schema's top-level `additionalProperties:false` so the fallback and python
  # jsonschema agree on an unknown-key reject (a manifest with a stray top-level
  # key must FAIL under both validators, not just on a jsonschema-equipped CI).
  jq -e '
    ((keys - ["schema_version","adapter","mode","input","command","expect","files"]) | length == 0)
    and (.schema_version == 1)
    and (.adapter | IN("claude","codex","kiro","agy","gemini","opencode"))
    and (.mode     | IN("dev-new","dev-resume","review","e2e-browser"))
    and (.input    | type == "object")
    and (.command  | type == "object")
    and (.command.argv | type == "array")
    and (.command.stdinSha256 | test("^[0-9a-f]{64}$"))
    and (.command.rc | type == "number")
    and (.command.stdout | type == "string")
    and (.command.stderr | type == "string")
    and (.expect.providerClass | IN("none","quota","auth","config","transient"))
    and (.expect.verdictState  | IN("valid","absent","malformed"))
    and (.expect.vote          | IN("pass","fail","drop","timeout-veto","not-applicable"))
    and (.expect.retryable     | type == "boolean")
  ' "$file" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Stub materialization. Writes a stub binary named <adapter> into <stub_dir>
# that:
#   - records the bytes it reads on stdin to <stub_dir>/.stdin (to assert the
#     prompt reached the stub over the INV-34 channel — non-empty stdin; not a
#     stdinSha256 byte-compare),
#   - if handed `--log-file <path>` (the agy contract) OR an env-named log path,
#     copies the staged log content there so the per-CLI scraper can read it,
#   - emits the recorded stdout/stderr and exits with the recorded rc.
# The recorded stdout/stderr/rc and the staged agy log are passed via files in
# <stub_dir> so the stub stays a tiny argv-agnostic emitter.
# ---------------------------------------------------------------------------
_materialize_stub() {
  local stub_dir="$1" adapter="$2" rc="$3" out_file="$4" err_file="$5" agy_log_src="$6"
  local stub="$stub_dir/$adapter"
  cat > "$stub" <<STUB
#!/bin/bash
# Hermetic stub for adapter '$adapter' (conformance fixture replay).
# Record stdin (the [INV-34] prompt channel) so the runner can assert the prompt
# reached the stub (non-empty .stdin), not a stdinSha256 byte-compare.
cat > "$stub_dir/.stdin"
# Honor an --log-file <path> argument (agy contract): stage the recorded log so
# the per-CLI scraper finds the quota/auth signal where run_agent expects it.
_logf=""
_argv=("\$@")
for ((_i=0; _i<\${#_argv[@]}; _i++)); do
  if [[ "\${_argv[\$_i]}" == "--log-file" ]]; then _logf="\${_argv[\$_i+1]:-}"; fi
done
if [[ -n "\$_logf" && -n "$agy_log_src" && -f "$agy_log_src" ]]; then
  cp "$agy_log_src" "\$_logf" 2>/dev/null || true
fi
[[ -f "$out_file" ]] && cat "$out_file"
[[ -f "$err_file" ]] && cat "$err_file" >&2
exit $rc
STUB
  chmod +x "$stub"
}

# ---------------------------------------------------------------------------
# _classify_fixture <manifest> <work_dir>  → echoes the four-axis tuple the
# classifier produced (`provider|verdict|vote|retryable`), or `__ERR__:<reason>`
# on a materialization/hermeticity failure. rc 0 always (the tuple/err is on
# stdout).
#
# Invokes the stub over the production [INV-34] stdin channel, then classifies the
# recorded process result with the REAL _smoke_classify. _smoke_classify's PASS
# criterion is a model that echoes the smoke nonce on stdout; a fixture's recorded
# `command.stdout` that should classify PASS embeds the literal placeholder
# `<NONCE>`, which the runner substitutes with the live per-call nonce before
# staging — so a "clean verdict" fixture round-trips the nonce exactly as a
# healthy CLI would, and a failure fixture (empty/quota/error stdout) does not.
# ---------------------------------------------------------------------------
_classify_fixture() {
  local manifest="$1" work="$2"
  local adapter mode rc
  adapter="$(_conf_field "$manifest" adapter)"
  mode="$(_conf_field "$manifest" mode)"
  rc="$(_conf_field "$manifest" command.rc)"

  local stub_dir="$work/stub" stage="$work/stage"
  mkdir -p "$stub_dir" "$stage"

  # Stage files{} (logs/sidecars). Each entry: files.<name>.path (relative to the
  # fixture root) → staged under <stage>/<basename>. We track an agy log source
  # for the stub: a `role:"log"` file ALWAYS wins (regardless of `jq keys[]`
  # ordering), else — for an agy fixture only — the first staged file is used as a
  # fallback. This assumes a SINGLE log-role file per fixture (true for every
  # promoted manifest today); a multi-log fixture would need an explicit pick.
  local agy_log_src="" agy_log_is_role=0
  local fkeys
  fkeys="$(jq -r '(.files // {}) | keys[]?' "$manifest" 2>/dev/null)"
  local k path role src base staged
  while IFS= read -r k; do
    [[ -n "$k" ]] || continue
    path="$(jq -r --arg k "$k" '.files[$k].path // empty' "$manifest")"
    role="$(jq -r --arg k "$k" '.files[$k].role // empty' "$manifest")"
    [[ -n "$path" ]] || continue
    base="$(basename "$path")"
    staged="$stage/$base"
    src="$PROJECT_ROOT/tests/conformance/$path"
    # Fall back to the fixture-relative dir if the path is not repo-rooted.
    [[ -f "$src" ]] || src="$FIXTURE_DIR/$base"
    if [[ -f "$src" ]]; then
      cp "$src" "$staged" 2>/dev/null || true
      if [[ "$role" == "log" ]]; then
        # A role:"log" file is authoritative and order-independent.
        agy_log_src="$staged"; agy_log_is_role=1
      elif [[ "$agy_log_is_role" -eq 0 && -z "$agy_log_src" && "$adapter" == "agy" ]]; then
        # Fallback only when no role:"log" file has been (or will be) chosen.
        agy_log_src="$staged"
      fi
    fi
  done <<<"$fkeys"

  # Recorded streams. The PASS placeholder <NONCE> is substituted with the live
  # per-call nonce so a "clean verdict" fixture round-trips it exactly as a
  # healthy CLI would; a failure fixture (empty/quota/error stdout) does not.
  local out_file="$stub_dir/.stdout" err_file="$stub_dir/.stderr"
  _conf_field "$manifest" command.stdout > "$out_file"
  _conf_field "$manifest" command.stderr > "$err_file"

  # The CLI BINARY name run_agent invokes differs from the adapter id for kiro
  # (`kiro-cli`). Materialize the stub under the real binary name so PATH
  # resolution lands on it; the classifier still keys on the adapter id.
  local bin="$adapter"
  [[ "$adapter" == "kiro" ]] && bin="kiro-cli"
  _materialize_stub "$stub_dir" "$bin" "$rc" "$out_file" "$err_file" "$agy_log_src"

  # Hermeticity: the stub MUST exist and be the ONLY resolution for the binary.
  [[ -x "$stub_dir/$bin" ]] || { printf '__ERR__:stub-missing\n'; return 0; }

  # Run the classification in a SUBSHELL with an ISOLATED PATH (stub dir +
  # coreutils only — the real claude/codex/kiro/agy are NEVER on it).
  (
    export PATH="$stub_dir:$_COREUTILS_DIR"
    export PROJECT_ID="conformance"
    export AGENT_CMD="$adapter"
    # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh
    source "$LIB_SMOKE" 2>/dev/null || { printf '__ERR__:lib-source-failed\n'; exit 0; }

    # Hermeticity guard: the binary MUST resolve into the stub dir, never a real
    # CLI. A breach (a system claude/codex/… shadowing the stub) is loud.
    local resolved; resolved="$(command -v "$bin" 2>/dev/null || true)"
    if [[ "$resolved" != "$stub_dir/$bin" ]]; then
      printf '__ERR__:hermeticity-breach:%s\n' "$resolved"; exit 0
    fi

    local nonce; nonce="$(_smoke_nonce)"
    # Substitute the PASS placeholder in the staged stdout with the live nonce.
    if grep -q '<NONCE>' "$out_file" 2>/dev/null; then
      sed -i "s/<NONCE>/$nonce/g" "$out_file" 2>/dev/null || true
    fi
    local prompt; prompt="$(_smoke_prompt "$nonce")"

    # --- INV-34 stdin contract proof (hermeticity): feed the prompt to the stub
    #     over stdin exactly as run_agent does, and assert the stub received it.
    #     This exercises the [INV-34] stdin channel against the real stub without
    #     coupling to each CLI's invocation quirks (codex thread-capture consuming
    #     stdout, opencode/codex PIPESTATUS, kiro binary rename) — those are
    #     invocation properties, not CLASSIFICATION properties, and are covered by
    #     test-lib-agent-prompt-stdin.sh. ---
    printf '%s' "$prompt" | "$stub_dir/$bin" >/dev/null 2>&1 || true
    if [[ ! -s "$stub_dir/.stdin" ]]; then
      printf '__ERR__:stdin-not-fed (prompt did not reach the stub over the INV-34 channel)\n'
      exit 0
    fi

    # Recover the agy --log-file path the stub wrote into (the agy scraper reads
    # the CLI's own --log-file sidecar, derived from PROJECT_ID + session id).
    local agy_log=""
    if [[ "$adapter" == "agy" ]]; then
      agy_log="$(_agy_log_file "$nonce" 2>/dev/null || true)"
      # The above stub invocation passed no --log-file, so stage the recorded
      # quota/auth log at the derived path the agy scraper will read.
      if [[ -n "$agy_log" && -n "$agy_log_src" && -f "$agy_log_src" ]]; then
        mkdir -p "$(dirname "$agy_log")" 2>/dev/null || true
        cp "$agy_log_src" "$agy_log" 2>/dev/null || true
      fi
    fi

    # --- Classify the RECORDED process result via the REAL production classifier.
    #     _smoke_classify (lib-agent-smoke.sh) dispatches to the per-CLI
    #     _classify_<cli>_drop_reason scrapers — this is TODAY's monolithic
    #     drop-reason / verdict-state / vote logic, the contract being pinned. ---
    local classified state tok
    classified="$(_smoke_classify "$adapter" "$rc" "$out_file" "$nonce" "$agy_log" "$err_file")"
    state="${classified%%|*}"

    # Recover the per-CLI scraper token (the provider-class signal) the EXACT way
    # _smoke_classify did, so the projection names the provider axis off the same
    # input the production classifier saw — no re-implemented or narrower copy
    # (INV-73: pin TODAY's logic, not an approximation). Two fidelity points the
    # earlier err-only recovery got wrong:
    #   - kiro/codex scan a COMBINED stdout+stderr view (auth / stream-error text
    #     lands on EITHER stream; lib-agent-smoke.sh:296-310). Scanning err only
    #     misses a signal recorded on stdout.
    #   - codex is called with NO rc (one arg), matching _smoke_classify's call
    #     site: the INV-62 config-error (clap argv rejection) branch then fires on
    #     the rc-less backward-compat path, not gated on rc==2.
    tok=""
    case "$adapter" in
      agy)
        tok="$(_classify_agy_drop_reason "$agy_log")"
        ;;
      kiro|codex)
        # Combined stdout+stderr (order is irrelevant to the substring scrapers),
        # mirroring _smoke_classify's `scan_file` temp.
        local scan_file; scan_file="$(mktemp "${TMPDIR:-/tmp}/conf-scan-XXXXXX" 2>/dev/null || true)"
        if [[ -n "$scan_file" ]]; then
          { [[ -f "$out_file" ]] && cat "$out_file"; [[ -f "$err_file" ]] && cat "$err_file"; } > "$scan_file" 2>/dev/null
        else
          # mktemp failed: fall back to stdout-only, EXACTLY as _smoke_classify
          # does (lib-agent-smoke.sh: `scan_file="$stdout_file"` default) — not
          # stderr-only, which would diverge from the classifier we mirror and
          # miss a signal recorded on stdout (e.g. codex-stream-error-stdout).
          scan_file="$out_file"
        fi
        if [[ "$adapter" == "kiro" ]]; then
          tok="$(_classify_kiro_drop_reason "$scan_file")"
        else
          tok="$(_classify_codex_drop_reason "$scan_file")"
        fi
        # Only drop the combined temp we created; never the recorded out/err files
        # (the mktemp-failure fallback aliases scan_file to one of them).
        [[ "$scan_file" != "$out_file" && "$scan_file" != "$err_file" ]] && rm -f "$scan_file" 2>/dev/null
        ;;
    esac

    # Emit the four-axis tuple the classifier produced.
    _conf_project "$adapter" "$mode" "$state" "$tok" "$rc"
    exit 0
  )
  return 0
}

# ---------------------------------------------------------------------------
# Main — iterate the fixture set, filter, classify, diff, tally.
# ---------------------------------------------------------------------------
main() {
  [[ -d "$FIXTURE_DIR" ]] || { log "FATAL: fixture dir not found: $FIXTURE_DIR"; exit 2; }

  local total=0 pass=0 fail=0 considered=0
  # work_root is a GLOBAL so the EXIT trap can clean it up after main() returns
  # (a `local` would be out of scope at trap time → unbound under `set -u`).
  work_root="$(mktemp -d "${TMPDIR:-/tmp}/conformance-XXXXXX")" || { log "FATAL: mktemp -d failed"; exit 2; }
  trap 'rm -rf "${work_root:-}" 2>/dev/null || true' EXIT

  local f name adapter mode
  for f in "$FIXTURE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    considered=$((considered + 1))
    name="$(basename "$f" .json)"
    adapter="$(_conf_field "$f" adapter)"
    mode="$(_conf_field "$f" mode)"

    # Apply filters (skip silently — a filtered-out fixture is not a fail).
    [[ -z "$FILTER_ADAPTER" || "$adapter" == "$FILTER_ADAPTER" ]] || continue
    [[ -z "$FILTER_MODE"    || "$mode"    == "$FILTER_MODE"    ]] || continue

    total=$((total + 1))
    local label="${adapter:-?}/${mode:-?}/${name}"

    # 1. Schema validation — loud reject.
    if ! _validate_manifest "$f"; then
      printf 'CONFORMANCE %s FAIL schema-invalid (manifest does not satisfy fixture-manifest.schema.json)\n' "$label"
      fail=$((fail + 1)); continue
    fi

    # 2/3/4. Materialize → classify → project.
    local work="$work_root/$name"; mkdir -p "$work"
    local actual_tuple; actual_tuple="$(_classify_fixture "$f" "$work")"

    if [[ "$actual_tuple" == __ERR__:* ]]; then
      printf 'CONFORMANCE %s FAIL %s\n' "$label" "${actual_tuple#__ERR__:}"
      fail=$((fail + 1)); continue
    fi

    # Expected tuple from the manifest's expect{} block.
    local exp_tuple
    exp_tuple="$(_conf_expect_field "$f" providerClass)|$(_conf_expect_field "$f" verdictState)|$(_conf_expect_field "$f" vote)|$(_conf_expect_field "$f" retryable)"

    local diff; diff="$(_conf_axis_diff "$exp_tuple" "$actual_tuple")"
    if [[ -z "$diff" ]]; then
      printf 'CONFORMANCE %s PASS\n' "$label"
      pass=$((pass + 1))
    else
      printf 'CONFORMANCE %s FAIL %s\n' "$label" "$diff"
      fail=$((fail + 1))
    fi
  done

  printf 'CONFORMANCE-SUMMARY total=%d pass=%d fail=%d\n' "$total" "$pass" "$fail"

  # Nothing to assert is a misconfig, not a pass (TC-CONFORMANCE-029): a filter
  # that matched zero fixtures, or an empty fixture dir, is loud.
  if [[ "$total" -eq 0 ]]; then
    log "FATAL: no fixtures matched (considered=${considered}, adapter='${FILTER_ADAPTER}', mode='${FILTER_MODE}')"
    exit 2
  fi

  [[ "$fail" -eq 0 ]]
}

main "$@"
