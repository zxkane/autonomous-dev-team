#!/bin/bash
# test-seam-source-meta.sh — issue #342, seam-source LANE meta-check.
#
# THE HAZARD THIS GUARDS
# ----------------------------------------------------------------------------
# When a raw gh call inside a shared lib migrates behind an itp_*/chp_* verb
# (the #296 pluggable-providers strangler-fig), any unit-test harness that
# sources that lib WITHOUT the matching ITP/CHP seam in the SAME shell context
# has the verb undefined: the call dies rc=127 or fail-softs to empty, and the
# harness gh stub silently stops intercepting. It has bitten twice —
# #329 round 1 (lib-review-e2e.sh, rc=127) and the chp_pr_comment migrations
# TC-TOKEN-SPLIT-072 (a bash -c sandbox re-sourcing lib-review-e2e.sh with a
# top-level-only seam). No meta-check enumerated which harness snippets must
# source which seam, so every migration re-discovered this in review round N
# instead of in the same-PR CI run. This test is that meta-check.
#
# WHAT IT CHECKS (hermetic — no gh / network / fixtures beyond scratch copies)
# ----------------------------------------------------------------------------
#   A. CONSUMER-LIB SET (tree-DERIVED, never hardcoded). Every
#      skills/autonomous-dispatcher/scripts/lib-*.sh that makes executable
#      (non-comment) calls to itp_*/chp_* verbs of a family whose seam it does
#      NOT itself source. The seam libs (lib-issue-provider.sh / lib-code-host.sh)
#      and everything under providers/ are EXCLUDED (their shim definitions are
#      not consumption). On the current main this set is exactly
#      lib-review-e2e.sh → CHP. A future lib gaining a non-self-sourced family
#      is caught automatically.
#   B. HARNESS RULE (same-shell-context). For every tests/unit/test-*.sh with an
#      executable source of a consumer lib, EACH sourcing shell context must,
#      BEFORE the lib source, either (i) source the matching seam lib, or
#      (ii) define/stub every verb of the missing family that the lib calls, or
#      (iii) be waived. A "shell context" = the top-level test script OR one
#      bash -c / env … bash -c string. A top-level seam source does NOT
#      satisfy a bash -c sandbox that re-sources the lib (the exact
#      TC-TOKEN-SPLIT-072 failure shape).
#   C. WAIVERS with self-accounting (mirrors the test-provider-caps-branches.sh
#      LIVE/WAIVED split). Stale-waiver rule: FAIL when a waived harness no
#      longer sources the lib at all (dead entry); print an informational NOTE
#      (not a failure) when a waived harness now satisfies the rule — so a
#      sibling PR fixing a waived harness merges without flipping this red.
#   D. NEGATIVE-PATH scratch fixtures (mirrors the test-provider-cutover.sh
#      scratch-tree pattern): the checker core is a bash FUNCTION driven
#      against SCRATCH scripts+tests dirs, so we can inject the three failure
#      modes without touching the committed tree.
#
# CLASSIFIER CONVENTION (shared with check-provider-cutover.sh / check-spec-drift.sh):
#   a "call site" / "source" is a non-comment line — strip leading whitespace,
#   skip lines whose first char is #. A mention inside a comment never counts.
#
# Run: bash tests/unit/test-seam-source-meta.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
TESTS_DIR="$PROJECT_ROOT/tests/unit"

RED='\033[0;31m'; GREEN='\033[0;32m'; YEL='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad()  { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
note() { echo -e "  ${YEL}NOTE${NC}: $1"; }

# ===========================================================================
# WAIVERS — "<harness-basename>:<lib-basename>:<reason>". Same self-accounting
# style as the test-provider-caps-branches.sh LIVE/WAIVED arrays. A waived
# (harness,lib) pair is NOT checked for the seam-before-source rule, but it IS
# still checked for the stale/now-satisfied conditions below.
# ---------------------------------------------------------------------------
#   - test-issue-308-b3b4-chp-reads.sh: PERMANENT. Its FAIL-SOFT section
#     (issue #308 AC4) DELIBERATELY sources lib-review-e2e.sh with NO CHP seam
#     to prove chp_pr_view degrades to empty (rc=0) rather than crashing — the
#     seams absence IS the thing under test. (Its S3 context DOES source the
#     seam and would pass on its own; the whole-harness waiver is the right
#     granularity because the rule keys on source statements, not call graphs.)
#   - test-autonomous-review-sequential-e2e.sh / test-autonomous-review-structured-ac.sh:
#     owned by open PR #337, which itself adds sandbox-level seam repairs to
#     structured-ac. Removed in a post-#337 cleanup (issue #342 Out of Scope).
WAIVERS=(
  "test-issue-308-b3b4-chp-reads.sh:lib-review-e2e.sh:permanent — #308 AC4 FAIL-SOFT proof sources the lib with NO CHP seam on purpose"
  "test-autonomous-review-sequential-e2e.sh:lib-review-e2e.sh:owned by open PR #337 (adds sandbox seam repairs); remove waiver post-#337"
  "test-autonomous-review-structured-ac.sh:lib-review-e2e.sh:owned by open PR #337 (adds sandbox seam repairs); remove waiver post-#337"
)
is_waived() { # <harness> <lib>
  local h="$1" l="$2" e key rest elib
  for e in "${WAIVERS[@]}"; do
    key="${e%%:*}"; rest="${e#*:}"; elib="${rest%%:*}"
    [ "$key" = "$h" ] && [ "$elib" = "$l" ] && return 0
  done
  return 1
}

# ===========================================================================
# CORE DETECTORS — shared by the live run AND the scratch-fixture tests, so the
# negative paths exercise the SAME logic that gates CI (no divergent stub).
# All take explicit dir args → drivable against scratch copies.
# ===========================================================================

# non_comment_lines FILE — emit each non-comment line, leading/trailing space
# stripped (the cutover-guard classifier). A #-first line never counts.
non_comment_lines() {
  local f="$1"
  [ -f "$f" ] || return 0
  awk '{ s=$0; sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s)
         if (substr(s,1,1)=="#") next
         print s }' "$f"
}

# lib_called_families LIBFILE - which verb families (itp / chp) does this lib
# CALL (executable, non-comment)? We match the verb as an itp_/chp_ token
# preceded by a non-[A-Za-z0-9_] boundary (or start-of-line). Definitions and
# shim bodies are excluded from the consumer SET by skipping the seam libs /
# providers wholesale; within a consumer lib a verb reference is a call, not a
# definition (consumer libs do not define verbs).
# Emits itp and/or chp, one per line, unique.
lib_called_families() {
  local f="$1"
  non_comment_lines "$f" \
    | grep -oE '(^|[^A-Za-z0-9_])(itp|chp)_[A-Za-z0-9_]+' 2>/dev/null \
    | grep -oE '(itp|chp)_' \
    | sed 's/_$//' \
    | LC_ALL=C sort -u
}

# lib_called_verbs LIBFILE FAMILY — the distinct verb names of FAMILY called in
# this lib (e.g. chp_pr_view). Used to check option (ii): the harness stubs
# every called verb of the missing family.
lib_called_verbs() {
  local f="$1" fam="$2"
  non_comment_lines "$f" \
    | grep -oE "(^|[^A-Za-z0-9_])${fam}_[A-Za-z0-9_]+" 2>/dev/null \
    | grep -oE "${fam}_[A-Za-z0-9_]+" \
    | LC_ALL=C sort -u
}

# lib_self_sources_family LIBFILE FAMILY — does the lib have an executable
# self-source of the family seam lib? itp→lib-issue-provider.sh, chp→lib-code-host.sh.
lib_self_sources_family() {
  local f="$1" fam="$2" seam hits
  case "$fam" in
    itp) seam='lib-issue-provider\.sh' ;;
    chp) seam='lib-code-host\.sh' ;;
    *)   return 1 ;;
  esac
  # Capture-then-test rather than piping into `grep -q`: under `set -o pipefail`
  # a `grep -q` short-circuits on the first match and SIGPIPEs the upstream awk,
  # making the whole pipeline exit non-zero even though the pattern WAS found —
  # a false "does not self-source". `grep -c` consumes all input, no SIGPIPE.
  hits="$(non_comment_lines "$f" | grep -cE "source[^#]*${seam}" || true)"
  [ "${hits:-0}" -gt 0 ]
}

# is_seam_lib BASENAME — the seam libs themselves are NOT consumers (their
# chp_*()/itp_*() shim definitions are not consumption).
is_seam_lib() {
  case "$1" in
    lib-issue-provider.sh|lib-code-host.sh) return 0 ;;
    *) return 1 ;;
  esac
}

# consumer_libs SCRIPTSDIR — emit "<lib-basename> <family>" rows: every
# top-level lib-*.sh that calls a family it does NOT self-source. providers/ is
# excluded by the top-level glob (no recursion); the seam libs are excluded by
# is_seam_lib. DERIVED — never hardcoded.
consumer_libs() {
  local sd="$1" f base fam
  for f in "$sd"/lib-*.sh; do
    [ -f "$f" ] || continue
    base="${f##*/}"
    is_seam_lib "$base" && continue
    while IFS= read -r fam; do
      [ -z "$fam" ] && continue
      lib_self_sources_family "$f" "$fam" && continue
      printf '%s %s\n' "$base" "$fam"
    done < <(lib_called_families "$f")
  done
}

# family_seam_basename FAMILY — the seam lib basename for a family.
family_seam_basename() {
  case "$1" in
    itp) echo "lib-issue-provider.sh" ;;
    chp) echo "lib-code-host.sh" ;;
  esac
}

# ---------------------------------------------------------------------------
# HARNESS CONTEXT SPLITTER - split a test file into "shell contexts". The
# top-level script is one context. Each bash -c string (single or double quoted,
# optionally prefixed with env/PATH assignments or an env ... bash -c form) is
# its own context. Rule aligned with the actual harness shapes in this repo: a
# context BOUNDARY opens at a non-comment line containing a bash -c opener with a
# following quote, and CLOSES at the line whose stripped content is the matching
# lone quote-delimiter (optionally followed by a redirection / close-paren /
# pipeline tail such as a redirect to /dev/null). Lines inside a bash -c belong
# ONLY to that context; lines outside all bash -c blocks belong to the top-level
# context. This matches every lib-review-e2e sourcing harness in the tree
# (verified against test-token-split-234.sh, test-issue-308-b3b4-chp-reads.sh,
# test-autonomous-review-*.sh).
#
# For each context, per lib basename it sources, we track whether a seam source
# / verb stub for the missing family appears BEFORE the FIRST executable source
# of the lib, positionally within the context line stream.

# context_report TESTFILE LIBBASENAME FAMILY SEAMBASENAME VERBS...  - prints one
# line per sourcing context that is an OFFENDER (sources the lib but has neither
# the seam nor all verb stubs BEFORE the source, in that same context). Format:
#   "<ctx-label>\t<lineno-in-file>"
# Prints NOTHING when every context is compliant. Detection is purely on source
# statements + shell contexts (R5: no test-file call-graph parsing).
context_report() {
  local tf="$1" lib="$2" fam="$3" seam="$4"; shift 4
  local -a verbs=("$@")
  awk -v LIB="$lib" -v SEAM="$seam" -v VERBSTR="${verbs[*]}" '
    function is_comment(line,   s) {
      s = line; sub(/^[[:space:]]+/,"",s)
      return (substr(s,1,1)=="#")
    }
    # A line that (executably) SOURCES a given basename: source … <base> or
    # . … <base> where <base> appears (literal, or via a $VAR/${VAR} whose
    # same-file assignment contains the basename — handled by pre-substituting
    # resolved vars in the caller; here we match the basename literally OR a
    # bare var token flagged as resolving to it).
    function sources_base(line, base,   s, re) {
      if (is_comment(line)) return 0
      # Must be an executable source/. command position.
      if (line !~ /(^|[;&|(){}[:space:]])(source|\.)[[:space:]]/) return 0
      # Basename literal present on the line?
      re = base; gsub(/\./,"\\.",re)
      if (line ~ re) return 1
      # Resolved-var marker (caller rewrote the var token to <<<base>>>).
      if (line ~ ("<<<" base ">>>")) return 1
      return 0
    }
    function has_seam_or_stub(line,   i, s, v, n, arr) {
      if (is_comment(line)) return 0
      if (sources_base(line, SEAM)) return 1
      # verb stub / definition: chp_pr_view() { or chp_pr_view()  { etc.,
      # or a bare chp_pr_view() { re-def. Any def of a called verb counts.
      n = split(VERBSTR, arr, " ")
      for (i=1;i<=n;i++) {
        v = arr[i]; if (v=="") continue
        if (line ~ ("(^|[^A-Za-z0-9_])" v "[[:space:]]*\\(\\)")) return 1
      }
      return 0
    }
    BEGIN { depth=0; ctx="top"; seam_seen["top"]=0; lineno=0 }
    {
      lineno++
      line=$0
      # Detect a bash -c opener (single- or double-quoted body). An opener may be
      # MULTI-LINE (the body continues on following lines, closing on a later line
      # whose stripped content is the lone matching quote) OR SINGLE-LINE INLINE
      # (the body opens AND closes on the same line, e.g. out=DOLLAR-paren-bash -c
      # "source X; cmd" close-paren). A single-line inline bash -c must NOT open a
      # multi-line context, or every following top-level line is mis-attributed to
      # a phantom sandbox until some later line accidentally looks like the closer
      # — a latent false positive/negative. NOTE: this awk program is wrapped in a
      # shell single-quoted string, so NO apostrophe may appear anywhere below.
      opener = (!is_comment(line) && (line ~ /bash[[:space:]]+-c[[:space:]]+["\x27]/))
      if (opener && depth==0) {
        tmp=line; sub(/.*bash[[:space:]]+-c[[:space:]]+/,"",tmp)  # from the opening quote
        qc=substr(tmp,1,1)
        rest=tmp; sub(/^./,"",rest)                              # strip opening quote
        # Does the SAME line also close the bash -c string? For the inline forms
        # in this tree the close is the next occurrence of the same quote char on
        # this line (nested inner quotes use the OTHER quote, so the first same-qc
        # char is the true close). If so, this is a self-contained inline sandbox.
        inline_close = (index(rest, qc) > 0)
        if (inline_close) {
          # Inline sandbox: its body is rest up to the closing quote. It is its
          # own context — a top-level seam does NOT cover it (same rule as a
          # multi-line sandbox). Evaluate seam-before-lib WITHIN the inline body.
          body=rest; sub(qc ".*$", "", body)
          ictx="bashc@" lineno; iseam=0
          if (has_seam_or_stub(body)) iseam=1
          if (sources_base(body, LIB) && iseam==0) print ictx "\t" lineno
          # depth stays 0 — we remain in the enclosing context (top or an outer
          # sandbox is not possible here since depth==0). Do NOT consume the line
          # for the top-level seam/lib scan: an inline sandbox source is the
          # sandbox context, not top-level.
          next
        }
        # Multi-line opener: enter the sandbox context; the opening line remainder
        # may itself carry a seam/lib (rare) — evaluate it as the first body line.
        depth=1; ctx="bashc@" lineno; seam_seen[ctx]=0
        if (rest ~ /[^[:space:]]/) {
          if (has_seam_or_stub(rest)) seam_seen[ctx]=1
          if (sources_base(rest, LIB) && seam_seen[ctx]==0) print ctx "\t" lineno
        }
        next
      }
      if (depth==1) {
        # Close when the stripped line is a lone matching quote + optional
        # redirection / close-paren / pipeline tail.
        s=line; sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s)
        closer=0
        if (qc=="\"") { if (substr(s,1,1)=="\"") closer=1 }
        else          { if (substr(s,1,1)=="\x27") closer=1 }
        if (closer) { depth=0; ctx="top"; next }
        # inside the bash -c context:
        if (has_seam_or_stub(line)) seam_seen[ctx]=1
        if (sources_base(line, LIB)) {
          if (seam_seen[ctx]==0) print ctx "\t" lineno
        }
        next
      }
      # top-level context:
      if (has_seam_or_stub(line)) seam_seen["top"]=1
      if (sources_base(line, LIB)) {
        if (seam_seen["top"]==0) print "top\t" lineno
      }
    }
  ' "$tf"
}

# resolve_lib_var_tokens TESTFILE LIBBASENAME - emit a copy of the file to
# stdout with every dollar-VAR / dollar-brace-VAR that a same-file assignment
# binds to a path containing LIBBASENAME rewritten to a triple-angle sentinel
# token on executable source lines, so the context_report basename matcher catches
# the  source "DOLLAR-E2E_LIB"  form. Also handles the SEAM var (a CHP_LIB=
# assignment whose value contains lib-code-host.sh).
# Conservative: only rewrites tokens whose assignment literally contains the
# target basename (R5: waiver over cleverness — an unresolvable var is left
# alone and, if it turns out to be a real source, surfaces as a finding).
resolve_lib_var_tokens() {
  local tf="$1"; shift
  local -a bases=("$@")   # basenames to resolve vars for (lib + seam)
  awk -v BASESTR="${bases[*]}" '
    function is_comment(line,   s){ s=line; sub(/^[[:space:]]+/,"",s); return (substr(s,1,1)=="#") }
    BEGIN { nb=split(BASESTR, B, " ") }
    {
      line=$0
      # Record var→base bindings: VAR=...<base>...  (executable assignment).
      if (!is_comment(line) && line ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=/) {
        vname=line; sub(/=.*/,"",vname); sub(/^[[:space:]]+/,"",vname)
        rhs=line; sub(/^[^=]*=/,"",rhs)
        for (i=1;i<=nb;i++) {
          b=B[i]; rb=b; gsub(/\./,"\\.",rb)
          if (rhs ~ rb) BIND[vname]=b
        }
      }
      # On executable source lines, rewrite $VAR / ${VAR} → <<<base>>> when bound.
      if (!is_comment(line) && line ~ /(^|[;&|(){}[:space:]])(source|\.)[[:space:]]/) {
        for (v in BIND) {
          b=BIND[v]
          # ${VAR} → sentinel (exact, no boundary concern).
          gsub("[$][{]" v "[}]", "<<<" b ">>>", line)
          # $VAR → sentinel + a space. The trailing boundary group
          # ([^A-Za-z0-9_]|$) both (a) prevents a short var ($E2E) from matching
          # inside a longer one ($E2E_LIB — the following _ is an identifier char,
          # so the boundary fails) and (b) is CONSUMED by the match. We replace
          # with the sentinel + a space rather than trying to re-emit the consumed
          # boundary char: sources_base only needs the <<<base>>> sentinel to
          # APPEAR anywhere on the line, so dropping that one char is harmless and
          # avoids the awk-gsub "&"-in-replacement pitfall (& = whole match, not a
          # capture group — POSIX awk has no replacement backreferences).
          gsub("[$]" v "([^A-Za-z0-9_]|$)", "<<<" b ">>> ", line)
        }
      }
      print line
    }
  ' "$tf"
}

# harness_offenders TESTFILE SCRIPTSDIR → for a single test file, emit offender
# rows across ALL consumer libs it sources:  "<lib>\t<ctx>\t<lineno>". Empty if
# the file sources no consumer lib, or every context is compliant. This is the
# per-file engine both the live run and the scratch fixtures call.
harness_offenders() {
  local tf="$1" sd="$2"
  local lib fam seam
  # Iterate the DERIVED consumer set from THIS scripts dir.
  while read -r lib fam; do
    [ -z "$lib" ] && continue
    seam="$(family_seam_basename "$fam")"
    local -a verbs=()
    mapfile -t verbs < <(lib_called_verbs "$sd/$lib" "$fam")
    # Rewrite $VAR source tokens (for lib + seam) so source "$E2E_LIB" matches.
    local resolved; resolved="$(resolve_lib_var_tokens "$tf" "$lib" "$seam")"
    # Feed the resolved stream to context_report via a temp (awk reads a file).
    local rtmp; rtmp="$(mktemp)"
    printf '%s\n' "$resolved" > "$rtmp"
    while IFS=$'\t' read -r ctx lineno; do
      [ -z "$ctx" ] && continue
      printf '%s\t%s\t%s\n' "$lib" "$ctx" "$lineno"
    done < <(context_report "$rtmp" "$lib" "$fam" "$seam" "${verbs[@]}")
    rm -f "$rtmp"
  done < <(consumer_libs "$sd")
}

# harness_sources_lib TESTFILE LIBBASENAME → 0 if the file has ANY executable
# source of the lib (literal or via a same-file-bound var), else 1. Used for the
# stale-waiver check.
harness_sources_lib() {
  local tf="$1" lib="$2"
  local resolved; resolved="$(resolve_lib_var_tokens "$tf" "$lib" "$lib")"
  printf '%s\n' "$resolved" \
    | awk -v LIB="$lib" '
        function is_comment(line,   s){ s=line; sub(/^[[:space:]]+/,"",s); return (substr(s,1,1)=="#") }
        {
          line=$0
          if (is_comment(line)) next
          if (line !~ /(^|[;&|(){}[:space:]])(source|\.)[[:space:]]/) next
          re=LIB; gsub(/\./,"\\.",re)
          if (line ~ re || line ~ ("<<<" LIB ">>>")) { found=1 }
        }
        END { exit(found?0:1) }
      '
}

# ===========================================================================
# 1. CONSUMER-LIB DERIVATION (tree, live)
# ===========================================================================
echo "=== TC-SEAMSRC-001..003: consumer-lib set is DERIVED from the tree ==="

mapfile -t LIVE_CONSUMERS < <(consumer_libs "$SCRIPTS")
echo "  DERIVED consumer libs (lib family): ${LIVE_CONSUMERS[*]:-<none>}"

# TC-SEAMSRC-001 — lib-review-e2e.sh → chp is in the derived set (it calls
# chp_pr_view and self-sources only the ITP seam).
if printf '%s\n' "${LIVE_CONSUMERS[@]:-}" | grep -qx 'lib-review-e2e.sh chp'; then
  ok "TC-SEAMSRC-001 lib-review-e2e.sh → CHP derived as a consumer lib (calls chp_*, no CHP self-source)"
else
  bad "TC-SEAMSRC-001 lib-review-e2e.sh → CHP NOT derived (set: ${LIVE_CONSUMERS[*]:-none})"
fi

# TC-SEAMSRC-002 — the seam libs themselves are NEVER consumers.
if printf '%s\n' "${LIVE_CONSUMERS[@]:-}" | grep -qE '^(lib-issue-provider|lib-code-host)\.sh '; then
  bad "TC-SEAMSRC-002 a seam lib was misclassified as a consumer (shim defs ≠ consumption)"
else
  ok "TC-SEAMSRC-002 neither lib-issue-provider.sh nor lib-code-host.sh is in the consumer set"
fi

# TC-SEAMSRC-003 — a lib that self-sources the family it calls is NOT a consumer
# for that family (lib-auth.sh / lib-pr-linkage.sh self-source CHP and call CHP;
# lib-review-poll.sh / lib-review-verdict.sh self-source ITP and call ITP).
_self_srcd_wrong=0
for pair in "lib-auth.sh chp" "lib-pr-linkage.sh chp" "lib-review-poll.sh itp" "lib-review-verdict.sh itp"; do
  set -- $pair; f="$1"; fam="$2"
  [ -f "$SCRIPTS/$f" ] || continue
  if lib_self_sources_family "$SCRIPTS/$f" "$fam"; then
    printf '%s\n' "${LIVE_CONSUMERS[@]:-}" | grep -qx "$f $fam" && { _self_srcd_wrong=1; echo "    -> $f $fam wrongly flagged"; }
  fi
done
if [ "$_self_srcd_wrong" -eq 0 ]; then
  ok "TC-SEAMSRC-003 a lib self-sourcing the family it calls is NOT a consumer for that family"
else
  bad "TC-SEAMSRC-003 a self-sourcing lib was wrongly flagged as a consumer"
fi

# ===========================================================================
# 2. LIVE HARNESS RULE — every tests/unit/test-*.sh, checked against the derived
#    consumer set, with waivers applied. This is the gate that must be GREEN on
#    current main after R3.
# ===========================================================================
echo ""
echo "=== TC-SEAMSRC-010: live harness rule (seam-before-source in every context) ==="

CHECKED=0; WAIVED_HITS=0; OFFENDERS=0
declare -A WAIVED_STILL_SOURCES     # "<h>:<lib>" -> 1 if the waived harness still sources the lib
for tf in "$TESTS_DIR"/test-*.sh; do
  base="${tf##*/}"
  [ "$base" = "test-seam-source-meta.sh" ] && continue   # don't self-scan
  while IFS=$'\t' read -r lib ctx lineno; do
    [ -z "$lib" ] && continue
    CHECKED=$((CHECKED + 1))
    if is_waived "$base" "$lib"; then
      WAIVED_HITS=$((WAIVED_HITS + 1))
      WAIVED_STILL_SOURCES["$base:$lib"]=1
      continue
    fi
    OFFENDERS=$((OFFENDERS + 1))
    bad "TC-SEAMSRC-010 $base sources $lib in context [$ctx] (line $lineno) with NO seam/stub before it — add the matching seam source BEFORE the lib source in that context, or waive"
  done < <(harness_offenders "$tf" "$SCRIPTS")
done

if [ "$OFFENDERS" -eq 0 ]; then
  ok "TC-SEAMSRC-010 every non-waived harness context sources its consumer lib WITH the seam/stub first ($CHECKED offending-context candidates, all waived-or-none)"
fi
echo "  ACCOUNTING: offending contexts found=$((OFFENDERS + WAIVED_HITS)) (waived=$WAIVED_HITS, unwaived=$OFFENDERS)"

# ===========================================================================
# 3. WAIVER HYGIENE — stale + now-satisfied semantics.
# ===========================================================================
echo ""
echo "=== TC-SEAMSRC-020..021: waiver hygiene (stale FAILs, now-satisfied NOTEs) ==="

# TC-SEAMSRC-020 — a waived (harness,lib) whose harness NO LONGER sources the lib
# at all is a DEAD entry → FAIL (delete the waiver).
_dead=0
for e in "${WAIVERS[@]}"; do
  h="${e%%:*}"; rest="${e#*:}"; l="${rest%%:*}"
  tf="$TESTS_DIR/$h"
  if [ ! -f "$tf" ]; then
    bad "TC-SEAMSRC-020 waiver names a MISSING harness ($h) — dead waiver, delete it"; _dead=1; continue
  fi
  if ! harness_sources_lib "$tf" "$l"; then
    bad "TC-SEAMSRC-020 waiver $h:$l is DEAD — $h no longer executably sources $l; delete the waiver entry"
    _dead=1
  fi
done
[ "$_dead" -eq 0 ] && ok "TC-SEAMSRC-020 every waiver still names a harness that executably sources the waived lib (no dead entries)"

# TC-SEAMSRC-021 — a waived (harness,lib) that NOW satisfies the rule in every
# context (no offending context surfaced above) prints an informational NOTE and
# does NOT fail — so a sibling PR fixing a waived harness merges without flipping
# this check red (the absolute-pin disease #342 removes).
for e in "${WAIVERS[@]}"; do
  h="${e%%:*}"; rest="${e#*:}"; l="${rest%%:*}"
  tf="$TESTS_DIR/$h"
  [ -f "$tf" ] || continue
  if [ "${WAIVED_STILL_SOURCES[$h:$l]:-0}" != "1" ] && harness_sources_lib "$tf" "$l"; then
    note "TC-SEAMSRC-021 waived $h:$l now SATISFIES the seam-before-source rule in every context — safe to remove this waiver (informational, not a failure)"
  fi
done
ok "TC-SEAMSRC-021 now-satisfied waivers are reported as NOTEs, never failures"

# ===========================================================================
# 4. NEGATIVE-PATH SCRATCH FIXTURES — the three failure modes, proven against
#    scratch scripts+tests dirs so the SAME detector logic is exercised. Mirrors
#    the test-provider-cutover.sh fresh_scratch pattern.
# ===========================================================================
echo ""
echo "=== TC-SEAMSRC-030..032: negative-path scratch fixtures (three failure modes) ==="

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A minimal scratch scripts dir holding one seam lib + one consumer lib, and a
# scratch tests dir holding harnesses. We reuse the LIVE detector functions
# (harness_offenders / consumer_libs) pointed at these scratch dirs.
mk_scratch() {
  local d="$WORK/$1"; rm -rf "$d"; mkdir -p "$d/scripts" "$d/tests"
  # A CHP seam lib (its shim def must NOT make it a consumer).
  cat > "$d/scripts/lib-code-host.sh" <<'SEAM'
#!/bin/bash
chp_pr_view() { chp_github_pr_view "$@"; }
SEAM
  # A consumer lib: calls chp_pr_view, self-sources ONLY the ITP seam (so CHP is
  # its non-self-sourced family), mirroring lib-review-e2e.sh.
  cat > "$d/scripts/lib-fixture-consumer.sh" <<'CONS'
#!/bin/bash
# self-source ITP only (a comment mention of lib-code-host.sh must NOT count):
# source lib-code-host.sh   <-- commented, inert
source "$(dirname "$0")/lib-issue-provider.sh" 2>/dev/null || true
fixture_read() { chp_pr_view "$1" --json comments; }
CONS
  cat > "$d/scripts/lib-issue-provider.sh" <<'ITP'
#!/bin/bash
itp_post_comment() { :; }
ITP
  printf '%s' "$d"
}

# TC-SEAMSRC-030 (mode i) — a lib gains a new non-self-sourced verb family while
# a BARE-sourcing harness exists → red. Here: consumer derived + a harness that
# sources it top-level with no seam.
S="$(mk_scratch 030)"
cat > "$S/tests/test-bare.sh" <<EOF
#!/bin/bash
LIBC="$S/scripts/lib-fixture-consumer.sh"
source "\$LIBC"
fixture_read 42
EOF
# Confirm the consumer is derived and the bare harness is an offender.
# Capture-then-test (never `consumer_libs | grep -q`): under pipefail a matching
# grep -q SIGPIPEs the upstream function and can flip the pipeline exit status.
_030_consumers="$(consumer_libs "$S/scripts")"
_030_offenders="$(harness_offenders "$S/tests/test-bare.sh" "$S/scripts")"
if printf '%s\n' "$_030_consumers" | grep -qx 'lib-fixture-consumer.sh chp' \
   && [ -n "$_030_offenders" ]; then
  ok "TC-SEAMSRC-030 (mode i) new non-self-sourced family + bare-sourcing harness → offender flagged"
else
  bad "TC-SEAMSRC-030 (mode i) NOT flagged — consumer=[$_030_consumers] offenders=[$_030_offenders]"
fi

# TC-SEAMSRC-031 (mode ii) — a harness DROPPING its seam source → red. Baseline:
# a harness that sources the seam THEN the lib is compliant; remove the seam line
# and it becomes an offender.
S="$(mk_scratch 031)"
cat > "$S/tests/test-compliant.sh" <<EOF
#!/bin/bash
SEAM="$S/scripts/lib-code-host.sh"
LIBC="$S/scripts/lib-fixture-consumer.sh"
source "\$SEAM"
source "\$LIBC"
fixture_read 42
EOF
compliant_off="$(harness_offenders "$S/tests/test-compliant.sh" "$S/scripts")"
cat > "$S/tests/test-dropped.sh" <<EOF
#!/bin/bash
LIBC="$S/scripts/lib-fixture-consumer.sh"
source "\$LIBC"
fixture_read 42
EOF
dropped_off="$(harness_offenders "$S/tests/test-dropped.sh" "$S/scripts")"
if [ -z "$compliant_off" ] && [ -n "$dropped_off" ]; then
  ok "TC-SEAMSRC-031 (mode ii) seam-then-lib is compliant; DROPPING the seam source → offender flagged"
else
  bad "TC-SEAMSRC-031 (mode ii) FAILED — compliant=[$compliant_off] dropped=[$dropped_off]"
fi

# TC-SEAMSRC-032 (mode iii) — a bash -c sandbox sourcing the lib without the
# seam WHILE the top level HAS it → red (the TC-TOKEN-SPLIT-072 shape: a
# top-level seam does NOT satisfy a re-sourcing sandbox).
S="$(mk_scratch 032)"
cat > "$S/tests/test-sandbox.sh" <<EOF
#!/bin/bash
SEAM="$S/scripts/lib-code-host.sh"
LIBC="$S/scripts/lib-fixture-consumer.sh"
source "\$SEAM"          # top-level seam — must NOT satisfy the sandbox below
bash -c "
  source '$S/scripts/lib-fixture-consumer.sh'
  fixture_read 42
"
EOF
sandbox_off="$(harness_offenders "$S/tests/test-sandbox.sh" "$S/scripts")"
# The offender must be the bash -c context, NOT the top level.
if printf '%s\n' "$sandbox_off" | grep -q 'bashc@'; then
  ok "TC-SEAMSRC-032 (mode iii) bash -c sandbox sourcing the lib without the seam (top-level seam present) → offender flagged in the SANDBOX context"
else
  bad "TC-SEAMSRC-032 (mode iii) NOT flagged in the sandbox — offenders=[$sandbox_off]"
fi

# TC-SEAMSRC-033 — POSITIVE control: a bash -c sandbox that sources the seam
# BEFORE the lib in the same context is compliant (no offender). And a context
# that STUBS the verb instead of sourcing the seam is ALSO compliant (option ii).
S="$(mk_scratch 033)"
cat > "$S/tests/test-sandbox-ok.sh" <<EOF
#!/bin/bash
bash -c "
  source '$S/scripts/lib-code-host.sh'
  source '$S/scripts/lib-fixture-consumer.sh'
  fixture_read 42
"
bash -c "
  chp_pr_view() { :; }
  source '$S/scripts/lib-fixture-consumer.sh'
  fixture_read 42
"
EOF
if [ -z "$(harness_offenders "$S/tests/test-sandbox-ok.sh" "$S/scripts")" ]; then
  ok "TC-SEAMSRC-033 seam-before-lib sandbox AND verb-stub-before-lib sandbox are both compliant (no offender)"
else
  bad "TC-SEAMSRC-033 a compliant sandbox was wrongly flagged: [$(harness_offenders "$S/tests/test-sandbox-ok.sh" "$S/scripts")]"
fi

# TC-SEAMSRC-034 — the seam lib in the scratch tree is NOT itself a consumer
# (its chp_pr_view() shim def is a definition, not a call).
S="$(mk_scratch 034)"
# Capture-then-test (never `consumer_libs | grep -q`) — see the TC-SEAMSRC-030 note.
_034_consumers="$(consumer_libs "$S/scripts")"
if printf '%s\n' "$_034_consumers" | grep -qE '^lib-code-host\.sh '; then
  bad "TC-SEAMSRC-034 scratch seam lib misclassified as a consumer"
else
  ok "TC-SEAMSRC-034 scratch seam lib (chp_pr_view shim def) is NOT a consumer"
fi

# TC-SEAMSRC-035 — SINGLE-LINE INLINE bash -c must NOT open a phantom multi-line
# context. A COMPLIANT harness that (1) sources the CHP seam at top level, then
# (2) has an inline  x=$(bash -c "...")  single-liner, then (3) sources the
# consumer lib at top level AFTER it — must have ZERO offenders. Before the
# inline-close fix, the inline bash -c stayed "open" and mis-attributed the
# later top-level lib source to a phantom sandbox that never saw the seam →
# a false CI red on a compliant harness (this file lives on the same tree as
# real inline single-liners, e.g. test-token-split-234.sh line 36).
S="$(mk_scratch 035)"
cat > "$S/tests/test-inline-ok.sh" <<EOF
#!/bin/bash
SEAM="$S/scripts/lib-code-host.sh"
LIBC="$S/scripts/lib-fixture-consumer.sh"
source "\$SEAM"                              # top-level seam
probe=\$(bash -c "echo inline-single-liner") # inline bash -c: opens AND closes here
source "\$LIBC"                              # top-level lib source, AFTER the inline
fixture_read 42
EOF
_035_off="$(harness_offenders "$S/tests/test-inline-ok.sh" "$S/scripts")"
if [ -z "$_035_off" ]; then
  ok "TC-SEAMSRC-035 inline single-line bash -c does NOT open a phantom context; a top-level-seam + later top-level lib source stays compliant"
else
  bad "TC-SEAMSRC-035 inline single-line bash -c mis-attributed a top-level source to a phantom sandbox: [$_035_off]"
fi

# TC-SEAMSRC-036 — the mirror: an inline single-line bash -c that ITSELF sources
# the consumer lib without a seam IS an offender (in the inline sandbox context),
# even when the top level has the seam. Proves the inline body is still scanned.
S="$(mk_scratch 036)"
cat > "$S/tests/test-inline-bad.sh" <<EOF
#!/bin/bash
SEAM="$S/scripts/lib-code-host.sh"
source "\$SEAM"                                                  # top-level seam (must NOT cover the inline)
probe=\$(bash -c "source '$S/scripts/lib-fixture-consumer.sh'; fixture_read 42")
EOF
_036_off="$(harness_offenders "$S/tests/test-inline-bad.sh" "$S/scripts")"
if printf '%s\n' "$_036_off" | grep -q 'bashc@'; then
  ok "TC-SEAMSRC-036 inline single-line bash -c sourcing the lib without the seam is flagged in the INLINE sandbox context (top-level seam does not cover it)"
else
  bad "TC-SEAMSRC-036 inline offender NOT flagged: [$_036_off]"
fi

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
