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
#      skills/autonomous-dispatcher/scripts/lib-*.sh that makes COMMAND-POSITION
#      calls to itp_*/chp_* verbs of a family whose seam it does NOT itself
#      source. A verb name inside an assignment RHS, a quoted string, a
#      `declare -F` guard, or a heredoc body is NOT a call (#342 round-2 P1 #3).
#      The seam libs (lib-issue-provider.sh / lib-code-host.sh) and everything
#      under providers/ are EXCLUDED (their shim definitions are not
#      consumption). On the current main this set is exactly
#      lib-review-e2e.sh → CHP. A future lib gaining a non-self-sourced family
#      is caught automatically.
#   B. HARNESS RULE (same-shell-context). For every tests/unit/test-*.sh with an
#      executable source of a consumer lib, EACH sourcing shell context must,
#      BEFORE the lib source, either (i) source the matching seam lib, or
#      (ii) define/stub EVERY verb of the missing family that the lib calls
#      (stubbing only some of them is NON-compliant — #342 round-2 P1 #1), or
#      (iii) be waived. A "shell context" = the top-level test script OR one
#      bash -c / env … bash -c string. A top-level seam source does NOT
#      satisfy a bash -c sandbox that re-sources the lib (the exact
#      TC-TOKEN-SPLIT-072 failure shape).
#   C. UNRESOLVED SOURCE TARGETS surface, never skip (#342 round-2 P1 #2). An
#      executable `source "$VAR"` whose VAR has no same-file assignment binding
#      it to a literal path (e.g. VAR=$(mktemp), VAR=$(pick_lib)) cannot be
#      proven not-a-consumer-lib. Each such line is a FINDING unless waived
#      under the `dynamic-source` pseudo-lib below.
#   D. WAIVERS with self-accounting (mirrors the test-provider-caps-branches.sh
#      LIVE/WAIVED split). Stale-waiver rule: FAIL when a waived harness no
#      longer sources the lib at all (dead entry); print an informational NOTE
#      (not a failure) when a waived harness now satisfies the rule — so a
#      sibling PR fixing a waived harness merges without flipping this red.
#   E. NEGATIVE-PATH scratch fixtures (mirrors the test-provider-cutover.sh
#      scratch-tree pattern): the checker core is a set of bash FUNCTIONS driven
#      against SCRATCH scripts+tests dirs, so we inject failure modes without
#      touching the committed tree.
#
# CLASSIFIER CONVENTION (shared with check-provider-cutover.sh / check-spec-drift.sh):
#   a "call site" / "source" is a non-comment line — strip leading whitespace,
#   skip lines whose first char is #. A mention inside a comment never counts.
#   ADDITIONALLY (this file): heredoc BODIES are blanked before scanning — a
#   `source`/verb token inside a `cat <<EOF … EOF` block is document text, not
#   executable code. Line numbers are preserved by the blanking.
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
#
# The pseudo-lib `dynamic-source` waives UNRESOLVED source targets (check C) —
# a `source "$VAR"` where VAR is bound at runtime (mktemp function-slice
# fixtures authored inline by the test itself). These are deliberate; the
# waiver records WHY each is safe. Hygiene: a dynamic-source waiver whose
# harness no longer has any unresolved target prints a removable-NOTE (never a
# FAIL — deleting a fixture must not flip this check red, the same no-flip rule
# as TC-SEAMSRC-021).
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
  "test-autonomous-review-verdict-via-helper.sh:dynamic-source:_FN_SLICE is a mktemp function-slice fixture authored inline by this test"
  "test-kill-before-spawn.sh:dynamic-source:EXTRACT_FILE is a mktemp function-slice fixture (kill fns extracted from dispatch-local.sh)"
  "test-pid-guard-pgid.sh:dynamic-source:EXTRACT_FILE is a mktemp function-slice fixture (kill fns extracted from dispatch-local.sh)"
  "test-pid-alive-long-running.sh:dynamic-source:KILL_FN_FILE is a mktemp function-slice fixture authored inline by this test"
)
is_waived() { # <harness> <lib-or-pseudo-lib>
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

# blank_heredocs FILE — emit the file with every heredoc BODY line (and its
# terminator) replaced by a `#hd` comment line, preserving the line count so
# downstream line numbers stay file-accurate. The opener line itself is kept
# (its pre-<< code is executable). Recognizes <<TAG, <<-TAG, <<'TAG', <<"TAG".
# Here-strings (<<<) and arithmetic shifts (x<<2) do not match (the tag must
# start with [A-Za-z_]).
blank_heredocs() {
  awk '
    BEGIN { hd=0; tag="" }
    {
      if (hd) {
        s=$0; sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s)
        if (s == tag) hd=0
        print "#hd"
        next
      }
      line=$0
      s=line; sub(/^[[:space:]]+/,"",s)
      if (substr(s,1,1) != "#" \
          && match(line, /<<-?[[:space:]]*["\x27]?[A-Za-z_][A-Za-z0-9_]*["\x27]?/)) {
        t=substr(line, RSTART, RLENGTH)
        sub(/^<<-?[[:space:]]*/, "", t); gsub(/["\x27]/, "", t)
        hd=1; tag=t
      }
      print line
    }
  ' "$1"
}

# non_comment_lines FILE — emit each non-comment line (heredoc bodies blanked),
# leading/trailing space stripped (the cutover-guard classifier). A #-first
# line never counts.
non_comment_lines() {
  local f="$1"
  [ -f "$f" ] || return 0
  blank_heredocs "$f" \
    | awk '{ s=$0; sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s)
             if (substr(s,1,1)=="#") next
             print s }'
}

# _verb_call_tokens LIBFILE — the distinct itp_*/chp_* verbs called in COMMAND
# POSITION (#342 round-2 P1 #3). A line is split into command segments on the
# shell metacharacters ; & | ( ) { } ` — then each segment is stripped of
# leading `!`, control keywords (if/then/elif/else/do/while/until/time), and
# UNQUOTED env-assignment prefixes (VAR=x cmd); the segment counts only when
# its FIRST word is a verb. This excludes:
#   - shim definitions (chp_x() { …    → masked to __DEF__ first)
#   - `declare -F chp_x` guards        (first word = declare)
#   - assignment RHS      X=chp_x      (assignment strip consumes the rhs)
#   - quoted-string prose "run chp_x"  (quote blocks the assignment strip; the
#                                       segment first word is the echo/msg cmd)
#   - heredoc prose                    (blanked upstream)
_verb_call_tokens() {
  local f="$1"
  [ -f "$f" ] || return 0
  blank_heredocs "$f" | awk '
    { s=$0; sub(/^[[:space:]]+/,"",s); if (substr(s,1,1)=="#") next
      line=s
      gsub(/(itp|chp)_[A-Za-z0-9_]+[[:space:]]*\(\)/, "__DEF__", line)
      n = split(line, seg, /[;&|(){}`]/)
      for (i=1;i<=n;i++) {
        t = seg[i]; sub(/^[[:space:]]+/, "", t)
        changed = 1
        while (changed) {
          changed = 0
          if (t ~ /^!([[:space:]]|$)/)  { sub(/^![[:space:]]*/, "", t); changed=1 }
          if (t ~ /^(if|then|elif|else|do|while|until|time)([[:space:]]|$)/) { sub(/^[A-Za-z]+[[:space:]]*/, "", t); changed=1 }
          if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=[^"\x27[:space:]]*([[:space:]]|$)/) { sub(/^[A-Za-z_][A-Za-z0-9_]*=[^"\x27[:space:]]*[[:space:]]*/, "", t); changed=1 }
        }
        w = t; sub(/[[:space:]].*$/, "", w)
        if (w ~ /^(itp|chp)_[A-Za-z0-9_]+$/) print w
      } }' | LC_ALL=C sort -u
}

# lib_called_families LIBFILE — which verb families (itp / chp) does this lib
# CALL (command-position)? Emits itp and/or chp, one per line, unique.
lib_called_families() {
  _verb_call_tokens "$1" | grep -oE '^(itp|chp)' | LC_ALL=C sort -u
}

# lib_called_verbs LIBFILE FAMILY — the distinct verb names of FAMILY called in
# command position (e.g. chp_pr_view). Used to check option (ii): the harness
# must stub EVERY one of these.
lib_called_verbs() {
  local f="$1" fam="$2"
  _verb_call_tokens "$f" | grep -E "^${fam}_" || true
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
# For each context, per lib basename it sources, we track whether — BEFORE the
# FIRST executable source of the lib, positionally within the context line
# stream — the context has EITHER a seam source OR a stub/definition of EVERY
# called verb of the missing family (#342 round-2 P1 #1: a partial stub set is
# NOT compliant).

# context_report TESTFILE LIBBASENAME FAMILY SEAMBASENAME VERBS...  - prints one
# line per sourcing context that is an OFFENDER (sources the lib but has neither
# the seam nor a COMPLETE verb-stub set BEFORE the source, in that same
# context). Format:
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
    function has_seam(line) {
      if (is_comment(line)) return 0
      return sources_base(line, SEAM)
    }
    # mark_stubs: record every called-verb DEFINITION on this line into
    # STUB[ctx SUBSEP verb]. A def looks like  chp_pr_view() {  (whitespace
    # tolerated). Any def of a called verb counts toward the COMPLETE set.
    function mark_stubs(line, ctx,   i, n, arr, v) {
      if (is_comment(line)) return
      n = split(VERBSTR, arr, " ")
      for (i=1;i<=n;i++) {
        v = arr[i]; if (v=="") continue
        if (line ~ ("(^|[^A-Za-z0-9_])" v "[[:space:]]*\\(\\)")) STUB[ctx SUBSEP v]=1
      }
    }
    # all_stubbed: 1 iff EVERY called verb has a stub recorded in this context
    # (and there is at least one verb). Partial stubbing is non-compliant.
    function all_stubbed(ctx,   i, n, arr, v, total) {
      n = split(VERBSTR, arr, " "); total=0
      for (i=1;i<=n;i++) {
        v = arr[i]; if (v=="") continue
        total++
        if (!((ctx SUBSEP v) in STUB)) return 0
      }
      return (total>0)
    }
    # body_compliant: for a SINGLE-LINE inline bash -c body — seam sourced, or
    # every called verb defined within the body string itself.
    function body_compliant(body,   i, n, arr, v, allv, total) {
      if (has_seam(body)) return 1
      n = split(VERBSTR, arr, " "); total=0; allv=1
      for (i=1;i<=n;i++) {
        v = arr[i]; if (v=="") continue
        total++
        if (body !~ ("(^|[^A-Za-z0-9_])" v "[[:space:]]*\\(\\)")) allv=0
      }
      return (total>0 && allv)
    }
    function ctx_compliant(ctx) {
      return (SEAMSEEN[ctx] || all_stubbed(ctx))
    }
    BEGIN { depth=0; ctx="top"; SEAMSEEN["top"]=0; lineno=0 }
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
          # multi-line sandbox). Evaluate seam/complete-stub-set WITHIN the body.
          body=rest; sub(qc ".*$", "", body)
          if (sources_base(body, LIB) && !body_compliant(body)) print "bashc@" lineno "\t" lineno
          # depth stays 0 — we remain in the enclosing context (top or an outer
          # sandbox is not possible here since depth==0). Do NOT consume the line
          # for the top-level seam/lib scan: an inline sandbox source is the
          # sandbox context, not top-level.
          next
        }
        # Multi-line opener: enter the sandbox context; the opening line remainder
        # may itself carry a seam/lib (rare) — evaluate it as the first body line.
        depth=1; ctx="bashc@" lineno; SEAMSEEN[ctx]=0
        if (rest ~ /[^[:space:]]/) {
          if (has_seam(rest)) SEAMSEEN[ctx]=1
          mark_stubs(rest, ctx)
          if (sources_base(rest, LIB) && !ctx_compliant(ctx)) print ctx "\t" lineno
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
        if (has_seam(line)) SEAMSEEN[ctx]=1
        mark_stubs(line, ctx)
        if (sources_base(line, LIB)) {
          if (!ctx_compliant(ctx)) print ctx "\t" lineno
        }
        next
      }
      # top-level context:
      if (has_seam(line)) SEAMSEEN["top"]=1
      mark_stubs(line, "top")
      if (sources_base(line, LIB)) {
        if (!ctx_compliant("top")) print "top\t" lineno
      }
    }
  ' "$tf"
}

# resolve_lib_var_tokens TESTFILE BASENAMES... - emit a copy of the file to
# stdout (heredoc bodies blanked, line count preserved) with every dollar-VAR /
# dollar-brace-VAR that a same-file assignment binds to a path containing one of
# BASENAMES rewritten to a triple-angle sentinel token on executable source
# lines, so the context_report basename matcher catches the
# source "DOLLAR-E2E_LIB" form. Also handles the SEAM var (a CHP_LIB=
# assignment whose value contains lib-code-host.sh).
# Conservative: only rewrites tokens whose assignment literally contains the
# target basename. An UNRESOLVABLE var is left alone here and surfaced as a
# finding by unresolved_source_targets (#342 round-2 P1 #2) — never skipped.
resolve_lib_var_tokens() {
  local tf="$1"; shift
  local -a bases=("$@")   # basenames to resolve vars for (lib + seam)
  blank_heredocs "$tf" | awk -v BASESTR="${bases[*]}" '
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
  '
}

# unresolved_source_targets TESTFILE — emit "<VAR>\t<lineno>" for every
# COMMAND-POSITION `source "$VAR"` / `. "$VAR"` whose target
#   (a) carries no literal path fragment on the line itself (no `/`, no `.sh`
#       beyond the var token), AND
#   (b) has no same-file assignment binding VAR to a literal path (an rhs
#       containing `/` or `.sh` counts as a binding; VAR=$(mktemp) does not).
# Such a target CANNOT be proven not-a-consumer-lib, so it is a finding unless
# waived under the dynamic-source pseudo-lib (#342 round-2 P1 #2 — surface,
# never silently skip). Heredoc bodies are blanked (document text). Positional
# vars ($1…) and array derefs are out of scope (none source libs in this tree).
unresolved_source_targets() {
  local tf="$1"
  blank_heredocs "$tf" | awk '
    function is_comment(line,   s){ s=line; sub(/^[[:space:]]+/,"",s); return (substr(s,1,1)=="#") }
    {
      lineno = NR
      line=$0
      if (is_comment(line)) next
      # Record literal-path bindings: VAR=rhs where rhs contains / or .sh
      if (line ~ /^[[:space:]]*(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=/) {
        l2=line; sub(/^[[:space:]]*local[[:space:]]+/, "", l2)
        vname=l2; sub(/=.*/,"",vname); sub(/^[[:space:]]+/,"",vname)
        rhs=l2; sub(/^[^=]*=/,"",rhs)
        if (rhs ~ /\// || rhs ~ /\.sh/) BOUND[vname]=1
      }
      # Command-position source segments.
      n = split(line, seg, /[;&|(){}`]/)
      for (i=1;i<=n;i++) {
        t = seg[i]; sub(/^[[:space:]]+/, "", t)
        changed = 1
        while (changed) {
          changed = 0
          if (t ~ /^!([[:space:]]|$)/)  { sub(/^![[:space:]]*/, "", t); changed=1 }
          if (t ~ /^(if|then|elif|else|do|while|until|time)([[:space:]]|$)/) { sub(/^[A-Za-z]+[[:space:]]*/, "", t); changed=1 }
          if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=[^"\x27[:space:]]*([[:space:]]|$)/) { sub(/^[A-Za-z_][A-Za-z0-9_]*=[^"\x27[:space:]]*[[:space:]]*/, "", t); changed=1 }
        }
        w = t; sub(/[[:space:]].*$/, "", w)
        if (w != "source" && w != ".") continue
        # target = second word of the segment
        tgt = t; sub(/^[^[:space:]]+[[:space:]]+/, "", tgt); sub(/[[:space:]].*$/, "", tgt)
        if (tgt == "" || tgt == t) continue
        # literal path fragment on the target itself → resolvable, skip
        if (tgt ~ /\.sh/ || tgt ~ /\//) continue
        # extract a $VAR / ${VAR} / "$VAR" / "${VAR}" token
        v = tgt
        gsub(/["\x27]/, "", v)
        if (v !~ /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/) continue
        sub(/^\$\{?/, "", v); sub(/\}$/, "", v)
        if (!(v in BOUND)) print v "\t" lineno
      }
    }
  '
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
#    current main after R3. Also surfaces UNRESOLVED source targets (check C).
# ===========================================================================
echo ""
echo "=== TC-SEAMSRC-010..011: live harness rule (seam-before-source; unresolved targets) ==="

CHECKED=0; WAIVED_HITS=0; OFFENDERS=0
UNRESOLVED_FOUND=0; UNRESOLVED_WAIVED=0
declare -A WAIVED_STILL_SOURCES     # "<h>:<lib>" -> 1 if the waived harness still sources the lib
declare -A DYNAMIC_LIVE             # "<h>" -> 1 if the harness still has unresolved targets
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
    bad "TC-SEAMSRC-010 $base sources $lib in context [$ctx] (line $lineno) with NO seam/complete-stub-set before it — add the matching seam source BEFORE the lib source in that context, or waive"
  done < <(harness_offenders "$tf" "$SCRIPTS")
  # Check C — unresolved dynamic source targets (finding or waiver, never skip).
  while IFS=$'\t' read -r var lineno; do
    [ -z "$var" ] && continue
    DYNAMIC_LIVE["$base"]=1
    if is_waived "$base" "dynamic-source"; then
      UNRESOLVED_WAIVED=$((UNRESOLVED_WAIVED + 1))
      continue
    fi
    UNRESOLVED_FOUND=$((UNRESOLVED_FOUND + 1))
    bad "TC-SEAMSRC-011 $base line $lineno sources \"\$${var}\" whose target is UNRESOLVABLE from this file (no literal-path assignment) — it cannot be proven not-a-consumer-lib; bind the var to a literal path or add a dynamic-source waiver"
  done < <(unresolved_source_targets "$tf")
done

if [ "$OFFENDERS" -eq 0 ]; then
  ok "TC-SEAMSRC-010 every non-waived harness context sources its consumer lib WITH the seam/complete-stub-set first ($CHECKED offending-context candidates, all waived-or-none)"
fi
if [ "$UNRESOLVED_FOUND" -eq 0 ]; then
  ok "TC-SEAMSRC-011 every unresolvable source target is waived under dynamic-source (found+waived=$UNRESOLVED_WAIVED, unwaived=0)"
fi
echo "  ACCOUNTING: offending contexts=$((OFFENDERS + WAIVED_HITS)) (waived=$WAIVED_HITS, unwaived=$OFFENDERS); unresolved targets=$((UNRESOLVED_FOUND + UNRESOLVED_WAIVED)) (waived=$UNRESOLVED_WAIVED, unwaived=$UNRESOLVED_FOUND)"

# ===========================================================================
# 3. WAIVER HYGIENE — stale + now-satisfied semantics.
# ===========================================================================
echo ""
echo "=== TC-SEAMSRC-020..021: waiver hygiene (stale FAILs, now-satisfied NOTEs) ==="

# TC-SEAMSRC-020 — a waived (harness,lib) whose harness NO LONGER sources the lib
# at all is a DEAD entry → FAIL (delete the waiver). dynamic-source waivers are
# exempt from the dead-FAIL (removable-NOTE below instead): deleting a mktemp
# fixture must not flip this check red in an unrelated PR.
_dead=0
for e in "${WAIVERS[@]}"; do
  h="${e%%:*}"; rest="${e#*:}"; l="${rest%%:*}"
  tf="$TESTS_DIR/$h"
  if [ ! -f "$tf" ]; then
    bad "TC-SEAMSRC-020 waiver names a MISSING harness ($h) — dead waiver, delete it"; _dead=1; continue
  fi
  [ "$l" = "dynamic-source" ] && continue
  if ! harness_sources_lib "$tf" "$l"; then
    bad "TC-SEAMSRC-020 waiver $h:$l is DEAD — $h no longer executably sources $l; delete the waiver entry"
    _dead=1
  fi
done
[ "$_dead" -eq 0 ] && ok "TC-SEAMSRC-020 every waiver still names a harness that executably sources the waived lib (no dead entries)"

# TC-SEAMSRC-021 — a waived (harness,lib) that NOW satisfies the rule in every
# context (no offending context surfaced above) prints an informational NOTE and
# does NOT fail — so a sibling PR fixing a waived harness merges without flipping
# this check red (the absolute-pin disease #342 removes). Same removable-NOTE for
# a dynamic-source waiver whose harness no longer has unresolved targets.
for e in "${WAIVERS[@]}"; do
  h="${e%%:*}"; rest="${e#*:}"; l="${rest%%:*}"
  tf="$TESTS_DIR/$h"
  [ -f "$tf" ] || continue
  if [ "$l" = "dynamic-source" ]; then
    if [ "${DYNAMIC_LIVE[$h]:-0}" != "1" ]; then
      note "TC-SEAMSRC-021 waived $h:dynamic-source has no unresolved source target left — safe to remove this waiver (informational, not a failure)"
    fi
    continue
  fi
  if [ "${WAIVED_STILL_SOURCES[$h:$l]:-0}" != "1" ] && harness_sources_lib "$tf" "$l"; then
    note "TC-SEAMSRC-021 waived $h:$l now SATISFIES the seam-before-source rule in every context — safe to remove this waiver (informational, not a failure)"
  fi
done
ok "TC-SEAMSRC-021 now-satisfied waivers are reported as NOTEs, never failures"

# ===========================================================================
# 4. NEGATIVE-PATH SCRATCH FIXTURES — the failure modes, proven against
#    scratch scripts+tests dirs so the SAME detector logic is exercised. Mirrors
#    the test-provider-cutover.sh fresh_scratch pattern.
# ===========================================================================
echo ""
echo "=== TC-SEAMSRC-030..036: negative-path scratch fixtures ==="

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
chp_merge() { chp_github_merge "$@"; }
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
# that STUBS the (single) called verb instead of sourcing the seam is ALSO
# compliant (option ii — the consumer calls only chp_pr_view).
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
# 5. ROUND-2 P1 REGRESSIONS — the three review findings, each pinned by a
#    scratch fixture that FAILS on the pre-fix detector.
# ===========================================================================
echo ""
echo "=== TC-SEAMSRC-040..043: round-2 P1 regressions (complete stub set; unresolved surfacing; command-position calls; heredoc prose) ==="

# TC-SEAMSRC-040 (P1 #1) — a consumer lib calling TWO chp verbs: a context that
# stubs only ONE of them is an OFFENDER; a context stubbing BOTH is compliant.
S="$(mk_scratch 040)"
cat > "$S/scripts/lib-fixture-consumer.sh" <<'CONS'
#!/bin/bash
source "$(dirname "$0")/lib-issue-provider.sh" 2>/dev/null || true
fixture_read()  { chp_pr_view "$1" --json comments; }
fixture_merge() { chp_merge "$1" --squash; }
CONS
cat > "$S/tests/test-partial-stub.sh" <<EOF
#!/bin/bash
bash -c "
  chp_pr_view() { :; }
  source '$S/scripts/lib-fixture-consumer.sh'
  fixture_read 42
"
EOF
cat > "$S/tests/test-full-stub.sh" <<EOF
#!/bin/bash
bash -c "
  chp_pr_view() { :; }
  chp_merge() { :; }
  source '$S/scripts/lib-fixture-consumer.sh'
  fixture_read 42
"
EOF
_040_partial="$(harness_offenders "$S/tests/test-partial-stub.sh" "$S/scripts")"
_040_full="$(harness_offenders "$S/tests/test-full-stub.sh" "$S/scripts")"
if [ -n "$_040_partial" ] && [ -z "$_040_full" ]; then
  ok "TC-SEAMSRC-040 (round-2 P1 #1) stubbing only ONE of two called verbs → offender; stubbing BOTH → compliant"
else
  bad "TC-SEAMSRC-040 (round-2 P1 #1) FAILED — partial=[$_040_partial] full=[$_040_full]"
fi

# TC-SEAMSRC-041 (P1 #2) — an unresolvable source target surfaces as a finding;
# a var bound to a literal path does NOT.
S="$(mk_scratch 041)"
cat > "$S/tests/test-dynamic.sh" <<EOF
#!/bin/bash
PICK=\$(pick_a_lib_somehow)
source "\$PICK"
LIBC="$S/scripts/lib-fixture-consumer.sh"
source "\$LIBC"
EOF
_041_unres="$(unresolved_source_targets "$S/tests/test-dynamic.sh")"
if printf '%s\n' "$_041_unres" | grep -q '^PICK	' \
   && ! printf '%s\n' "$_041_unres" | grep -q '^LIBC	'; then
  ok "TC-SEAMSRC-041 (round-2 P1 #2) opaque source target (\$PICK from command substitution) SURFACES; literal-bound \$LIBC does not"
else
  bad "TC-SEAMSRC-041 (round-2 P1 #2) FAILED — unresolved=[$_041_unres]"
fi

# TC-SEAMSRC-042 (P1 #3) — a lib whose ONLY verb mentions are an assignment RHS,
# a quoted string, and a declare -F guard is NOT a consumer; adding one real
# command-position call makes it one.
S="$(mk_scratch 042)"
cat > "$S/scripts/lib-fixture-mention.sh" <<'MEN'
#!/bin/bash
MSG="operators may later run chp_pr_view manually"
HANDLER=chp_pr_view
if declare -F chp_pr_view >/dev/null 2>&1; then
  :
fi
MEN
_042_before="$(consumer_libs "$S/scripts" | grep -c '^lib-fixture-mention\.sh ' || true)"
cat >> "$S/scripts/lib-fixture-mention.sh" <<'MEN2'
mention_read() { chp_pr_view "$1"; }
MEN2
_042_after="$(consumer_libs "$S/scripts" | grep -c '^lib-fixture-mention\.sh ' || true)"
if [ "${_042_before:-1}" -eq 0 ] && [ "${_042_after:-0}" -gt 0 ]; then
  ok "TC-SEAMSRC-042 (round-2 P1 #3) assignment/string/declare-F mentions are NOT calls; a command-position call IS"
else
  bad "TC-SEAMSRC-042 (round-2 P1 #3) FAILED — before=[$_042_before] after=[$_042_after]"
fi

# TC-SEAMSRC-043 — heredoc prose is not executable: a harness whose ONLY
# source-of-the-lib and verb text sit inside a heredoc body (document text
# written to a file) is neither an offender nor an unresolved-target finding.
S="$(mk_scratch 043)"
{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'cat > /tmp/seamsrc-043-doc.txt <<DOC'
  printf '%s\n' "source '$S/scripts/lib-fixture-consumer.sh'"
  printf '%s\n' 'source "$OPAQUE_VAR"'
  printf '%s\n' 'chp_pr_view 42'
  printf '%s\n' 'DOC'
  printf '%s\n' 'rm -f /tmp/seamsrc-043-doc.txt'
} > "$S/tests/test-heredoc-prose.sh"
_043_off="$(harness_offenders "$S/tests/test-heredoc-prose.sh" "$S/scripts")"
_043_unres="$(unresolved_source_targets "$S/tests/test-heredoc-prose.sh")"
if [ -z "$_043_off" ] && [ -z "$_043_unres" ]; then
  ok "TC-SEAMSRC-043 heredoc-body source/verb text is document prose — no offender, no unresolved finding"
else
  bad "TC-SEAMSRC-043 heredoc prose was scanned as executable — off=[$_043_off] unres=[$_043_unres]"
fi

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
