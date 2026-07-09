#!/bin/bash
# test-state-manager-bsd-date-tz.sh — Unit tests for issue #446
#
# Verifies fix for issue #446: state-manager.sh `check` action mis-parses
# the stored UTC mark timestamp on BSD `date` (no GNU `date -d`) in a
# non-UTC timezone, because BSD `date -j -f` ignores the trailing `Z` and
# parses the string as local time instead of UTC.
#
# This repo's CI runs Linux only, and GNU `date -d` already handles the
# `Z` suffix correctly, so a plain TZ-only test would pass before the fix
# and prove nothing. The BSD branch is forced via a PATH-shimmed fake
# `date` binary that rejects `-d` (forcing the real code to fall through)
# and emulates BSD `-j -f` semantics for both the pre-fix (no `-u`,
# ignores `Z`) and post-fix (`-u`, honors `Z` as UTC) forms.
#
# Run: bash tests/unit/test-state-manager-bsd-date-tz.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_MANAGER="$PROJECT_ROOT/skills/autonomous-common/hooks/state-manager.sh"
REAL_DATE="$(command -v date)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected exit=$expected, actual=$actual)"
    ((FAIL++))
  fi
}

# Snapshots a directory's contents so a later call can prove nothing
# changed. Returns empty string for a missing directory, which is a valid
# "nothing there" baseline distinct from "has entries".
#
# Hashes each regular file's content (not just its path) so an in-place
# rewrite of an existing file -- same path, new bytes -- shows up as a
# diff. A path-only `find` listing would miss that: entry names would be
# identical before and after even though the file's contents changed.
# Directory entries (including empty dirs) are still recorded by path so
# additions/removals of empty dirs are also caught.
snapshot_dir() {
  local dir="$1"
  local -a sha_cmd=()
  [[ -d "$dir" ]] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    sha_cmd=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then
    sha_cmd=(shasum -a 256)
  fi
  {
    find "$dir" -mindepth 1 -type d 2>/dev/null | LC_ALL=C sort | sed 's/^/DIR /'
    if [[ ${#sha_cmd[@]} -gt 0 ]]; then
      # Hash each file individually via a NUL-delimited read loop instead
      # of `sort -z` + `xargs -0 -r`: both are GNU-only (BSD/macOS sort
      # has no -z, and BSD xargs has no -r), so that pipeline silently
      # produced zero hash lines on a stock macOS shell. This form also
      # invokes the checksum tool as a proper argv array (`"${sha_cmd[@]}"`)
      # rather than as a single string ("shasum -a 256"), which xargs
      # would otherwise try to exec as one non-existent binary.
      local f
      while IFS= read -r -d '' f; do
        "${sha_cmd[@]}" "$f" 2>/dev/null
      done < <(find "$dir" -mindepth 1 -type f -print0 2>/dev/null) \
        | LC_ALL=C sort -k2
    else
      # Last-resort fallback if no checksum tool is available: fall back
      # to path + size + mtime, which still catches in-place rewrites
      # (unlike a bare path listing) even though it's weaker than a hash.
      find "$dir" -mindepth 1 -type f -exec stat -c '%s %Y %n' {} + 2>/dev/null \
        | LC_ALL=C sort -k3
    fi
  }
}

# Asserts a directory's contents are unchanged from a prior snapshot taken
# before the test ran. This replaces an earlier "must be empty" assertion:
# on this self-hosting repo, contributors can have legitimate pre-existing
# state under .claude/state, .kiro/state, or .agents/state (e.g. from their
# own dev/review sessions), so requiring emptiness produced false failures.
# Requiring "untouched by this test run" is the actual invariant that
# matters and holds regardless of what was there beforehand.
assert_dir_untouched() {
  local desc="$1" dir="$2" before="$3"
  local after
  after="$(snapshot_dir "$dir")"
  if [[ "$before" == "$after" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (contents changed)"
    echo "    before: ${before//$'\n'/ }"
    echo "    after:  ${after//$'\n'/ }"
    ((FAIL++))
  fi
}

TMPDIR=$(mktemp -d)
SHIM_DIR=$(mktemp -d)
TRACE_DIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR" "$SHIM_DIR" "$TRACE_DIR"' EXIT

# Baseline snapshots of this repo's own state dirs, taken before any test
# case runs. Used only as the fallback isolation signal when live syscall
# tracing (below) is unavailable.
BASELINE_CLAUDE_STATE="$(snapshot_dir "$PROJECT_ROOT/.claude/state")"
BASELINE_KIRO_STATE="$(snapshot_dir "$PROJECT_ROOT/.kiro/state")"
BASELINE_AGENTS_STATE="$(snapshot_dir "$PROJECT_ROOT/.agents/state")"

# ---------------------------------------------------------------------------
# Live filesystem-write tracing (primary isolation signal).
#
# The before/after snapshot above only proves the *net* state after the run
# matches the baseline. It cannot see a transient write: `check` legitimately
# deletes a stale/invalid mark file it just read (see clear-on-expiry logic
# in state-manager.sh), so a bug that makes it resolve to *this repo's own*
# state dir instead of the sandboxed project could create-then-remove a file
# there and still leave the final snapshot unchanged.
#
# strace -f -e trace=%file captures every filesystem-path syscall (openat,
# unlink[at], mkdir[at], rename[at], rmdir, ...) made by the traced command
# and its children, including ones that are undone before exit. We check the
# trace for any such syscall whose path argument falls under this repo's
# own .claude/state, .kiro/state, or .agents/state -- which should never
# happen since every run_mark/run_check call below pins CLAUDE_PROJECT_DIR
# to an isolated $TMPDIR/projN sandbox.
#
# Falls back to the weaker before/after snapshot (assert_dir_untouched)
# when strace isn't available or ptrace is denied in the sandbox (e.g. a
# restrictive seccomp/AppArmor profile) -- detected via a one-time probe
# rather than assumed from `command -v` alone, since strace can be present
# but unusable.
TRACE_AVAILABLE=0
if command -v strace >/dev/null 2>&1; then
  if strace -f -o /dev/null -- true >/dev/null 2>&1; then
    TRACE_AVAILABLE=1
  fi
fi

# Runs a command, tracing its filesystem-path syscalls (and its children's)
# into a fresh file under $TRACE_DIR when tracing is available; otherwise
# just runs it directly. Each call gets its own trace file named from a
# fresh mktemp (not an incrementing counter): run_traced is invoked from
# inside a `(...)` subshell in run_mark/run_check, and subshells don't
# share writes to a parent-scope counter variable, so a counter would
# collide and overwrite trace files across calls.
run_traced() {
  if [[ $TRACE_AVAILABLE -eq 1 ]]; then
    local trace_file
    trace_file=$(mktemp "$TRACE_DIR/trace-XXXXXX.log")
    strace -f -e trace=%file -o "$trace_file" -- "$@"
  else
    "$@"
  fi
}

# Scans all accumulated trace logs for any filesystem-path syscall whose
# path argument is under the given repo-owned state directory. Matches on
# the directory's real (symlink-resolved) absolute path so a sandboxed
# tmp dir can never false-positive-match by string prefix alone.
check_trace_for_leak() {
  local dir="$1" desc="$2"
  local real_dir
  real_dir=$(cd "$dir" 2>/dev/null && pwd -P) || real_dir="$dir"
  if ! compgen -G "$TRACE_DIR/trace-*.log" >/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: $desc (no trace activity recorded)"
    ((PASS++))
    return
  fi
  local hit
  hit=$(grep -F "$real_dir/" "$TRACE_DIR"/trace-*.log 2>/dev/null | head -3)
  if [[ -z "$hit" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (filesystem syscall touched $real_dir during the run)"
    hit="${hit//$'\n'/$'\n    '}"
    echo "    $hit"
    ((FAIL++))
  fi
}

# ---------------------------------------------------------------------------
# Fake `date` binary. Placed ahead of the real `date` in PATH for the
# forced-BSD-branch cases only.
#
#   date -u +FORMAT / date +%s        -> passthrough to real date
#   date -d ...                       -> exit 1 (forces fallthrough)
#   date -j -f FORMAT VALUE +%s       -> pre-fix BSD semantics: strip
#                                         trailing Z, parse under ambient
#                                         $TZ as local time
#   date -u -j -f FORMAT VALUE +%s    -> post-fix BSD semantics: strip
#                                         trailing Z, parse as UTC
#
# On a GNU-date host (this repo's Linux CI) the above two -j -f forms are
# emulated by delegating through the real GNU `date -d`, since GNU date
# has no native -j -f. On a real BSD/macOS host, the shim delegates
# straight to the real `date -j -f` instead, which already natively
# implements those exact semantics -- re-emulating it via `-d` would
# break, since BSD date has no `-d` at all.
# ---------------------------------------------------------------------------
# Probe REAL_DATE's own flavor once, at shim-generation time, so the shim
# can pick the right emulation strategy for -j -f instead of assuming GNU:
#   - GNU date (Linux CI): has -d, no real -j -f. The shim must emulate
#     BSD -j -f semantics by delegating through -d.
#   - BSD/macOS date (real macOS run): -j -f is native and already gets
#     the -u/no-u + literal-Z semantics right (that's the exact behavior
#     issue #446's production fix relies on). Forcing it through a
#     GNU-only `-d` call breaks it, since BSD date has no `-d`. Delegate
#     straight to the real binary instead of re-implementing what it
#     already does correctly.
REAL_DATE_IS_GNU=0
if TZ=UTC "$REAL_DATE" -d "1970-01-01T00:00:00Z" +%s >/dev/null 2>&1; then
  REAL_DATE_IS_GNU=1
fi

cat > "$SHIM_DIR/date" <<SHIMEOF
#!/bin/bash
REAL_DATE="$REAL_DATE"
REAL_DATE_IS_GNU=$REAL_DATE_IS_GNU
args=("\$@")
for a in "\${args[@]}"; do
  if [[ "\$a" == "-d" ]]; then
    exit 1
  fi
done
use_utc=0
rest=("\${args[@]}")
if [[ "\${rest[0]:-}" == "-u" ]]; then
  use_utc=1
  rest=("\${rest[@]:1}")
fi
if [[ "\${rest[0]:-}" == "-j" ]]; then
  if [[ \$REAL_DATE_IS_GNU -eq 1 ]]; then
    # Forced-BSD-branch emulation on a GNU-date host (Linux CI): strip the
    # trailing Z and re-parse via the real GNU date's -d, honoring -u the
    # same way real BSD -j -f would (no -u => ambient TZ as local time;
    # -u => UTC), since GNU date has no native -j -f to fall back on.
    value="\${rest[3]}"
    outfmt="\${rest[4]}"
    stripped="\${value%Z}"
    if [[ \$use_utc -eq 1 ]]; then
      TZ=UTC "\$REAL_DATE" -d "\$stripped" "\$outfmt"
    else
      TZ="\${TZ:-UTC}" "\$REAL_DATE" -d "\$stripped" "\$outfmt"
    fi
    exit \$?
  else
    # Real BSD/macOS host: the real date binary already natively
    # supports -j -f with correct -u/local-time and literal-Z semantics,
    # so delegate straight to it instead of re-emulating.
    exec "\$REAL_DATE" "\${args[@]}"
  fi
fi
exec "\$REAL_DATE" "\${args[@]}"
SHIMEOF
chmod +x "$SHIM_DIR/date"

setup_project() {
  local dir="$1"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  mkdir -p "$dir/.claude/state"
  echo "a" > "$dir/a.txt"
  git -C "$dir" add a.txt
  git -C "$dir" commit -q -m "initial"
}

run_mark() {
  local project="$1" action="$2" path_prefix="$3"
  ( cd "$project" && CLAUDE_PROJECT_DIR="$project" PATH="${path_prefix}${path_prefix:+:}$PATH" run_traced "$STATE_MANAGER" mark "$action" >/dev/null 2>&1 )
}

run_check() {
  local project="$1" action="$2" path_prefix="$3"
  ( cd "$project" && CLAUDE_PROJECT_DIR="$project" PATH="${path_prefix}${path_prefix:+:}$PATH" run_traced "$STATE_MANAGER" check "$action" >/dev/null 2>&1; echo $? )
}

# Backdates a state file's timestamp by N minutes, using the REAL date
# binary directly (test scaffolding, not the code under test).
#
# Tries GNU `date -d "N minutes ago"` first; on macOS/BSD, REAL_DATE is
# the BSD `date` binary, which has no `-d` and exits non-zero (empty
# stdout), so old_ts would silently become "" and the subsequent `check`
# call would fail on an invalid timestamp -- passing TC-SMTZ-002 for the
# wrong reason (bad input) instead of the real invariant (stale mark).
# Falls back to BSD `date -v-NM`, which adjusts the current time by N
# minutes without needing `-d`.
backdate_state() {
  local project="$1" action="$2" minutes="$3"
  local state_file="$project/.claude/state/${action}.json"
  local old_ts
  old_ts=$("$REAL_DATE" -u -d "$minutes minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  if [[ -z "$old_ts" ]]; then
    old_ts=$("$REAL_DATE" -u -v"-${minutes}M" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
  fi
  jq --arg ts "$old_ts" '.timestamp = $ts' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
}

# ===========================================================================
echo ""
echo "=== TC-SMTZ-001: forced-BSD branch + positive offset (Asia/Shanghai) is fresh ==="
echo ""
PROJECT1="$TMPDIR/proj1"
setup_project "$PROJECT1"
export TZ="Asia/Shanghai"
run_mark "$PROJECT1" "pr-review" "$SHIM_DIR"
exit_code=$(TZ="Asia/Shanghai" run_check "$PROJECT1" "pr-review" "$SHIM_DIR")
assert_exit "check returns 0 for a fresh mark under UTC+8 forced-BSD parsing" "0" "$exit_code"
unset TZ

# ===========================================================================
echo ""
echo "=== TC-SMTZ-002: forced-BSD branch + negative offset (America/New_York) rejects stale mark ==="
echo ""
PROJECT2="$TMPDIR/proj2"
setup_project "$PROJECT2"
export TZ="America/New_York"
run_mark "$PROJECT2" "pr-review" "$SHIM_DIR"
backdate_state "$PROJECT2" "pr-review" 45
exit_code=$(TZ="America/New_York" run_check "$PROJECT2" "pr-review" "$SHIM_DIR")
assert_exit "check returns 1 for a 45-minute-old mark under UTC-5 forced-BSD parsing" "1" "$exit_code"
unset TZ

# ===========================================================================
echo ""
echo "=== TC-SMTZ-003: GNU date -d branch unaffected (no shim, real date) ==="
echo ""
PROJECT3="$TMPDIR/proj3"
setup_project "$PROJECT3"
export TZ="Asia/Shanghai"
run_mark "$PROJECT3" "pr-review" ""
exit_code=$(TZ="Asia/Shanghai" run_check "$PROJECT3" "pr-review" "")
assert_exit "check returns 0 for a fresh mark via real GNU date -d under UTC+8" "0" "$exit_code"
unset TZ

# ===========================================================================
echo ""
echo "=== TC-SMTZ-004: state isolation — repo's own state dirs untouched ==="
echo ""
if [[ $TRACE_AVAILABLE -eq 1 ]]; then
  echo "  (live syscall tracing active — catches transient writes, not just net state)"
  check_trace_for_leak "$PROJECT_ROOT/.claude/state" "repo .claude/state: no filesystem writes during this test run"
  check_trace_for_leak "$PROJECT_ROOT/.kiro/state" "repo .kiro/state: no filesystem writes during this test run"
  check_trace_for_leak "$PROJECT_ROOT/.agents/state" "repo .agents/state: no filesystem writes during this test run"
else
  echo "  (strace/ptrace unavailable in this sandbox — falling back to before/after snapshot;"
  echo "   this fallback cannot detect a transient write that is undone before the run ends)"
  assert_dir_untouched "repo .claude/state unchanged by this test run" "$PROJECT_ROOT/.claude/state" "$BASELINE_CLAUDE_STATE"
  assert_dir_untouched "repo .kiro/state unchanged by this test run" "$PROJECT_ROOT/.kiro/state" "$BASELINE_KIRO_STATE"
  assert_dir_untouched "repo .agents/state unchanged by this test run" "$PROJECT_ROOT/.agents/state" "$BASELINE_AGENTS_STATE"
fi

# Summary
echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
