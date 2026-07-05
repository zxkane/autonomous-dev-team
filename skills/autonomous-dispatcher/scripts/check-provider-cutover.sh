#!/bin/bash
# check-provider-cutover.sh — issue #286, [INV-91] provider-cutover guard.
#
# The final strangler-fig guard for the pluggable-providers refactor (provider-
# spec.md §7/§9): no NEW raw `gh` call may re-enter the provider-neutral caller
# layer (lib-dispatch.sh, autonomous-dev.sh, autonomous-review.sh, every
# lib-review-*.sh) outside scripts/providers/. All host I/O is supposed to route
# through the itp_*/chp_* verbs — including the dispatcher's own marker writers
# post_dispatch_token ([INV-18]) and _dep_block_comment ([INV-39]), which route
# through itp_post_comment (the sole marker choke-point, spec M6).
#
# TREE-WIDE COVERAGE + BASELINE-ANCHORED REGRESSION GUARD (NOT a from-zero ban).
# ---------------------------------------------------------------------------
# AC #41 requires that EVERY surviving raw-gh site in skills/autonomous-dispatcher/
# scripts/ resolve to providers/ OR an allowlisted file — not just the caller
# layer. So the guard scans the WHOLE scripts tree (every *.sh + providers/*.sh)
# and classifies each non-comment raw `gh ` token as exactly one of:
#   (1) under providers/            — the legitimate home of migrated host I/O;
#   (2) an allowlisted FILE         — the auth/transport wrappers (spec §8);
#   (3) a BASELINED surviving site  — frozen in providers/cutover-baseline.json;
#   (4) one of the guard's OWN structurally-exempt infrastructure lines — ONLY in
#       check-provider-cutover.sh, ONLY the ALLOWLISTED_FILES array declaration, the
#       primary matcher line, and the generated _comment template, matched by a
#       top-of-line structural anchor (is_checker_infra_line, #286-amendment #343).
#       These change content whenever the allowlist POLICY changes, so baselining
#       them meant an allowlist disposition self-tripped Check 4 monotonicity. The
#       guard's PASS/FAIL MESSAGE strings are NOT exempt — a NEW raw `gh` added to
#       the checker still FAILs (the guard is NOT wholesale-allowlisted; #286 round 2).
# Anything else is a NEW raw-gh and FAILs LOUD naming the exact file:line (AC #2).
#
# The depends-on issues (#281–#285) migrated ONLY the spec-named verb leaves
# (provider-spec.md §3.1/§3.2). On the current HEAD many raw `gh ` tokens survive
# across the tree (real calls — label flips, `gh issue view/close`, `gh pr
# comment`, `gh api`, dispatcher/util scripts — plus heredoc agent-prompt prose).
# A strict from-zero ban therefore CANNOT pass today. So the surviving sites are
# frozen in the baseline manifest, keyed by (file, trimmed-content) COUNT — the
# same discovered-vs-declared reconciliation check-spec-drift.sh's Check C.4 uses.
# The guard:
#   - PASSES today (baseline = exactly the surviving sites on the migrated HEAD);
#   - FAILs on any NEW raw-gh (content not in the baseline) naming file:line;
#   - FAILs on a DUPLICATE of a baselined line (discovered count > baseline);
#   - FAILs on a REMOVED baselined site (discovered count < baseline) — so a
#     migration PR that deletes a gh leaf is FORCED to shrink the baseline in the
#     same PR. As the remaining sites migrate behind verbs the baseline shrinks to
#     empty and the guard becomes the strict from-zero ban the issue envisioned.
# Keying on CONTENT (not line numbers) makes the baseline robust to line drift;
# keying on COUNT makes it robust to identical-duplicate lines. The file:line in a
# FAILURE message is resolved live (grep) at report time, so it is always accurate
# without baking volatile line numbers into the manifest.
#
# NO wrapper file is edited (Out-of-Scope: "touches NO runtime wrapper logic"; the
# repo is self-hosting — a dirty wrapper crashes the live dispatcher).
#
# CI / dev tool only — NOT sourced by any dispatch-time wrapper, NOT an
# entry-point script symlinked into projects by install-project-hooks.sh. It runs
# in CI through the existing tests/unit/test-*.sh loop (tests/unit/
# test-provider-cutover.sh invokes it against the real repo) — the same
# CI-without-a-dedicated-workflow-step accommodation [INV-83] uses, because a
# scoped App token cannot edit .github/workflows/. Depends only on jq + coreutils
# (grep, sort, uniq, mktemp), so it runs on bare ubuntu-latest with no credentials.
#
# Usage:
#   check-provider-cutover.sh                 Run all checks against the repo.
#   check-provider-cutover.sh --scripts-dir D --baseline F
#                                             Override paths (the unit test points
#                                             these at scratch copies for drift
#                                             injection — mirrors check-spec-drift.sh).
#   check-provider-cutover.sh --generate-baseline [--scripts-dir D]
#                                             Emit a fresh baseline JSON for the
#                                             current tree to stdout (regenerate
#                                             after a migration PR shrinks the set).
#   check-provider-cutover.sh --trusted-ref REF [--trusted-baseline-path P]
#                              [--trusted-scripts-prefix D]
#                                             Check 4 (monotonicity): compare the
#                                             working-tree baseline against the
#                                             trusted copy at git REF (default
#                                             origin/main); FAIL if it GREW. May
#                                             only SHRINK. Skips off-git/missing-ref.
#                                             --trusted-scripts-prefix overrides the
#                                             ref-tree scripts dir (else derived from
#                                             --trusted-baseline-path AFTER parsing).
#   check-provider-cutover.sh --require-trusted-ref
#                                             STRICT mode (fail-closed, AC #6): a
#                                             missing/unreadable/unparseable baseline,
#                                             an unresolvable trusted ref, OR a trusted
#                                             ref lacking cutover-baseline.json each
#                                             EXIT 1 (never exit 0 + "nothing to
#                                             regress against"). No silent derive-from-
#                                             tree fallback here; a baseline is rebuilt
#                                             only via --generate-baseline. Closes the
#                                             shallow-CI + initial-landing holes.
#
# Exit: 0 all checks pass; 1 a drift/integrity failure; 2 usage; 3 env.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

SCRIPTS_DIR="$SCRIPT_DIR"
BASELINE="$SCRIPT_DIR/providers/cutover-baseline.json"
GENERATE=0
# The git ref carrying the TRUSTED (already-merged, already-reviewed) baseline that
# the working-tree baseline is checked against for MONOTONICITY (Check 4). A PR may
# only SHRINK the baseline (migration removes a leaf); it may NEVER grow it — that
# would ratify a NEW raw-gh in the same change that introduces it, the [INV-91]
# bypass the cutover guard exists to prevent. Override for tests/forks.
TRUSTED_REF="${CUTOVER_TRUSTED_REF:-origin/main}"
# Path of the baseline file RELATIVE to the git repo root, used to read the trusted
# copy via `git show <ref>:<path>`. Defaults to the in-repo location; overridable
# so a test can point at a scratch ref. Empty => derive from BASELINE at run time.
TRUSTED_BASELINE_PATH="${CUTOVER_TRUSTED_BASELINE_PATH:-skills/autonomous-dispatcher/scripts/providers/cutover-baseline.json}"
# Git-root-relative path to the scripts dir IN THE TRUSTED TREE -- used to derive the
# trusted survivor set from the ref when its baseline JSON is absent (#286 finding #1).
# DERIVED FROM TRUSTED_BASELINE_PATH *after* arg parsing (see below) unless explicitly
# set here via the env. It MUST track a --trusted-baseline-path override: deriving it
# eagerly from the DEFAULT path (before the arg loop) left it stale when a caller
# overrode --trusted-baseline-path without also exporting CUTOVER_TRUSTED_SCRIPTS_PREFIX
# -- the ref-tree probe then used the wrong prefix and misclassified real growth in an
# existing file as a new-file introduction -> false PASS (#286 review P1#1, 2026-06-28).
TRUSTED_SCRIPTS_PREFIX="${CUTOVER_TRUSTED_SCRIPTS_PREFIX:-}"
# STRICT monotonicity: when set, a Check 4 that cannot resolve the trusted ref
# (no git / shallow checkout / ref absent) is a FAILURE, not a graceful skip. This
# closes the shallow-CI hole (#286 review): the hermetic job runs the guard via the
# test glob under a depth-1 checkout where origin/main is absent, so a permissive
# skip there would let a self-ratifying PR pass green. The unit test drives the
# guard with this ON (after making a trusted ref resolvable), so the monotonicity
# property is enforced regardless of CI checkout depth. Default OFF so a fork PR /
# ad-hoc run without origin/main still works (the test, not the bare run, is the gate).
REQUIRE_TRUSTED_REF="${CUTOVER_REQUIRE_TRUSTED_REF:-0}"

while [ $# -gt 0 ]; do
  case "$1" in
    --scripts-dir)        SCRIPTS_DIR="$2"; shift ;;
    --baseline)           BASELINE="$2"; shift ;;
    --generate-baseline)  GENERATE=1 ;;
    --trusted-ref)        TRUSTED_REF="$2"; shift ;;
    --trusted-baseline-path) TRUSTED_BASELINE_PATH="$2"; shift ;;
    --trusted-scripts-prefix) TRUSTED_SCRIPTS_PREFIX="$2"; shift ;;
    --require-trusted-ref) REQUIRE_TRUSTED_REF=1 ;;
    -h|--help)            sed -n '2,86p' "$0"; exit 0 ;;
    *) echo "check-provider-cutover.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# Derive TRUSTED_SCRIPTS_PREFIX from the FINAL TRUSTED_BASELINE_PATH (dir two levels
# up: .../scripts/providers/cutover-baseline.json -> .../scripts) unless it was set
# explicitly (env CUTOVER_TRUSTED_SCRIPTS_PREFIX or --trusted-scripts-prefix). Doing
# this AFTER the arg loop is the #286 P1#1 fix: it now tracks a --trusted-baseline-path
# override instead of being frozen to the default at init time.
if [ -z "$TRUSTED_SCRIPTS_PREFIX" ]; then
  _tbp_dir="${TRUSTED_BASELINE_PATH%/*}"
  TRUSTED_SCRIPTS_PREFIX="${_tbp_dir%/*}"
  unset _tbp_dir
fi

command -v jq >/dev/null 2>&1 || { echo "check-provider-cutover.sh: jq is required" >&2; exit 3; }

# The provider-neutral caller layer — the files INV-91 is fundamentally about.
# (Used only for the human-facing classification in failure messages; the scan
# itself is TREE-WIDE per AC #41.)
CALLER_FILES=(lib-dispatch.sh autonomous-dev.sh autonomous-review.sh)
# Allowlisted gh-holding files: the auth/refresh wrappers + the remote-SSM
# transport (spec §8: GitHub auth is unchanged; the wrappers are allowlisted,
# not refactored), plus `upload-screenshot.sh` (#344, #296 FINAL batch) — its
# git-Data-API commit path migrated behind chp_commit_file (#330/#335), leaving
# only a `command -v gh` capability-presence guard, not I/O; a single-purpose
# non-caller-layer utility script, so file-level allowlisting is the correct
# disposition (same class as the auth/transport wrappers: a presence check, not
# a call site the provider seam owns). `gh` is the project-side wrapper SYMLINK
# (scripts/gh → gh-with-token-refresh.sh): allowlisted by NAME but
# gitignored/operator-local, so it has no committed file to scan or stat.
#
# NOTE: this guard script itself is NOT allowlisted (#286 review round 2 [P1] #2).
# Wholesale-exempting it meant a real `gh api user` could be added to the checker
# without tripping. Instead the checker IS scanned like any other file: its own
# legitimate `gh `-mentioning lines (the PASS/FAIL messages) are recorded in the
# baseline as ordinary surviving sites, so a NEW raw gh added to the checker is
# unbaselined → FAILs. (Its comment lines are skipped by the detector; the
# baseline'd lines are the few non-comment ones.)
ALLOWLISTED_FILES=(gh gh-with-token-refresh.sh gh-app-token.sh gh-as-user.sh dispatch-remote-aws-ssm.sh upload-screenshot.sh)

# The #286-amendment (#343). The guard's OWN infrastructure lines change content
# whenever the allowlist POLICY changes, so baselining them means an allowlist
# disposition self-trips Check 4 monotonicity — the edited line's (file,content)
# signature changes, so the old signature "no longer found" AND a NEW unbaselined
# signature appears, forcing a hand-edit of the baseline in the same PR (the exact
# self-ratification the guard exists to prevent). So these lines are STRUCTURALLY
# EXEMPT from the scan — but ONLY in check-provider-cutover.sh, and ONLY when the
# line matches a structural ANCHOR (the assignment/matcher/generator shape), NEVER a
# magic comment an arbitrary file could carry (a general escape hatch would invite
# self-allowlisting — TC-CUTOVER-014). The deliberate self-scan of the guard's
# PASS/FAIL MESSAGE strings STAYS: a NEW raw `gh` added to the checker (not matching
# an anchor) is still unbaselined → FAILs LOUD (TC-CUTAMEND-006). Exempt:
#   (a) the ALLOWLISTED_FILES=(…) array declaration  — churns directly on an edit;
#   (b) the guard's own primary matcher line          — the mechanical detector
#       (`grep -aE '(^|[^A-Za-z_-])gh ' …` in gh_lines_in — the ONLY line in this
#        file that mentions `gh ` as part of the detector regex, not a message);
#   (c) the generated baseline `_comment:` template   — embeds the allowlist
#       file-list (see the jq -n block), so an allowlist edit churns it too.
# True iff (rel, trimmed content) is one of check-provider-cutover.sh's own
# structurally-exempt infrastructure lines. rel-scoped to this one file; anchored on
# line SHAPE (the assignment / matcher / generator prefix), not a comment marker.
# The (b) anchor deliberately stops the literal BEFORE the `gh ` token so this arm
# is not itself a scannable raw-gh line (else the exemption would re-introduce the
# very signature it removes); the matcher line is the sole `grep -aE '(^|[^…` line.
CHECKER_SELF="check-provider-cutover.sh"
is_checker_infra_line() {
  local rel="$1" content="$2"
  [ "$rel" = "$CHECKER_SELF" ] || return 1
  case "$content" in
    'ALLOWLISTED_FILES=('*)          return 0 ;;   # (a) allowlist array declaration
    "grep -aE '(^|[^A-Za-z_-])"*)    return 0 ;;   # (b) primary matcher line
    "grep -aE 'curl.*"*)             return 0 ;;   # (d) [#416 R4] /api/v4 curl matcher
    '_comment:'*)                    return 0 ;;   # (c) the generated _comment template
  esac
  return 1
}

# Files that need not exist on disk to be a valid allowlist entry (runtime symlink).
ALLOWLIST_NO_STAT=(gh)

FAILED=0
fail() { echo "::error::$*" >&2; FAILED=1; }
info() { echo "  $*"; }

in_list() { local needle="$1"; shift; local e; for e in "$@"; do [ "$e" = "$needle" ] && return 0; done; return 1; }

# Every *.sh ANYWHERE under the scripts tree, as paths RELATIVE to SCRIPTS_DIR
# ("autonomous-dev.sh", "adapters/codex.sh", "providers/itp-github.sh", and any
# future nested subdir). RECURSIVE (find), so a raw gh under adapters/ or any new
# subdirectory is discovered — a top-level + providers/-only glob silently missed
# them (#286 review round 2 [P1] #1). NUL-delimited to survive odd names; emits a
# leading "./" that we strip so the relative path matches the allowlist/baseline.
tree_sh_files() {
  [ -d "$SCRIPTS_DIR" ] || return 0
  # `find -L` FOLLOWS symlinks: several tracked scripts (mark-issue-checkbox.sh,
  # reply-to-comments.sh, upload-screenshot.sh, gh-as-user.sh) are committed as
  # symlinks into sibling skill dirs but still live in skills/autonomous-dispatcher/
  # scripts/ and carry raw gh — a plain `find -type f` (no -L) would SKIP them
  # (a symlink is not -type f) and silently drop their gh sites from the scan. The
  # printed path is the symlink's own relative path (its basename), which is the
  # baseline/allowlist key. No symlink target here points back inside SCRIPTS_DIR,
  # so -L introduces no cycle.
  ( cd "$SCRIPTS_DIR" && find -L . -type f -name '*.sh' -print ) 2>/dev/null \
    | sed 's#^\./##' | LC_ALL=C sort
}

# Resolve the caller-layer file list (literals + lib-review-*.sh glob), bare
# basenames. (Classification helper only.)
caller_layer_files() {
  local f
  for f in "${CALLER_FILES[@]}"; do [ -f "$SCRIPTS_DIR/$f" ] && printf '%s\n' "$f"; done
  for f in "$SCRIPTS_DIR"/lib-review-*.sh; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done
}
is_caller_layer() {
  local rel="$1" c
  while IFS= read -r c; do [ "$c" = "$rel" ] && return 0; done < <(caller_layer_files)
  return 1
}

# The raw-gh detector, applied to ONE file. Emits the trimmed content of each
# non-comment line carrying a raw `gh ` token, one per line.
#   - RE2-safe CONSUMING boundary `(^|[^A-Za-z_-])gh ` — never a look-behind/
#     look-ahead, so it survives both grep and any `gh --jq` RE2 context
#     (memory project_gh_jq_re2_no_lookbehind). A bare `gh ` after start-of-line
#     or any non-[A-Za-z_-] char matches; `agh `/`_gh `/`-gh `/`high ` do NOT.
#   - skips comment lines (first non-space char `#`) — a prose mention in a
#     comment is not a call site (symmetric with check-spec-drift.sh).
gh_lines_in() {
  local path="$1"
  [ -f "$path" ] || return 0
  # -a (treat input as text): a script carrying UTF-8 punctuation (em-dashes in
  # comments, etc.) can be misclassified "binary data" by grep under some locales,
  # which then SILENTLY suppresses all matches → a real raw-gh site would slip past
  # the scan. -a forces text mode so the detector is content/locale-independent.
  grep -aE '(^|[^A-Za-z_-])gh ' "$path" 2>/dev/null | awk '
    { s = $0; sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      if (substr(s, 1, 1) == "#") next
      print s }'
}

# [#416 R4] The raw-glab detector — parallel to gh_lines_in, using the same
# RE2-safe consuming boundary `(^|[^A-Za-z_-])glab ` so `_glab `/`slab
# `/`glabber ` etc. do NOT match. Emits the trimmed content of each non-comment
# line carrying a raw `glab ` token, one per line. Applied to ONE file.
glab_lines_in() {
  local path="$1"
  [ -f "$path" ] || return 0
  grep -aE '(^|[^A-Za-z_-])glab[[:space:]]' "$path" 2>/dev/null | awk '
    { s = $0; sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      if (substr(s, 1, 1) == "#") next
      print s }'
}

# [#416 R4] The `/api/v4` curl detector — a `curl ...` line whose argv
# mentions `/api/v4` (`grep -E 'curl.*[/"]api/v4[/"]'`).
#
# BOUND — SAME-LINE-ONLY, DOCUMENTED HONESTLY (codex round-1 [P2-6]):
# this same-line matcher MISSES a two-line split like
#   url="https://gitlab.example/api/v4/projects/1/issues"
#   curl -sS -H "PRIVATE-TOKEN: $tok" "$url"
# where the URL is stored in a variable on one line and `curl "$url"`
# fires on another. The review gate is the intended second line of
# defense — a reviewer eyeballs a NEW curl invocation and its context.
# `gitlab_api_var_and_curl_lines_in` below adds a best-effort file-level
# detector for the "same VAR name in both places" subset of that shape.
# Indirect flows (function args, env-var derivation, arithmetic pieces
# of the URL) remain bypassable and belong to the review gate.
#
# Shape-exclusion of gh-app-token sites is automatic — those curl argvs
# mention `api.github.com/…`, not `/api/v4/…`, so this detector does
# not match them (no allowlist entry needed for gh-app-token.sh).
gitlab_api_curl_lines_in() {
  local path="$1"
  [ -f "$path" ] || return 0
  grep -aE '(^|[^A-Za-z_-])curl([[:space:]]|$).*[/"]api/v4[/"]|[/"]api/v4[/"].*(^|[^A-Za-z_-])curl([[:space:]]|$)' "$path" 2>/dev/null | awk '
    { s = $0; sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      if (substr(s, 1, 1) == "#") next
      print s }'
}

# [#416 P2-6] Split-across-lines detector (best-effort, file-level).
# Fires when the SAME file:
#   (a) assigns a variable to a string containing `/api/v4/`
#         — line matches `<VAR>=<value-with-/api/v4/>` (with an optional
#           leading `local `/`export `/`declare `/`readonly `),
#   AND
#   (b) invokes `curl` on `"$<VAR>"`, `${<VAR>}`, or `$<VAR>` on a
#       DIFFERENT line.
# Only "same variable NAME literally appears in both places" is required
# — indirect flows (function args, derived URLs) are NOT covered; this
# is the documented bound. Emits the CURL LINE (the actual leak site)
# not the assignment, so failure messages name the right file:line.
gitlab_api_var_and_curl_lines_in() {
  local path="$1"
  [ -f "$path" ] || return 0
  local var_names
  # Allow leading whitespace (indented assignments inside functions), an
  # optional `local`/`export`/`declare`/`readonly ` prefix, and finally the
  # VAR=<value-with-/api/v4/> shape.
  var_names=$(grep -aE '^[[:space:]]*(local |export |declare |readonly )?[A-Za-z_][A-Za-z0-9_]*=.*/api/v4/' "$path" 2>/dev/null \
    | sed -E 's/^[[:space:]]*(local |export |declare |readonly )?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/' \
    | sort -u)
  [ -z "$var_names" ] && return 0
  local var line s
  while IFS= read -r var; do
    [ -z "$var" ] && continue
    # For each var name, grep lines with `curl` + `$VAR` (via a
    # dynamically-built regex that boundary-anchors the var name so
    # `foo` doesn't match `foobar`). Skip lines that ALSO carry the
    # `/api/v4/` literal (same-line case, already handled).
    local pattern="(^|[^A-Za-z_-])curl[[:space:]].*\\\$\\{?${var}\\}?([^A-Za-z_0-9]|$)"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      s="$line"
      s="${s#"${s%%[![:space:]]*}"}"
      s="${s%"${s##*[![:space:]]}"}"
      [ "${s:0:1}" = "#" ] && continue
      # Skip the same-line case (already covered above).
      case "$s" in
        *"/api/v4/"*) continue ;;
      esac
      printf '%s\n' "$s"
    done < <(grep -aE "$pattern" "$path" 2>/dev/null)
  done <<< "$var_names"
}

# gh_lines_in for a SCRIPTS_DIR-relative file, additionally dropping
# check-provider-cutover.sh's OWN structurally-exempt infrastructure lines
# (#286-amendment, #343 — is_checker_infra_line). Used by BOTH the working-tree scan
# (discover_guarded_sites) and the ref-tree scan (discover_guarded_sites_at_ref), so
# the exemption is applied identically on the check path and --generate-baseline.
guarded_gh_lines_in() {
  local rel="$1" path="$2" line
  gh_lines_in "$path" | while IFS= read -r line; do
    is_checker_infra_line "$rel" "$line" && continue
    printf '%s\n' "$line"
  done
}

# [#416 R4] glab_lines_in for a SCRIPTS_DIR-relative file, with the same
# is_checker_infra_line exemption applied.
guarded_glab_lines_in() {
  local rel="$1" path="$2" line
  glab_lines_in "$path" | while IFS= read -r line; do
    is_checker_infra_line "$rel" "$line" && continue
    printf '%s\n' "$line"
  done
}

# [#416 R4] gitlab_api_curl_lines_in for a SCRIPTS_DIR-relative file, with
# the same is_checker_infra_line exemption applied.
guarded_gitlab_api_curl_lines_in() {
  local rel="$1" path="$2" line
  gitlab_api_curl_lines_in "$path" | while IFS= read -r line; do
    is_checker_infra_line "$rel" "$line" && continue
    printf '%s\n' "$line"
  done
}

# [#416 P2-6] gitlab_api_var_and_curl_lines_in for a SCRIPTS_DIR-relative
# file, with the same is_checker_infra_line exemption applied.
guarded_gitlab_api_var_and_curl_lines_in() {
  local rel="$1" path="$2" line
  gitlab_api_var_and_curl_lines_in "$path" | while IFS= read -r line; do
    is_checker_infra_line "$rel" "$line" && continue
    printf '%s\n' "$line"
  done
}

# Discover raw-gh sites across the WHOLE tree, EXCLUDING providers/ and the
# allowlisted files. These are the sites the baseline must account for. Emits
# "<count>\t<file>\t<content>" rows grouped by trimmed content.
discover_guarded_sites() {
  local rel
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    case "$rel" in providers/*) continue ;; esac        # providers/ is the migration target
    in_list "$rel" "${ALLOWLISTED_FILES[@]}" && continue # allowlisted file
    guarded_gh_lines_in "$rel" "$SCRIPTS_DIR/$rel" | sed "s#^#${rel}\t#"
  done < <(tree_sh_files) | LC_ALL=C sort | uniq -c | awk '{
    # `uniq -c` prefixes "<spaces><count> <file>\t<content>". Pull the leading
    # count off WITHOUT rebuilding $0 (which would collapse the file\tcontent tab
    # to a space). The rest (from the first tab onward) is preserved verbatim.
    line = $0
    sub(/^[[:space:]]+/, "", line)
    count = line; sub(/[[:space:]].*$/, "", count)
    rest = line; sub(/^[0-9]+[[:space:]]+/, "", rest)
    print count "\t" rest
  }'
}

# Does a SCRIPTS_DIR-relative path exist (as a file OR symlink) in the trusted ref?
ref_has_file() { git ls-tree "${1}" -- "${TRUSTED_SCRIPTS_PREFIX}/${2}" 2>/dev/null | grep -q .; }

# Read a tree path from a ref, dereferencing one level of git symlink (mode 120000):
# git show of a symlink entry yields the LINK TARGET text, not content, so symlinked
# tracked scripts (mark-issue-checkbox.sh -> ../../autonomous-common/...) would
# undercount. Resolve the target relative to the entry dir and show THAT. (find -L
# does the equivalent for the working tree; this is the ref-tree analogue.)
git_show_deref() {
  local ref="$1" path="$2" mode tgt dir
  mode="$(git ls-tree "$ref" -- "$path" 2>/dev/null | awk '{print $1}')"
  if [ "$mode" = "120000" ]; then
    tgt="$(git show "${ref}:${path}" 2>/dev/null)"
    dir="${path%/*}"
    # normalize dir/tgt (handles ../) via a subshell pwd against a virtual root.
    path="$(cd / && p="${dir}/${tgt}"; printf '%s' "$(realpath -m --relative-to=/ "/$p" 2>/dev/null || echo "$p")")"
  fi
  git show "${ref}:${path}" 2>/dev/null
}

# Discover raw-gh sites in the TRUSTED TREE at a git ref (NOT the working tree),
# emitting "<count>\t<file>\t<content>" rows. Mirrors discover_guarded_sites but
# reads each file via git_show_deref. Used by Check 4 to derive the trusted survivor
# set when the trusted baseline JSON is absent at the ref (#286 review finding #1).
discover_guarded_sites_at_ref() {
  local ref="$1" relroot="${2:-$TRUSTED_SCRIPTS_PREFIX}" rel sub gtmp
  gtmp="$(mktemp)"
  while IFS= read -r sub; do
    [ -z "$sub" ] && continue
    rel="${sub#"$relroot"/}"
    case "$rel" in providers/*) continue ;; esac
    in_list "$rel" "${ALLOWLISTED_FILES[@]}" && continue
    git_show_deref "$ref" "$sub" >"$gtmp" 2>/dev/null || continue
    guarded_gh_lines_in "$rel" "$gtmp" | sed "s#^#${rel}\t#"
  done < <(git ls-tree -r --name-only "$ref" -- "$relroot" 2>/dev/null | grep -E '\.sh$') \
    | LC_ALL=C sort | uniq -c | awk '{
      line = $0
      sub(/^[[:space:]]+/, "", line)
      count = line; sub(/[[:space:]].*$/, "", count)
      rest = line; sub(/^[0-9]+[[:space:]]+/, "", rest)
      print count "\t" rest
    }'
  rm -f "$gtmp"
}

# Resolve the concrete file:line(s) of a (file, trimmed-content) site for the
# failure message (AC #2). grep -nF the exact content; emit "file:line" per hit.
# The content was trimmed, so grep the trimmed form with -F (fixed string) — it
# still matches the indented source line as a substring.
sites_file_lines() {
  local rel="$1" content="$2" path="$SCRIPTS_DIR/$1" n
  [ -f "$path" ] || { printf '%s:?' "$rel"; return; }
  while IFS=: read -r n _; do
    [ -n "$n" ] && printf '%s:%s ' "$rel" "$n"
  done < <(grep -anF -- "$content" "$path" 2>/dev/null)
}

# ---------------------------------------------------------------------------
# --generate-baseline — emit a fresh baseline JSON for the current tree.
# ---------------------------------------------------------------------------
if [ "$GENERATE" -eq 1 ]; then
  sites_json="$(discover_guarded_sites | jq -R -s '
    [ split("\n")[] | select(length > 0) | split("\t")
      | { count: (.[0] | tonumber), file: .[1], content: (.[2:] | join("\t")) } ]
    | sort_by(.file, .content)
  ')"
  # The file-allowlist is intentionally NOT emitted here — it is authoritative
  # ONLY in check-provider-cutover.sh's ALLOWLISTED_FILES array, so a data-file
  # edit cannot silently widen the guarded surface. This manifest carries ONLY
  # the surviving-site freeze.
  #
  # #286-amendment (#343): the _comment template no longer EMBEDS the allowlist
  # file-list — an allowlist-policy edit used to churn this _comment signature too
  # (it appeared in the baseline as a survivor). The template is also structurally
  # exempt from the scan now (is_checker_infra_line, anchor `_comment:`), so this
  # string is neither scanned nor baselined; keeping the file-list out of it keeps
  # the single source of truth in ALLOWLISTED_FILES and prevents future churn.
  jq -n --argjson sites "$sites_json" \
    '{
      _comment: "Baseline of raw-gh sites surviving across the dispatcher scripts tree (RECURSIVE; EXCLUDING providers/ and the allowlisted files) after the partial pluggable-providers migration (#281-#285). check-provider-cutover.sh ([INV-91]) FAILs any tree raw-gh NOT under providers/, NOT an allowlisted file, and NOT accounted for here — naming the exact file:line. The checker script itself is scanned (not allowlisted), so its own PASS/FAIL message strings appear here as ordinary survivors; its infrastructure lines (the ALLOWLISTED_FILES array declaration, the primary matcher line, and this _comment template) are structurally exempt (#286-amendment #343) so an allowlist-policy edit does not self-trip Check 4 monotonicity. Regenerate with: bash check-provider-cutover.sh --generate-baseline. Migration PRs that remove a gh leaf MUST shrink this manifest in the same PR; the guard becomes a strict from-zero ban once this is empty. The file-allowlist lives in check-provider-cutover.sh (ALLOWLISTED_FILES), not here.",
      surviving_sites: $sites
    }'
  exit 0
fi

# ---------------------------------------------------------------------------
# Env / file prerequisites.
# ---------------------------------------------------------------------------
# AC #6 (review P1#1) -- a missing/unreadable/unparseable working-tree baseline is
# FAIL-CLOSED under strict mode (exit 1), never a silent pass. Without strict it is
# an env error (exit 3) -- a bare lint with no baseline file is a setup mistake, not
# a ratchet regression. Either way a baseline is (re)generated ONLY via the explicit
# --generate-baseline maintainer flag, never silently here.
if [ ! -f "$BASELINE" ]; then
  if [ "$REQUIRE_TRUSTED_REF" = "1" ]; then
    fail "strict mode: baseline not found at '$BASELINE' (a missing baseline FAILs closed under --require-trusted-ref; regenerate it with --generate-baseline as a maintainer, never silently)."
    echo "cutover-guard: FAIL"; exit 1
  fi
  echo "check-provider-cutover.sh: baseline not found: $BASELINE" >&2; exit 3
fi
jq -e . "$BASELINE" >/dev/null 2>&1 || { fail "baseline is not valid JSON / unreadable: $BASELINE (fail-closed; --generate-baseline to rebuild as a maintainer)"; echo "cutover-guard: FAIL"; exit 1; }

PROVIDERS_DIR="$SCRIPTS_DIR/providers"

# ---------------------------------------------------------------------------
# Check 1 — tree-wide raw-gh reconciles with the baseline (every non-providers,
# non-allowlisted gh site is a known surviving site). Names file:line on drift.
# ---------------------------------------------------------------------------
echo "=== Check 1: tree-wide raw-gh reconciles with the cutover baseline (providers/ + allowlist excluded) ==="

DISC_TMP="$(mktemp)"; BASE_TMP="$(mktemp)"
trap 'rm -f "$DISC_TMP" "$BASE_TMP"' EXIT

# Discovered "<count>\t<file>\t<content>" → "<file>\t<content>\t<count>". Build
# field-by-field with an explicit tab (do NOT blank $1 + reprint $0 — that
# collapses the tab); content may itself contain tabs, so rejoin $3..NF.
# LC_ALL=C on BOTH sorts so their collation matches the LC_ALL=C comm below — a
# bare `sort` inherits the ambient locale and comm (run under C) would then see
# its inputs as "not sorted" and emit phantom records (false PASS/FAIL under
# e.g. en_US.UTF-8 CI).
discover_guarded_sites | awk -F'\t' '{
  c = $1; f = $2; content = $3
  for (i = 4; i <= NF; i++) content = content "\t" $i
  print f "\t" content "\t" c
}' | LC_ALL=C sort > "$DISC_TMP"
jq -r '.surviving_sites[] | "\(.file)\t\(.content)\t\(.count)"' "$BASELINE" | LC_ALL=C sort > "$BASE_TMP"

# Reconcile the two sorted 3-field tables with `comm`. DISC-only = NEW site or
# count BUMP; BASE-only = REMOVED site or count DROP. The full 3-field record is
# the key, so a count change makes BOTH records differ — caught in one pass.
# `comm` is byte-exact (no regex, no `awk -v` C-escape mangling of the gh
# content's backslashes/`$`/quotes; memory project_inv73_malformed_detector_self_ref).
disc_only="$(LC_ALL=C comm -23 "$DISC_TMP" "$BASE_TMP")"
base_only="$(LC_ALL=C comm -13 "$DISC_TMP" "$BASE_TMP")"

if [ -n "$disc_only" ]; then
  while IFS=$'\t' read -r dfile dcontent dcount; do
    [ -z "$dfile" ] && continue
    layer="dispatcher scripts tree"
    is_caller_layer "$dfile" && layer="provider-neutral caller layer"
    locs="$(sites_file_lines "$dfile" "$dcontent")"
    fail "NEW/unbaselined raw-gh (${layer}) at ${locs:-$dfile:?}(×$dcount): '$dcontent'. Route this host I/O through an itp_*/chp_* verb (a raw gh outside providers/ is an [INV-91] cutover regression). If it is a legitimate surviving site (or a count change), regenerate providers/cutover-baseline.json (--generate-baseline)."
  done <<< "$disc_only"
fi
if [ -n "$base_only" ]; then
  while IFS=$'\t' read -r bfile bcontent bcount; do
    [ -z "$bfile" ] && continue
    fail "baseline declares a raw-gh site the scanner no longer finds at this count — $bfile (×$bcount): '$bcontent'. A gh leaf was removed/changed (good — a migration landed). Shrink providers/cutover-baseline.json to match (--generate-baseline)."
  done <<< "$base_only"
fi

[ "$FAILED" -eq 0 ] && info "all tree raw-gh sites resolve to providers/, an allowlisted file, or a baselined survivor ($(wc -l < "$BASE_TMP" | tr -d ' ') distinct signatures, $(jq '[.surviving_sites[].count] | add // 0' "$BASELINE") occurrences)"

# ---------------------------------------------------------------------------
# Check 2 — provider files exist + are the migration target.
# ---------------------------------------------------------------------------
echo "=== Check 2: provider leaf files exist ==="
for pf in itp-github.sh chp-github.sh; do
  if [ -f "$PROVIDERS_DIR/$pf" ]; then
    info "providers/$pf present"
  else
    fail "providers/$pf is MISSING — the GitHub provider leaf file must exist (the cutover target; created by the depends-on migration issues)"
  fi
done

# ---------------------------------------------------------------------------
# Check 3 — allowlist + baseline integrity.
# ---------------------------------------------------------------------------
# Every allowlisted file must still exist (a stale allowlist entry FAILs loud,
# except the gitignored runtime-symlink names); every file named in the baseline
# must still exist (a stale baseline entry FAILs).
echo "=== Check 3: allowlist + baseline integrity ==="
for af in "${ALLOWLISTED_FILES[@]}"; do
  if in_list "$af" "${ALLOWLIST_NO_STAT[@]}"; then
    info "allowlisted: $af (runtime wrapper symlink — gitignored, target gh-with-token-refresh.sh checked separately)"
    continue
  fi
  if [ -e "$SCRIPTS_DIR/$af" ]; then
    info "allowlisted file present: $af"
  else
    fail "allowlisted file '$af' no longer exists in $SCRIPTS_DIR — drop the stale allowlist entry (a stale allowlist silently shrinks the guarded surface)."
  fi
done

while IFS= read -r bfile; do
  [ -z "$bfile" ] && continue
  [ -f "$SCRIPTS_DIR/$bfile" ] || fail "baseline references file '$bfile' which no longer exists in $SCRIPTS_DIR — drop the stale baseline entry (--generate-baseline)."
done < <(jq -r '.surviving_sites[].file' "$BASELINE" | sort -u)

# ---------------------------------------------------------------------------
# Check 4 — baseline MONOTONICITY vs the trusted (merged) ref. Closes the
# same-PR self-ratification bypass: Check 1 only proves the tree matches WHATEVER
# baseline ships in the same change, so a PR that BOTH adds a raw-gh AND regenerates
# the baseline passes Check 1 (#286 review: `gh issue view 123` + --generate-baseline
# → exit 0). This check compares the working-tree baseline against the trusted copy
# at $TRUSTED_REF and FAILs if the PR's baseline GREW — a new signature, or a higher
# count for an existing one. SHRINKING (a migration removed a leaf) is allowed.
# The baseline may only ever get smaller; ratifying a new site is rejected here even
# though Check 1 was satisfied by the regenerated manifest.
# ---------------------------------------------------------------------------
echo "=== Check 4: baseline monotonicity vs trusted ref ($TRUSTED_REF) — a PR may only SHRINK the baseline ==="
# When --require-trusted-ref / CUTOVER_REQUIRE_TRUSTED_REF is set, an unresolvable
# trusted ref is a FAILURE (the shallow-CI hole, #286 review): a permissive skip in
# the depth-1 hermetic job would let a self-ratifying PR pass green. Default OFF →
# graceful skip so a fork / no-origin/main run still works; the unit test runs the
# guard with it ON after making a trusted ref resolvable.
_no_trusted_ref() {  # $1 = human reason
  if [ "$REQUIRE_TRUSTED_REF" = "1" ]; then
    fail "monotonicity check REQUIRED but $1. With --require-trusted-ref a missing trusted baseline is a failure, not a skip — otherwise a shallow CI checkout (no origin/main) lets a PR add a raw-gh + regenerate the baseline and still pass (#286). Deepen the checkout (fetch-depth: 0) or fetch '$TRUSTED_REF', or run without --require-trusted-ref."
  else
    info "$1 — skipping monotonicity check (Check 1 still anchors the tree to the in-repo baseline; run with --require-trusted-ref to make this a hard failure)"
  fi
}
if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
  _no_trusted_ref "not a git work tree (or git absent)"
elif ! git rev-parse --verify --quiet "$TRUSTED_REF" >/dev/null 2>&1; then
  _no_trusted_ref "trusted ref '$TRUSTED_REF' not resolvable here (shallow/forked checkout)"
else
  # TRUSTED SURVIVOR TABLE "<file>\t<content>\t<count>" from: (1) the trusted
  # baseline JSON at the ref (steady state, once it has landed on main); else (2)
  # DERIVED from the trusted TREE (the initial-landing PR -- main has the scripts but
  # not the baseline JSON yet; #286 finding #1). Deriving from the tree stops a PR
  # self-ratifying a new raw-gh in an EXISTING script.
  TRUSTED_SET="$(mktemp)"; TRUSTED_RAW="$(mktemp)"
  _trusted_src=""; _derived_from_tree=0
  if git show "${TRUSTED_REF}:${TRUSTED_BASELINE_PATH}" >"$TRUSTED_RAW" 2>/dev/null && jq -e . "$TRUSTED_RAW" >/dev/null 2>&1; then
    jq -r '.surviving_sites[]? | "\(.file)\t\(.content)\t\(.count)"' "$TRUSTED_RAW" 2>/dev/null | LC_ALL=C sort > "$TRUSTED_SET"
    _trusted_src="trusted baseline at ${TRUSTED_REF}:${TRUSTED_BASELINE_PATH}"
  elif [ "$REQUIRE_TRUSTED_REF" = "1" ]; then
    # AC #6 (review P1#1) -- STRICT mode FAILs CLOSED when the trusted ref resolves
    # but carries no readable/parseable cutover-baseline.json. We do NOT fall back to
    # deriving from the tree here: strict mode demands a committed trusted baseline to
    # ratchet against, and a baseline is (re)generated only under the explicit
    # --generate-baseline maintainer flag, never silently during a normal lint. (The
    # non-strict default below still derives-from-tree as a best-effort belt.)
    fail "strict monotonicity: trusted ref '$TRUSTED_REF' has no readable cutover-baseline.json at '${TRUSTED_BASELINE_PATH}'. With --require-trusted-ref a missing/unreadable trusted baseline is a hard FAILURE (never 'nothing to regress against' + exit 0) -- otherwise the initial-landing PR could self-ratify. Land the baseline on '$TRUSTED_REF' first, or run without --require-trusted-ref."
    rm -f "$TRUSTED_SET" "$TRUSTED_RAW"
    _trusted_src=""
  else
    discover_guarded_sites_at_ref "$TRUSTED_REF" | awk -F'\t' '{
      c=$1; f=$2; content=$3; for(i=4;i<=NF;i++) content=content "\t" $i; print f "\t" content "\t" c
    }' | LC_ALL=C sort > "$TRUSTED_SET"
    _trusted_src="trusted TREE ${TRUSTED_REF}:${TRUSTED_SCRIPTS_PREFIX}/ (no baseline JSON there -- derived from the tree, non-strict best-effort)"
    _derived_from_tree=1
  fi
  grew="$(awk -F'\t' '
    NR==FNR { old[$1 FS $2]=$3; next }
    { k=$1 FS $2; oc=(k in old)?old[k]:0; if (($3+0) > (oc+0)) print $1 "\t" $2 "\t" $3 "\t" oc }
  ' "$TRUSTED_SET" <(jq -r '.surviving_sites[]? | "\(.file)\t\(.content)\t\(.count)"' "$BASELINE" 2>/dev/null) 2>/dev/null)"
  _grew_real=0
  if [ -n "$grew" ]; then
    while IFS=$'\t' read -r gfile gcontent gcount goldcount; do
      [ -z "$gfile" ] && continue
      # Derived-from-tree: a growth in a file ABSENT from the trusted ref is this PR
      # legitimately introducing a NEW file (e.g. the guard itself) -- gated by Check 1,
      # not a caller-layer regression. Only growth in a file PRESENT on the ref is a
      # self-ratified new raw-gh in existing code -> FAIL.
      if [ "$_derived_from_tree" = "1" ] && ! ref_has_file "$TRUSTED_REF" "$gfile"; then
        info "baseline adds raw-gh in NEW file '$gfile' (absent from $TRUSTED_REF) -- allowed introduction, gated by Check 1; not a monotonicity regression"
        continue
      fi
      _grew_real=1
      fail "baseline GREW vs $_trusted_src -- $gfile raw-gh '$gcontent' count $goldcount->$gcount. This ratifies a NEW raw-gh site in an existing script in the same change that adds it (the [INV-91] self-ratification bypass). Route the new host I/O through an itp_*/chp_* verb instead of baselining it; the baseline may only shrink as migrations land."
    done <<< "$grew"
  fi
  [ "$_grew_real" = "0" ] && info "baseline did not grow vs $_trusted_src for any file present on the trusted ref -- no new raw-gh ratified in existing code"
  rm -f "$TRUSTED_SET" "$TRUSTED_RAW"
fi

# ---------------------------------------------------------------------------
# [#416 R4] Check 5 — GitLab host-API token class. Two matchers, both
# strict-from-zero on the gitlab axis (no baseline entries — there is no
# legacy gitlab code to grandfather):
#   (a) raw `glab ` outside providers/ and the allowlist = FAIL.
#   (b) `curl` mentioning `/api/v4` outside providers/lib-gitlab-transport.sh
#       and the allowlist = FAIL. Shape-exclusion: the 5 gh-app-token.sh
#       curl sites hit `api.github.com/…`, not `/api/v4/…`, so they don't
#       match — no allowlist entry needed for gh-app-token.sh.
# The guard's OWN matcher literal lines are exempted by is_checker_infra_line
# (`grep -aE 'curl.*` anchor added above).
# ---------------------------------------------------------------------------
echo "=== Check 5: no raw \`glab\` outside providers/ (#416 R4, GitLab host-API token class) ==="
GITLAB_TRANSPORT_ALLOWLIST=(lib-gitlab-transport.sh)
_glab_hits=0
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  case "$rel" in providers/*) continue ;; esac
  in_list "$rel" "${ALLOWLISTED_FILES[@]}" && continue
  # Also skip files in the GitLab-transport-allowlist (curl-in-lib is the
  # legitimate home; enforced by the /api/v4 matcher exemption below).
  in_list "$rel" "${GITLAB_TRANSPORT_ALLOWLIST[@]}" && continue
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _glab_hits=$((_glab_hits + 1))
    locs="$(sites_file_lines "$rel" "$line")"
    fail "raw \`glab\` token outside providers/ at ${locs:-$rel:?}: '$line'. Route this host I/O through a chp_*/itp_* verb (a raw \`glab\` is an [INV-91] cutover regression on the GitLab axis)."
  done < <(guarded_glab_lines_in "$rel" "$SCRIPTS_DIR/$rel")
done < <(tree_sh_files)
[ "$_glab_hits" -eq 0 ] && info "no raw \`glab\` token found outside providers/"

echo "=== Check 6: no '/api/v4' curl outside providers/lib-gitlab-transport.sh (#416 R4) ==="
# Two matchers, both applied to every non-allowlisted tree file:
#   (a) same-line `curl … /api/v4/…`  — gitlab_api_curl_lines_in
#   (b) split-across-lines `VAR=…/api/v4/…` + `curl "$VAR"` on a
#       different line  — gitlab_api_var_and_curl_lines_in (P2-6).
# (b) is documented BOUND: file-level; matches only "same VAR name in
# both places"; indirect flows still bypass (review-gate territory).
#
# [#421] providers/prompts-gitlab.sh additionally excluded: its `curl
# .../api/v4/...` lines are AGENT-FACING PROSE (printf template strings
# inside _PP_GITLAB_FRAGMENT, each explicitly labeled "reference, not a
# requirement") — never executed by the wrapper. This detector targets
# EXECUTABLE curl invocations that bypass _gl_api's pagination/backoff/
# fail-closed choke-point (#416 R1); a string literal an agent may or may
# not choose to run is not that.
_v4_hits=0
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  case "$rel" in
    providers/lib-gitlab-transport.sh|providers/prompts-gitlab.sh) continue ;;
  esac
  in_list "$rel" "${ALLOWLISTED_FILES[@]}" && continue
  # (a) same-line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _v4_hits=$((_v4_hits + 1))
    locs="$(sites_file_lines "$rel" "$line")"
    fail "raw '/api/v4' curl outside providers/lib-gitlab-transport.sh at ${locs:-$rel:?}: '$line'. Route this GitLab API call through _gl_api (a raw /api/v4 curl bypasses the pagination/backoff/fail-closed choke-point; #416 R1)."
  done < <(guarded_gitlab_api_curl_lines_in "$rel" "$SCRIPTS_DIR/$rel")
  # (b) split-across-lines (P2-6)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    _v4_hits=$((_v4_hits + 1))
    locs="$(sites_file_lines "$rel" "$line")"
    fail "split-across-lines \`/api/v4\` invocation outside providers/lib-gitlab-transport.sh at ${locs:-$rel:?}: '$line' (file also assigns a var containing the GitLab API path). Route through _gl_api; the pre-P2-6 same-line-only matcher would have MISSED this shape (#416 P2-6)."
  done < <(guarded_gitlab_api_var_and_curl_lines_in "$rel" "$SCRIPTS_DIR/$rel")
done < <(tree_sh_files)
[ "$_v4_hits" -eq 0 ] && info "no '/api/v4' curl (same-line or split-across-lines) found outside providers/lib-gitlab-transport.sh"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "cutover-guard: PASS — no new raw gh across the dispatcher scripts tree; the migration surface is unchanged."
  exit 0
else
  echo "cutover-guard: FAIL — see the ::error:: lines above ([INV-91])."
  exit 1
fi
