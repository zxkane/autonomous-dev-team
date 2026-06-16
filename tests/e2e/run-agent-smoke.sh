#!/bin/bash
# run-agent-smoke.sh — agent-CLI smoke matrix harness (INV-63, issue #222).
#
# WHAT IT DOES
# ------------
# Iterates a matrix of agent-CLI entries, runs each entry's smoke_agent
# (lib-agent-smoke.sh) in a CLEAN SUBSHELL with the entry's per-entry env, and
# aggregates the three-state results:
#   any FAIL        → overall rc 1   (operator-side config/launch breakage)
#   UNAVAILABLE     → recorded, NON-blocking (environmental quota/capacity)
#   SKIP            → recorded, NON-blocking (a declared-required env var is
#                                             missing on this box)
# Prints one `SMOKE <agent> <STATE> <elapsed>s reason=<...>` line per entry plus
# a final `SMOKE-SUMMARY pass=N fail=N unavailable=N skip=N` line. Entries run in
# PARALLEL, so overall wall-clock ≈ the slowest entry, not the sum.
#
# OPERATOR USAGE (real CLIs on a dev box)
# ---------------------------------------
#   1. cp tests/e2e/e2e.conf.example tests/e2e/e2e.conf   # gitignored
#   2. edit tests/e2e/e2e.conf for your box's CLIs / creds
#   3. bash tests/e2e/run-agent-smoke.sh
# Each matrix entry is `name|agent_cmd|model|env-setup`; env-setup is eval'd in
# the entry's own subshell (operator-trusted config, same trust model as
# AGENT_LAUNCHER). A leading `require:VAR; ` in env-setup declares VAR mandatory:
# if it is unset/empty after env-setup runs, the entry is SKIP (not FAIL) — used
# for the custom-endpoint entry whose API key lives in a local secrets file.
#
# CI / STUB MODE (no real CLIs or credentials)
# --------------------------------------------
#   SMOKE_STUB=1 bash tests/e2e/run-agent-smoke.sh
# Puts stub CLIs on PATH and uses a bundled stub matrix that exercises every
# branch (PASS, FAIL, UNAVAILABLE, SKIP) so CI runs the FULL harness end-to-end.
# This is the E2E artifact for #222.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_SMOKE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh"

# The matrix file. SMOKE_CONF overrides for tests; default tests/e2e/e2e.conf.
# Remember whether the caller provided SMOKE_CONF explicitly: in stub mode we
# only synthesize the bundled stub matrix when the caller did NOT supply one, so
# `SMOKE_STUB=1 SMOKE_CONF=<custom>` runs the custom matrix against the stub CLIs.
_SMOKE_CONF_FROM_CALLER=0
[[ -n "${SMOKE_CONF:-}" ]] && _SMOKE_CONF_FROM_CALLER=1
SMOKE_CONF="${SMOKE_CONF:-$SCRIPT_DIR/e2e.conf}"

log() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Stub mode — bundle stub CLIs + a stub matrix so the harness runs end-to-end
# with no real CLIs/credentials. Activated by SMOKE_STUB=1.
# ---------------------------------------------------------------------------
_setup_stub_mode() {
  local stub_dir
  stub_dir=$(mktemp -d "${TMPDIR:-/tmp}/smoke-stub-XXXXXX") || {
    log "FATAL: cannot create stub dir"; exit 1
  }
  _SMOKE_STUB_DIR="$stub_dir"

  # A stub agent CLI that echoes back the nonce it is asked for (PASS). The
  # nonce arrives on stdin via the [INV-34] prompt channel; grep it out and
  # print it. `claude`/`gemini`/generic read `-p` from stdin, so a bare reader
  # that echoes the SMOKE-<hex> token works for all of them.
  cat > "$stub_dir/smoke-pass-cli" <<'PASS_CLI'
#!/bin/bash
in=$(cat)
tok=$(printf '%s' "$in" | grep -oE 'SMOKE-[0-9a-f]{16}' | head -1)
printf '%s\n' "$tok"
exit 0
PASS_CLI

  # A stub that NEVER echoes the nonce and exits non-zero with no recognizable
  # signal — the bare `no-response` path. Under [INV-75] this is a TRANSIENT (the
  # CLI died before emitting any signal), so smoke_agent retries it once and, if it
  # stays no-response, classifies UNAVAILABLE — NOT a FAIL. Kept for documentation /
  # potential reuse, but no longer the matrix's FAIL entry (a bare no-response can
  # no longer be the gate-worthy FAIL case).
  cat > "$stub_dir/smoke-noresponse-cli" <<'NORESP_CLI'
#!/bin/bash
cat >/dev/null
echo "stub: simulated transient infra hiccup (no model response, no signal)" >&2
exit 3
NORESP_CLI

  # A stub that emits a GENUINE operator-side config error: the codex `codex review`
  # clap argv rejection (`error: unexpected argument '<flag>' found`) + clap exit 2.
  # _classify_codex_drop_reason recognizes this as `config-error:<flag>` → a FAIL
  # that survives [INV-75] (operator-side breakage is NOT a transient, NOT retried).
  # This is the matrix's FAIL entry post-INV-75 — exercising the still-live
  # "any FAIL → overall rc 1" gate branch with a real config break.
  cat > "$stub_dir/smoke-config-error-cli" <<'CFG_CLI'
#!/bin/bash
cat >/dev/null
echo "error: unexpected argument '--stub-bad-flag' found" >&2
echo "" >&2
echo "Usage: codex review [OPTIONS] [PROMPT]" >&2
exit 2
CFG_CLI

  # A stub `agy`: reads --log-file from argv, writes the committed quota fixture
  # into it, then exits empty (UNAVAILABLE via the agy scraper). This is the
  # #205 shape — rc 0, empty stdout, quota signal only in the log.
  cat > "$stub_dir/smoke-agy-quota" <<AGY_CLI
#!/bin/bash
cat >/dev/null
logf=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --log-file) logf="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$logf" ]] && cp "$PROJECT_ROOT/tests/unit/fixtures/agy-quota-exhausted.fixture" "\$logf" 2>/dev/null
exit 0
AGY_CLI

  chmod +x "$stub_dir"/smoke-pass-cli "$stub_dir"/smoke-noresponse-cli \
    "$stub_dir"/smoke-config-error-cli "$stub_dir"/smoke-agy-quota
  # Symlink the agent-cmd names the stub matrix uses onto the stub binaries. codex
  # is the FAIL entry → point it at the GENUINE config-error stub (a bare
  # no-response would now retry → UNAVAILABLE under [INV-75], so it can no longer
  # be the matrix's gate-worthy FAIL case).
  ln -sf "$stub_dir/smoke-pass-cli" "$stub_dir/claude"
  ln -sf "$stub_dir/smoke-config-error-cli" "$stub_dir/codex"
  ln -sf "$stub_dir/smoke-agy-quota" "$stub_dir/agy"
  export PATH="$stub_dir:$PATH"

  # A bundled stub matrix exercising every branch.
  # Only synthesize the bundled stub matrix when the caller did NOT supply one
  # (so `SMOKE_STUB=1 SMOKE_CONF=<custom>` runs <custom> against the stub CLIs).
  if [[ "$_SMOKE_CONF_FROM_CALLER" -eq 0 ]]; then
    local stub_conf="$stub_dir/e2e.conf"
    cat > "$stub_conf" <<'STUB_CONF'
# name | agent_cmd | model | env-setup (eval'd in the entry subshell)
stub-pass|claude|sonnet|true
stub-fail|codex|gpt|export BEDROCK_AWS_REGION=us-west-2
stub-unavail|agy||true
stub-skip|claude|sonnet|require:SMOKE_NONEXISTENT_KEY; true
STUB_CONF
    SMOKE_CONF="$stub_conf"
  fi
  log "[stub] PATH=$stub_dir; matrix=$SMOKE_CONF"
}

_stub_cleanup() {
  [[ -n "${_SMOKE_STUB_DIR:-}" && -d "${_SMOKE_STUB_DIR:-}" ]] && rm -rf "$_SMOKE_STUB_DIR"
}

# ---------------------------------------------------------------------------
# Matrix parsing — read non-blank, non-comment lines; split on `|` into exactly
# four fields. A line with the wrong field count is a LOUD reject (the whole
# harness fails) — a silently-skipped malformed entry would hide a real CLI from
# the gate.
#
# Populates the parallel arrays _NAMES _AGENTS _MODELS _ENVS. Returns rc 1 on a
# malformed entry or an empty matrix (nothing to smoke is a misconfig, not a
# pass).
# ---------------------------------------------------------------------------
_NAMES=(); _AGENTS=(); _MODELS=(); _ENVS=()
_parse_matrix() {
  local conf="$1"
  [[ -f "$conf" && -r "$conf" ]] || { log "FATAL: matrix not found/readable: $conf"; return 1; }
  local line lineno=0 name agent model env nfields
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    # Strip leading/trailing whitespace for the blank/comment test.
    local trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" || "$trimmed" == \#* ]] && continue
    # Count fields. Exactly 4 `|`-delimited fields required (env may be empty but
    # the 3 separators must be present).
    nfields=$(awk -F'|' '{print NF}' <<<"$line")
    if [[ "$nfields" -ne 4 ]]; then
      log "FATAL: malformed matrix entry at line ${lineno} (expected 4 |-fields, got ${nfields}): ${line}"
      return 1
    fi
    name="${line%%|*}"; line="${line#*|}"
    agent="${line%%|*}"; line="${line#*|}"
    model="${line%%|*}"; line="${line#*|}"
    env="$line"
    # name + agent are mandatory; model + env may be empty.
    if [[ -z "$name" || -z "$agent" ]]; then
      log "FATAL: matrix entry at line ${lineno} missing name or agent_cmd: still parsed ${nfields} fields"
      return 1
    fi
    _NAMES+=("$name"); _AGENTS+=("$agent"); _MODELS+=("$model"); _ENVS+=("$env")
  done < "$conf"

  if [[ ${#_NAMES[@]} -eq 0 ]]; then
    log "FATAL: matrix is empty (no entries in $conf)"
    return 1
  fi
  return 0
}

# _run_entry <idx> <out_file>
#
# Run one matrix entry in a clean subshell: apply its env-setup, honor any
# `require:VAR` directives (missing → emit a SKIP line, rc 3), then call
# smoke_agent and forward its evidence line + rc. Writes the evidence line to
# <out_file>; the rc is carried via the subshell exit code.
#
# rc carried: 0 PASS, 1 FAIL, 2 UNAVAILABLE, 3 SKIP.
_run_entry() {
  local idx="$1" out_file="$2"
  local name="${_NAMES[$idx]}" agent="${_AGENTS[$idx]}" model="${_MODELS[$idx]}" env="${_ENVS[$idx]}"

  (
    # Everything below runs in this entry's OWN subshell, so per-entry env never
    # leaks across entries.
    #
    # ORDER MATTERS (the #222 [P1] fixes — env-setup must be the LAST writer):
    #   1. source the smoke lib — lib-agent.sh's `load_autonomous_conf` re-sources
    #      the project's autonomous.conf, which assigns globals like
    #      BEDROCK_AWS_REGION / CLAUDE_CODE_USE_BEDROCK UNCONDITIONALLY and
    #      tokenizes any shared AGENT_LAUNCHER.
    #   2. THEN clear an INHERITED shared AGENT_LAUNCHER for a non-claude entry —
    #      the launcher is a claude-only contract, so prepending it to a
    #      codex/kiro/agy command is a false FAIL ([P1] review). Done before
    #      env-setup so an entry can still opt back into a CLI-specific launcher.
    #   3. THEN clear an INHERITED AGENT_DEV_EXTRA_ARGS for EVERY entry — these
    #      flags are CLI-SPECIFIC (kiro's --trust-all-tools, gemini's
    #      --approval-mode yolo, …), so an entry inheriting another CLI's conf
    #      flags is a false FAIL ([P1] review). Done before env-setup so an entry
    #      can opt INTO its own CLI's flags. (run_agent reads AGENT_DEV_EXTRA_ARGS
    #      for the fresh-session path that smoke_agent uses.)
    #   4. THEN eval the entry's env-setup — so an env-setup that pins the codex
    #      Bedrock region or blanks the custom-endpoint Bedrock vars OVERRIDES the
    #      conf value (the conf would otherwise clobber it if env-setup ran first).
    #   5. THEN clear an inherited launcher for a CUSTOM-ENDPOINT entry — a claude
    #      entry that env-setup pointed at a custom Anthropic endpoint
    #      (ANTHROPIC_BASE_URL) is still agent_cmd=claude, so step 2 did not fire;
    #      a Bedrock-specific inherited launcher would reintroduce Bedrock / fail
    #      before the custom endpoint runs — a false FAIL ([P1] review). Cleared
    #      only when env-setup did NOT itself set a launcher.
    #   6. THEN re-tokenize AGENT_LAUNCHER — run_agent reads the pre-tokenized
    #      AGENT_LAUNCHER_ARGV[] (built at lib source time), so an AGENT_LAUNCHER
    #      set in env-setup (or the step-5 clear) is honored only after
    #      smoke_retokenize_launcher reruns the tokenization.
    #      (AGENT_CMD/AGENT_TIMEOUT/AGENT_DEV_EXTRA_ARGS are re-read per invocation,
    #      so they need no re-tokenize — only the launcher does.)

    # Source the smoke lib FIRST (loads autonomous.conf + tokenizes the launcher).
    # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh
    if ! source "$LIB_SMOKE" 2>/dev/null; then
      printf 'SMOKE %s FAIL 0s reason=lib-source-failed (entry=%s)\n' "$agent" "$name" >"$out_file"
      exit 1
    fi

    # Neutralize an INHERITED shared AGENT_LAUNCHER for a NON-claude entry, BEFORE
    # env-setup runs (#222 [P1] review fix). AGENT_LAUNCHER is a claude-only
    # contract ([INV-22]/[INV-38]): the canonical `cc` launcher ends in
    # `$CLAUDE_CMD "$@"`, so prepending it to a `codex`/`kiro`/`agy` command yields
    # e.g. `cc codex exec …` which fails — a FALSE FAIL that would block the gate
    # on a healthy non-claude CLI. When the operator's autonomous.conf sets a
    # shared AGENT_LAUNCHER (the documented Bedrock-claude shape), it is inherited
    # into every entry's subshell; clear it for non-claude agents here so it does
    # not survive into smoke_retokenize_launcher. The entry's env-setup runs
    # AFTER this, so an entry can still opt INTO a CLI-specific launcher
    # (`export AGENT_LAUNCHER=…`) — that env-setup value is preserved.
    if [[ "$agent" != "claude" && -n "${AGENT_LAUNCHER:-}" ]]; then
      AGENT_LAUNCHER=""
    fi

    # Neutralize an INHERITED AGENT_DEV_EXTRA_ARGS for EVERY entry, BEFORE env-setup
    # (#222 [P1] review fix). run_agent tokenizes AGENT_DEV_EXTRA_ARGS and appends
    # it to EVERY CLI branch's argv (the fresh-session path smoke_agent uses). The
    # operator's autonomous.conf tunes it for ONE CLI — e.g. `--trust-all-tools`
    # (kiro) or `--approval-mode yolo --output-format stream-json` (gemini). Those
    # flags are CLI-SPECIFIC: feeding kiro's `--trust-all-tools` to codex/claude/agy
    # makes the CLI reject the flag and the smoke reports a FALSE FAIL even though
    # the CLI is healthy. Unlike the launcher (claude-only), there is no single CLI
    # the shared value is correct for, so we clear it for ALL entries; an entry that
    # genuinely needs flags opts in via its own env-setup (`export
    # AGENT_DEV_EXTRA_ARGS=…`), which runs AFTER this clear and is preserved (and is
    # re-read per run_agent invocation, so no re-tokenize is needed).
    AGENT_DEV_EXTRA_ARGS=""

    # Extract `require:VAR` directives from the env-setup. They are leading
    # `require:NAME;` tokens; collect them, then strip them so the remainder is
    # the real env-setup to eval.
    local required=() rest="$env" tok
    while [[ "$rest" =~ ^[[:space:]]*require:([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\;?(.*)$ ]]; do
      required+=("${BASH_REMATCH[1]}")
      rest="${BASH_REMATCH[2]}"
    done

    # Snapshot the launcher value AS IT STANDS BEFORE env-setup runs (the
    # inherited shared value, possibly already cleared above for a non-claude
    # entry). Used by the custom-endpoint neutralize below to tell an inherited
    # launcher apart from one the entry's env-setup explicitly opts into.
    local _launcher_before_envsetup="${AGENT_LAUNCHER:-}"

    # Apply the (de-require'd) env-setup AFTER the lib/conf load, so it is the
    # last writer and its overrides win over the auto-loaded autonomous.conf.
    # eval is intentional — the matrix is operator-trusted config (same trust
    # model as AGENT_LAUNCHER). A parse failure is a FAIL, not a silent skip.
    if [[ -n "${rest//[[:space:]]/}" ]]; then
      if ! eval "$rest" 2>/dev/null; then
        printf 'SMOKE %s FAIL 0s reason=env-setup-failed (entry=%s)\n' "$agent" "$name" >"$out_file"
        exit 1
      fi
    fi

    # Neutralize an INHERITED launcher for a CUSTOM-ENDPOINT entry (#222 [P1]
    # review fix). A claude entry that points at a custom Anthropic-compatible
    # endpoint (env-setup sets ANTHROPIC_BASE_URL and blanks the Bedrock vars) is
    # still `agent_cmd=claude`, so the non-claude clear above did NOT fire and the
    # inherited shared `cc`/Bedrock launcher survives. A Bedrock-specific launcher
    # would then reintroduce Bedrock env (or fail) BEFORE the custom endpoint is
    # exercised — a FALSE FAIL on a healthy MiniMax/custom setup. So: if env-setup
    # turned on a custom endpoint AND did NOT itself set a launcher (the current
    # AGENT_LAUNCHER is byte-identical to the pre-env-setup snapshot, i.e. the
    # inherited value), clear it. An entry that DELIBERATELY set its own launcher
    # in env-setup (value changed from the snapshot) keeps it.
    if [[ -n "${ANTHROPIC_BASE_URL:-}" \
          && -n "${AGENT_LAUNCHER:-}" \
          && "${AGENT_LAUNCHER:-}" == "$_launcher_before_envsetup" ]]; then
      AGENT_LAUNCHER=""
    fi

    # Re-tokenize the launcher so an AGENT_LAUNCHER set in env-setup reaches
    # run_agent (which reads the pre-tokenized AGENT_LAUNCHER_ARGV[]), and so the
    # custom-endpoint clear above is reflected in AGENT_LAUNCHER_ARGV[].
    smoke_retokenize_launcher

    # Honor require: any missing/empty required var → SKIP (rc 3, non-blocking).
    # NOTE: the require: check runs AFTER env-setup (and therefore after the lib
    # source), because a required var may be SET BY env-setup itself — e.g.
    # `require:ANTHROPIC_API_KEY` for the custom-endpoint entry whose env-setup
    # sources a local secrets file that defines the key. Checking before env-setup
    # would spuriously SKIP such an entry. The cost is that a SKIP entry sources
    # the lib (+ re-loads autonomous.conf) before skipping — cheap, and the
    # conf-load is required anyway for the override-ordering in sub-rule 6.
    local missing=""
    for tok in "${required[@]:-}"; do
      [[ -z "$tok" ]] && continue
      if [[ -z "${!tok:-}" ]]; then missing="$tok"; break; fi
    done
    if [[ -n "$missing" ]]; then
      printf 'SMOKE %s SKIP 0s reason=missing-required-env:%s (entry=%s)\n' "$agent" "$missing" "$name" >"$out_file"
      exit 3
    fi

    # Run the smoke. Capture its evidence line; carry its rc out as the subshell
    # exit code.
    local line src_rc
    line=$(smoke_agent "$agent" "$model")
    src_rc=$?
    printf '%s\n' "$line" >"$out_file"
    exit "$src_rc"
  )
}

main() {
  [[ -f "$LIB_SMOKE" ]] || { log "FATAL: lib-agent-smoke.sh not found at $LIB_SMOKE"; exit 1; }

  if [[ "${SMOKE_STUB:-}" == "1" ]]; then
    _setup_stub_mode
    trap _stub_cleanup EXIT
  fi

  _parse_matrix "$SMOKE_CONF" || exit 1

  local n=${#_NAMES[@]}
  log "Running ${n} agent-smoke entries in parallel from ${SMOKE_CONF}"

  # Launch every entry in parallel; each writes its evidence line to a temp file
  # and carries its rc via the background job's exit code.
  local tmp_dir
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/smoke-run-XXXXXX") || { log "FATAL: mktemp -d failed"; exit 1; }
  local pids=() outs=() i
  for ((i = 0; i < n; i++)); do
    local out="$tmp_dir/entry-$i.out"
    outs+=("$out")
    _run_entry "$i" "$out" &
    pids+=($!)
  done

  # Join: collect each entry's rc → tally.
  local pass=0 fail=0 unavail=0 skip=0
  for ((i = 0; i < n; i++)); do
    local rc=0
    wait "${pids[$i]}" || rc=$?
    case "$rc" in
      0) pass=$((pass + 1)) ;;
      2) unavail=$((unavail + 1)) ;;
      3) skip=$((skip + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
  done

  # Print the per-entry evidence lines (in matrix order, deterministic).
  for ((i = 0; i < n; i++)); do
    if [[ -f "${outs[$i]}" ]]; then
      cat "${outs[$i]}"
    else
      printf 'SMOKE %s FAIL 0s reason=no-output (entry=%s)\n' "${_AGENTS[$i]}" "${_NAMES[$i]}"
    fi
  done

  rm -rf "$tmp_dir" 2>/dev/null || true

  printf 'SMOKE-SUMMARY pass=%d fail=%d unavailable=%d skip=%d\n' "$pass" "$fail" "$unavail" "$skip"

  # Any FAIL → overall rc 1. UNAVAILABLE + SKIP are non-blocking.
  [[ "$fail" -eq 0 ]]
}

main "$@"
