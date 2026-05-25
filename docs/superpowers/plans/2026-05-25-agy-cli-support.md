# Antigravity CLI (`agy`) Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Google Antigravity 2.0 CLI (`agy` v1.0.2) as a supported `AGENT_CMD` value alongside claude/codex/gemini/kiro/opencode.

**Architecture:** Adds a sixth `case "$AGENT_CMD"` branch to `run_agent` and `resume_agent` in `lib-agent.sh`, plus a sidecar trio (`_agy_log_file`, `_agy_capture_conversation`, `_agy_conversation_id`) mirroring the codex/opencode sidecar pattern. agy mints its own conversation UUID and exposes it only via its log file (no JSON event stream), so capture is `grep` of `--log-file`. INV-36 governs that capture is best-effort: missing UUID triggers fresh-session fallback in `resume_agent`.

**Tech Stack:** Bash 5.x, coreutils `timeout`, GNU `grep`/`sed`. No new runtime dependencies.

**Spec:** [`docs/pipeline/agy-cli-support.md`](../../pipeline/agy-cli-support.md) (already merged in same PR).

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `skills/autonomous-dispatcher/scripts/lib-agent.sh` | Modify | Add `agy)` cases to `run_agent` + `resume_agent`; add three private helpers next to `_codex_thread_*` helpers. |
| `skills/autonomous-dispatcher/scripts/autonomous.conf.example` | Modify | Add `# --- agy block ---` after the `# --- opencode block ---` block; mention `agy` in the AGENT_CMD comment header. |
| `skills/autonomous-dispatcher/SKILL.md` | Modify | Add `agy` to "Supported Agent CLIs" listing. |
| `docs/pipeline/invariants.md` | Modify | Append `## INV-36: agy conversation id capture is best-effort`. |
| `tests/unit/test-lib-agent-agy.sh` | Create | Eight test cases (AGY-01..AGY-08) per spec §Test coverage. Mirrors `test-lib-agent-codex.sh` structure. |
| `.github/workflows/ci.yml` | Modify | Already runs `tests/unit/test-*.sh` glob — no change needed. |

The spec document `docs/pipeline/agy-cli-support.md` has already been written and committed before this plan executes (it's part of brainstorming output). The implementation worktree starts with the spec doc in place; this plan only adds the code, conf, SKILL.md, INV-36 entry, and tests.

---

## Pre-flight: Worktree

This project's hooks block direct commits on `main` (CLAUDE.md "All code changes must be developed in a Git Worktree"). Before Task 1, the executor MUST create a worktree using the `superpowers:using-git-worktrees` skill (or, if working interactively, `git worktree add .worktrees/agy-cli-support -b feat/agy-cli-support`).

All `git commit` / `git push` steps below assume the executor is `cd`'d into the worktree. If you see `block-commit-outside-worktree` rejecting a commit, you forgot the worktree setup — go back and create it.

---

## Task 1: Add the three private helpers (`_agy_log_file`, `_agy_conversation_file`, `_agy_capture_conversation`, `_agy_conversation_id`)

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/lib-agent.sh` (insert after the existing opencode helpers around line 445, before the `acquire_pid_guard` function)
- Test: `tests/unit/test-lib-agent-agy.sh` (new file)

**Goal of this task:** Get the four helpers in place with unit tests, *before* wiring them into `run_agent`/`resume_agent`. This isolates the sidecar mechanics (paths, grep pattern, CWE-59 defense) from the dispatch flow.

- [ ] **Step 1.1: Read `lib-agent.sh` lines 305–450 to confirm the codex+opencode helper region**

Run:
```bash
sed -n '305,450p' skills/autonomous-dispatcher/scripts/lib-agent.sh
```
Expected: see `_codex_thread_file`, `_codex_capture_thread`, `_codex_thread_id`, then `_opencode_session_file`, `_opencode_capture_session`, `_opencode_session_id`. Confirm the `acquire_pid_guard` function starts after them — that's where you'll insert. Note the closing line of the last opencode helper for use in Step 1.4.

- [ ] **Step 1.2: Create the test file with the test scaffolding (no test cases yet)**

Create `tests/unit/test-lib-agent-agy.sh`:

```bash
#!/bin/bash
# test-lib-agent-agy.sh — Unit tests for the agy branches of
# lib-agent.sh (Antigravity 2.0 CLI support, INV-36).
#
# Verifies:
#   - run_agent agy branch invokes `agy -p --dangerously-skip-permissions
#     --print-timeout <timeout> --log-file <path>` (stdin prompt, INV-34)
#   - The conversation UUID is grepped from the log file and captured
#     to a sidecar under pid_dir_for_project(), keyed by session_id
#   - resume_agent agy branch reads the sidecar and invokes
#     `agy --conversation <uuid> -p ...`
#   - resume_agent falls back to run_agent when the sidecar is missing
#   - Non-empty `model` arg emits one-time WARN, execution continues
#   - Capture is best-effort (INV-36): missing log line / symlink sidecar
#     do not fail run_agent
#
# Strategy: source lib-agent.sh in a sandbox with a stub `agy` on PATH
# that records argv to a recorder file and writes a fixed log file with
# a `Print mode: conversation=<UUID>` line.
#
# Run: bash tests/unit/test-lib-agent-agy.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should not contain: '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

# Placeholder — test cases land in subsequent steps.
echo "=== test-lib-agent-agy.sh — scaffolding only (test cases follow) ==="

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 1.3: Make the test file executable and run the scaffold**

Run:
```bash
chmod +x tests/unit/test-lib-agent-agy.sh
bash tests/unit/test-lib-agent-agy.sh
```

Expected: scaffold prints "scaffolding only" line and exits 0 (`PASS: 0 FAIL: 0`).

- [ ] **Step 1.4: Add AGY-S1: structural grep — helpers exist**

This is a cheap source-of-truth check before any behavioral test. Append to `tests/unit/test-lib-agent-agy.sh` *before* the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo "=== AGY-S1: source-of-truth — helper functions exist ==="
# ---------------------------------------------------------------------------

if grep -qE '^_agy_log_file\(\)' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: _agy_log_file defined"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _agy_log_file missing"
  FAIL=$((FAIL + 1))
fi

if grep -qE '^_agy_conversation_file\(\)' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: _agy_conversation_file defined"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _agy_conversation_file missing"
  FAIL=$((FAIL + 1))
fi

if grep -qE '^_agy_capture_conversation\(\)' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: _agy_capture_conversation defined"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _agy_capture_conversation missing"
  FAIL=$((FAIL + 1))
fi

if grep -qE '^_agy_conversation_id\(\)' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: _agy_conversation_id defined"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _agy_conversation_id missing"
  FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 1.5: Run the scaffold + AGY-S1 — verify it FAILS (helpers don't exist yet)**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: `FAIL: 4` (all four helpers missing). Exit code != 0.

- [ ] **Step 1.6: Insert the four helpers into `lib-agent.sh`**

Find the line `acquire_pid_guard() {` in `skills/autonomous-dispatcher/scripts/lib-agent.sh` (around line 455). Insert the following block *immediately before* that line, after the closing `}` of the last opencode helper:

```bash
# _agy_log_file <session_id>
# _agy_conversation_file <session_id>
#
# Sidecar paths under pid_dir_for_project() for the agy branch
# (Antigravity 2.0 CLI). agy mints conversation UUIDs internally and
# exposes them only via the CLI log file (no JSON event stream on
# stdout). We direct agy's log to a per-session path with --log-file,
# then grep the UUID and persist it to a separate per-session file
# for resume.
#
# Pattern mirrors _codex_thread_file / _opencode_session_file. Two
# files instead of one because the log is mostly noise and is not
# the canonical UUID store — only the sidecar is.
_agy_log_file() {
  local session_id="$1" pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/agy-log-%s.log\n' "$pid_dir" "$session_id"
}

_agy_conversation_file() {
  local session_id="$1" pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/agy-conversation-%s\n' "$pid_dir" "$session_id"
}

# _agy_capture_conversation <session_id> <log_file>
#
# Best-effort capture per [INV-36]: grep the log_file for
#   Print mode: conversation=<UUID>
# and write the UUID to the sidecar. Missing log file, missing match,
# unwritable sidecar all return 0 — capture failure must not gate
# run_agent's exit code, because resume_agent falls back to a fresh
# run when the sidecar is absent.
#
# CWE-59 defense via [[ -L ]] — same pattern as _codex_capture_thread.
_agy_capture_conversation() {
  local session_id="$1" log_file="$2" conv_file uuid
  conv_file=$(_agy_conversation_file "$session_id") || return 0
  [[ -f "$log_file" ]] || return 0
  uuid=$(grep -oE 'Print mode: conversation=[a-f0-9-]+' "$log_file" \
    | head -1 | sed 's/.*=//')
  [[ -n "$uuid" ]] || return 0
  if [[ -L "$conv_file" ]]; then
    echo "[lib-agent] WARN: $conv_file is a symlink; refusing to write." >&2
    return 0
  fi
  printf '%s\n' "$uuid" > "$conv_file"
}

# _agy_conversation_id <session_id>
#
# Read the captured UUID. Missing sidecar returns rc 1 so resume_agent
# can detect it and fall back to a fresh run_agent.
_agy_conversation_id() {
  local session_id="$1" conv_file
  conv_file=$(_agy_conversation_file "$session_id") || return 1
  [[ -f "$conv_file" ]] || return 1
  cat "$conv_file"
}

```

(Note the trailing blank line — keep one blank line of separation before `acquire_pid_guard()`.)

- [ ] **Step 1.7: Run AGY-S1 — verify all four helpers detected**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: `PASS: 4 FAIL: 0`. Exit 0.

- [ ] **Step 1.8: Add AGY-S2: behavioral — `_agy_capture_conversation` writes sidecar from a fixture log**

Append to `tests/unit/test-lib-agent-agy.sh`, before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-S2: behavioral — _agy_capture_conversation writes sidecar ==="
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PID_DIR="$TMPROOT/pid"
mkdir -p "$PID_DIR"
chmod 700 "$PID_DIR"

# Fixture log line copied from a real `agy -p` run.
cat > "$TMPROOT/agy.log" <<'EOF'
I0524 22:56:05.692100 1234 input.go:42] Starting print mode
I0524 22:56:05.692112 1234 printmode.go:130] Print mode: conversation=f41baebb-89f5-4c15-9dae-35c2adde4e32, sending message
I0524 22:56:08.236212 1234 input_loop.go:499] Auth done received
EOF

SESSION_ID="11111111-2222-3333-4444-555555555555"

(
  PATH="$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    _agy_capture_conversation "'"$SESSION_ID"'" "'"$TMPROOT"'/agy.log"
  '
)

sidecar="$PID_DIR/agy-conversation-$SESSION_ID"
if [[ -f "$sidecar" ]]; then
  echo -e "  ${GREEN}PASS${NC}: sidecar created at $sidecar"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: sidecar missing at $sidecar"
  FAIL=$((FAIL + 1))
fi
assert_eq "sidecar contains UUID from log" \
  "f41baebb-89f5-4c15-9dae-35c2adde4e32" \
  "$(cat "$sidecar" 2>/dev/null)"
```

- [ ] **Step 1.9: Run — verify AGY-S2 passes**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: `PASS: 6 FAIL: 0`.

- [ ] **Step 1.10: Add AGY-S3 + AGY-S4: capture is best-effort (no match → no sidecar; symlink → refusal)**

Append to `tests/unit/test-lib-agent-agy.sh`, before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-S3: best-effort — log without match leaves sidecar absent (INV-36) ==="
# ---------------------------------------------------------------------------
SESSION_ID2="22222222-bbbb-cccc-dddd-eeeeeeeeeeee"
cat > "$TMPROOT/agy-nomatch.log" <<'EOF'
I0524 22:56:05.692100 1234 input.go:42] Starting print mode
I0524 22:56:05.692112 1234 something.go:99] Some other line
EOF

(
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    _agy_capture_conversation "'"$SESSION_ID2"'" "'"$TMPROOT"'/agy-nomatch.log"
  '
)

sidecar2="$PID_DIR/agy-conversation-$SESSION_ID2"
if [[ ! -e "$sidecar2" ]]; then
  echo -e "  ${GREEN}PASS${NC}: sidecar absent for log without match"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: sidecar should be absent but exists"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-S4: CWE-59 — symlink sidecar is refused with WARN ==="
# ---------------------------------------------------------------------------
SESSION_ID3="33333333-cccc-dddd-eeee-ffffffffffff"
# Pre-create the sidecar path as a symlink pointing at /etc/passwd.
ln -s /etc/passwd "$PID_DIR/agy-conversation-$SESSION_ID3"

stderr_capture=$(
  (
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD=agy \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
      source "'"$LIB"'"
      _agy_capture_conversation "'"$SESSION_ID3"'" "'"$TMPROOT"'/agy.log"
    '
  ) 2>&1 1>/dev/null
)

# /etc/passwd content must NOT have been overwritten — readlink still
# points at /etc/passwd, and the actual file is unchanged. We just check
# the symlink wasn't resolved-and-overwritten by inspecting that the
# target is intact (assert head -1 is still root:).
target_first_line=$(head -1 /etc/passwd 2>/dev/null)
assert_contains "/etc/passwd not overwritten by symlink-following write" \
  "root:" "$target_first_line"
assert_contains "WARN logged for symlink refusal" \
  "is a symlink; refusing to write" "$stderr_capture"
```

- [ ] **Step 1.11: Run — verify AGY-S3 and AGY-S4 pass**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: `PASS: 9 FAIL: 0` (4 structural + S2 sidecar create + S2 content + S3 absent + S4 not-overwritten + S4 WARN-logged = 9).

- [ ] **Step 1.12: shellcheck the modified `lib-agent.sh`**

Run:
```bash
shellcheck -S error skills/autonomous-dispatcher/scripts/lib-agent.sh
```

Expected: exit 0, no errors. (CI's shellcheck job is `-S error` per `.github/workflows/ci.yml`.)

- [ ] **Step 1.13: Commit Task 1**

Run:
```bash
git add skills/autonomous-dispatcher/scripts/lib-agent.sh tests/unit/test-lib-agent-agy.sh
git commit -m "feat(lib-agent): add agy sidecar helpers (INV-36)

Add _agy_log_file, _agy_conversation_file, _agy_capture_conversation,
_agy_conversation_id mirroring the codex/opencode sidecar pattern.
agy mints conversation UUIDs internally and exposes them only via
its CLI log file; we grep the log to capture and persist for resume.

Capture is best-effort per INV-36: missing log line, missing match,
or symlink sidecar all return 0. resume_agent (Task 2) will handle
sidecar-absent by falling back to a fresh run_agent.

Helpers only — wiring into run_agent / resume_agent lands in Task 2."
```

---

## Task 2: Wire `agy)` branch into `run_agent` and `resume_agent`

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/lib-agent.sh` — `run_agent` case statement (around line 496) and `resume_agent` case statement (around line 662).
- Test: `tests/unit/test-lib-agent-agy.sh` — append AGY-01..AGY-08 behavioral cases.

**Goal of this task:** Add the actual dispatch branch so `AGENT_CMD=agy` reaches the new helpers from Task 1. Tests are written first per TDD.

- [ ] **Step 2.1: Add AGY-01 + AGY-02: run_agent invokes agy with stdin prompt and structural flags**

Append to `tests/unit/test-lib-agent-agy.sh` before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-01/02: run_agent agy branch — stdin prompt + structural flags ==="
# ---------------------------------------------------------------------------
BIN="$TMPROOT/bin"
mkdir -p "$BIN"

# Stub agy: record argv + drain stdin to recorders, then write a fake
# log file at the path requested via --log-file containing the
# Print mode line. Exits 0.
cat > "$BIN/agy" <<'STUB'
#!/bin/bash
echo "$@" > "$AGY_ARGS_FILE"
cat > "${AGY_STDIN_FILE:-/dev/null}"
# Find --log-file argument and write a fixture log there.
log_file=""
i=0
for arg in "$@"; do
  if [[ "$prev" == "--log-file" ]]; then
    log_file="$arg"
    break
  fi
  prev="$arg"
done
if [[ -n "$log_file" ]]; then
  cat > "$log_file" <<EOF
I0524 22:56:05.692112 1234 printmode.go:130] Print mode: conversation=${AGY_FAKE_UUID:-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb}, sending message
EOF
fi
exit 0
STUB
chmod +x "$BIN/agy"

# Stub timeout: pass through, drop the leading 3 args (--kill-after,
# --signal, DURATION).
cat > "$BIN/timeout" <<'STUB'
#!/bin/bash
shift 3
exec "$@"
STUB
chmod +x "$BIN/timeout"

ARGS_FILE="$TMPROOT/agy-args"
STDIN_FILE="$TMPROOT/agy-stdin"
SESSION_ID4="44444444-aaaa-bbbb-cccc-dddddddddddd"
FAKE_UUID="dead-beef-cafe-0000-1111aaaa2222"

run_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_FAKE_UUID="$FAKE_UUID" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID4"'" "implement the agy thing" "" ""
  ' 2>&1
)
run_rc=$?

assert_eq "run_agent agy returns 0 on success" 0 "$run_rc"

agy_argv=$(cat "$ARGS_FILE")
assert_contains "agy argv contains -p"                          "-p"                              "$agy_argv"
assert_contains "agy argv contains --dangerously-skip-permissions" "--dangerously-skip-permissions" "$agy_argv"
assert_contains "agy argv contains --print-timeout 4h"          "--print-timeout 4h"              "$agy_argv"
assert_contains "agy argv contains --log-file under PID_DIR"    "--log-file $PID_DIR/agy-log-$SESSION_ID4.log" "$agy_argv"
assert_not_contains "agy argv does NOT carry the prompt positionally" \
  "implement the agy thing" "$agy_argv"

agy_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "agy stdin contains the prompt (INV-34)" \
  "implement the agy thing" "$agy_stdin"

# AGY-03: sidecar populated from the fake log line written by the stub.
sidecar4="$PID_DIR/agy-conversation-$SESSION_ID4"
if [[ -f "$sidecar4" ]]; then
  echo -e "  ${GREEN}PASS${NC}: AGY-03 — sidecar populated post-run"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: AGY-03 — sidecar missing at $sidecar4"
  FAIL=$((FAIL + 1))
fi
assert_eq "AGY-03 — sidecar contains UUID from stub-written log" \
  "$FAKE_UUID" "$(cat "$sidecar4" 2>/dev/null)"
```

- [ ] **Step 2.2: Run — verify AGY-01/02/03 FAIL (no agy branch yet)**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: AGY-01..AGY-03 fail because `run_agent` falls into the generic `*)` branch (which uses `agy "${extra_args[@]}" -p` — no `--dangerously-skip-permissions`, no `--log-file`, no sidecar). Either FAIL count rises, or the generic-branch WARN is emitted to stderr.

- [ ] **Step 2.3: Insert the `agy)` case into `run_agent`**

In `skills/autonomous-dispatcher/scripts/lib-agent.sh`, find the line with `opencode)` inside the `run_agent` case statement (around line 605). Insert the following case *before* the `*)` (generic) fallback — i.e., after the `;;` that closes the `opencode)` case:

```bash
    agy)
      # Antigravity 2.0 CLI (Google). agy mints conversation UUIDs
      # internally and emits them only via the CLI log file (no JSON
      # event stream). We direct the log to a per-session path with
      # --log-file, then capture the UUID into a sidecar for resume.
      # Pattern mirrors codex/opencode but with a grep-based capture
      # channel. See docs/pipeline/agy-cli-support.md and INV-36.
      #
      # Structural flags (NOT operator-tunable, NOT in EXTRA_ARGS):
      #   -p — headless print mode; reads prompt from stdin per INV-34.
      #   --dangerously-skip-permissions — load-bearing in headless mode;
      #     without it agy denies every tool call. Same role as kiro's
      #     --trust-all-tools and gemini's --approval-mode yolo.
      #   --print-timeout "$AGENT_TIMEOUT" — agy's internal cap defaults
      #     to 5m, far below AGENT_TIMEOUT (default 4h). Without override,
      #     every wrapper would die in 5m regardless of the outer cap.
      #   --log-file — only programmatic channel for the conversation
      #     UUID; per-session path so concurrent issues do not race.
      #
      # `model` parameter is ignored — agy doesn't accept --model on the
      # CLI. Configure model selection via ~/.gemini/antigravity-cli/
      # settings.json. WARN once per process so operators learn to stop
      # passing AGENT_DEV_MODEL.
      if [[ -n "$model" && -z "${_LIB_AGENT_AGY_MODEL_WARNED:-}" ]]; then
        echo "[lib-agent] WARN: AGENT_CMD=agy does not support --model flag; ignoring AGENT_DEV_MODEL=${model}. Configure model via ~/.gemini/antigravity-cli/settings.json instead." >&2
        export _LIB_AGENT_AGY_MODEL_WARNED=1
      fi

      local agy_log
      agy_log=$(_agy_log_file "$session_id") || return 1

      printf '%s' "$prompt" \
        | _run_with_timeout "$AGENT_CMD" \
            -p \
            --dangerously-skip-permissions \
            --print-timeout "$AGENT_TIMEOUT" \
            --log-file "$agy_log" \
            "${extra_args[@]}"
      local rc=$?

      _agy_capture_conversation "$session_id" "$agy_log"

      return $rc
      ;;
```

- [ ] **Step 2.4: Run — verify AGY-01/02/03 now PASS**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: previous tests + AGY-01/02/03 all green. `PASS: 19 FAIL: 0` (9 from Task 1 + 10 new assertions: rc + 4 argv contains + 1 argv not-contains + 1 stdin + 1 sidecar exists + 1 sidecar content + 1 implicit no-WARN. The exact count may vary ±1 depending on how you count multi-assertion `assert_contains` calls — what matters is `FAIL: 0`.)

- [ ] **Step 2.5: Add AGY-04: resume_agent uses captured UUID**

Append to `tests/unit/test-lib-agent-agy.sh` before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-04: resume_agent agy branch — uses captured conversation UUID ==="
# ---------------------------------------------------------------------------
# Reuse the sandbox from AGY-01/02/03 — sidecar4 is already populated
# from the prior run_agent invocation.
: > "$ARGS_FILE"
: > "$STDIN_FILE"

resume_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_FAKE_UUID="$FAKE_UUID" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    resume_agent "'"$SESSION_ID4"'" "address review feedback" "" ""
  ' 2>&1
)
resume_rc=$?

assert_eq "resume_agent agy returns 0 on success" 0 "$resume_rc"

agy_argv=$(cat "$ARGS_FILE")
assert_contains "resume agy argv contains --conversation <UUID>" \
  "--conversation $FAKE_UUID" "$agy_argv"
assert_contains "resume agy argv still contains -p"                          "-p"                              "$agy_argv"
assert_contains "resume agy argv still contains --dangerously-skip-permissions" "--dangerously-skip-permissions" "$agy_argv"
assert_contains "resume agy argv still contains --log-file"                  "--log-file"                      "$agy_argv"

agy_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "resume agy stdin contains the new prompt" \
  "address review feedback" "$agy_stdin"
```

- [ ] **Step 2.6: Run — verify AGY-04 FAILS (no resume_agent branch yet)**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: `--conversation $FAKE_UUID` is missing because `resume_agent` falls through to the generic `*)` which calls `run_agent` → which uses run_agent's flags (no `--conversation`).

- [ ] **Step 2.7: Insert the `agy)` case into `resume_agent`**

In `skills/autonomous-dispatcher/scripts/lib-agent.sh`, find the `opencode)` case inside `resume_agent` (around line 738). Insert the following case after the closing `;;` of the `opencode)` case, before the `*)` fallback:

```bash
    agy)
      # See run_agent agy branch for structural-flag rationale and
      # sidecar mechanics. resume reads the captured UUID from the
      # sidecar and feeds it back via --conversation <UUID>. If the
      # sidecar is missing (run_agent never ran for this session, or
      # capture failed per INV-36), fall back to a fresh run_agent —
      # same defensive pattern as the codex / opencode branches.
      local _agy_cid
      if _agy_cid=$(_agy_conversation_id "$session_id"); then
        local agy_log
        agy_log=$(_agy_log_file "$session_id") || return 1
        printf '%s' "$prompt" \
          | _run_with_timeout "$AGENT_CMD" \
              --conversation "$_agy_cid" \
              -p \
              --dangerously-skip-permissions \
              --print-timeout "$AGENT_TIMEOUT" \
              --log-file "$agy_log" \
              "${extra_args[@]}"
        local rc=$?
        # Self-healing re-capture: under normal operation the UUID
        # equals _agy_cid (agy keeps the id on resume), so this is a
        # no-op overwrite. If a future agy version rotates IDs on
        # resume, the sidecar tracks the live one without code change.
        _agy_capture_conversation "$session_id" "$agy_log"
        return $rc
      else
        echo "[lib-agent] no captured agy conversation_id for session $session_id; starting a new agy session" >&2
        run_agent "$session_id" "$prompt" "$model" "$session_name"
      fi
      ;;
```

- [ ] **Step 2.8: Run — verify AGY-04 PASSES**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: `FAIL: 0`.

- [ ] **Step 2.9: Add AGY-05: resume_agent without sidecar falls back to run_agent**

Append to `tests/unit/test-lib-agent-agy.sh` before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-05: resume_agent without sidecar — falls back to run_agent ==="
# ---------------------------------------------------------------------------
SESSION_ID5="55555555-eeee-ffff-aaaa-bbbbbbbbbbbb"  # No sidecar pre-populated.
: > "$ARGS_FILE"
: > "$STDIN_FILE"

fallback_stderr=$(
  (
    PATH="$BIN:$PATH" \
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD=agy \
    AGENT_PERMISSION_MODE=auto \
    AGENT_TIMEOUT=4h \
    AGY_ARGS_FILE="$ARGS_FILE" \
    AGY_STDIN_FILE="$STDIN_FILE" \
    AGY_FAKE_UUID="fallback-uuid-aaaa-bbbb-cccccccccccc" \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
      source "'"$LIB"'"
      resume_agent "'"$SESSION_ID5"'" "fresh start" "" ""
    '
  ) 2>&1 1>/dev/null
)

agy_argv=$(cat "$ARGS_FILE")
assert_contains "fallback stderr mentions 'no captured agy conversation_id'" \
  "no captured agy conversation_id" "$fallback_stderr"
assert_not_contains "fallback argv does NOT contain --conversation" \
  "--conversation" "$agy_argv"
# After fallback to run_agent, the new sidecar is created.
sidecar5="$PID_DIR/agy-conversation-$SESSION_ID5"
if [[ -f "$sidecar5" ]]; then
  echo -e "  ${GREEN}PASS${NC}: fallback created a new sidecar"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: fallback did not create new sidecar"
  FAIL=$((FAIL + 1))
fi
```

- [ ] **Step 2.10: Run — verify AGY-05 passes**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: `FAIL: 0`.

- [ ] **Step 2.11: Add AGY-06: model parameter triggers WARN, execution continues**

Append to `tests/unit/test-lib-agent-agy.sh` before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-06: model parameter — WARN once, execution continues ==="
# ---------------------------------------------------------------------------
SESSION_ID6="66666666-1234-1234-1234-123456789012"
: > "$ARGS_FILE"
: > "$STDIN_FILE"

# Run with non-empty model; capture stderr separately from stdout.
run_stderr=$(
  (
    PATH="$BIN:$PATH" \
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD=agy \
    AGENT_PERMISSION_MODE=auto \
    AGENT_TIMEOUT=4h \
    AGY_ARGS_FILE="$ARGS_FILE" \
    AGY_STDIN_FILE="$STDIN_FILE" \
    AGY_FAKE_UUID="model-warn-uuid-aaaa-bbbb-cccccccccccc" \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE _LIB_AGENT_AGY_MODEL_WARNED
      source "'"$LIB"'"
      run_agent "'"$SESSION_ID6"'" "with model" "gemini-3-pro-preview" ""
    '
  ) 2>&1 1>/dev/null
)
# rc captured separately — re-run for it, since the subshell pattern above
# is for stderr capture.
(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_FAKE_UUID="model-warn-uuid-aaaa-bbbb-cccccccccccc" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE _LIB_AGENT_AGY_MODEL_WARNED
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID6"'" "with model" "gemini-3-pro-preview" ""
  ' >/dev/null 2>&1
)
model_rc=$?

assert_contains "model WARN emitted to stderr" \
  "AGENT_CMD=agy does not support --model" "$run_stderr"
assert_eq "execution continues despite WARN — rc=0" 0 "$model_rc"
agy_argv=$(cat "$ARGS_FILE")
assert_not_contains "agy argv does NOT contain --model" "--model" "$agy_argv"
```

- [ ] **Step 2.12: Add AGY-07: log without Print mode line — sidecar absent, rc still propagates**

Append to `tests/unit/test-lib-agent-agy.sh` before the final PASS/FAIL printout:

```bash
# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-07: log without Print-mode line — INV-36 best-effort ==="
# ---------------------------------------------------------------------------
SESSION_ID7="77777777-aaaa-bbbb-cccc-dddddddddddd"

# Stub agy variant that writes a log file WITHOUT the Print-mode line.
cat > "$BIN/agy-nomatch" <<'STUB'
#!/bin/bash
echo "$@" > "$AGY_ARGS_FILE"
cat > "${AGY_STDIN_FILE:-/dev/null}"
log_file=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--log-file" ]]; then
    log_file="$arg"
    break
  fi
  prev="$arg"
done
if [[ -n "$log_file" ]]; then
  cat > "$log_file" <<EOF
I0524 22:56:05.692100 1234 input.go:42] Starting print mode
I0524 22:56:05.692500 1234 nomatch.go:99] Some unrelated line
EOF
fi
exit 0
STUB
chmod +x "$BIN/agy-nomatch"

# Symlink agy → agy-nomatch for this case.
mv "$BIN/agy" "$BIN/agy.real"
ln -sf "$BIN/agy-nomatch" "$BIN/agy"

: > "$ARGS_FILE"; : > "$STDIN_FILE"

(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE _LIB_AGENT_AGY_MODEL_WARNED
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID7"'" "no-match prompt" "" ""
  ' >/dev/null 2>&1
)
nomatch_rc=$?

# Restore real stub for any later cases.
rm -f "$BIN/agy"
mv "$BIN/agy.real" "$BIN/agy"

assert_eq "AGY-07 — rc still propagates from agy stub (0)" 0 "$nomatch_rc"
sidecar7="$PID_DIR/agy-conversation-$SESSION_ID7"
if [[ ! -e "$sidecar7" ]]; then
  echo -e "  ${GREEN}PASS${NC}: AGY-07 — sidecar absent for log without Print-mode line"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: AGY-07 — sidecar should be absent"
  FAIL=$((FAIL + 1))
fi
```

(AGY-08, the symlink-sidecar refusal case, is already covered by AGY-S4 from Task 1, so no new test is needed — the helper-level check is the same protection regardless of who calls it. Reference AGY-S4 in the spec table where AGY-08 was listed.)

- [ ] **Step 2.13: Run all tests — verify everything passes**

Run:
```bash
bash tests/unit/test-lib-agent-agy.sh
```

Expected: all assertions PASS, exit 0.

- [ ] **Step 2.14: Run shellcheck**

Run:
```bash
shellcheck -S error skills/autonomous-dispatcher/scripts/lib-agent.sh
```

Expected: exit 0.

- [ ] **Step 2.15: Run the existing lib-agent test suite (regression)**

Run:
```bash
for t in tests/unit/test-lib-agent-*.sh; do
  echo "=== $t ==="
  bash "$t" || echo "FAILED: $t"
done
```

Expected: all of `test-lib-agent-codex.sh`, `test-lib-agent-extra-args.sh`, `test-lib-agent-gemini.sh`, `test-lib-agent-kiro-permission.sh`, `test-lib-agent-opencode.sh`, `test-lib-agent-prompt-stdin.sh`, `test-lib-agent-agy.sh` exit 0. The agy branch is purely additive and must not regress any existing branch.

- [ ] **Step 2.16: Commit Task 2**

Run:
```bash
git add skills/autonomous-dispatcher/scripts/lib-agent.sh tests/unit/test-lib-agent-agy.sh
git commit -m "feat(lib-agent): add agy branch to run_agent and resume_agent

Wires AGENT_CMD=agy through the dispatch flow:

run_agent:
  - WARN once per process when model param is non-empty (agy doesn't
    accept --model; configure via ~/.gemini/antigravity-cli/settings.json)
  - printf prompt | _run_with_timeout agy -p --dangerously-skip-permissions
    --print-timeout \$AGENT_TIMEOUT --log-file <pid_dir>/agy-log-<sid>.log
  - post-step: _agy_capture_conversation grabs the UUID from the log

resume_agent:
  - reads sidecar, invokes agy --conversation <uuid> with same flags
  - sidecar miss -> falls back to run_agent (codex/opencode pattern)

INV-36 best-effort capture: missing log line / unwritable sidecar /
symlink sidecar do not gate run_agent's exit code.

Tests: AGY-S1..S4 (helpers) + AGY-01..07 (dispatch flow) green.
All existing test-lib-agent-*.sh tests still pass."
```

---

## Task 3: Add `# --- agy block ---` to `autonomous.conf.example`

**Files:**
- Modify: `skills/autonomous-dispatcher/scripts/autonomous.conf.example`

- [ ] **Step 3.1: Locate the opencode block (the last block in the file)**

Run:
```bash
grep -n "^# --- opencode block ---" skills/autonomous-dispatcher/scripts/autonomous.conf.example
```

Expected: returns line number around 271. The opencode block runs ~10 lines from there.

- [ ] **Step 3.2: Update the AGENT_CMD comment header to mention `agy`**

Find the comment line near line 102:
```
# First-class support: claude, codex, gemini, kiro, opencode. Other
```
Edit it to:
```
# First-class support: claude, codex, gemini, kiro, opencode, agy. Other
```

- [ ] **Step 3.3: Append the agy block immediately after the opencode block**

Find the closing line of the opencode block (line containing `# AGENT_REVIEW_EXTRA_ARGS=""` followed by a blank line, just before `# === GitHub Authentication ===`). Insert this block in between:

```bash

# --- agy block ---
# Antigravity 2.0 CLI (Google) — successor to gemini CLI.
# agy 1.0.2 verified.
#
# Structural flags managed by lib-agent.sh (NOT to add here):
#   -p, --dangerously-skip-permissions, --print-timeout, --log-file
#
# Operator notes:
#   1. agy does NOT accept --model on the CLI. AGENT_DEV_MODEL /
#      AGENT_REVIEW_MODEL are ignored with a one-time WARN. Configure
#      model selection via ~/.gemini/antigravity-cli/settings.json.
#   2. --dangerously-skip-permissions is structural and load-bearing
#      for headless tool execution; without it agy denies every tool
#      call (silent fabrication failure, same shape as gemini's
#      ask_user→deny default that --approval-mode yolo fixes).
#   3. agy's internal --print-timeout default is 5 minutes. lib-agent
#      passes AGENT_TIMEOUT through so the outer wall-clock cap is
#      authoritative.
#   4. Conversation IDs are minted by agy and captured from the CLI
#      log file via grep — see [INV-36] in docs/pipeline/invariants.md
#      for the best-effort contract.
#
# AGENT_CMD="agy"
# AGENT_DEV_MODEL=""        # Ignored — see note 1.
# AGENT_REVIEW_MODEL=""     # Ignored — see note 1.
# AGENT_DEV_EXTRA_ARGS=""
# AGENT_REVIEW_EXTRA_ARGS=""
```

- [ ] **Step 3.4: Sanity-check the conf file is still valid bash syntax**

Run:
```bash
bash -n skills/autonomous-dispatcher/scripts/autonomous.conf.example
```

Expected: exit 0. (`-n` is parse-only.)

- [ ] **Step 3.5: Commit Task 3**

Run:
```bash
git add skills/autonomous-dispatcher/scripts/autonomous.conf.example
git commit -m "docs(conf): document agy block in autonomous.conf.example

Adds # --- agy block --- with the four operator notes (model not
honored, --dangerously-skip-permissions structural, --print-timeout
override, conversation-id capture per INV-36) and the AGENT_CMD
listing in the header comment."
```

---

## Task 4: Add INV-36 entry to `docs/pipeline/invariants.md`

**Files:**
- Modify: `docs/pipeline/invariants.md` (append after the INV-35 block, before the "Adding a new invariant" section)

- [ ] **Step 4.1: Locate the insertion point**

Run:
```bash
grep -n "^## Adding a new invariant" docs/pipeline/invariants.md
```

Expected: a single line number. Insert *immediately before* that heading.

- [ ] **Step 4.2: Insert the INV-36 block**

Insert this content immediately before `## Adding a new invariant`:

```markdown
## INV-36: agy conversation id capture is best-effort

**Rule**: `_agy_capture_conversation` (in `lib-agent.sh`, used by the `agy)` branch of `run_agent` / `resume_agent`) MUST NOT gate `run_agent`'s exit code on capture success. A grep miss, missing log file, or unwritable sidecar path all return 0 from the helper and leave the sidecar absent. `resume_agent` MUST handle sidecar-absent by falling back to a fresh `run_agent`.

**Why**: agy's `Print mode: conversation=<UUID>` log line is undocumented (emitted from agy's internal `printmode.go:130` as of agy 1.0.2). A future agy version may rename the log message, change the format, or move the channel entirely. Gating `run_agent` on capture would convert a documentation drift into a pipeline outage. The sidecar pattern already includes a degraded-but-functional fallback (fresh run loses conversation continuity but preserves pipeline progress) — INV-36 makes that explicit so future maintainers do not "helpfully" promote capture failure to a hard error.

**Producer**: `_agy_capture_conversation` in `skills/autonomous-dispatcher/scripts/lib-agent.sh`.

**Consumer**: `resume_agent` agy branch reads the sidecar via `_agy_conversation_id`; absent return-1 triggers fallback to `run_agent`.

**Test**: `tests/unit/test-lib-agent-agy.sh` — AGY-S3 (log without match leaves sidecar absent), AGY-S4 (symlink sidecar refused with WARN), AGY-05 (resume without sidecar falls back to fresh run), AGY-07 (run_agent rc still propagates when log lacks the Print-mode line).

**Cross-references**:
- [`docs/pipeline/agy-cli-support.md`](agy-cli-support.md) — full per-CLI spec for the agy branch.
- [INV-31](#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh) — agy's structural flags (-p, --dangerously-skip-permissions, --print-timeout, --log-file) live in `lib-agent.sh`, NOT in `AGENT_*_EXTRA_ARGS`.
- [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element) — agy's `-p` (no value) reads from stdin, same channel contract as claude/gemini.

```

(Blank line before `## Adding a new invariant` heading.)

- [ ] **Step 4.3: Verify the link from `agy-cli-support.md` resolves**

Run:
```bash
grep -n "inv-36-agy-conversation-id-capture-is-best-effort" docs/pipeline/invariants.md
```

Expected: returns the auto-generated GFM anchor for the new heading. The anchor matches `docs/pipeline/agy-cli-support.md`'s link `invariants.md#inv-36-agy-conversation-id-capture-is-best-effort`.

- [ ] **Step 4.4: Commit Task 4**

Run:
```bash
git add docs/pipeline/invariants.md
git commit -m "docs(pipeline): record INV-36 best-effort capture for agy

INV-36 formalizes that _agy_capture_conversation is best-effort:
missing log line / unwritable sidecar / symlink path do not gate
run_agent's exit code. resume_agent handles sidecar-absent via
fallback to a fresh run_agent.

Anchored to docs/pipeline/agy-cli-support.md and tests
test-lib-agent-agy.sh AGY-S3/S4/05/07."
```

---

## Task 5: Add agy to `autonomous-dispatcher/SKILL.md`

**Files:**
- Modify: `skills/autonomous-dispatcher/SKILL.md`

- [ ] **Step 5.1: Find the supported-CLIs listing**

Run:
```bash
grep -n -i "claude\|codex\|gemini\|kiro\|opencode" skills/autonomous-dispatcher/SKILL.md | head -10
```

Expected: there's a section (likely a table or bulleted list) that enumerates the supported CLI values for `AGENT_CMD`. Identify the exact location.

- [ ] **Step 5.2: Add `agy` to the listing**

Add `agy` to wherever the other five CLI names appear, in the same style. Two common forms:
- Inline list: change "claude, codex, gemini, kiro, opencode" → "claude, codex, gemini, kiro, opencode, agy"
- Bulleted list: add a new bullet:
  ```markdown
  - `agy` — Antigravity 2.0 CLI (Google). Sidecar capture from log file. See [`docs/pipeline/agy-cli-support.md`](../../docs/pipeline/agy-cli-support.md) and [INV-36](../../docs/pipeline/invariants.md#inv-36-agy-conversation-id-capture-is-best-effort).
  ```

Inspect the existing entries to match the format exactly. Do NOT introduce a third style.

- [ ] **Step 5.3: Commit Task 5**

Run:
```bash
git add skills/autonomous-dispatcher/SKILL.md
git commit -m "docs(skill): list agy as supported AGENT_CMD value"
```

---

## Task 6: PR review + push

- [ ] **Step 6.1: Run the full unit-test suite (final regression)**

Run:
```bash
failed=0
for t in tests/unit/test-*.sh; do
  if ! bash "$t" >/dev/null 2>&1; then
    echo "FAILED: $t"
    failed=1
  fi
done
[[ $failed -eq 0 ]] && echo "ALL UNIT TESTS PASS"
```

Expected: `ALL UNIT TESTS PASS`. Any failure here is a regression and must be fixed before pushing — agy support is purely additive and should not break any existing test.

- [ ] **Step 6.2: shellcheck the lib-agent file once more**

Run:
```bash
shellcheck -S error skills/autonomous-dispatcher/scripts/lib-agent.sh
```

Expected: exit 0. CI runs the same check.

- [ ] **Step 6.3: Trigger pr-review agent**

This project's `check-pr-review.sh` hook blocks `git push` until the pr-review agent has run. Use the project's standard process for invoking it (typically the `/pr-review` slash command in Claude Code, or whatever the local agent supports).

Expected: pr-review reports OK or surfaces fixable findings. Address any findings before push.

- [ ] **Step 6.4: Rebase onto main and push**

Run:
```bash
git fetch origin main
git rebase origin/main
git push -u origin feat/agy-cli-support
```

Expected: push succeeds (the `block-push-to-main` hook only blocks pushes targeting `main` itself; pushing a feature branch is fine).

- [ ] **Step 6.5: Open a PR**

Run:
```bash
gh pr create --title "feat: add Antigravity 2.0 CLI (agy) support" --body "$(cat <<'EOF'
## Summary

- Adds `AGENT_CMD=agy` (Google Antigravity 2.0 CLI, v1.0.2) as a sixth supported value in `lib-agent.sh`, alongside claude/codex/gemini/kiro/opencode.
- Sidecar pattern for conversation-id capture (UUID lives in agy's CLI log file, not stdout) — mirrors codex/opencode.
- New invariant **INV-36**: capture is best-effort; missing log line / unwritable sidecar / symlink path do not gate run_agent.

## Spec

`docs/pipeline/agy-cli-support.md` — full per-CLI contract (verified against agy 1.0.2).

## Test plan

- [ ] `bash tests/unit/test-lib-agent-agy.sh` — AGY-S1..S4 (helpers) + AGY-01..07 (dispatch flow)
- [ ] `bash tests/unit/test-lib-agent-codex.sh` — regression, codex unaffected
- [ ] `bash tests/unit/test-lib-agent-opencode.sh` — regression
- [ ] `bash tests/unit/test-lib-agent-gemini.sh` — regression
- [ ] CI green on `unit-tests` + `shellcheck` + `pipeline-docs-gate`

## Pipeline-docs gate

Touches `skills/autonomous-dispatcher/scripts/lib-agent.sh`, so the gate requires a `docs/pipeline/` change. Satisfied by:
- `docs/pipeline/agy-cli-support.md` (new spec)
- `docs/pipeline/invariants.md` (INV-36)
- `docs/pipeline/README.md` (file index)
EOF
)"
```

Expected: PR URL printed.

---

## Self-Review (run after all tasks complete)

**Spec coverage** — every section of `docs/pipeline/agy-cli-support.md` mapped to a task:

| Spec section | Task |
|---|---|
| §CLI shape | Task 2 — flag set goes into the case body |
| §Session model — sidecar pattern | Task 1 (helpers) + Task 2 (wiring) |
| §`run_agent` contract — agy branch | Task 2 |
| §`resume_agent` contract — agy branch | Task 2 |
| §Helper trio | Task 1 |
| §Failure-mode table | Tests AGY-05/AGY-07 + AGY-S3/S4 (Task 1+2) |
| §Differences from peer CLIs | (no code — spec only) |
| §Operator-facing config | Task 3 |
| §Test coverage table | Task 1+2 (AGY-S1..S4 + AGY-01..07) |
| §INV-36 invariant | Task 4 |

**Placeholder scan** — none. Every code block is complete and copy-pasteable. No "similar to Task N" handwaves; resume_agent code in Task 2 is fully written even though its structure parallels run_agent.

**Type / signature consistency** —
- `_agy_log_file` returns the log path, used in run_agent (Task 2 Step 2.3) and resume_agent (Task 2 Step 2.7). Same return type (stdout string).
- `_agy_conversation_id` returns rc 0 + UUID on stdout when sidecar exists, rc 1 when absent. Used in `if _agy_cid=$(_agy_conversation_id ...); then` — matches.
- `_agy_capture_conversation` returns 0 in all best-effort paths (INV-36). Called as a fire-and-forget post-step in both run_agent and resume_agent — matches.
- Sidecar path used in production code (`pid_dir/agy-conversation-<sid>`) matches sidecar path asserted by tests (`$PID_DIR/agy-conversation-$SESSION_IDn`) — same template.
- AGY-08 from the spec is consolidated into AGY-S4 at the helper level (Task 1.10) — addressed in Task 2.12 commentary.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-25-agy-cli-support.md`. Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
