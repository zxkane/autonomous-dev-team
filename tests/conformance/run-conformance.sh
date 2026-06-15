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
  # jq fallback: a FAITHFUL structural mirror of fixture-manifest.schema.json —
  # NOT a loose subset. It enforces the SAME required nested fields/types and the
  # SAME `additionalProperties:false` at every object level the schema declares
  # (top-level, input, command, expect, each files entry), so a manifest that
  # python jsonschema would reject (e.g. missing `input.promptBytes`, a non-string
  # `input.env` value, an unknown nested key, a bad `files.<k>.role`) ALSO fails
  # here. This closes the PR #244 [P1]: the fallback must fail-closed on the same
  # malformed manifests, not pass them through when `jsonschema` is unavailable.
  # An integer in JSON parses as jq `number`; `promptBytes` additionally requires
  # the value be an integer ≥ 0 (schema `"type":"integer","minimum":0`).
  jq -e '
    def is_uint: (type == "number") and (. == floor) and (. >= 0);
    # top-level: required keys present, no unknown keys (additionalProperties:false)
    (["schema_version","adapter","mode","input","command","expect"] - keys | length == 0)
    and ((keys - ["schema_version","adapter","mode","input","command","expect","files"]) | length == 0)
    and (.schema_version == 1)
    and (.adapter | IN("claude","codex","kiro","agy","gemini","opencode"))
    and (.mode     | IN("dev-new","dev-resume","review","e2e-browser"))
    # input: object, required {promptBytes:uint, model:string, env:object<string>},
    # additionalProperties:false
    and (.input | type == "object")
    and (["promptBytes","model","env"] - (.input | keys) | length == 0)
    and ((.input | keys) - ["promptBytes","model","env"] | length == 0)
    and (.input.promptBytes | is_uint)
    and (.input.model | type == "string")
    and (.input.env | type == "object")
    and (.input.env | to_entries | all(.value | type == "string"))
    # command: object, required {argv:[string], stdinSha256:64hex, rc:int,
    # stdout:string, stderr:string}, additionalProperties:false
    and (.command | type == "object")
    and (["argv","stdinSha256","rc","stdout","stderr"] - (.command | keys) | length == 0)
    and ((.command | keys) - ["argv","stdinSha256","rc","stdout","stderr"] | length == 0)
    and (.command.argv | type == "array")
    and (.command.argv | all(type == "string"))
    and (.command.stdinSha256 | type == "string")
    and (.command.stdinSha256 | test("^[0-9a-f]{64}$"))
    and (.command.rc | (type == "number") and (. == floor))
    and (.command.stdout | type == "string")
    and (.command.stderr | type == "string")
    # expect: object, required four axes, additionalProperties:false
    and (.expect | type == "object")
    and (["providerClass","verdictState","vote","retryable"] - (.expect | keys) | length == 0)
    and ((.expect | keys) - ["providerClass","verdictState","vote","retryable"] | length == 0)
    and (.expect.providerClass | IN("none","quota","auth","config","transient"))
    and (.expect.verdictState  | IN("valid","absent","malformed"))
    and (.expect.vote          | IN("pass","fail","drop","timeout-veto","not-applicable"))
    and (.expect.retryable     | type == "boolean")
    # files (OPTIONAL): the KEY may be absent, but if PRESENT it MUST be an object
    # (a literal files:null is rejected, matching the schema type:object). Using
    # has("files") distinguishes key-absent from key-present-null, which a bare
    # .files == null cannot. Each entry: path:string (required), sha256?:64hex,
    # role?:enum, additionalProperties:false per entry.
    and ((has("files") | not) or (
      (.files | type == "object")
      and (.files | to_entries | all(
        (.value | type == "object")
        and (.value | has("path")) and (.value.path | type == "string")
        and ((.value | keys) - ["path","sha256","role"] | length == 0)
        # sha256/role are OPTIONAL but, WHEN PRESENT, must be a string (the schema
        # has no "null" in their type) — `has(...)` distinguishes absent (valid)
        # from an explicit null (invalid). A bare `== null` check wrongly accepts
        # `sha256: null` / `role: null`, which Draft-07 rejects (#244 [P1] #2).
        and ((.value | has("sha256") | not) or (.value.sha256 | type == "string" and test("^[0-9a-f]{64}$")))
        and ((.value | has("role") | not) or (.value.role | IN("sidecar","log","artifact","input")))
      ))
    ))
  ' "$file" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# DETERMINISTIC smoke nonce. The runner MUST feed a deterministic prompt so the
# stub-recorded stdin hash is stable and CAN be pinned by `command.stdinSha256`
# (the [P1] requirement — a random per-call nonce makes the hash unreproducible
# and the field non-load-bearing). The nonce keeps the `SMOKE-<16hex>` shape
# _smoke_classify's PASS criterion expects; an all-zero hex is a valid value.
# Exported so the EXIT-trap-safe subshell and the stub both see the same value.
# ---------------------------------------------------------------------------
_CONF_NONCE="SMOKE-0000000000000000"

# ---------------------------------------------------------------------------
# _compare_argv <manifest> <recorded-argv-json> <uuid> <perm_mode> <prompt>
#
# The argv assertion that makes `command.argv` LOAD-BEARING (the PR #244 [P1]
# finding). <recorded-argv-json> is the JSON array the STUB recorded for the
# bytes the REAL dispatch path (run_agent / resume_agent / _run_codex_review)
# actually launched it with — NOT a value the runner synthesized. A regression in
# how an adapter assembles its argv (a dropped flag, a reordered positional, a
# wrong subcommand) makes the recorded argv diverge from the manifest's
# `command.argv` and the fixture FAILs.
#
# Placeholders in the manifest stand for per-run values the adapter fills in:
#   <uuid>            — claude --session-id (a v4 UUID minted per run)
#   <logfile>         — agy --log-file (a per-session path under the pid dir)
#   <prompt>          — the positional prompt (codex review); matched by the
#                       deterministic smoke-prompt signature, not a fixed literal
#   <permission-mode> — claude --permission-mode (AGENT_PERMISSION_MODE)
#   <timeout>         — agy --print-timeout (a coreutils-`timeout` duration)
# rc 0 iff the recorded argv matches (length + per-element), 1 otherwise.
# ---------------------------------------------------------------------------
_compare_argv() {
  local manifest="$1" act_file="$2" uuid="$3" perm_mode="$4" prompt="$5"
  [[ -f "$manifest" && -f "$act_file" ]] || return 1

  jq -n -e \
    --argjson exp "$(jq '.command.argv' "$manifest")" \
    --argjson act "$(cat "$act_file")" \
    --arg uuid "$uuid" \
    --arg prompt "$prompt" \
    --arg perm "$perm_mode" \
    '
    def elem_match(e; a):
      if   e == "<uuid>"            then a | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
      elif e == "<logfile>"         then a | test("\\.log$")
      elif e == "<prompt>"          then (a == $prompt) or (a | test("Reply with EXACTLY this token"))
      elif e == "<permission-mode>" then a == $perm
      elif e == "<timeout>"         then a | test("^[0-9]+[smhd]?$")
      else e == a end;
    ($exp | length) == ($act | length)
    and all(range(0; $exp | length); elem_match($exp[.]; $act[.]))
    ' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Stub materialization. Writes a stub binary named <bin> into <stub_dir> that the
# REAL dispatch path launches on the isolated PATH. The stub:
#   - records the EXACT argv it was launched with to <stub_dir>/.argv.json (so the
#     runner pins it against `command.argv` — making that field load-bearing),
#   - records the EXACT bytes it read on stdin to <stub_dir>/.stdin (so the runner
#     pins sha256(stdin) against `command.stdinSha256` — making THAT field
#     load-bearing; this IS the INV-34 prompt channel),
#   - if handed `--log-file <path>` (the agy contract), copies the staged
#     quota/auth log there so the per-CLI scraper finds it where run_agent expects,
#   - for the bare agy `models` subcommand only, emits CONFORMANCE_AGY_MODELS so
#     the adapter's [INV-50] `agy models` validation passes and `--model` is
#     forwarded (mirrors agy's real dual behavior: `agy models` lists; `agy -p …`
#     runs a turn) — without it the adapter omits --model and the argv diverges,
#   - otherwise emits the recorded command.{stdout,stderr} and exits command.rc.
# The recorded streams/rc and staged log are passed via files so the stub stays a
# tiny emitter; because its OUTPUT *is* the recorded process result, classifying
# the stub's captured output == classifying the recorded result over the real path.
# ---------------------------------------------------------------------------
_materialize_stub() {
  local stub_dir="$1" bin="$2" rc="$3" out_file="$4" err_file="$5" agy_log_src="$6"
  local stub="$stub_dir/$bin"
  local jq_cmd; jq_cmd="$(command -v jq)"
  cat > "$stub" <<STUB
#!/bin/bash
# Hermetic stub for binary '$bin' (conformance fixture replay).
# Record the EXACT argv (argv[0]=basename, then the launched args) for the
# command.argv assertion.
"$jq_cmd" -n '\$ARGS.positional' --args -- "\$(basename "\$0")" "\$@" > "$stub_dir/.argv.json"
# agy [INV-50] model-validation channel: \`agy models\` must list models so the
# adapter forwards a known --model. ONLY the bare \`models\` subcommand triggers it.
if [[ \$# -eq 1 && "\$1" == "models" ]]; then
  printf '%s\n' "\${CONFORMANCE_AGY_MODELS:-}"
  exit 0
fi
# Record stdin (the [INV-34] prompt channel) for the command.stdinSha256 assertion.
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
# on a materialization/hermeticity/contract failure. rc 0 always (tuple/err on
# stdout).
#
# Drives the REAL dispatch path (run_agent / resume_agent / _run_codex_review)
# with the stub on an isolated PATH — so the manifest's `command.argv` and
# `command.stdinSha256` are LOAD-BEARING (PR #244 [P1]): the stub records the
# exact argv it was launched with and the exact stdin bytes it received, and the
# runner asserts both against the manifest before classifying. A regression in
# how an adapter assembles argv or feeds the prompt diverges from the manifest and
# FAILs the fixture (no longer a canned-stdout-only replay).
#
# Then classifies the stub's ACTUAL captured output (which equals the recorded
# command.{stdout,stderr,rc}, since the stub emits them) with the REAL
# _smoke_classify + per-CLI scrapers — TODAY's monolithic logic, by design.
#
# The smoke prompt is fed with a DETERMINISTIC nonce (_CONF_NONCE) so the stdin
# hash is reproducible and pinnable. A PASS fixture's `command.stdout` embeds the
# `<NONCE>` placeholder, substituted with _CONF_NONCE before staging, so a "clean
# verdict" fixture round-trips the nonce exactly as a healthy CLI would.
# ---------------------------------------------------------------------------
_classify_fixture() {
  local manifest="$1" work="$2"
  local adapter mode rc
  adapter="$(_conf_field "$manifest" adapter)"
  mode="$(_conf_field "$manifest" mode)"
  rc="$(_conf_field "$manifest" command.rc)"

  local stub_dir="$work/stub" stage="$work/stage"
  # A guaranteed conf-FREE directory used to neutralize lib-agent.sh's
  # conf-discovery (see the HERMETIC ENV BASELINE block below). It MUST contain no
  # `autonomous.conf` so `load_autonomous_conf` finds nothing via the
  # AUTONOMOUS_CONF_DIR branch.
  local no_conf_dir="$work/no-conf"
  mkdir -p "$stub_dir" "$stage" "$no_conf_dir"

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

  # CANNED streams — the recorded command.{stdout,stderr} the stub EMITS. Kept in
  # dedicated files distinct from the capture targets below so the dispatch path's
  # `>` redirect cannot truncate the stub's own source before it `cat`s it. The
  # PASS placeholder <NONCE> is substituted (in the subshell, after the
  # deterministic nonce is known) so a "clean verdict" fixture round-trips the
  # nonce exactly as a healthy CLI would; a failure fixture does not.
  local canned_out="$stub_dir/.canned_stdout" canned_err="$stub_dir/.canned_stderr"
  _conf_field "$manifest" command.stdout > "$canned_out"
  _conf_field "$manifest" command.stderr > "$canned_err"

  # The CLI BINARY name run_agent invokes differs from the adapter id for kiro
  # (`kiro-cli`). Materialize the stub under the real binary name so PATH
  # resolution lands on it; the classifier still keys on the adapter id.
  local bin="$adapter"
  [[ "$adapter" == "kiro" ]] && bin="kiro-cli"
  _materialize_stub "$stub_dir" "$bin" "$rc" "$canned_out" "$canned_err" "$agy_log_src"

  # Hermeticity: the stub MUST exist and be the ONLY resolution for the binary.
  [[ -x "$stub_dir/$bin" ]] || { printf '__ERR__:stub-missing\n'; return 0; }

  # Run the classification in a SUBSHELL with an ISOLATED PATH (stub dir +
  # coreutils only — the real claude/codex/kiro/agy are NEVER on it).
  (
    export PATH="$stub_dir:$_COREUTILS_DIR"
    export PROJECT_ID="conformance"

    # --- HERMETIC ENV BASELINE (PR #244 [P1] #1) ---
    # The classification must depend ONLY on the fixture's input.env, never on the
    # operator's inherited environment. lib-agent.sh reads operator-facing vars the
    # argv builders splice in (AGENT_DEV_EXTRA_ARGS / AGENT_REVIEW_EXTRA_ARGS) and,
    # at SOURCE time, tokenizes any inherited AGENT_LAUNCHER / AGENT_*_LAUNCHER into
    # the launcher *_ARGV arrays run_agent reads AND validates them (a launcher set
    # with a non-claude per-side CMD makes lib-agent.sh emit an ERROR + `return 1`
    # at source time). A caller with `AGENT_DEV_EXTRA_ARGS=--bogus` would otherwise
    # append `--bogus` to an empty-env fixture's argv (argv-mismatch); a caller with
    # `AGENT_LAUNCHER=cc` would route the dispatch through a launcher not on the
    # isolated PATH (stdin-not-fed). Neutralize the operator surface to an empty
    # baseline BEFORE the source, so the source-time tokenization/validation sees a
    # clean slate and no inherited launcher/extra-args survives. (Empty string, not
    # `unset`: lib-agent.sh expands these UNGUARDED at source time — an `unset`
    # under the runner's `set -u` would abort the subshell on the first reference.)
    export AGENT_DEV_EXTRA_ARGS="" AGENT_REVIEW_EXTRA_ARGS=""
    export AGENT_LAUNCHER="" AGENT_DEV_LAUNCHER="" AGENT_REVIEW_LAUNCHER=""
    export AGENT_DEV_CMD="" AGENT_REVIEW_CMD=""

    # --- NEUTRALIZE CONF DISCOVERY (PR #244 [P1], codex review dc696d40) ---
    # lib-agent.sh::load_autonomous_conf has THREE discovery branches, ALL read at
    # source time: (1) AUTONOMOUS_CONF (a file), (2) AUTONOMOUS_CONF_DIR/autonomous.conf
    # — called as `load_autonomous_conf "${AUTONOMOUS_CONF_DIR:-$_LIB_AGENT_DIR}"`,
    # (3) PROJECT_DIR/scripts/autonomous.conf. Scrubbing only AUTONOMOUS_CONF is NOT
    # enough: an inherited AUTONOMOUS_CONF_DIR pointing at a real project conf (e.g.
    # one with AGENT_DEV_EXTRA_ARGS='--bogus') would splice extra argv into an
    # empty-env fixture (argv-mismatch), and an inherited PROJECT_DIR would do the
    # same via branch 3. CRUCIALLY, setting AUTONOMOUS_CONF_DIR="" does NOT help —
    # the `${AUTONOMOUS_CONF_DIR:-$_LIB_AGENT_DIR}` default treats empty as unset and
    # falls back to $_LIB_AGENT_DIR, which on a self-hosting checkout resolves into a
    # real scripts/ tree that DOES carry a live autonomous.conf. So point the
    # conf-discovery vars at CONCRETE conf-free paths: AUTONOMOUS_CONF at a file that
    # cannot exist, AUTONOMOUS_CONF_DIR + PROJECT_DIR at an empty dir (no
    # autonomous.conf, no scripts/autonomous.conf). All three branches then miss and
    # `load_autonomous_conf` returns 1 — the classification depends ONLY on input.env.
    # This makes the runner self-defending: it no longer relies on the caller passing
    # `env -u PROJECT_DIR`.
    export AUTONOMOUS_CONF="$no_conf_dir/.nonexistent.conf"
    export AUTONOMOUS_CONF_DIR="$no_conf_dir"
    export PROJECT_DIR="$no_conf_dir"

    # --- RESET THE REMAINING argv/LAUNCH KNOBS TO DETERMINISTIC DEFAULTS ---
    # (PR #244 [P1], codex review fff5f671). lib-agent.sh reads MORE operator knobs
    # at source time than the EXTRA_ARGS / launcher / conf surface above — and some
    # are spliced into argv or drive the launch, so an inherited value breaks an
    # empty-env fixture even though it is absent from input.env:
    #   • KIRO_AGENT_NAME — spliced verbatim into the kiro argv as `--agent <name>`
    #     (run_agent). An inherited `KIRO_AGENT_NAME=other` ⇒ both kiro fixtures
    #     FAIL argv-mismatch. The fixtures encode the lib default `autonomous-dev`.
    #   • AGENT_TIMEOUT — the `timeout(1)` duration wrapped around every launch AND
    #     (for agy) forwarded into the argv as `--print-timeout`. An inherited
    #     `AGENT_TIMEOUT=bogus` makes `timeout` reject the duration so the stub
    #     never runs and the prompt never reaches it ⇒ stdin-not-fed, and would
    #     also reshape the agy `--print-timeout` argv ⇒ argv-mismatch. The fixtures
    #     expect the lib default `4h`.
    #   • AGENT_PERMISSION_MODE — claude `--permission-mode`. The `<permission-mode>`
    #     argv placeholder compares against this var so it currently self-absorbs,
    #     but pin the default `auto` as defense-in-depth (so the baseline is explicit
    #     and a future placeholder change can't silently leak it).
    # Reset to the lib's OWN documented defaults (the values the fixtures were
    # recorded against), BEFORE the source so the `${VAR:-default}` reads resolve
    # identically with or without an operator value. input.env is still applied
    # AFTER (a fixture that genuinely wants a non-default re-enables it there).
    # (AGENT_DEV_MODEL / AGENT_REVIEW_MODEL are NOT reset here: run_agent /
    # resume_agent take the model as an explicit positional arg sourced from
    # input.model, so those knobs never reach the argv — verified.)
    export KIRO_AGENT_NAME="autonomous-dev"
    export AGENT_TIMEOUT="4h"
    export AGENT_PERMISSION_MODE="auto"

    # The codex review lane (`_run_codex_review`, INV-62) has its OWN runtime
    # controls, read at call time — NOT at lib source time — so they live outside
    # the lib-agent surface above but still change a codex fixture's behavior when
    # inherited (PR #244 [P1], codex review 1c29ba19):
    #   • CODEX_REVIEW_MAX_RERUNS — the bounded re-run count on a non-zero codex
    #     exit (default 3). An inherited `CODEX_REVIEW_MAX_RERUNS=100000` makes a
    #     transient (rc≠0) fixture re-run 100000× → the run hangs / times out,
    #     despite the value being absent from input.env.
    #   • AGENT_REVIEW_TIMEOUT — the review wall-clock cap (default 1h) that bounds
    #     the re-run loop. An inherited value changes how long the lane runs.
    # Reset both to the lib defaults so a codex fixture's runtime depends ONLY on
    # the manifest. input.env is still applied AFTER (a fixture that genuinely
    # wants a non-default re-enables it).
    export CODEX_REVIEW_MAX_RERUNS="3"
    export AGENT_REVIEW_TIMEOUT="1h"

    # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh
    source "$LIB_SMOKE" 2>/dev/null || { printf '__ERR__:lib-source-failed\n'; exit 0; }

    # AGENT_CMD MUST be set AFTER sourcing: lib-agent.sh's load_autonomous_conf
    # runs at source time and (when a conf is present) would CLOBBER an AGENT_CMD
    # exported beforehand with the operator's configured CLI. With it set after,
    # run_agent dispatches to the fixture's adapter. (The conf is neutralized above,
    # but keep this ordering as defense in depth — it mirrors the smoke matrix
    # harness's documented source-then-set ordering, lib-agent-smoke.sh "WHY".)
    export AGENT_CMD="$adapter"

    # Apply the manifest's input.env AFTER the scrub: it is the ONLY channel by
    # which a fixture opts into an operator var (e.g. codex-cli-error sets
    # AGENT_DEV_EXTRA_ARGS so the offending flag is spliced into the recorded argv).
    local env_keys ek ev
    env_keys="$(jq -r '(.input.env // {}) | keys[]?' "$manifest" 2>/dev/null)"
    while IFS= read -r ek; do
      [[ -n "$ek" ]] || continue
      ev="$(jq -r --arg k "$ek" '.input.env[$k]' "$manifest")"
      export "$ek=$ev"
    done <<<"$env_keys"

    # Hermeticity guard: the binary MUST resolve into the stub dir, never a real
    # CLI. A breach (a system claude/codex/… shadowing the stub) is loud.
    local resolved; resolved="$(command -v "$bin" 2>/dev/null || true)"
    if [[ "$resolved" != "$stub_dir/$bin" ]]; then
      printf '__ERR__:hermeticity-breach:%s\n' "$resolved"; exit 0
    fi

    # DETERMINISTIC nonce + prompt — the stdin hash must be reproducible so
    # command.stdinSha256 is pinnable (PR #244 [P1]).
    local nonce="$_CONF_NONCE"
    # Substitute the PASS placeholder in the CANNED stdout (the stub's source) with
    # the nonce, so a PASS fixture's stub emits the nonce a healthy model would.
    if grep -q '<NONCE>' "$canned_out" 2>/dev/null; then
      sed -i "s/<NONCE>/$nonce/g" "$canned_out" 2>/dev/null || true
    fi
    local prompt; prompt="$(_smoke_prompt "$nonce")"
    local model; model="$(_conf_field "$manifest" input.model)"

    # The agy adapter validates --model against `agy models` ([INV-50]); the stub
    # answers that probe from CONFORMANCE_AGY_MODELS so a known model is forwarded
    # (else the adapter omits --model and the argv diverges). Feed it the fixture's
    # own model so a known-model fixture round-trips its --model argv.
    export CONFORMANCE_AGY_MODELS="$model"
    # A fresh process must NOT inherit a stale models cache from a prior fixture.
    unset _LIB_AGENT_AGY_MODELS_CACHE

    # claude mints a real v4 session id; the others ignore it. Use a deterministic
    # UUID-shaped id for claude so the <uuid> argv placeholder has a value to match
    # AND the agy --log-file path is stable.
    local session_id="00000000-0000-4000-8000-000000000000"

    # --- Drive the REAL dispatch path with the stub on PATH. The stub records the
    #     argv it was launched with (.argv.json) and the stdin it received
    #     (.stdin); we assert both below. The stub EMITS the canned streams, which
    #     we capture into .actual_{stdout,stderr} (distinct from the .canned_*
    #     source files so the `>` redirect cannot truncate the stub's own input).
    #     The classifier then reads the captured streams — the recorded result as
    #     produced over the live path. ---
    local out_file="$stub_dir/.actual_stdout" err_file="$stub_dir/.actual_stderr"
    : >"$out_file"; : >"$err_file"
    if [[ "$mode" == "dev-resume" ]]; then
      resume_agent "$session_id" "$prompt" "$model" "conformance" >"$out_file" 2>"$err_file" || true
    elif [[ "$mode" == "review" && "$adapter" == "codex" ]]; then
      # codex review has its own launch controller (no run_agent path, INV-62). It
      # writes codex's CLEAN review stdout to the file arg; stderr is not captured
      # by the controller, so the canned stderr (a stream-error blip) is folded in.
      # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-codex.sh
      source "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-codex.sh" 2>/dev/null \
        || { printf '__ERR__:lib-review-codex-source-failed\n'; exit 0; }
      # Feed /dev/null on stdin (PR #244 [P1], codex review 1c29ba19): the codex
      # review path carries the prompt as an argv positional and does NOT pipe a
      # prompt, but the hermetic stub unconditionally runs `cat > .stdin` to record
      # the [INV-34] channel. On a CI runner stdin is already EOF so `cat` returns
      # instantly; on a LOCAL standalone run from a terminal the stub would block
      # on the TTY forever (rc 124). Redirect /dev/null so the stub reads immediate
      # EOF on every host — recording empty stdin, which matches the codex fixtures'
      # empty-string `command.stdinSha256` (the argv-positional prompt).
      _run_codex_review "$prompt" "$model" "$out_file" "$PWD" </dev/null >/dev/null 2>&1 || true
      cp "$canned_err" "$err_file" 2>/dev/null || true
    else
      # dev-new / review (non-codex) / e2e-browser all launch via run_agent.
      run_agent "$session_id" "$prompt" "$model" "conformance" >"$out_file" 2>"$err_file" || true
    fi

    # --- stdin assertion: the prompt MUST have reached the stub. codex review
    #     carries the prompt as an argv POSITIONAL (empty stdin → empty-string
    #     hash), so a missing .stdin is only a failure for the stdin-fed adapters. ---
    local empty_sha="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    local actual_sha="$empty_sha"
    if [[ -f "$stub_dir/.stdin" ]]; then
      actual_sha="$(sha256sum "$stub_dir/.stdin" 2>/dev/null | cut -d' ' -f1)"
    fi
    local expected_sha; expected_sha="$(_conf_field "$manifest" command.stdinSha256)"
    if [[ "$expected_sha" != "$empty_sha" && ! -f "$stub_dir/.stdin" ]]; then
      printf '__ERR__:stdin-not-fed (prompt did not reach the stub over the INV-34 channel)\n'
      exit 0
    fi

    # --- command.argv assertion (LOAD-BEARING): the argv the dispatch path
    #     actually launched the stub with MUST match the manifest. ---
    local recorded_argv="$stub_dir/.argv.json"
    if ! _compare_argv "$manifest" "$recorded_argv" "$session_id" "$AGENT_PERMISSION_MODE" "$prompt"; then
      printf '__ERR__:argv-mismatch (recorded: %s)\n' "$(cat "$recorded_argv" 2>/dev/null || printf '<none>')"
      exit 0
    fi

    # --- command.stdinSha256 assertion (LOAD-BEARING): the bytes the dispatch
    #     path fed the stub on stdin MUST hash to the manifest's recorded value. ---
    if [[ "$actual_sha" != "$expected_sha" ]]; then
      printf '__ERR__:stdin-sha-mismatch (recorded: %s expected: %s)\n' "$actual_sha" "$expected_sha"
      exit 0
    fi

    # Recover the agy --log-file path the dispatch path passed the stub (the agy
    # scraper reads the CLI's own --log-file sidecar, derived from PROJECT_ID +
    # session id). run_agent already handed the stub `--log-file <agy_log>` and the
    # stub copied the staged quota/auth log there, so it is in place for the scraper.
    local agy_log=""
    if [[ "$adapter" == "agy" ]]; then
      agy_log="$(_agy_log_file "$session_id" 2>/dev/null || true)"
      # Defensive: if the stub did not stage the log (e.g. an argv without
      # --log-file), stage it at the derived path so the scraper still reads it.
      if [[ -n "$agy_log" && ! -f "$agy_log" && -n "$agy_log_src" && -f "$agy_log_src" ]]; then
        mkdir -p "$(dirname "$agy_log")" 2>/dev/null || true
        cp "$agy_log_src" "$agy_log" 2>/dev/null || true
      fi
    fi

    # --- Classify the ACTUAL captured process result via the REAL production
    #     classifier. _smoke_classify (lib-agent-smoke.sh) dispatches to the
    #     per-CLI _classify_<cli>_drop_reason scrapers — TODAY's monolithic
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
    #   - codex is called WITH the fixture rc as the 2nd arg, matching the
    #     production review wrapper (autonomous-review.sh's drop-loop), so the
    #     INV-62 config-error (clap argv rejection) branch is gated on rc == 2 —
    #     a transient codex (rc 1) whose capture merely quotes a clap line falls
    #     through to stream-error, not config (PR #244 [P1], review fff5f671). See
    #     the call site below.
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
          # Pass the fixture's launch rc as the 2nd arg — production passes it
          # (autonomous-review.sh's drop-loop: `_classify_codex_drop_reason <log>
          # <launch-rc>`), and the classifier GATES the config-error bucket on
          # rc == 2 (clap's parse-error exit). Omitting the rc skipped the gate
          # (backward-compat), so a transient codex fixture (rc 1) whose capture
          # merely QUOTES a clap line ("error: unexpected argument '-s' found")
          # was mislabeled `config` instead of falling through to stream-error /
          # empty as production does. (PR #244 [P1], codex review fff5f671.)
          tok="$(_classify_codex_drop_reason "$scan_file" "$rc")"
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
