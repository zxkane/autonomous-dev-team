#!/bin/bash
# lib-agent-smoke.sh — three-state agent-CLI smoke check (INV-63, issue #222).
#
# WHY this exists
# ---------------
# This repo's PRs routinely change lib-agent.sh and the per-CLI invocation
# branches, but nothing executes the REAL CLIs end-to-end before merge. Unit
# tests stub the CLIs, so the launch → auth → model chain is never exercised.
# Past incidents an agent smoke would have caught AT PR TIME:
#   - codex fan-out members dropped `unavailable` on every review due to a
#     BEDROCK_AWS_REGION env pollution (#180 root cause);
#   - agy silent exit-0 with no model call on a quota wall (#205);
#   - kiro auth/login token expiry (#215).
# "Can it run" is the bar: CLI starts → auth works → model TRULY responds.
#
# THE THREE-STATE CONTRACT (the load-bearing design decision)
# -----------------------------------------------------------
# smoke_agent <agent-cmd> <model> [timeout-seconds]  → one of three rcs:
#
#   rc 0  PASS         — stdout contains the nonce; the model truly responded.
#   rc 2  UNAVAILABLE  — quota exhausted / backend model capacity / transient
#                        backend failure, OR a BARE timeout with no auth/config
#                        signal (#246: a Bedrock slow-start / capacity blip — see
#                        _smoke_classify step 4). ENVIRONMENTAL, self-healing — NOT
#                        a failure. A follow-up gate records but does NOT block on
#                        this (promoting it to a deciding FAIL would block every PR
#                        whenever an agent's daily quota is spent or its backend
#                        has a one-off slow tick).
#   rc 1  FAIL         — EVERYTHING ELSE: the CLI fails to launch, an auth/config
#                        error, region drift, or a non-timeout no-response (a
#                        prompt non-zero exit with no nonce and no signal).
#                        Operator-side configuration breakage — this is what the
#                        gate exists to catch. (A timeout that DOES carry an
#                        auth/config scraper signal is still FAIL — the signal wins
#                        before the bare-timeout rule; only the bare timeout moved
#                        to UNAVAILABLE in #246.)
#
# The split mirrors [INV-40]'s review-side treatment of `unavailable`:
# FAIL = operator-side config/launch breakage (gate-worthy), UNAVAILABLE =
# environmental quota/capacity (ignorable).
#
# MECHANISM — reuse the production chain, NO parallel invocation path
# ------------------------------------------------------------------
# smoke_agent generates a random nonce, builds a "reply with exactly this token,
# use no tools" prompt, sets AGENT_CMD=<agent-cmd> + a short AGENT_TIMEOUT
# override, and calls the EXISTING run_agent (lib-agent.sh). So the smoke
# exercises the exact production chain — [INV-34] stdin channel, [INV-50] agy
# model validation, launcher handling, EXTRA_ARGS parsing — with zero duplicated
# invocation code.
#
# CLASSIFICATION reuses the existing per-CLI drop-reason scrapers:
#   agy   — _classify_agy_drop_reason   (INV-58): quota/auth from --log-file
#   kiro  — _classify_kiro_drop_reason  (INV-61): browser/device-flow auth
#   codex — _classify_codex_drop_reason (INV-62): upstream-5xx stream error
# Quota/capacity/transient-backend signal → UNAVAILABLE; auth/config signal → FAIL.
# A BARE timeout (rc 124/137) with NO scraper signal → UNAVAILABLE (#246: a
# Bedrock slow-start / capacity blip, environmental). Any OTHER no-signal outcome
# (a non-timeout prompt non-zero exit with no nonce) → FAIL — the model never
# answered and there is no environmental excuse → conservative, gate-worthy
# default.
#
# LAYER: wrapper-free. A follow-up issue will consume smoke_agent from the review
# wrapper as a pre-fan-out gate (Phase A.5); this lib deliberately carries NO
# wrapper-specific assumptions — it needs only lib-agent.sh + the three
# drop-reason libs, sourced by BASH_SOURCE-relative path ([INV-14] symlink-vendor
# pattern), and never touches GitHub.

# ---------------------------------------------------------------------------
# Source dependencies via the [INV-14] symlink-vendor pattern: ${BASH_SOURCE[0]}
# (NOT readlink -f) so the per-project scripts/ symlink resolves to the project's
# vendored copy rather than the skill installation dir.
# ---------------------------------------------------------------------------
_LIB_AGENT_SMOKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# lib-agent.sh sources lib-config.sh and may `return 1` on a launcher-parse
# error; we source it once. Guard against double-source (the harness may source
# this lib and lib-agent.sh independently) by checking for run_agent.
if ! declare -F run_agent >/dev/null 2>&1; then
  # shellcheck source=lib-agent.sh
  source "${_LIB_AGENT_SMOKE_DIR}/lib-agent.sh"
fi
# shellcheck source=lib-review-agy.sh
source "${_LIB_AGENT_SMOKE_DIR}/lib-review-agy.sh"
# shellcheck source=lib-review-kiro.sh
source "${_LIB_AGENT_SMOKE_DIR}/lib-review-kiro.sh"
# shellcheck source=lib-review-codex.sh
source "${_LIB_AGENT_SMOKE_DIR}/lib-review-codex.sh"

# Default smoke timeout (seconds). A smoke is a one-token round-trip; 120s is
# generous headroom for cold-start auth + first-token latency on a slow backend.
SMOKE_DEFAULT_TIMEOUT_SECONDS="${SMOKE_DEFAULT_TIMEOUT_SECONDS:-120}"

# smoke_retokenize_launcher — re-tokenize the CURRENT $AGENT_LAUNCHER into
# AGENT_LAUNCHER_ARGV[]. rc 0 always (best-effort).
#
# WHY: lib-agent.sh tokenizes AGENT_LAUNCHER → AGENT_LAUNCHER_ARGV ONCE at source
# time, and run_agent reads the pre-tokenized ARRAY (not the live string). The
# matrix harness sources this lib and only THEN applies the per-entry env-setup
# (so env-setup can override conf values that lib-agent.sh's `load_autonomous_conf`
# assigns at source time — see run-agent-smoke.sh::_run_entry / [INV-63]). An AGENT_LAUNCHER set
# in env-setup would therefore be silently ignored unless we re-tokenize after
# env-setup. This helper does exactly that, mirroring lib-agent.sh's own eval +
# empty-array WARN, so an env-setup launcher is honored without re-sourcing the
# lib. A malformed value degrades to an empty (launcher-less) argv with a WARN —
# never aborts (a single entry's typo must not crash the harness).
smoke_retokenize_launcher() {
  AGENT_LAUNCHER="${AGENT_LAUNCHER:-}"
  # Hard reset: unset then re-declare global so a pre-existing array (populated
  # by lib-agent.sh's source-time tokenization, or a sibling caller) cannot leave
  # stale leading elements behind.
  unset AGENT_LAUNCHER_ARGV
  declare -ga AGENT_LAUNCHER_ARGV=()
  [[ -n "$AGENT_LAUNCHER" ]] || return 0
  if ! eval "AGENT_LAUNCHER_ARGV=($AGENT_LAUNCHER)" 2>/dev/null; then
    echo "[lib-agent-smoke] WARN: AGENT_LAUNCHER from env-setup failed to parse as a shell argv list; treating as unset. Value: ${AGENT_LAUNCHER}" >&2
    AGENT_LAUNCHER=""
    AGENT_LAUNCHER_ARGV=()
    return 0
  fi
  if [[ ${#AGENT_LAUNCHER_ARGV[@]} -eq 0 ]]; then
    echo "[lib-agent-smoke] WARN: AGENT_LAUNCHER from env-setup tokenized to zero argv elements; treating as unset. Value: ${AGENT_LAUNCHER}" >&2
  fi
  return 0
}

# _smoke_nonce — emit a fresh per-call nonce: `SMOKE-<16 lowercase hex>`.
#
# Uniqueness is load-bearing (a stale-stdout false-PASS would defeat the smoke),
# so we prefer a CSPRNG and fall back through three sources:
#   1. openssl rand -hex 8                 (best — true randomness)
#   2. /dev/urandom via od                 (kernel CSPRNG)
#   3. PID + a monotonic per-process counter (worst — but still collision-free
#      WITHIN a process, which is all the tests and the parallel harness need;
#      each entry runs in its own subshell ⇒ distinct PID).
# `$RANDOM` alone is deliberately NOT the primary source — a tight loop in one
# shell reseeds slowly and can repeat (TC-AGENT-SMOKE-009).
_SMOKE_NONCE_COUNTER=0
_smoke_nonce() {
  local hex
  if hex=$(openssl rand -hex 8 2>/dev/null) && [[ "$hex" =~ ^[0-9a-f]{16}$ ]]; then
    printf 'SMOKE-%s\n' "$hex"
    return 0
  fi
  if hex=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') && [[ "$hex" =~ ^[0-9a-f]{16}$ ]]; then
    printf 'SMOKE-%s\n' "$hex"
    return 0
  fi
  # Deterministic-but-unique fallback: PID + counter, zero-padded to keep the
  # 16-hex shape. Increment first so two calls in the same process never collide.
  _SMOKE_NONCE_COUNTER=$((_SMOKE_NONCE_COUNTER + 1))
  printf 'SMOKE-%016x\n' $(( ($$ << 20) ^ _SMOKE_NONCE_COUNTER ))
}

# _smoke_session_id — emit a fresh, VALID RFC-4122 UUID for the smoke session.
#
# WHY a UUID (not the old `smoke-<agent>-<pid>-…` string): the Claude Code CLI
# REJECTS `--session-id` unless it is a valid UUID, so every real claude /
# claude-custom-endpoint smoke entry would fail at LAUNCH — before any model
# call — even with healthy auth/config (#222 [P1] review). run_agent's claude
# branch passes the smoke's session_id straight to `--session-id`, so it must be
# UUID-shaped. (codex/opencode mint their own ids and ignore ours; kiro/agy/
# gemini tolerate any string — but claude is the gate, so we always emit a UUID.)
#
# Source ladder (each validated against the canonical 8-4-4-4-12 lowercase-hex
# shape before use):
#   1. /proc/sys/kernel/random/uuid   (Linux kernel UUID — the prod box)
#   2. uuidgen                        (macOS / portable; lowercased)
#   3. /dev/urandom via od            (construct a v4-shaped UUID from 16 bytes)
#   4. PID + RANDOM + counter          (last-resort; still UUID-SHAPED so claude
#                                       accepts it — uniqueness within a process
#                                       is all the parallel harness needs)
_smoke_session_id() {
  local u
  if u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) \
     && [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    printf '%s\n' "$u"; return 0
  fi
  if u=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]') \
     && [[ "$u" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    printf '%s\n' "$u"; return 0
  fi
  # Construct a v4-shaped UUID from 16 random bytes (set version nibble to 4 and
  # variant bits to 10xx, matching RFC-4122 so it is a well-formed v4 UUID).
  local h
  if h=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') && [[ ${#h} -eq 32 ]]; then
    printf '%s-%s-4%s-%x%s-%s\n' \
      "${h:0:8}" "${h:8:4}" "${h:13:3}" \
      "$(( 0x8 + (0x${h:16:1} & 0x3) ))" "${h:17:3}" "${h:20:12}"
    return 0
  fi
  # Last resort: deterministic-but-unique, still 8-4-4-4-12 hex. Increment the
  # shared nonce counter so two calls in the same process differ. Pad/truncate to
  # the canonical widths.
  _SMOKE_NONCE_COUNTER=$((_SMOKE_NONCE_COUNTER + 1))
  local seed
  seed=$(printf '%08x%08x%08x%08x' "$$" "${RANDOM}" "${RANDOM}" "$_SMOKE_NONCE_COUNTER")
  printf '%s-%s-4%s-8%s-%s\n' \
    "${seed:0:8}" "${seed:8:4}" "${seed:13:3}" "${seed:17:3}" "${seed:20:12}"
}

# _smoke_prompt <nonce> — the minimal model round-trip prompt. Asks for the
# exact token and nothing else, explicitly forbids tool use (a smoke must not
# touch the workspace). Kept terse so even a small/cheap model complies.
_smoke_prompt() {
  local nonce="$1"
  printf 'Reply with EXACTLY this token and nothing else: %s\nDo not use any tools. Do not explain. Output only the token.\n' "$nonce"
}

# _smoke_stdout_has_nonce <stdout_file> <nonce>
#
# rc 0 iff <stdout_file> contains <nonce> after TTY sanitization. rc 1 otherwise
# (incl. empty/missing/unreadable file). Fail-safe — never aborts under set -e.
#
# WHY sanitize (the #222 operator live-matrix [BLOCKING]): kiro `--no-interactive`
# stdout wraps the model response in terminal decoration AND injects a BEL (0x07)
# byte INSIDE the echoed token — captured stdout literally contains
# `SMOKE-<0x07><hex>`, so a raw `grep -qF "$nonce"` never matches a verified-healthy
# kiro and it is misclassified `no-response` FAIL. On a healthy box that would rc-1
# every PR (this repo's own command-mode E2E) and smoke-fail every healthy kiro
# fleet member under the future Phase A.5 gate (#224).
#
# The sanitization:
#   tr -d '\000-\010\013-\037\177'  — strip C0 control bytes (NUL..BS, VT..US) and
#       DEL, which covers the injected BEL (0x07). Deliberately KEEPS \n (012) and
#       \t (011) so multi-line / tab-decorated output is unchanged structurally.
#   sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'  — strip ANSI CSI escape sequences (cursor
#       moves, colors) that kiro/other CLIs wrap the token in.
# then grep -qF the nonce. This only ever RECOVERS a hidden real match — it cannot
# widen the false-PASS surface: the caller still gates on rc==0 and reads stdout
# only, and the nonce's 16-hex uniqueness still enforces an exact token match.
_smoke_stdout_has_nonce() {
  local stdout_file="$1" nonce="$2"
  [[ -n "$stdout_file" && -f "$stdout_file" ]] || return 1
  # CAPTURE the sanitized text, then glob-substring-match — do NOT pipe into
  # `grep -q`. A trailing `grep -q` early-exits on the first match and closes its
  # stdin, so the upstream `tr`/`sed` die with SIGPIPE; under the wrappers'
  # `set -o pipefail` the pipeline rc becomes 141 (128+13) DESPITE a successful
  # match, which the caller's `&& _smoke_stdout_has_nonce` reads as false → a
  # false `no-response` FAIL whenever the nonce lands early in >~64 KB of stdout
  # (a CLI that streams the token then emits a large banner/narration). Capturing
  # into a var and using a bash `[[ == *…* ]]` glob has no pipe and no early-exit,
  # so it is SIGPIPE-immune (#222 operator-review follow-up). The capture is a
  # one-token smoke (output is small in the healthy case; a pathological multi-MB
  # stdout is bounded by the wrapper's own capture, not re-read here).
  local cleaned
  cleaned=$(tr -d '\000-\010\013-\037\177' < "$stdout_file" 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' 2>/dev/null) || return 1
  [[ "$cleaned" == *"$nonce"* ]]
}

# _smoke_classify <agent> <rc> <stdout_file> <nonce> <agy_log> [stderr_file]
#
# Pure decision function: maps (agent, run_agent rc, captured stdout, nonce, agy
# log path, captured stderr) to a smoke state. Echoes ONE line `STATE|reason` on
# stdout, where STATE ∈ {PASS,UNAVAILABLE,FAIL}. rc of THIS function is always 0
# — the STATE is carried on stdout, not in $?, so the caller never trips `set -e`
# on a FAIL. The `STATE|reason` single-line shape is command-substitution-safe (a
# nameref out-var would not survive `$(...)`).
#
# STREAM SEPARATION (#222 [P1] review): the nonce PASS check reads **only
# stdout**, never stderr. A broken CLI/wrapper that echoes the stdin prompt (which
# CONTAINS the nonce) onto STDERR and exits non-zero must NOT be reported PASS —
# no model response occurred. The per-CLI drop-reason scrapers (kiro/codex) DO
# scan stderr too, since a CLI's auth / stream-error text legitimately lands on
# either stream; they receive a combined stdout+stderr view. The agy scraper reads
# its own separate `--log-file`, unaffected by stream merging.
#
# Decision order (first match wins):
#   1. nonce present in STDOUT ONLY         → PASS         reason=nonce-ok
#   2. environmental signal (per-CLI scraper, quota/capacity/transient) → UNAVAILABLE
#   3. auth/config signal (per-CLI scraper) → FAIL         reason=<scraper phrase>
#   4. run_agent rc 124/137 (timeout/kill)  → UNAVAILABLE  reason=timeout   (#246)
#   5. otherwise (non-timeout, no nonce, no signal) → FAIL  reason=no-response
#
# Note step 2/3 (the per-CLI scrapers) are checked BEFORE the timeout step: an agy
# whose --log-file shows a quota wall, or a kiro whose capture shows auth-failed,
# but whose CLI then hung to the timeout, resolves by the scraper signal — quota →
# UNAVAILABLE (TC-AGENT-SMOKE-008), auth/config → FAIL (TC-AGENT-SMOKE-008c/d) —
# NOT by the bare-timeout rule below. The step-4 reclassification (#246) only
# changes the BARE timeout (no scraper signal) from FAIL to UNAVAILABLE: a bare
# 124/137 on a Bedrock-backed CLI is a transient slow-start / capacity blip, the
# same environmental tolerance as a quota wall — so the member is dropped, not the
# whole [INV-64] review aborted. A non-timeout prompt non-zero exit (step 5) stays
# FAIL (launch/config failure, not a capacity blip).
_smoke_classify() {
  local agent="$1" rc="$2" stdout_file="$3" nonce="$4" agy_log="$5" stderr_file="${6:-}"

  # 1. PASS — the model echoed the exact nonce ON STDOUT *and* run_agent exited 0.
  #    The nonce is a unique 16-hex blob, so the match is exact (a truncated/garbled
  #    echo will not match). STDOUT ONLY — a prompt echoed onto stderr is NOT a
  #    model response (#222 [P1] r1).
  #    The `rc == 0` gate is the SECOND half of that [P1] (#222 [P1] r2): a broken
  #    CLI/wrapper can echo the stdin prompt (which CONTAINS the nonce) to STDOUT
  #    and THEN exit non-zero (launch/config failure after the echo). Without the
  #    rc gate that reads as PASS despite no real model response. Requiring a
  #    successful underlying run closes it — a healthy model round-trip exits 0,
  #    and a non-zero exit falls through to the drop-reason scrapers / timeout /
  #    no-response classification below.
  #    The nonce check runs over a TTY-SANITIZED view of stdout (_smoke_stdout_has_nonce):
  #    kiro `--no-interactive` wraps its response in terminal decoration AND injects
  #    a BEL (0x07) INSIDE the echoed token (captured stdout literally contains
  #    `SMOKE-^G<hex>`), so a raw `grep -qF "$nonce"` never matches a verified-healthy
  #    kiro → false `no-response` FAIL (#222 operator live-matrix review). Stripping
  #    C0 control bytes + ANSI CSI before the match fixes it WITHOUT widening the
  #    false-PASS surface: the strip can only RECOVER a hidden real match, the rc==0
  #    gate and stdout-only separation are unchanged, and the nonce's uniqueness still
  #    enforces exactness.
  if [[ "$rc" == "0" ]] && _smoke_stdout_has_nonce "$stdout_file" "$nonce"; then
    printf 'PASS|nonce-ok\n'
    return 0
  fi

  # 2/3. Per-CLI drop-reason scraper. The kiro/codex scrapers scan a COMBINED
  #      stdout+stderr view (auth / stream-error text can land on either stream);
  #      build it into a temp and clean it up. agy uses its own --log-file. Each
  #      scraper echoes a token (or empty) and is rc-0-always (fail-safe under
  #      set -euo pipefail).
  local tok="" phrase="" combined="" scan_file="$stdout_file"
  if [[ "$agent" == "kiro" || "$agent" == "codex" ]]; then
    combined=$(mktemp "${TMPDIR:-/tmp}/smoke-combined-XXXXXX" 2>/dev/null) || combined=""
    if [[ -n "$combined" ]]; then
      # Concatenate stdout then stderr (order does not matter to the substring
      # scrapers). Missing files contribute nothing.
      { [[ -f "$stdout_file" ]] && cat "$stdout_file"; [[ -n "$stderr_file" && -f "$stderr_file" ]] && cat "$stderr_file"; } > "$combined" 2>/dev/null
      scan_file="$combined"
    fi
  fi
  case "$agent" in
    agy)
      tok=$(_classify_agy_drop_reason "$agy_log")
      phrase=$(_agy_drop_reason_phrase "$tok")
      ;;
    kiro)
      tok=$(_classify_kiro_drop_reason "$scan_file")
      phrase=$(_kiro_drop_reason_phrase "$tok")
      ;;
    codex)
      tok=$(_classify_codex_drop_reason "$scan_file")
      phrase=$(_codex_drop_reason_phrase "$tok")
      ;;
  esac
  # The scrapers have read scan_file synchronously; drop the combined temp now so
  # every downstream return path is leak-free without per-branch cleanup.
  [[ -n "$combined" ]] && rm -f "$combined" 2>/dev/null
  case "$tok" in
    # quota/capacity/transient-backend signal → environmental (UNAVAILABLE).
    # `malformed-output` (codex INV-73: a prompt-echo / startup-trace instead of a
    # response) is also environmental, NOT operator-side breakage — the CLI ran but
    # emitted garbage, the same "drop the member, don't FAIL the whole Phase A.5
    # fan-out" tolerance a bare timeout (INV-67) / stream-error gets. FAILing on it
    # would let one misbehaving codex strand the issue in `reviewing` (INV-64).
    quota-exhausted*|stream-error*|malformed-output)   printf 'UNAVAILABLE|%s\n' "$phrase"; return 0 ;;
    # auth / config breakage → operator-side (FAIL). `config-error[:<flag>]` is the
    # codex INV-62 token (an exec-only flag rejected by `codex review`'s clap
    # parser); like auth-failed it is operator-side config breakage, so FAIL — and
    # surfacing the specific rejected flag is the observability win the per-CLI
    # scraper exists for (otherwise it would fall through to a generic no-response).
    auth-failed|config-error*)        printf 'FAIL|%s\n' "$phrase";        return 0 ;;
  esac

  # 4. Timeout / kill with no nonce and NO auth/config signal → UNAVAILABLE (#246).
  #    A smoke is a one-token round-trip, and this branch is reached ONLY after the
  #    per-CLI auth/config scrapers (steps 2/3) have already had their say — so a
  #    `124`/`137` here is a BARE timeout with no operator-side evidence. On a
  #    Bedrock-backed CLI (codex via IAM-role→Bedrock, or any model whose
  #    first-token latency is backend-capacity dependent) a bare timeout is far
  #    more likely a transient backend slow-start / capacity blip than a config
  #    hang — i.e. ENVIRONMENTAL. Classifying it FAIL made one slow member abort an
  #    entire Phase A.5 review fan-out ([INV-64]), stranding the issue in
  #    `reviewing` for hours (a healthy codex that smoked PASS in 9s on another
  #    dispatch the same day). So a bare timeout is UNAVAILABLE — the member is
  #    dropped and the review proceeds on the survivors, the same tolerance
  #    [INV-40] / [INV-58] (agy quota) / [INV-61] (kiro auth) apply: environmental
  #    → drop, never a deciding veto. A timeout that DID carry an auth/config
  #    signal already returned FAIL above (step 3), so genuine config breakage is
  #    unaffected. (The fan-out's own post-window timeout-veto, [INV-48], is a
  #    DIFFERENT path — a real review run that hit its 1h budget after producing no
  #    verdict — and stays a deciding FAIL; this changes only the pre-fan-out
  #    smoke probe.)
  if [[ "$rc" == "124" || "$rc" == "137" ]]; then
    # SMOKE_TIMEOUT_USED already carries its unit (e.g. `5s`/`2h`), so no trailing
    # `s` in the format — otherwise the reason would read `5ss` (#222 [P2]).
    printf 'UNAVAILABLE|timeout (no model response within %s)\n' "${SMOKE_TIMEOUT_USED:-?}"
    return 0
  fi

  # 5. No nonce, no recognizable signal, and NOT a timeout (a prompt non-zero exit
  #    — the CLI launched and exited without producing the nonce). This shape is a
  #    launch/config failure, not a capacity blip (a slow-start manifests as the
  #    timeout branch above, not a prompt exit), so it stays the conservative,
  #    gate-worthy FAIL (#246 keeps this branch FAIL — the change is scoped to the
  #    124/137 timeout branch only).
  printf 'FAIL|no-response (rc=%s; nonce absent from CLI output)\n' "$rc"
  return 0
}

# _smoke_probe_once <agent> <model> <agent_timeout> — run ONE real one-token
# round-trip against <agent>/<model> via the production run_agent chain and
# classify it. Echoes ONE line `STATE|reason|elapsed` on stdout (STATE ∈
# {PASS,UNAVAILABLE,FAIL}); rc of THIS function is always 0 — the STATE is carried
# on stdout, never in $?, so the caller never trips `set -e` on a FAIL probe. The
# 3-field `STATE|reason|elapsed` shape is command-substitution-safe: elapsed is the
# LAST field, so the caller splits it off the tail and the reason (which contains
# spaces/parens but no `|`) survives intact.
#
# WHY this is its own function ([INV-75] / issue #257): the retry-once of a bare
# `no-response` needs a FRESH run_agent round-trip — a new nonce, a new session id,
# a new stdout/stderr capture — and `_smoke_classify` is a PURE decision function
# that cannot drive run_agent. Factoring the single-probe body here lets smoke_agent
# invoke it twice (probe + at most one retry) with zero duplicated invocation code,
# and keeps `_smoke_classify` a single-probe pure function ([INV-63]).
#
# <agent_timeout> is the already-normalized `timeout(1)` duration (e.g. `5s`/`2m`)
# the caller built; this function sets SMOKE_TIMEOUT_USED from it so the timeout
# reason text reads `…within 5s` not `…within 5ss` (#222 [P2]).
#
# A mktemp failure echoes `FAIL|mktemp-failed|0` (the caller renders the evidence
# line). Each probe mints its OWN nonce/session-id so a retry cannot stale-PASS off
# the first probe's stdout, and so the agy --log-file sidecar stays unique.
_smoke_probe_once() {
  local agent="$1" model="$2" agent_timeout="$3"

  local nonce stdout_file stderr_file agy_log session_id
  nonce=$(_smoke_nonce)
  stdout_file=$(mktemp "${TMPDIR:-/tmp}/smoke-${agent}-out-XXXXXX") || {
    printf 'FAIL|mktemp-failed|0\n'
    return 0
  }
  # Separate stderr capture (#222 [P1] review): the nonce PASS check must read
  # ONLY stdout, so a CLI/wrapper that echoes the prompt (which contains the
  # nonce) onto stderr and dies cannot be misreported PASS. stderr stays available
  # to the kiro/codex drop-reason scrapers (they get a combined view).
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/smoke-${agent}-err-XXXXXX") || {
    rm -f "$stdout_file" 2>/dev/null || true
    printf 'FAIL|mktemp-failed|0\n'
    return 0
  }
  # A per-call session id — a VALID UUID (claude's --session-id rejects non-UUIDs;
  # #222 [P1]). Also keeps the agy --log-file sidecar (run_agent's agy branch
  # writes it, keyed by session_id) unique across concurrent harness entries.
  session_id=$(_smoke_session_id)

  # Drive run_agent with the smoke's AGENT_CMD + a SHORT AGENT_TIMEOUT override,
  # in a SUBSHELL so the override (and any per-CLI env the caller set) never
  # leaks back to a sibling/the parent. PROJECT_ID is required by
  # pid_dir_for_project() (the agy sidecar path) — default it if unset so a bare
  # invocation outside a configured project still works.
  local prompt rc
  prompt=$(_smoke_prompt "$nonce")
  # SMOKE_TIMEOUT_USED feeds the timeout-reason evidence text; use the NORMALIZED
  # duration so the message reads `…within 5s` not `…within 5ss` (#222 [P2]).
  SMOKE_TIMEOUT_USED="$agent_timeout"

  local start end elapsed
  start=$(date +%s)
  (
    export AGENT_CMD="$agent"
    # Normalized duration (#222 [P2]): a suffixed input like `5s` is passed through
    # verbatim — appending `s` here would make `5ss` and `timeout(1)` fail at once.
    export AGENT_TIMEOUT="$agent_timeout"
    export PROJECT_ID="${PROJECT_ID:-agent-smoke}"
    # No PID file / heartbeat for a smoke — it is a transient probe, not a
    # dispatched wrapper. AGENT_PID_FILE stays unset so _run_with_timeout skips
    # the PID write.
    run_agent "$session_id" "$prompt" "$model" "smoke"
  ) >"$stdout_file" 2>"$stderr_file"
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))

  # The agy branch of run_agent writes its log to _agy_log_file <session_id>
  # under pid_dir_for_project(). Recover the path with the same PROJECT_ID the
  # subshell used so the agy classifier can scrape it.
  agy_log=""
  if [[ "$agent" == "agy" ]]; then
    agy_log=$(PROJECT_ID="${PROJECT_ID:-agent-smoke}" _agy_log_file "$session_id" 2>/dev/null || true)
  fi

  local classified state reason
  classified=$(_smoke_classify "$agent" "$rc" "$stdout_file" "$nonce" "$agy_log" "$stderr_file")
  state="${classified%%|*}"
  reason="${classified#*|}"

  rm -f "$stdout_file" "$stderr_file" 2>/dev/null || true

  printf '%s|%s|%s\n' "$state" "$reason" "$elapsed"
  return 0
}

# _smoke_is_transient_no_response <state> <reason> — rc 0 iff the probe outcome is
# the step-5 generic `no-response` FAIL with a NON-ZERO CLI exit (the retry-eligible
# TRANSIENT case), rc 1 otherwise. This is the discriminator smoke_agent uses to
# decide whether to retry:
#
#   - `_smoke_classify`'s step-5 fallthrough is the ONLY path that emits
#     `FAIL|no-response (rc=<n>; …)`. The genuine operator-side FAILs (`auth-failed`,
#     `config-error[:<flag>]`) carry their own scraper phrase, never `no-response`,
#     so they do NOT match → no retry, gate-worthy on the first probe (preserved).
#   - The pre-flight FAILs (`bad-args`, `mktemp-failed`) also do NOT start with
#     `no-response`.
#   - rc==0 SILENT-SUCCESS guard (issue #257 review follow-up): step 5 also fires
#     when a CLI exits `0` with no nonce/no scraper signal — the CLI CLAIMED success
#     but produced no token. Issue #257 ONLY relaxed the `rc≠0` fallthrough: a
#     transient Bedrock hiccup kills the CLI with a NON-ZERO exit, whereas a clean
#     `rc=0`-with-no-answer is genuine broken-output / misconfiguration, not a
#     capacity blip. So the retry guard keys on the ORIGINAL non-zero exit code
#     (preserved in the `rc=<n>` of the reason): a `rc=0` no-response is NOT
#     transient → no retry, single-shot gate-worthy FAIL (preserved). Only `rc≠0` is
#     retry-eligible.
#
# Keying on STATE==FAIL && reason-prefix `no-response` && rc≠0 is the structural
# contract (mirrors [INV-67]'s note that only the bare branch is relaxed); a future
# reword of the human reason text MUST keep the `no-response (rc=<n>; …)` shape or
# update this guard.
_smoke_is_transient_no_response() {
  local state="$1" reason="$2"
  [[ "$state" == "FAIL" && "$reason" == no-response* ]] || return 1
  # Parse the original CLI exit out of the `rc=<n>;` token the step-5 reason carries.
  # A non-zero rc → transient (retry-eligible); rc=0 (silent success) or an
  # unparseable rc → NOT transient (conservative: stays a gate-worthy FAIL).
  local rc="${reason#*rc=}"; rc="${rc%%;*}"
  [[ "$rc" =~ ^[0-9]+$ && "$rc" -ne 0 ]]
}

# smoke_agent <agent-cmd> <model> [timeout-seconds]
#
# Run a real one-token round-trip against <agent-cmd>/<model> via the production
# run_agent chain and classify the outcome into the three-state contract.
#
# Returns:  0 PASS   2 UNAVAILABLE   1 FAIL
# Emits ONE machine-readable evidence line on stdout (consumed by the INV-46
# command-mode evidence parser):
#   SMOKE <agent> <PASS|FAIL|UNAVAILABLE> <elapsed>s reason=<...>
#
# A missing/empty <agent-cmd> is a caller bug → FAIL with reason=bad-args (the
# evidence line still prints so the harness records it deterministically).
#
# RETRY-ONCE on a bare `no-response` ([INV-75] / issue #257): a step-5 generic
# `no-response` FAIL (rc≠0, nonce absent, NO per-CLI scraper signal, NOT a
# timeout) is a TRANSIENT infra hiccup on a Bedrock-backed CLI — the CLI died
# before emitting any recognizable signal — not operator-side config breakage. So
# smoke_agent RETRIES it EXACTLY ONCE (one fresh probe — a cheap one-token
# round-trip):
#   - retry PASSes (nonce present)            → PASS (the transient cleared);
#   - retry surfaces a real auth/config FAIL  → FAIL (the retry exposed genuine
#                                               breakage — surface it, don't mask);
#   - retry STILL bare no-response / any      → UNAVAILABLE, reason
#     other non-FAIL transient                  `no-response (rc=<n>; no nonce after
#                                               retry — transient infra)`.
# An UNAVAILABLE member casts NO Phase A.5 vote ([INV-64]) — the review proceeds on
# the survivors instead of aborting. Genuine config breakage (`auth-failed` /
# `config-error`) and the already-environmental UNAVAILABLE cases (quota /
# stream-error / malformed-output / bare timeout [INV-67]) are returned on the FIRST
# probe with NO retry — unchanged.
smoke_agent() {
  local agent="${1:-}" model="${2:-}" timeout_s="${3:-$SMOKE_DEFAULT_TIMEOUT_SECONDS}"

  if [[ -z "$agent" ]]; then
    printf 'SMOKE <none> FAIL 0s reason=bad-args (empty agent-cmd)\n'
    return 1
  fi
  # Validate the timeout; a non-positive/garbage value falls back to the default
  # so a typo can never DISABLE the bound (GNU `timeout 0` disables — INV-13).
  if ! _is_positive_timeout_value "$timeout_s"; then
    timeout_s="$SMOKE_DEFAULT_TIMEOUT_SECONDS"
  fi
  # Normalize to a `timeout(1)`-ready duration (#222 [P2] review): the validator
  # accepts BOTH bare seconds (`5`) and suffixed durations (`5s`/`2h`). A suffixed
  # value must NOT get another `s` appended — `5ss` makes coreutils `timeout` fail
  # immediately ("invalid time interval") on an otherwise healthy CLI. So append
  # `s` ONLY when the value is bare digits; a value that already carries a unit is
  # passed through verbatim.
  local agent_timeout="$timeout_s"
  [[ "$agent_timeout" =~ ^[0-9]+$ ]] && agent_timeout="${agent_timeout}s"

  # Probe #1. _smoke_probe_once echoes `STATE|reason|elapsed`; split elapsed off the
  # TAIL (it is the last `|`-field) so the reason (which contains spaces/parens but
  # no `|`) stays intact.
  local probe state reason elapsed rest
  probe=$(_smoke_probe_once "$agent" "$model" "$agent_timeout")
  state="${probe%%|*}"
  rest="${probe#*|}"           # reason|elapsed
  reason="${rest%|*}"          # reason
  elapsed="${rest##*|}"        # elapsed

  # [INV-75] retry-once: ONLY the step-5 bare `no-response` FAIL is retried.
  # Anything else (PASS, an environmental UNAVAILABLE, a genuine auth/config FAIL,
  # or a pre-flight bad-args/mktemp FAIL) is returned as-is — no retry.
  if _smoke_is_transient_no_response "$state" "$reason"; then
    local probe2 state2 reason2 elapsed2 rest2
    probe2=$(_smoke_probe_once "$agent" "$model" "$agent_timeout")
    state2="${probe2%%|*}"
    rest2="${probe2#*|}"
    reason2="${rest2%|*}"
    elapsed2="${rest2##*|}"
    # Report the TOTAL elapsed across both probes so the evidence reflects the real
    # wall-clock cost of the retried smoke.
    [[ "$elapsed" =~ ^[0-9]+$ && "$elapsed2" =~ ^[0-9]+$ ]] && elapsed=$((elapsed + elapsed2))
    case "$state2" in
      PASS)
        # The transient cleared on the retry — the member is healthy.
        state="PASS"; reason="$reason2" ;;
      FAIL)
        if _smoke_is_transient_no_response "$state2" "$reason2"; then
          # Failed twice with a bare no-response → drop UNAVAILABLE (transient
          # infra), naming the retry probe's rc. The retry reason is
          # `no-response (rc=<n>; nonce absent from CLI output)`; pull out <n> and
          # render the explicit after-retry message.
          local rc2="${reason2#*rc=}"; rc2="${rc2%%;*}"
          state="UNAVAILABLE"
          reason="no-response (rc=${rc2}; no nonce after retry — transient infra)"
        else
          # The retry exposed a GENUINE auth/config FAIL → keep it gate-worthy.
          state="FAIL"; reason="$reason2"
        fi ;;
      *)
        # Any other non-FAIL transient on the retry (an UNAVAILABLE scraper signal
        # or a timeout) — drop the member UNAVAILABLE with that probe's reason.
        state="UNAVAILABLE"; reason="$reason2" ;;
    esac
  fi

  printf 'SMOKE %s %s %ss reason=%s\n' "$agent" "$state" "$elapsed" "$reason"

  case "$state" in
    PASS)        return 0 ;;
    UNAVAILABLE) return 2 ;;
    *)           return 1 ;;
  esac
}
