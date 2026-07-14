#!/bin/bash
# check-shell-idioms.sh — issue #477, [INV-130] shell-idiom ratchet gate.
#
# Blocks GROWTH of two recurring shell-idiom bug surfaces across the
# dispatcher scripts tree (baseline-anchored, NOT a from-zero ban — mirrors
# [INV-91]'s check-provider-cutover.sh):
#
#   Rule J (jq nullable-string guard) — a jq `.body` string op
#     (test/contains/startswith/endswith/sub/gsub) with no `type == "string"`
#     guard nearby. A bot comment with `body: null` (a real GitHub REST
#     shape) makes the unguarded op a jq RUNTIME ERROR that aborts the whole
#     invocation, not a per-row non-match.
#   Rule S (swallow justification) — `|| true` / `|| echo …` with no
#     adjacent comment explaining which-direction-does-this-fail.
#
# Both detectors are line-window HEURISTICS, not a bash/jq parser (deliberate
# — see the issue body's Design Considerations). A false positive in EXISTING
# code is absorbed by the committed baseline; a false positive in NEW code
# costs the author one guard/comment — the behavior this gate wants.
#
# Baseline-anchored, per-file counts (shape: { "<path>": { "jq_unguarded": N,
# "swallow_unjustified": N } }). Per file: current > baseline -> FAIL (prints
# the offending file:line + matched text); current < baseline -> PASS with a
# regeneration notice (ratchet-down is a separate voluntary commit). A file
# with zero baseline entry defaults to baseline 0, so "absent with count > 0"
# falls out of the same "current > baseline" comparison — no special case.
#
# Usage:
#   check-shell-idioms.sh                    Check the working tree against
#                                             the committed baseline.
#   check-shell-idioms.sh --scan-root D --baseline F
#                                             Override paths (unit tests point
#                                             these at scratch fixture trees).
#   check-shell-idioms.sh --write-baseline [--scan-root D]
#                                             Emit a fresh baseline JSON (sorted
#                                             keys, deterministic) for the
#                                             current tree to stdout.
#   check-shell-idioms.sh --require-trusted-ref [--trusted-ref REF]
#                              [--trusted-baseline-path P]
#                                             STRICT mode (fail-closed): read
#                                             the baseline from the TRUSTED ref
#                                             (default origin/main) via
#                                             `git show` instead of the working
#                                             tree, so a PR cannot regenerate
#                                             its own baseline and self-ratify.
#                                             An unresolvable ref/baseline FAILs
#                                             closed (exit 1), never a silent
#                                             pass.
#
# Exit: 0 pass; 1 violations (or strict-mode fail-closed); 2 usage/infra error.
#
# Credential-free (bash + jq + coreutils only) — CI/dev tool, not sourced by
# any dispatch-time wrapper.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# check-shell-idioms.sh lives at skills/autonomous-dispatcher/scripts/ — two
# levels up is skills/, the R4 scan root ("all *.sh under skills/").
SCAN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASELINE="$SCRIPT_DIR/shell-idioms-baseline.json"
WRITE_BASELINE=0
TRUSTED_REF="${SHELL_IDIOMS_TRUSTED_REF:-origin/main}"
# Path of the baseline file RELATIVE to the git repo root, used to read the
# trusted copy via `git show <ref>:<path>`.
TRUSTED_BASELINE_PATH="${SHELL_IDIOMS_TRUSTED_BASELINE_PATH:-skills/autonomous-dispatcher/scripts/shell-idioms-baseline.json}"
REQUIRE_TRUSTED_REF="${SHELL_IDIOMS_REQUIRE_TRUSTED_REF:-0}"

# Usage guard for value-taking options (review finding, round 2): without
# this, an option given with no following value (e.g. a bare trailing
# `--scan-root`) died on an unbound `$2` under `set -u`, exiting 1 (looks
# like an internal shell crash) instead of the documented exit-2 usage error.
# $1 = option name (for the message), $2 = the loop's remaining arg count.
require_value() {
  [ "$2" -ge 2 ] || { echo "check-shell-idioms.sh: $1 requires an argument" >&2; exit 2; }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scan-root)              require_value "$1" "$#"; SCAN_ROOT="$2"; shift ;;
    --baseline)                require_value "$1" "$#"; BASELINE="$2"; shift ;;
    --write-baseline)           WRITE_BASELINE=1 ;;
    --trusted-ref)              require_value "$1" "$#"; TRUSTED_REF="$2"; shift ;;
    --trusted-baseline-path)    require_value "$1" "$#"; TRUSTED_BASELINE_PATH="$2"; shift ;;
    --require-trusted-ref)      REQUIRE_TRUSTED_REF=1 ;;
    -h|--help)                  sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "check-shell-idioms.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "check-shell-idioms.sh: jq is required" >&2; exit 2; }

FAILED=0
fail() { echo "::error::$*" >&2; FAILED=1; }
info() { echo "  $*"; }

# Rule J: a jq `.body` string-op call, guarded iff `type == "string"` appears
# literally within +/-15 lines of the match (R2 — "approximated as the
# surrounding 15 lines within the same file"). Deliberately NOT comment-aware
# (unlike Rule S) — the issue's Rule J definition has no comment carve-out.
# Double-backslashed: passed to awk via -v, which un-escapes once before the
# regex engine sees it, so a single backslash here would reach awk's ERE
# parser as a bare `.`/`(` (a silent WIDENING of the match, not a syntax
# error — awk warns "escape sequence treated as plain" and keeps going).
RULE_J_ERE='\\.body[[:space:]]*\\|[[:space:]]*(test|contains|startswith|endswith|sub|gsub)\\('
# Rule S: an error-swallow, comment-scoped per R3 (stripped before matching).
# POSIX word-end boundary `([^[:alnum:]_]|$)` wraps the WHOLE alternation, not
# gawk's `\>` on a single branch — `(true|echo\>)` looked plausible but only
# bounded `echo`, leaving bare `true` unanchored so it prefix-matched
# `truex`; `\>` is also a GNU-awk extension absent under mawk (a silent
# under-count of `|| echo` there). A NON-WORD-CHAR boundary (rather than
# whitespace-or-EOL) is load-bearing: real swallows are routinely
# paren/semicolon/brace-terminated — `x=$(cmd || true)`, `cmd || true;`,
# `{ cmd || true; }` — and a whitespace/EOL-only boundary silently missed
# every one of them (confirmed ~130 such sites tree-wide). The bracket
# expression is plain POSIX (no `\b`/`\>`) — verified identical under both
# gawk and mawk.
RULE_S_ERE='\\|\\|[[:space:]]*(true|echo)([^[:alnum:]_]|$)'

# Every *.sh under SCAN_ROOT, EXCLUDING any path with a `tests` path segment
# (R4 — test scaffolding legitimately swallows). `find -L` follows symlinks
# so tracked-but-symlinked scripts stay in scope (mirrors
# check-provider-cutover.sh's tree_sh_files). Emits SCAN_ROOT-relative paths.
tree_sh_files() {
  [ -d "$SCAN_ROOT" ] || return 0
  ( cd "$SCAN_ROOT" && find -L . -type f -name '*.sh' -print ) 2>/dev/null \
    | sed 's#^\./##' \
    | grep -Ev '(^|/)tests/' \
    | LC_ALL=C sort
}

# Rule J occurrences for one file: emits "<line>\t<content>" for each
# UNGUARDED match (guard window +/-15 lines, literal substring `type ==
# "string"`).
rule_j_unguarded_lines_in() {
  local path="$1"
  [ -f "$path" ] || return 0
  awk -v rule_re="$RULE_J_ERE" -v window=15 '
    { lines[NR] = $0; total = NR }
    END {
      for (n = 1; n <= total; n++) {
        if (lines[n] !~ rule_re) continue
        guarded = 0
        lo = n - window; if (lo < 1) lo = 1
        hi = n + window; if (hi > total) hi = total
        for (w = lo; w <= hi && !guarded; w++) {
          if (index(lines[w], "type == \"string\"") > 0) guarded = 1
        }
        if (!guarded) {
          s = lines[n]
          gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
          print n "\t" s
        }
      }
    }
  ' "$path"
}

# Rule S occurrences for one file: emits "<line>\t<content>" for each
# UNJUSTIFIED swallow. Comment handling (R3): a whole-line comment (first
# non-space char `#`) never matches at all; an inline trailing comment
# (the first `#` preceded by whitespace) is stripped before matching, so a
# swallow token appearing only inside a comment is never counted as an
# occurrence. Justification: a trailing same-line comment (anything was
# stripped) OR any of the 3 immediately preceding lines being a comment line.
rule_s_unjustified_lines_in() {
  local path="$1"
  [ -f "$path" ] || return 0
  awk -v rule_re="$RULE_S_ERE" '
    function strip_comment(line,    t, s) {
      t = line
      gsub(/^[ \t]+/, "", t)
      if (substr(t, 1, 1) == "#") return ""
      s = line
      sub(/[ \t]#.*$/, "", s)
      return s
    }
    { lines[NR] = $0; total = NR }
    END {
      for (n = 1; n <= total; n++) {
        stripped = strip_comment(lines[n])
        if (stripped == "" || stripped !~ rule_re) continue
        # Same-line trailing comment: something was stripped off this line.
        justified = (stripped != lines[n])
        if (!justified) {
          for (k = 1; k <= 3 && !justified; k++) {
            p = n - k
            if (p < 1) break
            t = lines[p]; gsub(/^[ \t]+/, "", t)
            if (substr(t, 1, 1) == "#") justified = 1
          }
        }
        if (!justified) {
          s = lines[n]
          gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s)
          print n "\t" s
        }
      }
    }
  ' "$path"
}

# Discover per-file counts across the scan tree. Emits "<file>\t<jq>\t<swallow>"
# rows, ONLY for files with at least one occurrence of either rule (mirrors
# check-provider-cutover.sh's "only surviving sites" baseline convention).
discover_counts() {
  local rel path jq_n sw_n
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    path="$SCAN_ROOT/$rel"
    jq_n=$(rule_j_unguarded_lines_in "$path" | wc -l | tr -d ' ')
    sw_n=$(rule_s_unjustified_lines_in "$path" | wc -l | tr -d ' ')
    if [ "$jq_n" -gt 0 ] || [ "$sw_n" -gt 0 ]; then
      printf '%s\t%s\t%s\n' "$rel" "$jq_n" "$sw_n"
    fi
  done < <(tree_sh_files)
}

# ---------------------------------------------------------------------------
# --write-baseline — emit a fresh, deterministic (sorted-key) baseline JSON.
# ---------------------------------------------------------------------------
if [ "$WRITE_BASELINE" -eq 1 ]; then
  discover_counts | jq -R -S -s '
    [ split("\n")[] | select(length > 0) | split("\t")
      | { key: .[0], value: { jq_unguarded: (.[1] | tonumber), swallow_unjustified: (.[2] | tonumber) } } ]
    | from_entries
  '
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the baseline to check against: working tree (default) or the
# trusted ref (--require-trusted-ref, fail-closed on any resolution failure).
# ---------------------------------------------------------------------------
BASELINE_JSON=""
if [ "$REQUIRE_TRUSTED_REF" = "1" ]; then
  if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    fail "strict mode: not a git work tree (or git absent) — cannot resolve trusted ref '$TRUSTED_REF'. A PR must not be able to bypass the ratchet by regenerating its own baseline; run in a git checkout, or drop --require-trusted-ref only for ad-hoc/local runs."
    echo "shell-idioms-guard: FAIL"; exit 1
  fi
  if ! git rev-parse --verify --quiet "$TRUSTED_REF" >/dev/null 2>&1; then
    fail "strict mode: trusted ref '$TRUSTED_REF' is not resolvable here (shallow/fork checkout?). A missing trusted ref FAILs closed under --require-trusted-ref rather than silently passing; deepen the checkout (fetch-depth: 0) or fetch '$TRUSTED_REF'."
    echo "shell-idioms-guard: FAIL"; exit 1
  fi
  if ! BASELINE_JSON="$(git show "${TRUSTED_REF}:${TRUSTED_BASELINE_PATH}" 2>/dev/null)" || ! jq -e . >/dev/null 2>&1 <<<"$BASELINE_JSON"; then
    fail "strict mode: trusted ref '$TRUSTED_REF' has no readable/parseable baseline at '${TRUSTED_BASELINE_PATH}'. A baseline is (re)generated only via --write-baseline as a maintainer, never silently; land it on '$TRUSTED_REF' first, or run without --require-trusted-ref."
    echo "shell-idioms-guard: FAIL"; exit 1
  fi
  info "reading trusted baseline from ${TRUSTED_REF}:${TRUSTED_BASELINE_PATH}"
else
  if [ ! -f "$BASELINE" ]; then
    echo "check-shell-idioms.sh: baseline not found: $BASELINE (regenerate with --write-baseline)" >&2
    exit 2
  fi
  if ! BASELINE_JSON="$(cat "$BASELINE")" || ! jq -e . >/dev/null 2>&1 <<<"$BASELINE_JSON"; then
    echo "check-shell-idioms.sh: baseline is not valid JSON / unreadable: $BASELINE" >&2
    exit 2
  fi
fi

# Schema-validate the resolved baseline: every value must be an object whose
# jq_unguarded/swallow_unjustified (if present) are non-negative INTEGERS —
# not merely jq `number`s. "Parseable JSON" alone is not enough, and neither
# is a bare `type == "number"`: a malformed entry (a string, or a non-integer
# number like 1.5/1e2, where an integer is expected) feeds the reconciliation
# loop's `[ -gt ]`/`[ -lt ]` a non-integer. Bash then prints "integer
# expected" to stderr but still returns non-zero (false), and under
# `set -uo pipefail` (no `-e`) that degrades to a silently-skipped file rather
# than a hard failure — defeating the ratchet for exactly that file, even
# under --require-trusted-ref fail-closed strict mode.
#
# The upper bound (review finding, round 3): an integer-VALUED count can
# still break the same comparisons even after the integer check above. jq
# stores numbers as IEEE-754 doubles, which represent integers exactly only
# up to 2^53 (9007199254740992); beyond that, `floor` rendering flips to
# exponential notation (e.g. 1e20), and even a plain-decimal value close to
# bash's int64 ceiling can round UP past it (9223372036854775808 renders as
# "9223372036854776000", which itself overflows `[ -gt ]`/`[ -lt ]` with the
# same silently-swallowed "integer expected" failure). Capping at 2^53 keeps
# every accepted value both exactly representable in jq and guaranteed to
# render in plain decimal well inside bash's integer range — no legitimate
# per-file occurrence count is anywhere near this ceiling.
# Checked after both baseline-resolution branches so one check covers both.
if ! jq -e 'def nonneg_int: type == "number" and . >= 0 and (. == (. | floor)) and . <= 9007199254740992;
      type == "object" and (to_entries | all(.value | type == "object"
      and ((.jq_unguarded // 0) | nonneg_int)
      and ((.swallow_unjustified // 0) | nonneg_int)))' \
    >/dev/null 2>&1 <<<"$BASELINE_JSON"; then
  if [ "$REQUIRE_TRUSTED_REF" = "1" ]; then
    fail "strict mode: trusted baseline at '${TRUSTED_REF}:${TRUSTED_BASELINE_PATH}' is valid JSON but does not match the expected shape ({\"<path>\": {\"jq_unguarded\": <non-negative integer <= 9007199254740992>, \"swallow_unjustified\": <non-negative integer <= 9007199254740992>}}) — a malformed entry would otherwise silently exempt that file from the ratchet. Regenerate with --write-baseline."
    echo "shell-idioms-guard: FAIL"; exit 1
  else
    echo "check-shell-idioms.sh: baseline at '$BASELINE' is valid JSON but does not match the expected shape ({\"<path>\": {\"jq_unguarded\": <non-negative integer <= 9007199254740992>, \"swallow_unjustified\": <non-negative integer <= 9007199254740992>}}) — regenerate with --write-baseline" >&2
    exit 2
  fi
fi

# Sanity check (found in review): a wrong/missing SCAN_ROOT (bad --scan-root,
# a checkout run from the wrong directory, a sparse checkout missing skills/)
# makes tree_sh_files() silently return nothing. Every baseline entry then
# looks like it "shrank to 0" — the reconciliation loop below would PASS
# trivially, even under --require-trusted-ref, defeating the entire ratchet
# with zero real coverage. Require at least one scanned file before
# reconciling. Not checked before --write-baseline (above) — emitting an
# empty `{}` baseline for a genuinely-empty scan root is legitimate there.
SCANNED_COUNT="$(tree_sh_files | wc -l | tr -d ' ')"
if [ "$SCANNED_COUNT" -eq 0 ]; then
  msg="scan root '$SCAN_ROOT' yielded ZERO *.sh files to check — likely a wrong --scan-root, a missing skills/ directory, or a sparse checkout. Refusing to reconcile against a baseline with nothing to check, which would otherwise PASS trivially (every baseline entry looks like a shrink)."
  if [ "$REQUIRE_TRUSTED_REF" = "1" ]; then
    fail "strict mode: $msg"
    echo "shell-idioms-guard: FAIL"; exit 1
  else
    echo "check-shell-idioms.sh: $msg" >&2
    exit 2
  fi
fi

# ---------------------------------------------------------------------------
# Reconcile discovered counts against the resolved baseline, per file per rule.
# ---------------------------------------------------------------------------
echo "=== Shell-idiom ratchet: Rule J (jq nullable-.body guard) + Rule S (swallow justification) ==="

# Under `set -uo pipefail` (no `-e`), an unchecked `mktemp`/write failure does
# NOT stop the script: reads of the empty temp path degrade to "no rows", the
# reconciliation loop reads that as "every baseline entry shrank to 0", and the
# checker PASSes without running the ratchet (INV-130). Each allocation/write is
# therefore checked and treated as an exit-2 infra error in both modes — this is
# scratch-space breakage, not a ratchet violation. Keep the `mktemp` guards
# inline (NOT via a command-substitution helper): an `exit 2` inside `$(...)`
# only kills the subshell, leaving the assignment empty and reintroducing the bug.
DISC_TMP="$(mktemp)" || { echo "check-shell-idioms.sh: mktemp failed — cannot allocate scratch file for discovered counts" >&2; exit 2; }
BASE_TMP="$(mktemp)" || { echo "check-shell-idioms.sh: mktemp failed — cannot allocate scratch file for baseline counts" >&2; exit 2; }
ALL_FILES_TMP="$(mktemp)" || { echo "check-shell-idioms.sh: mktemp failed — cannot allocate scratch file for the file-union list" >&2; exit 2; }
trap 'rm -f "$DISC_TMP" "$BASE_TMP" "$ALL_FILES_TMP"' EXIT

discover_counts > "$DISC_TMP" \
  || { echo "check-shell-idioms.sh: failed to write discovered counts to scratch file" >&2; exit 2; }
# `| floor` normalizes the rendered TEXT, not the value: a schema-valid
# integer-valued number in exponent form (e.g. `1e2`) interpolates as "1E+2",
# which would then fail the same `[ -gt ]`/`[ -lt ]` integer comparisons the
# schema check above protects against. `floor` is a no-op on an already-integer
# value but forces jq to print it in plain decimal form.
jq -r 'to_entries[] | "\(.key)\t\((.value.jq_unguarded // 0) | floor)\t\((.value.swallow_unjustified // 0) | floor)"' <<<"$BASELINE_JSON" \
  | LC_ALL=C sort > "$BASE_TMP" \
  || { echo "check-shell-idioms.sh: failed to write baseline counts to scratch file" >&2; exit 2; }

{ cut -f1 "$DISC_TMP"; cut -f1 "$BASE_TMP"; } | LC_ALL=C sort -u > "$ALL_FILES_TMP" \
  || { echo "check-shell-idioms.sh: failed to write the file-union list to scratch file" >&2; exit 2; }

# Column <fld> of the row for file <rel> in a "<file>\t<jq>\t<swallow>" table
# (DISC_TMP/BASE_TMP), defaulting to 0 when the file has no row. Both tables
# omit zero-only files, so an absent row legitimately means count 0.
field_or_zero() {
  local tmp="$1" rel="$2" fld="$3"
  awk -F'\t' -v f="$rel" -v c="$fld" '$1==f{print $c; found=1} END{if(!found)print 0}' "$tmp"
}

any_shrink=0
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  cur_jq=$(field_or_zero "$DISC_TMP" "$rel" 2)
  cur_sw=$(field_or_zero "$DISC_TMP" "$rel" 3)
  base_jq=$(field_or_zero "$BASE_TMP" "$rel" 2)
  base_sw=$(field_or_zero "$BASE_TMP" "$rel" 3)

  if [ "$cur_jq" -gt "$base_jq" ]; then
    while IFS=$'\t' read -r ln content; do
      [ -z "$ln" ] && continue
      fail "Rule J (jq nullable-.body guard) regression at ${rel}:${ln} (baseline=${base_jq}, current=${cur_jq}): '$content'. Add a select(.body | type == \"string\") guard within 15 lines, or route through an existing guarded helper. If this is a legitimate baseline change, regenerate shell-idioms-baseline.json (--write-baseline)."
    done < <(rule_j_unguarded_lines_in "$SCAN_ROOT/$rel")
  elif [ "$cur_jq" -lt "$base_jq" ]; then
    any_shrink=1
    info "notice: $rel Rule J count shrank (baseline=${base_jq}, current=${cur_jq}) — consider regenerating shell-idioms-baseline.json (--write-baseline)"
  fi

  if [ "$cur_sw" -gt "$base_sw" ]; then
    while IFS=$'\t' read -r ln content; do
      [ -z "$ln" ] && continue
      fail "Rule S (swallow justification) regression at ${rel}:${ln} (baseline=${base_sw}, current=${cur_sw}): '$content'. Add a same-line trailing comment or a comment on one of the 3 preceding lines explaining which direction this fails. If this is a legitimate baseline change, regenerate shell-idioms-baseline.json (--write-baseline)."
    done < <(rule_s_unjustified_lines_in "$SCAN_ROOT/$rel")
  elif [ "$cur_sw" -lt "$base_sw" ]; then
    any_shrink=1
    info "notice: $rel Rule S count shrank (baseline=${base_sw}, current=${cur_sw}) — consider regenerating shell-idioms-baseline.json (--write-baseline)"
  fi
done < "$ALL_FILES_TMP"

[ "$FAILED" -eq 0 ] && [ "$any_shrink" -eq 0 ] && info "all files reconcile with the baseline — no growth in unguarded jq .body ops or unjustified swallows"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "shell-idioms-guard: PASS"
  exit 0
else
  echo "shell-idioms-guard: FAIL — see the ::error:: lines above ([INV-130])."
  exit 1
fi
