#!/bin/bash
# test-cli-adapters.sh — Unit tests for the per-CLI adapter extraction (#232,
# [INV-75]). Pins: adapter dispatch (known CLI → adapter; unknown → generic
# fallback), mode routing, the source-by-path compat shims, golden argv parity,
# and the INV-75 "no per-CLI flag logic inline in orchestration code" guard.
#
# IDs: TC-ADAPTER-EXTRACT-NNN.
#
# Run: bash tests/unit/test-cli-adapters.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB="$SCRIPTS/lib-agent.sh"
ADAPTERS="$SCRIPTS/adapters"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() { local d="$1" e="$2" a="$3"; if [[ "$e" == "$a" ]]; then ok "$d"; else bad "$d"; echo "      expected='$e'"; echo "      actual=  '$a'"; fi; }
assert_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" == *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      needle='$n'"; echo "      haystack='${h:0:300}'"; fi; }
assert_not_contains() { local d="$1" n="$2" h="$3"; if [[ "$h" != *"$n"* ]]; then ok "$d"; else bad "$d"; echo "      should not contain: '$n'"; fi; }

# ---------------------------------------------------------------------------
echo "=== TC-ADAPTER-EXTRACT-013: each adapter defines adapter_invoke_<cli> ==="
# ---------------------------------------------------------------------------
defined=$(
  env -u AGENT_CMD -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      AGENT_LAUNCHER="" \
  bash -c '
    source "'"$LIB"'" 2>/dev/null
    for c in claude codex gemini kiro opencode agy; do
      declare -F "adapter_invoke_$c" >/dev/null 2>&1 && echo "$c"
    done
  '
)
for c in claude codex gemini kiro opencode agy; do
  if grep -qx "$c" <<<"$defined"; then ok "adapter_invoke_$c defined after sourcing lib-agent.sh"; else bad "adapter_invoke_$c NOT defined"; fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ADAPTER-EXTRACT-050: INV-75 — no per-CLI flag logic inline in lib-agent.sh ==="
# ---------------------------------------------------------------------------
# The ONLY claude/codex/kiro/agy/gemini/opencode tokens inside run_agent /
# resume_agent are the dispatch arm. None of the per-CLI argv literals remain.
strip_comments() { awk '{ l=$0; sub(/[[:space:]]*#.*$/, "", l); print l }' "$1"; }
agent_code=$(strip_comments "$LIB")
for lit in '"$AGENT_CMD" exec --json' '"$AGENT_CMD" exec resume' '--trust-all-tools' \
           '--dangerously-skip-permissions' '--log-file' '--conversation' \
           'run --format json' '--session-id' '--no-interactive'; do
  assert_not_contains "INV-75: lib-agent.sh carries no inline per-CLI literal [$lit]" "$lit" "$agent_code"
done
# The thin dispatch IS present (the only permitted CLI condition).
assert_contains "INV-75: run_agent/resume_agent dispatch via adapter_invoke_\"\$AGENT_CMD\"" \
  'adapter_invoke_"$AGENT_CMD"' "$agent_code"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ADAPTER-EXTRACT-040..043: source-by-path compat shims ==="
# ---------------------------------------------------------------------------
# Sourcing lib-review-codex.sh (by path) must still define the codex review API.
codex_fns=$(
  bash -c 'source "'"$SCRIPTS"'/lib-review-codex.sh" 2>/dev/null
    for f in _run_codex_review _codex_review_prepare_worktree _codex_review_cleanup_worktree \
             _codex_review_classify_stdout _codex_review_compose_body _classify_codex_drop_reason \
             _codex_drop_reason_phrase; do
      declare -F "$f" >/dev/null 2>&1 && echo "$f"; done'
)
for f in _run_codex_review _codex_review_prepare_worktree _codex_review_cleanup_worktree \
         _codex_review_classify_stdout _codex_review_compose_body _classify_codex_drop_reason \
         _codex_drop_reason_phrase; do
  if grep -qx "$f" <<<"$codex_fns"; then ok "TC-040 lib-review-codex.sh (shim) still defines $f"; else bad "TC-040 lib-review-codex.sh missing $f"; fi
done

agy_fns=$(bash -c 'source "'"$SCRIPTS"'/lib-review-agy.sh" 2>/dev/null
  for f in _classify_agy_drop_reason _agy_drop_reason_phrase; do declare -F "$f" >/dev/null 2>&1 && echo "$f"; done')
for f in _classify_agy_drop_reason _agy_drop_reason_phrase; do
  if grep -qx "$f" <<<"$agy_fns"; then ok "TC-041 lib-review-agy.sh (shim) still defines $f"; else bad "TC-041 lib-review-agy.sh missing $f"; fi
done

kiro_fns=$(bash -c 'source "'"$SCRIPTS"'/lib-review-kiro.sh" 2>/dev/null
  for f in _classify_kiro_drop_reason _kiro_drop_reason_phrase; do declare -F "$f" >/dev/null 2>&1 && echo "$f"; done')
for f in _classify_kiro_drop_reason _kiro_drop_reason_phrase; do
  if grep -qx "$f" <<<"$kiro_fns"; then ok "TC-042 lib-review-kiro.sh (shim) still defines $f"; else bad "TC-042 lib-review-kiro.sh missing $f"; fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ADAPTER-EXTRACT-044: compat shims resolve adapters/ from realpath, not symlink dir ==="
# ---------------------------------------------------------------------------
# Legacy installs may carry a DIRECT per-lib symlink to a shim (e.g. only
# scripts/lib-review-codex.sh) without adapters/ alongside it. The shim MUST
# resolve adapters/<cli>.sh from its OWN real location (readlink -f of its
# BASH_SOURCE, like lib-agent.sh per [INV-65]) — not from the symlink's dir,
# which would point at the caller's adapter-less scripts/. Repro the finding:
# symlink each shim into an empty dir (no adapters/) and source it.
TMPSYM=$(mktemp -d)
for shim in lib-review-codex.sh lib-review-agy.sh lib-review-kiro.sh; do
  ln -s "$SCRIPTS/$shim" "$TMPSYM/$shim"
done
# codex shim via symlink → must still define the review API.
codex_sym_fns=$(bash -c 'source "'"$TMPSYM"'/lib-review-codex.sh" 2>/dev/null
  for f in _run_codex_review _classify_codex_drop_reason; do declare -F "$f" >/dev/null 2>&1 && echo "$f"; done')
for f in _run_codex_review _classify_codex_drop_reason; do
  if grep -qx "$f" <<<"$codex_sym_fns"; then ok "TC-044 lib-review-codex.sh via direct symlink (no sibling adapters/) defines $f"; else bad "TC-044 lib-review-codex.sh via symlink missing $f (adapters/ resolved from symlink dir, not realpath)"; fi
done
agy_sym_fns=$(bash -c 'source "'"$TMPSYM"'/lib-review-agy.sh" 2>/dev/null
  declare -F _classify_agy_drop_reason >/dev/null 2>&1 && echo ok')
if [[ "$agy_sym_fns" == ok ]]; then ok "TC-044 lib-review-agy.sh via direct symlink defines _classify_agy_drop_reason"; else bad "TC-044 lib-review-agy.sh via symlink missing _classify_agy_drop_reason"; fi
kiro_sym_fns=$(bash -c 'source "'"$TMPSYM"'/lib-review-kiro.sh" 2>/dev/null
  declare -F _classify_kiro_drop_reason >/dev/null 2>&1 && echo ok')
if [[ "$kiro_sym_fns" == ok ]]; then ok "TC-044 lib-review-kiro.sh via direct symlink defines _classify_kiro_drop_reason"; else bad "TC-044 lib-review-kiro.sh via symlink missing _classify_kiro_drop_reason"; fi
rm -rf "$TMPSYM"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ADAPTER-EXTRACT-010/011/020..025: dispatch + golden argv parity ==="
# ---------------------------------------------------------------------------
# A recording stub per CLI; assert run_agent/resume_agent route to the adapter
# and assemble the expected argv (the structural shape — full byte-parity is
# pinned by the pre/after golden capture documented in the PR body).
TMPG=$(mktemp -d)
trap 'rm -rf "$TMPG"' EXIT
mkdir -p "$TMPG/bin"
for b in claude codex gemini kiro-cli opencode agy frobnik; do
  { printf '#!/bin/bash\n'; printf 'SELFBIN=%q\n' "$b"; cat <<'BODY'
if [[ "$SELFBIN" == "agy" && "$1" == "models" ]]; then exit 0; fi
{ printf 'BIN=%s argv:' "$SELFBIN"; printf ' %q' "$@"; printf '\n'; } >> "$REC"
exit 0
BODY
  } > "$TMPG/bin/$b"; chmod +x "$TMPG/bin/$b"
done
# Stub timeout: strip the 3 leading control args and exec the rest.
cat > "$TMPG/bin/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$TMPG/bin/timeout"

run_dispatch() {
  local cli="$1" fn="$2" rec="$3"
  env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR \
      PATH="$TMPG/bin:$PATH" REC="$rec" \
      AGENT_CMD="$cli" AGENT_PERMISSION_MODE="auto" AGENT_TIMEOUT="4h" \
      AGENT_DEV_EXTRA_ARGS="" AGENT_REVIEW_EXTRA_ARGS="" AGENT_LAUNCHER="" \
      KIRO_AGENT_NAME="autonomous-dev" PROJECT_ID="adtest" REPO="t/r" PROJECT_DIR="$TMPG" \
  bash -c '
    unset AGENT_PID_FILE
    source "'"$LIB"'" 2>/dev/null
    '"$fn"' "11111111-2222-3333-4444-555555555555" "PROMPT" "m" "nm" >/dev/null 2>&1 || true
  '
}

# TC-010 claude → adapter assembles --session-id / --output-format json.
REC="$TMPG/rec-claude"; : > "$REC"; run_dispatch claude run_agent "$REC"
claude_argv=$(cat "$REC")
assert_contains "TC-010 claude run_agent routes to adapter (--session-id present)" '--session-id' "$claude_argv"
assert_contains "TC-010 claude argv carries --output-format json" '--output-format json' "$claude_argv"

# TC-012 mode routing: claude resume uses --resume.
REC="$TMPG/rec-claude-r"; : > "$REC"; run_dispatch claude resume_agent "$REC"
assert_contains "TC-012 claude resume_agent → adapter dev-resume (--resume)" '--resume' "$(cat "$REC")"

# TC-020..025 per-CLI run_agent structural argv (kiro binary alias → kiro-cli).
REC="$TMPG/rec-codex"; : > "$REC"; run_dispatch codex run_agent "$REC"
assert_contains "TC-021 codex run_agent → 'exec --json'" 'exec --json' "$(cat "$REC")"
REC="$TMPG/rec-gemini"; : > "$REC"; run_dispatch gemini run_agent "$REC"
assert_contains "TC-022 gemini run_agent → '--session-id … -p'" '--session-id' "$(cat "$REC")"
REC="$TMPG/rec-kiro"; : > "$REC"; run_dispatch kiro run_agent "$REC"
kiro_argv=$(cat "$REC")
assert_contains "TC-023 kiro run_agent → 'kiro-cli chat'" 'BIN=kiro-cli' "$kiro_argv"
assert_contains "TC-023 kiro argv → '--no-interactive'" '--no-interactive' "$kiro_argv"
REC="$TMPG/rec-oc"; : > "$REC"; run_dispatch opencode run_agent "$REC"
assert_contains "TC-024 opencode run_agent → 'run --format json'" 'run --format json' "$(cat "$REC")"
REC="$TMPG/rec-agy"; : > "$REC"; run_dispatch agy run_agent "$REC"
agy_argv=$(cat "$REC")
assert_contains "TC-025 agy run_agent → '--dangerously-skip-permissions'" '--dangerously-skip-permissions' "$agy_argv"
assert_contains "TC-025 agy argv → '--log-file'" '--log-file' "$agy_argv"

# TC-011 unknown CLI → generic fallback (NOT an adapter): `<cli> … -p`, with WARN.
REC="$TMPG/rec-frob"; : > "$REC"
warn=$(run_dispatch frobnik run_agent "$REC" 2>&1)
frob_argv=$(cat "$REC")
assert_contains "TC-011 unknown CLI hits generic fallback ('frobnik … -p')" 'BIN=frobnik' "$frob_argv"
assert_contains "TC-011 generic fallback argv ends with -p" '-p' "$frob_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ADAPTER-EXTRACT-030: agy --model validation still wrapper-side (INV-50) ==="
# ---------------------------------------------------------------------------
# A stub `agy models` that lists ONE known model; an UNKNOWN id must be OMITTED.
cat > "$TMPG/bin/agy" <<'EOF'
#!/bin/bash
if [[ "$1" == "models" ]]; then echo "Gemini 3.5 Flash (High)"; exit 0; fi
{ printf 'argv:'; printf ' %q' "$@"; printf '\n'; } >> "$REC"
exit 0
EOF
chmod +x "$TMPG/bin/agy"
REC="$TMPG/rec-agy-unknown"; : > "$REC"
env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR PATH="$TMPG/bin:$PATH" REC="$REC" \
    AGENT_CMD=agy AGENT_TIMEOUT="4h" AGENT_DEV_EXTRA_ARGS="" AGENT_LAUNCHER="" \
    PROJECT_ID="adtest" REPO="t/r" PROJECT_DIR="$TMPG" \
  bash -c 'unset AGENT_PID_FILE; source "'"$LIB"'" 2>/dev/null
    run_agent "11111111-2222-3333-4444-555555555555" "P" "claude-sonnet-4.6" "nm" >/dev/null 2>&1 || true' 2>/dev/null
assert_not_contains "TC-030 agy omits an unknown --model (INV-50 validation in adapter)" \
  '--model' "$(cat "$REC")"

echo ""
echo "=== SUMMARY: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
