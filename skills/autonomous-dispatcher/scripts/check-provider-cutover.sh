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
# BASELINE-ANCHORED REGRESSION GUARD (NOT a from-zero ban).
# ---------------------------------------------------------------------------
# The depends-on issues (#281–#285) migrated ONLY the spec-named verb leaves
# (provider-spec.md §3.1/§3.2). On the current HEAD the caller layer STILL holds
# ~70 raw `gh ` tokens (real calls — label flips, `gh issue view/close`,
# `gh pr comment`, `gh api` — plus heredoc agent-prompt prose mentioning `gh`).
# A strict from-zero ban therefore CANNOT pass today. So this guard instead
# reconciles the discovered raw-gh surface against a DECLARATIVE baseline
# manifest (providers/cutover-baseline.json), keyed by (file, trimmed-content)
# COUNT — the same discovered-vs-declared reconciliation check-spec-drift.sh's
# Check C.4 uses. It:
#   - PASSES today (baseline = exactly the surviving sites on the migrated HEAD);
#   - FAILs on any NEW raw-gh (content not in the baseline);
#   - FAILs on a DUPLICATE of a baselined line (discovered count > baseline);
#   - FAILs on a REMOVED baselined site (discovered count < baseline) — so a
#     migration PR that deletes a caller-side gh leaf is FORCED to shrink the
#     baseline in the same PR. As the remaining sites migrate behind verbs the
#     baseline shrinks to empty and the guard becomes the strict from-zero ban
#     the issue envisioned.
# Keying on CONTENT (not line numbers) makes the baseline robust to line drift;
# keying on COUNT makes it robust to identical-duplicate lines.
#
# This is the AC-#41 reading: "every SURVIVING raw-gh site … resolves to either
# providers/ OR an allowlisted [construct]" — the surviving caller-layer sites
# are the allowlisted construct, recorded in the baseline manifest. NO wrapper
# file is edited (Out-of-Scope: "touches NO runtime wrapper logic"; the repo is
# self-hosting — a dirty wrapper crashes the live dispatcher).
#
# CI / dev tool only — NOT sourced by any dispatch-time wrapper, NOT an
# entry-point script symlinked into projects by install-project-hooks.sh.
# Depends only on jq + coreutils (grep, sort, uniq, mktemp), so it runs on bare
# ubuntu-latest with no credentials. Companion unit test:
# tests/unit/test-provider-cutover.sh.
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
#
# Exit: 0 all checks pass; 1 a drift/integrity failure; 2 usage; 3 env.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

SCRIPTS_DIR="$SCRIPT_DIR"
BASELINE="$SCRIPT_DIR/providers/cutover-baseline.json"
GENERATE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --scripts-dir)        SCRIPTS_DIR="$2"; shift ;;
    --baseline)           BASELINE="$2"; shift ;;
    --generate-baseline)  GENERATE=1 ;;
    -h|--help)            sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "check-provider-cutover.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "check-provider-cutover.sh: jq is required" >&2; exit 3; }

# The provider-neutral caller layer — the files that must NOT grow new raw gh.
# A literal list plus the lib-review-*.sh glob (resolved against SCRIPTS_DIR).
CALLER_FILES=(lib-dispatch.sh autonomous-dev.sh autonomous-review.sh)
# Allowlisted gh-holding files: the auth/refresh wrappers + the remote-SSM
# transport. These legitimately invoke gh and are NOT the caller layer (spec §8:
# GitHub auth is unchanged; the wrappers are allowlisted, not refactored).
ALLOWLISTED_FILES=(gh gh-with-token-refresh.sh gh-app-token.sh gh-as-user.sh dispatch-remote-aws-ssm.sh)

FAILED=0
fail() { echo "::error::$*" >&2; FAILED=1; }
info() { echo "  $*"; }

# Resolve the caller-layer file list against SCRIPTS_DIR (literals + the
# lib-review-*.sh glob). Emits bare basenames, one per line, de-duplicated.
caller_layer_files() {
  local f
  for f in "${CALLER_FILES[@]}"; do
    [ -f "$SCRIPTS_DIR/$f" ] && printf '%s\n' "$f"
  done
  # lib-review-*.sh glob
  for f in "$SCRIPTS_DIR"/lib-review-*.sh; do
    [ -f "$f" ] && printf '%s\n' "${f##*/}"
  done
}

# Emit the discovered raw-gh sites in one file as "<count>\t<file>\t<content>"
# rows, grouped by trimmed content. The detector:
#   - RE2-safe CONSUMING boundary `(^|[^A-Za-z_-])gh ` — never a look-behind/
#     look-ahead, so it survives both grep and any `gh --jq` RE2 context
#     (memory project_gh_jq_re2_no_lookbehind). A bare `gh ` after start-of-line
#     or any non-[A-Za-z_-] char matches; `agh `/`_gh `/`-gh ` do NOT (avoids
#     false hits on words ending in "gh").
#   - skips comment lines (first non-space char `#`) — a prose mention in a
#     comment is not a call site (symmetric with check-spec-drift.sh).
# The content is trimmed of leading/trailing whitespace so a re-indented line
# still matches its baseline entry.
discover_sites_in_file() {
  local file="$1" path="$SCRIPTS_DIR/$1"
  [ -f "$path" ] || return 0
  grep -E '(^|[^A-Za-z_-])gh ' "$path" 2>/dev/null | awk -v F="$file" '
    {
      s = $0
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      if (substr(s, 1, 1) == "#") next          # comment line — not a call
      print F "\t" s
    }
  ' | LC_ALL=C sort | uniq -c | awk '{
    # `uniq -c` prefixes "<spaces><count> <file>\t<content>". Pull the leading
    # count off the front WITHOUT rebuilding $0 (which would collapse the
    # file\tcontent tab to a space). The rest (from the first tab onward, i.e.
    # "<file>\t<content>") is preserved verbatim.
    line = $0
    sub(/^[[:space:]]+/, "", line)              # drop uniq -c indent
    count = line; sub(/[[:space:]].*$/, "", count)  # leading integer
    rest = line; sub(/^[0-9]+[[:space:]]+/, "", rest) # "<file>\t<content>"
    print count "\t" rest
  }'
}

# Discover ALL caller-layer sites across the resolved file list, as
# "<count>\t<file>\t<content>" rows.
discover_caller_sites() {
  local f
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    discover_sites_in_file "$f"
  done < <(caller_layer_files)
}

# ---------------------------------------------------------------------------
# --generate-baseline — emit a fresh baseline JSON for the current tree.
# ---------------------------------------------------------------------------
if [ "$GENERATE" -eq 1 ]; then
  sites_json="$(discover_caller_sites | jq -R -s '
    [ split("\n")[] | select(length > 0) | split("\t")
      | { count: (.[0] | tonumber), file: .[1], content: (.[2:] | join("\t")) } ]
    | sort_by(.file, .content)
  ')"
  # The file-allowlist is intentionally NOT emitted here — it is authoritative
  # ONLY in check-provider-cutover.sh's ALLOWLISTED_FILES array, so a data-file
  # edit cannot silently widen the guarded surface. This manifest carries ONLY
  # the surviving-site freeze.
  jq -n --argjson sites "$sites_json" \
    '{
      _comment: "Baseline of raw-gh sites surviving in the provider-neutral caller layer after the partial pluggable-providers migration (#281-#285). check-provider-cutover.sh ([INV-91]) FAILs any caller-layer gh NOT accounted for here. Regenerate with: bash check-provider-cutover.sh --generate-baseline. Migration PRs that remove a caller-side gh leaf MUST shrink this manifest in the same PR; the guard becomes a strict from-zero ban once this is empty. The file-allowlist (scripts/gh, gh-with-token-refresh.sh, gh-app-token.sh, gh-as-user.sh, dispatch-remote-aws-ssm.sh) lives in the script, not here.",
      surviving_sites: $sites
    }'
  exit 0
fi

# ---------------------------------------------------------------------------
# Env / file prerequisites.
# ---------------------------------------------------------------------------
[ -f "$BASELINE" ] || { echo "check-provider-cutover.sh: baseline not found: $BASELINE" >&2; exit 3; }
jq -e . "$BASELINE" >/dev/null 2>&1 || { fail "baseline is not valid JSON: $BASELINE"; echo "cutover-guard: FAIL"; exit 1; }

PROVIDERS_DIR="$SCRIPTS_DIR/providers"

# ---------------------------------------------------------------------------
# Check 1 — no NEW raw-gh in the caller layer (baseline reconciliation).
# ---------------------------------------------------------------------------
# Discovered (file,content)->count vs baseline (file,content)->count, both ways:
#   discovered NOT in baseline (new content, or count above baseline) → FAIL
#   baseline NOT discovered (count below baseline, e.g. a removed site) → FAIL
echo "=== Check 1: caller-layer raw-gh reconciles with the cutover baseline ==="

DISC_TMP="$(mktemp)"; BASE_TMP="$(mktemp)"
trap 'rm -f "$DISC_TMP" "$BASE_TMP"' EXIT

# Discovered: "<count>\t<file>\t<content>" → reshape to "<file>\t<content>\t<count>".
# Build the output field-by-field with an explicit tab — do NOT blank $1 and
# reprint $0 (that rebuilds the record with OFS=space and collapses the tabs,
# mangling file/content; the content may itself contain tabs, so join $3..NF).
# LC_ALL=C on BOTH sorts so their collation matches the LC_ALL=C comm below — a
# bare `sort` inherits the ambient locale and comm (run under C) would then see
# its inputs as "not sorted" and emit phantom add/remove records (false PASS/FAIL
# under e.g. en_US.UTF-8 CI).
discover_caller_sites | awk -F'\t' '{
  c = $1; f = $2; content = $3
  for (i = 4; i <= NF; i++) content = content "\t" $i
  print f "\t" content "\t" c
}' | LC_ALL=C sort > "$DISC_TMP"
# Baseline: same shape "<file>\t<content>\t<count>".
jq -r '.surviving_sites[] | "\(.file)\t\(.content)\t\(.count)"' "$BASELINE" | LC_ALL=C sort > "$BASE_TMP"

# Reconcile the two sorted "<file>\t<content>\t<count>" tables with `comm`. A
# record present ONLY in DISC (not in BASE) is a NEW site or a count BUMP; a
# record present ONLY in BASE is a REMOVED site or a count DROP. The full
# 3-field record is the comparison key, so a count change makes BOTH the old
# and new record differ — caught in one pass. `comm` is byte-exact (no regex,
# no `awk -v` C-escape mangling of the gh content's backslashes/`$`/quotes;
# memory project_inv73_malformed_detector_self_ref) and credential-free.
# LC_ALL=C so `comm`'s collation matches the `sort` that produced both files.
disc_only="$(LC_ALL=C comm -23 "$DISC_TMP" "$BASE_TMP")"
base_only="$(LC_ALL=C comm -13 "$DISC_TMP" "$BASE_TMP")"

if [ -n "$disc_only" ]; then
  while IFS=$'\t' read -r dfile dcontent dcount; do
    [ -z "$dfile" ] && continue
    fail "NEW/unbaselined raw-gh in the caller layer — $dfile (×$dcount): '$dcontent'. Route this host I/O through an itp_*/chp_* verb (a raw gh in the caller layer outside providers/ is an [INV-91] cutover regression). If it is a legitimate surviving site (or a count change), regenerate providers/cutover-baseline.json (--generate-baseline)."
  done <<< "$disc_only"
fi
if [ -n "$base_only" ]; then
  while IFS=$'\t' read -r bfile bcontent bcount; do
    [ -z "$bfile" ] && continue
    fail "baseline declares a raw-gh site the scanner no longer finds at this count — $bfile (×$bcount): '$bcontent'. A caller-side gh leaf was removed/changed (good — a migration landed). Shrink providers/cutover-baseline.json to match (--generate-baseline)."
  done <<< "$base_only"
fi

[ "$FAILED" -eq 0 ] && info "all caller-layer raw-gh sites reconcile with the baseline ($(wc -l < "$BASE_TMP" | tr -d ' ') distinct signatures, $(jq '[.surviving_sites[].count] | add // 0' "$BASELINE") occurrences)"

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
# Every allowlisted file must still exist (a stale allowlist entry FAILs loud);
# every file named in the baseline must still exist (a stale baseline entry FAILs).
echo "=== Check 3: allowlist + baseline integrity ==="
for af in "${ALLOWLISTED_FILES[@]}"; do
  # `gh` is the PROJECT-SIDE wrapper SYMLINK (scripts/gh → gh-with-token-refresh.sh).
  # It is gitignored / operator-local, so it is NOT present in the committed skill
  # tree (and absent in CI/test scratch dirs). It is allowlisted by NAME (a literal
  # `gh ` invocation resolves to the wrapper at runtime) but has no committed file
  # to stat — its real target gh-with-token-refresh.sh IS existence-checked below.
  if [ "$af" = "gh" ]; then
    info "allowlisted: gh (runtime wrapper symlink — target gh-with-token-refresh.sh checked separately)"
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
echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "cutover-guard: PASS — no new raw gh in the caller layer; the migration surface is unchanged."
  exit 0
else
  echo "cutover-guard: FAIL — see the ::error:: lines above ([INV-91])."
  exit 1
fi
