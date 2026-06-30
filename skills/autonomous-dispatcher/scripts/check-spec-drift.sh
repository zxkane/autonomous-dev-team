#!/bin/bash
# check-spec-drift.sh — issue #236, executable-spec gate (CI-checker half).
#
# Fails (non-zero) when the dispatcher/wrapper CODE drifts from the declared
# spec in docs/pipeline/transitions.json. Four independent checks:
#
#   A. Diagram drift — state-machine.md mermaid must equal the generator's
#      output (delegates to gen-state-machine.sh --check).
#   D. Retracted-doc drift — normative provider-spec.md text that a migration
#      falsified MUST NOT survive. Today: the #296/B2 (#306) issue-body read
#      migration retired the claim that check_deps_resolved's body read "remains a
#      raw caller-side `gh` call" — so that exact phrase MUST NOT appear in
#      provider-spec.md. This runs in the SAME `spec-drift` CI job as A/B/C (the
#      job the #306 owner comment named), so the named surface enforces it; it is
#      NOT only in the hermetic-unit job. Fails LOUD naming the file:line.
#   B. Guard/action mapping — every guard + every load-bearing action verb in
#      transitions.json must have an entry in spec-guard-map.json, and every
#      mapped anchor (function name OR greppable predicate) must still resolve
#      in its cited file. A token with no mapping, or a mapped anchor that no
#      longer resolves, fails LOUD naming the pair.
#   C. Label-write-SITE completeness — FIVE sub-checks over the four pipeline
#      files (label_swap args + --add-label/--remove-label literals), PLUS a hard
#      ban on un-allowlisted variable-valued writes (P1.1):
#        C.1 vocabulary — every label literal WRITTEN must appear in
#            transitions.json as a state label or inside an actions[]
#            (add-label:X / remove-label:X). A brand-new label (e.g. a typo) with
#            no declared transition fails LOUD naming the orphan label + site.
#        C.2 movement — every write SITE performs a label MOVEMENT (the set of
#            labels it removes + the set it adds). That movement must be declared
#            by some transition's actions[]. A new write that REUSES existing
#            labels in an undeclared (remove→add) combination — e.g.
#            `label_swap "$n" "approved" "stalled"` — passes C.1 (both labels
#            exist) but MUST fail C.2: no transition declares that movement.
#        C.3 code-site coverage — every CODE-BEARING transition (actor ∉
#            {maintainer, github}) is pinned by spec-codesite-map.json to a
#            grep-stable code anchor, checked BOTH ways: forward (every such
#            transition has an entry whose anchor still greps) and reverse (every
#            map entry's key is a live transition id). C.2 alone is movement-SET
#            membership — two transitions sharing one movement make a row's
#            deletion invisible. C.3 makes write-SITE/code-site coverage hold:
#            deleting a transition row whose movement is shared elsewhere leaves
#            an orphaned map entry and fails CI.
#        C.4 discovered-site reconciliation — the COUNT of literal write sites the
#            scanner finds per (file, movement) must equal the count of `sites[]`
#            manifest entries for that (file, movement). C.2/C.3 never iterate the
#            DISCOVERED sites, so a NEW site whose movement already exists elsewhere
#            (a second `label_swap "$n" "pending-dev" "pending-review"`) passes
#            both — C.4 catches it: discovered count > manifest count.
#        C.5 per-site anchor adjacency — each `sites[]` manifest entry's `anchor`
#            must grep EXACTLY ONCE in its file AND a write of its `movement` must
#            sit within ±8 lines. C.4 is a count, so RELOCATING a write within the
#            same file (same movement, count unchanged) is invisible to it; C.5
#            binds each site to a concrete location, so moving the write out of its
#            anchor's neighbourhood fails. Together C.1+C.2+C.3+C.4+C.5 — plus the
#            P1.1 variable-write ban (an un-allowlisted variable-valued
#            --add/--remove-label "$x" is a hard FAIL, not a NOTE: it could inject
#            an undeclared label the literal-site checks never see) — make "a PR
#            adding (even a duplicate / shared-movement / relocated / variable)
#            or removing a label-write site without the matching transitions.json
#            entry fails CI" (issue #236 AC) actually hold.
#
# CI / dev tool only — NOT sourced by any dispatch-time wrapper. Depends only on
# jq + coreutils (grep, diff, mktemp), so it runs on bare ubuntu-latest with no
# credentials. The companion unit test is tests/unit/test-spec-drift.sh.
#
# Usage:
#   check-spec-drift.sh                 Run all three checks against the repo.
#   check-spec-drift.sh --transitions P --guard-map P --doc P --scripts-dir D
#                                       Override paths (used by the unit test to
#                                       point at scratch copies for drift injection).
#
# Exit: 0 all checks pass; 1 a drift/mapping/completeness failure; 2/3 usage/env.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TRANSITIONS="$PROJECT_ROOT/docs/pipeline/transitions.json"
GUARD_MAP="$PROJECT_ROOT/docs/pipeline/spec-guard-map.json"
CODESITE_MAP="$PROJECT_ROOT/docs/pipeline/spec-codesite-map.json"
DOC="$PROJECT_ROOT/docs/pipeline/state-machine.md"
# Check D (retracted-doc drift) target. Overridable so the unit test can point at a
# scratch copy for injection; defaults to the pipeline-doc sibling of $DOC.
PROVIDER_SPEC="$PROJECT_ROOT/docs/pipeline/provider-spec.md"
SCRIPTS_DIR="$SCRIPT_DIR"
GEN="$SCRIPT_DIR/gen-state-machine.sh"

while [ $# -gt 0 ]; do
  case "$1" in
    --transitions)  TRANSITIONS="$2"; shift ;;
    --guard-map)    GUARD_MAP="$2"; shift ;;
    --codesite-map) CODESITE_MAP="$2"; shift ;;
    --doc)          DOC="$2"; shift ;;
    --provider-spec) PROVIDER_SPEC="$2"; shift ;;
    --scripts-dir)  SCRIPTS_DIR="$2"; shift ;;
    --gen)          GEN="$2"; shift ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "check-spec-drift.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "check-spec-drift.sh: jq is required" >&2; exit 3; }
for f in "$TRANSITIONS" "$GUARD_MAP" "$CODESITE_MAP"; do
  [ -f "$f" ] || { echo "check-spec-drift.sh: not found: $f" >&2; exit 3; }
done

# The four pipeline files whose label writes must be declared.
PIPELINE_FILES=(autonomous-dev.sh autonomous-review.sh dispatcher-tick.sh lib-dispatch.sh)

FAILED=0
fail() { echo "::error::$*" >&2; FAILED=1; }
info() { echo "  $*"; }
# note() surfaces a non-fatal pointer WITHOUT setting FAILED. Originally emitted
# by the old warn_variable_writes (variable-valued writes were a green audit hint
# under the M1 contract). P1.1 replaced that with check_variable_writes, which now
# FAILS such writes, so note() currently has no caller; it is kept as a sibling of
# fail/info for any future non-fatal pointer.
note() { echo "  NOTE: $*"; }

# ---------------------------------------------------------------------------
# Check A — diagram drift.
# ---------------------------------------------------------------------------
echo "=== Check A: state-machine.md mermaid is generated from transitions.json ==="
if [ -x "$GEN" ] || [ -f "$GEN" ]; then
  if bash "$GEN" --check --transitions "$TRANSITIONS" --doc "$DOC"; then
    info "diagram in sync"
  else
    fail "state-machine.md mermaid DRIFTED from transitions.json (see diff above). Run: scripts/gen-state-machine.sh"
  fi
else
  fail "generator not found: $GEN"
fi

# ---------------------------------------------------------------------------
# Check B — guard/action mapping.
# ---------------------------------------------------------------------------
echo "=== Check B: every guard/action maps to a resolvable code anchor ==="

# B.0 — guard map is well-formed JSON.
jq -e . "$GUARD_MAP" >/dev/null 2>&1 || { fail "spec-guard-map.json is not valid JSON"; }

# Resolve a single anchor entry against $SCRIPTS_DIR.
#   resolve_anchor <token> <entry-json>
# Echoes nothing on success; echoes a reason string on failure. All fields are
# read in ONE jq pass (a tab-joined record) so there is no stdin-consumption
# race between multiple jq calls.
resolve_anchor() {
  local token="$1" entry="$2" kind file name pattern target
  # Four separate jq reads from the in-variable JSON. (jq reads its program's
  # input from the heredoc string, NOT a shared stdin, so there is no
  # consumption race; and unlike @tsv + `read`, empty middle fields can't
  # collapse — tab is IFS-whitespace, so \t\t would merge into one delimiter.)
  kind="$(jq -r '.kind // ""' <<<"$entry")"
  file="$(jq -r '.file // ""' <<<"$entry")"
  name="$(jq -r '.name // ""' <<<"$entry")"
  pattern="$(jq -r '.pattern // ""' <<<"$entry")"
  if [ -z "$kind" ] || [ -z "$file" ]; then
    echo "entry for '$token' missing kind/file"; return
  fi
  target="$SCRIPTS_DIR/$file"
  if [ ! -f "$target" ]; then
    echo "'$token' cites missing file: $file"; return
  fi
  case "$kind" in
    function)
      [ -n "$name" ] || { echo "'$token' kind=function but no name"; return; }
      # Function definition anchor: `name() {` possibly preceded by `function `.
      if ! grep -Eq "^(function[[:space:]]+)?${name}[[:space:]]*\(\)" "$target"; then
        echo "'$token' → function ${name}() NOT defined in $file (code drift?)"
      fi
      ;;
    predicate)
      [ -n "$pattern" ] || { echo "'$token' kind=predicate but no pattern"; return; }
      # Fixed-string grep: the literal must still appear in the cited file.
      if ! grep -Fq -- "$pattern" "$target"; then
        echo "'$token' → predicate '$pattern' NOT found in $file (code drift?)"
      fi
      ;;
    *)
      echo "'$token' has unknown kind: $kind"
      ;;
  esac
}

# Action verbs that are documentation-only (no code anchor required).
mapfile -t EXEMPT_VERBS < <(jq -r '.exempt_action_verbs[]? // empty' "$GUARD_MAP")
is_exempt_verb() {
  local verb="$1" e
  for e in "${EXEMPT_VERBS[@]:-}"; do [ "$verb" = "$e" ] && return 0; done
  return 1
}

# B.1 — every guard token has a mapping and the anchor resolves.
while IFS= read -r token; do
  [ -z "$token" ] && continue
  entry="$(jq -c --arg t "$token" '.guards[$t] // empty' "$GUARD_MAP")"
  if [ -z "$entry" ]; then
    fail "guard '$token' (in transitions.json) has NO entry in spec-guard-map.json"
    continue
  fi
  reason="$(resolve_anchor "$token" "$entry")"
  [ -n "$reason" ] && fail "guard mapping: $reason"
done < <(jq -r '[.transitions[].guards[]] | unique | .[]' "$TRANSITIONS")

# B.2 — every action verb either is exempt (comment:*) or has an action mapping
#        whose anchor resolves.
while IFS= read -r action; do
  [ -z "$action" ] && continue
  # Label writes are validated by Check C, not here.
  case "$action" in add-label:*|remove-label:*) continue ;; esac
  verb="${action%%:*}"
  if is_exempt_verb "$verb"; then
    continue
  fi
  entry="$(jq -c --arg t "$action" '.actions[$t] // empty' "$GUARD_MAP")"
  if [ -z "$entry" ]; then
    fail "action '$action' (in transitions.json) has NO entry in spec-guard-map.json (and is not an exempt verb)"
    continue
  fi
  reason="$(resolve_anchor "$action" "$entry")"
  [ -n "$reason" ] && fail "action mapping: $reason"
done < <(jq -r '[.transitions[].actions[]] | unique | .[]' "$TRANSITIONS")

[ "$FAILED" -eq 0 ] && info "all guard/action tokens map to resolvable anchors"

# ---------------------------------------------------------------------------
# Check C — label-write-SITE completeness (vocabulary C.1 + movement C.2).
# ---------------------------------------------------------------------------
echo "=== Check C: every label WRITE SITE in the pipeline is declared in transitions.json ==="

# --- C.1 vocabulary ---------------------------------------------------------
# Declared label universe = label_vocabulary ∪ every state label ∪ every
# add/remove-label action target.
declared_labels() {
  jq -r '
    (.label_vocabulary // [])
    + ([.states[].label])
    + ([.transitions[].actions[] | select(startswith("add-label:") or startswith("remove-label:")) | sub("^(add|remove)-label:";"")])
    | unique | .[]
  ' "$TRANSITIONS"
}
DECLARED="$(declared_labels)"

is_declared() {
  local lbl="$1"
  # Here-string, NOT `printf … | grep -Fxq`: `grep -q` closes the pipe on the
  # first match, which SIGPIPEs the still-writing printf (exit 141); under
  # `set -o pipefail` that 141 becomes the pipeline status and a DECLARED label
  # is randomly mis-reported as undeclared (~6% of runs). A here-string has no
  # upstream writer to kill, so the status is just grep's.
  grep -Fxq -- "$lbl" <<<"$DECLARED"
}

# Collect every label literal WRITTEN by the pipeline files, with its site.
# Two literal write forms (the gate enforces these against the table):
#   1. label_swap "$issue_num" "<remove>" "<add>"   (positional label literals)
#   2. gh issue edit ... --add-label "X" / --remove-label "X"
# Emits "<label>\t<file>:<lineno>" lines. Variable-valued writes (e.g.
# --add-label "$var", or the hygiene loop's dynamic args[]) cannot be resolved
# to a literal here; they are handled separately by check_variable_writes, which
# (under P1.1) FAILS any such write unless its enclosing function is allowlisted —
# so the gap is never silent.
#
# ONE awk pass per file (no per-line pipe fan-out): physical lines are joined
# across trailing `\` continuations first, so a `gh issue edit \` whose
# `--add-label "X"` sits on the next physical line is still seen as one logical
# line (M2). The emitted line number is the FIRST physical line of the logical
# line. awk extracts the quoted label operands itself.
collect_writes() {
  local f path
  for f in "${PIPELINE_FILES[@]}"; do
    path="$SCRIPTS_DIR/$f"
    [ -f "$path" ] || continue
    awk -v file="$f" '
      # Strip the optional surrounding quote chars from a label operand. A quoted
      # operand ("label" or '\''label'\'') has its first+last char dropped; a BARE
      # (unquoted) operand is returned as-is. The label char class is
      # [a-z][a-z0-9-]* — lowercase start then lowercase/DIGIT/hyphen, matching the
      # add-label/remove-label pattern in transitions.schema.json EXACTLY, so a
      # digit-bearing label (e.g. v2-blocked) is scanned, not silently skipped.
      function strip_quotes(t,   c) {
        c = substr(t, 1, 1)
        if (c == "\"" || c == "'\''") return substr(t, 2, length(t) - 2)
        return t
      }
      # Print every quoted-OR-bare label_swap operand in s (Form 1 path). label_swap
      # callers in the repo are all quoted, but the bare alternative keeps Form 1
      # symmetric with Form 2. Saves RSTART/RLENGTH into locals each iteration BEFORE
      # substr so a caller that also uses match() is unaffected (this is a leaf — it
      # calls no other match()).
      function emit_labels(s,   rest, st, ln) {
        rest = s
        while (match(rest, /["'\''][a-z][a-z0-9-]*["'\'']/)) {
          st = RSTART; ln = RLENGTH
          print substr(rest, st + 1, ln - 2) "\t" file ":" startno
          rest = substr(rest, st + ln)
        }
      }
      function scan(s,   rest, st, ln, tok, lbl) {
        # Form 1 (label_swap) + Form 3 (itp_transition_state, INV-87) are both
        # positional; emit_labels prints every QUOTED lowercase label literal. A
        # variable operand (issue-number or a dollar-var) starts with a dollar
        # sign, which the quoted-lowercase regex excludes, so only static labels
        # are emitted (a fully variable-arg itp_transition_state call emits
        # nothing here, symmetric with emit_movement skip-variable guard).
        if (s ~ /label_swap[ \t]/ || s ~ /itp_transition_state[ \t]/) { emit_labels(s); return }
        # Form 2: --add-label/--remove-label LITERAL — the literal may be DOUBLE-
        # quoted, SINGLE-quoted, OR BARE (unquoted shell word, e.g.
        # `--add-label frobnicate`; reviewer [BLOCKING]). A bare label is matched by
        # the second alternative; it can never match a variable write (`$x`/`"$x"`)
        # because those start with `$` or a quote, which the bare class excludes —
        # variable writes remain the P1.1 ban'\''s job. CRITICAL: capture RSTART/RLENGTH
        # into locals BEFORE the nested strip — advancing rest with clobbered globals
        # is an infinite loop (INV-75 class).
        rest = s
        while (match(rest, /--(add|remove)-label[ \t=]+(["'\''][a-z][a-z0-9-]*["'\'']|[a-z][a-z0-9-]*)/)) {
          st = RSTART; ln = RLENGTH
          tok = substr(rest, st, ln)
          # The label operand is the trailing token after the flag+separator.
          sub(/^--(add|remove)-label[ \t=]+/, "", tok)
          lbl = strip_quotes(tok)
          print lbl "\t" file ":" startno
          rest = substr(rest, st + ln)
        }
      }
      /^[[:space:]]*#/ { next }   # skip comment lines (a prose mention is not a write site — symmetric with collect_movements)
      { stripped = $0; sub(/\\[[:space:]]*$/, "", stripped) }
      cont == 0 { startno = NR; buf = stripped }
      cont == 1 { buf = buf " " stripped }
      /\\[[:space:]]*$/ { cont = 1; next }
      { scan(buf); cont = 0 }
    ' "$path"
  done
}

# P1.1 — variable-valued label writes (`--add-label "$var"` / `--remove-label $x`)
# are a hard FAIL, NOT a NOTE. A variable write can introduce an undeclared label
# the literal-site checks (C.1–C.5) never see, so leaving it as a green "audit
# this" pointer left the AC unmet. The ONLY legitimate variable writes are the two
# allowlisted sites in spec-codesite-map.json.variable_write_allowlist (the
# label_swap helper definition, whose $remove/$add come from validated literal
# callers; and the hygiene_strip_residual_labels loop over a hard-coded declared
# label list). A variable write whose enclosing function is NOT allowlisted (for
# its file) fails LOUD naming the site.
#
# Enclosing-function attribution: awk tracks brace DEPTH so `fn` is the function a
# write is lexically INSIDE, and resets to empty at the function's closing brace.
# A write attributed to "" (top level, or after a function closed) can never be
# allowlisted — it MUST fail. The allowlist match is EXACT (the allowlist anchor is
# normalized to a bare function name and compared `=`, never a glob), so neither a
# top-level write (empty fn) nor a prefix-named function (`label` vs `label_swap`)
# can spuriously match. (Both were the pr-review-flagged glob bypasses.)
#
# Detected write forms: `--add/remove-label` followed by a `$` token, either
# whitespace-separated or `=`-joined, quoted or bare (`--add-label "$x"`,
# `--add-label $x`, `--add-label="$x"`, `--add-label=$x`; TC-050 pins the `=`
# form), INCLUDING when the write is split across backslash-continuation lines —
# the detector joins continuations into a logical line first (TC-053). The
# LITERAL-site scanners (C.1/C.2/C.5) accept the same `[ \t=]+` separator AND both
# quote styles (`["'\'']`), so a literal `--add-label="frobnicate"` (TC-052) and a
# single-quoted `--add-label 'frobnicate'` (TC-054) are scanned too — every write
# style is covered, none can bypass the gate.
# Accepted scanner boundaries (NOT statically detectable without a real
# bash parser, and none present in the four PIPELINE_FILES today):
#   1. a flag whose text is itself held in a variable
#      (`f=--add-label; gh issue edit "$n" $f "$lbl"`); and
#   2. an UNBALANCED brace inside a string literal *inside an allowlisted
#      function* — the line-by-line brace counter would keep that function's
#      depth elevated past its real close and mis-attribute a LATER write to it.
#      Stripping strings before counting was tried and REGRESSED real attribution
#      (the files are brace-balanced file-wide only WITH their string braces; see
#      the braces() note). This is latent: no allowlisted fn carries an unbalanced
#      string brace today, and TC-034 pins that the real allowlisted writes stay
#      correctly attributed. A robust fix needs a bash-aware tokenizer (out of
#      scope for this CI-checker; the gated runtime reconciler would supersede it).
check_variable_writes() {
  local f path fn lineno text allowlisted norm a
  # Precompute the allowlisted bare function names per file (exact-match set).
  for f in "${PIPELINE_FILES[@]}"; do
    path="$SCRIPTS_DIR/$f"
    [ -f "$path" ] || continue
    while IFS=$'\t' read -r lineno fn text; do
      [ -z "$lineno" ] && continue
      # awk emits the literal token "(top-level)" for an unattributable write so the
      # middle field is NEVER empty — a `\t\t` would otherwise collapse under
      # `IFS=$'\t' read` (field 2 swallows field 3; see resolve_anchor's note), and
      # a top-level write must NOT match the allowlist. Map it back to empty here.
      [ "$fn" = "(top-level)" ] && fn=""
      # Allowed iff fn is non-empty AND exactly matches an allowlist anchor's bare
      # function name for this file.
      allowlisted=""
      if [ -n "$fn" ]; then
        while IFS= read -r a; do
          # Normalize the allowlist anchor to a bare function name: drop a trailing
          # "() {" / "()" so `label_swap() {` and `hygiene_strip_residual_labels()`
          # both reduce to the bare name, then compare EXACTLY.
          norm="${a%%(*}"
          if [ "$fn" = "$norm" ]; then allowlisted="HIT"; break; fi
        done < <(jq -r --arg f "$f" '.variable_write_allowlist.sites[]? | select(.file == $f) | .anchor' "$CODESITE_MAP" 2>/dev/null)
      fi
      if [ "$allowlisted" = "HIT" ]; then
        info "allowlisted variable label write at $f:$lineno (fn $fn) — $text"
      else
        fail "variable label write at $f:$lineno (fn ${fn:-<top-level>}) is NOT allowlisted: '$text' — a variable-valued --add/--remove-label can introduce an undeclared label invisibly. Use a literal label_swap/--add-label, or add this site to spec-codesite-map.json.variable_write_allowlist if it is provably safe (values come from a hard-coded declared-label set)."
      fi
    done < <(awk '
      # Net brace delta on a line (crude but adequate for these brace-balanced,
      # well-indented bash files): +1 per "{", -1 per "}". NOTE: string/comment
      # braces are counted raw. The four pipeline files are brace-balanced FILE-WIDE
      # *including* their ~100 brace-in-string lines (JSON jq patterns etc.), so the
      # running depth returns to 0 at each top-level boundary and function entry
      # (depth == 0) fires correctly — verified by TC-034 (real label_swap/hygiene
      # writes are attributed + allowlisted). Stripping strings was TRIED and
      # REGRESSED this: the per-region string braces are NOT individually balanced,
      # so blanking them drove depth negative at label_swap() and mis-attributed its
      # legitimate writes to <top-level>. The brace-in-string fail-open the pr-review
      # flagged is therefore LATENT only (no allowlisted fn carries an unbalanced
      # string-brace today); TC-034 pins that the real allowlisted writes stay
      # correctly attributed even though the file is full of brace-in-string lines.
      function braces(line,   n, i, c) { n = 0; for (i = 1; i <= length(line); i++) { c = substr(line, i, 1); if (c == "{") n++; else if (c == "}") n-- } return n }
      # Strip a trailing backslash-continuation so the join reads as one logical line.
      function decont(line) { sub(/\\[[:space:]]*$/, "", line); return line }
      # Enter a function at a top-level `name() {`; remember the depth it opened at.
      # (Brace tracking + function entry are PER PHYSICAL LINE so attribution is exact.)
      /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ && depth == 0 { fn = $0; sub(/\(\).*/, "", fn); fndepth = depth }
      {
        # A variable-valued label flag: --add/remove-label followed by a $ token,
        # either whitespace-separated (--add-label "$x" / --add-label $x) or the
        # equals form (--add-label="$x" / --add-label=$x). The write may be SPLIT
        # across backslash-continuation lines (`gh issue edit "$n" \` ⏎ `--add-label \`
        # ⏎ `"$evil"`), so the regex runs on the JOINED logical line, not $0 — else a
        # continuation-split variable write bypasses the ban (reviewer [P1]). The
        # logical-line START line/fn (captured when its first physical line is read)
        # is what we attribute + report. (A flag held in a variable, e.g. $flag with
        # a "$lbl", is NOT statically detectable and is a documented scanner boundary.)
        #
        # A comment PHYSICAL line is excluded from the write buffer ENTIRELY: a
        # trailing `\` on a `#`-comment does NOT continue the line in real bash (it is
        # comment text), so a comment must neither START nor EXTEND the logical line —
        # else `# ...\` ⏎ <real var write> would join into a buffer that fails the
        # leading-`#` test and the genuine write is swallowed (a bypass that the prior
        # join introduced; collect_writes was already immune via its own comment skip).
        # Brace tracking below still runs on comment lines (the raw counter relies on
        # their string-braces for file-wide balance — see the braces() note).
        if ($0 ~ /^[[:space:]]*#/) {
          # Comment line: it is never part of a write. A trailing backslash on a
          # comment is comment text (bash does not continue a # line), so a comment
          # neither starts nor extends the logical write buffer — drop any open run.
          vcont = 0
        } else {
          if (vcont == 0) { vstart = NR; vfn = (fn == "" ? "(top-level)" : fn); vbuf = decont($0) }
          else            { vbuf = vbuf " " decont($0) }
          if ($0 ~ /\\[[:space:]]*$/) { vcont = 1 }
          else {
            vcont = 0
            # Logical line complete (defensive leading-`#` re-check; the buffer can
            # only start on a non-comment line now, but keep the guard symmetric).
            if (vbuf !~ /^[[:space:]]*#/ && vbuf ~ /--(add|remove)-label[[:space:]=]+"?\$/) {
              t = vbuf; sub(/^[[:space:]]+/, "", t)
              # "(top-level)" sentinel keeps the middle field non-empty so `read` can"t
              # collapse a \t\t (a top-level write must stay unallowlisted).
              print vstart "\t" vfn "\t" t
            }
          }
        }
        depth += braces($0)
        # Closed back to (or below) the depth the function opened at → leave it.
        if (fn != "" && depth <= fndepth) fn = ""
      }
    ' "$path")
  done
}

# --- C.2 movement -----------------------------------------------------------
# The declared MOVEMENT universe: for each transition, the SET of labels it
# removes and the SET it adds, normalized as "<sorted-removes-csv>|<sorted-adds-csv>".
# A code write site's movement must equal one of these. (Empty sides are legal —
# an add-only or remove-only write has an empty removes/adds component.)
declared_movements() {
  jq -r '
    .transitions[]
    | { rem: ([.actions[] | select(startswith("remove-label:")) | sub("^remove-label:";"")] | sort),
        add: ([.actions[] | select(startswith("add-label:"))    | sub("^add-label:";"")]    | sort) }
    | (.rem | join(",")) + "|" + (.add | join(","))
  ' "$TRANSITIONS" | sort -u
}

# Collect the MOVEMENT signature of every literal label-write SITE, one record
# per logical write site: "<sorted-removes-csv>|<sorted-adds-csv>\t<file>:<lineno>".
# Two write forms, same as collect_writes:
#   1. label_swap "$issue_num" "<remove>" "<add>"  → operands 2 (remove) and 3
#      (add); either may be "" (add-only / remove-only). Operand 1 ("$issue_num")
#      is skipped by position — that is why this matches ALL quoted tokens
#      (/"[^"]*"/), not just lowercase-label tokens: it must count past the
#      variable operand. An empty operand contributes nothing to its side.
#   2. gh issue edit … --remove-label "A" [--remove-label "B"] --add-label "C"
#      on one logical line → removes={A,B}, adds={C}.
# Comment lines are skipped (a prose "→ label_swap → in-progress" in a doc-block
# is not a write site). Continuation lines are joined first (M2), so a multi-flag
# edit split across physical lines is read as one movement. The label sets are
# sorted in awk so {reviewing,autonomous} compares equal to the table's
# {autonomous,reviewing} regardless of source order.
collect_movements() {
  local f path
  for f in "${PIPELINE_FILES[@]}"; do
    path="$SCRIPTS_DIR/$f"
    [ -f "$path" ] || continue
    awk -v file="$f" '
      # Sort a CSV set and drop empty members; returns the sorted CSV. Sorting
      # makes {reviewing,autonomous} compare equal to {autonomous,reviewing}.
      function norm(csv,   n, a, i, j, t, s) {
        n = split(csv, a, ",")
        for (i = 1; i <= n; i++)
          for (j = i + 1; j <= n; j++)
            if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
        s = ""
        for (i = 1; i <= n; i++)
          if (a[i] != "") s = (s == "" ? a[i] : s "," a[i])
        return s
      }
      # Emit one movement record for logical line s. Saves RSTART/RLENGTH into
      # locals before any nested call (norm calls split(), not match(), so the
      # globals survive — but the discipline matches collect_writes/INV-75).
      function emit_movement(s,   rest, st, ln, tok, lbl, rem, add, i, isrem) {
        rem = ""; add = ""
        # Form 1 (label_swap) AND Form 3 (itp_transition_state, the INV-87 ITP
        # transition verb) are POSITIONAL and structurally identical: token #1 =
        # issue number (ignored), #2 = remove label, #3 = add label. A variable
        # operand (a dollar-var) is NOT a static label, so skip it: a fully
        # variable-arg call (such as the label_swap delegation
        # itp_transition_state DOLLARissue_num DOLLARremove DOLLARadd in
        # lib-dispatch.sh) emits no movement; those labels come from the LITERAL
        # label_swap callers this same scanner reads as their own Form-1 sites.
        # LIMITATION (intentional): the positional loop matches DOUBLE-quoted
        # operands only; single-quoted / bare itp_transition_state args escape
        # movement coverage. The repo is uniformly double-quoted (38/38 label
        # operands) and #296 migrations emit double-quoted positionals, so this
        # is sufficient. If the convention ever changes, widen the token regex to
        # a quoted-or-bare alternative like Form 2 and add tests.
        if (s ~ /label_swap[ \t]/ || s ~ /itp_transition_state[ \t]/) {
          rest = s; i = 0
          while (match(rest, /"[^"]*"/)) {
            st = RSTART; ln = RLENGTH
            tok = substr(rest, st + 1, ln - 2); rest = substr(rest, st + ln); i++
            # Skip variable operands ($-leading) — only literal labels are movements.
            if (substr(tok, 1, 1) == "$") tok = ""
            if (i == 2 && tok != "") rem = tok
            if (i == 3 && tok != "") add = tok
          }
          # Only emit when at least one literal label was found; a fully-variable
          # call (no static movement) declares nothing.
          if (rem != "" || add != "") print norm(rem) "|" norm(add) "\t" file ":" startno
          return
        }
        # gh issue edit form: gather every --add/remove-label LITERAL on the line.
        # Separator is whitespace OR "=" (--add-label="x" scanned too); the literal
        # may be DOUBLE-quoted, SINGLE-quoted, OR BARE (--add-label frobnicate;
        # reviewer [BLOCKING]). The bare alternative never matches a variable write
        # ($x / "$x") — those start with $ or a quote.
        rest = s
        while (match(rest, /--(add|remove)-label[ \t=]+(["'\''][a-z][a-z0-9-]*["'\'']|[a-z][a-z0-9-]*)/)) {
          # Save the flag+literal span BEFORE any nested op clobbers RSTART/RLENGTH
          # (INV-75: advancing rest with stale globals is an infinite loop).
          st = RSTART; ln = RLENGTH; tok = substr(rest, st, ln)
          isrem = (tok ~ /--remove-label/)
          # Isolate the label operand: strip the flag+separator, then the optional
          # surrounding quote (a bare operand has none).
          sub(/^--(add|remove)-label[ \t=]+/, "", tok)
          if (substr(tok, 1, 1) == "\"" || substr(tok, 1, 1) == "'\''") lbl = substr(tok, 2, length(tok) - 2)
          else lbl = tok
          if (isrem) rem = (rem == "" ? lbl : rem "," lbl)
          else       add = (add == "" ? lbl : add "," lbl)
          rest = substr(rest, st + ln)
        }
        if (rem != "" || add != "") print norm(rem) "|" norm(add) "\t" file ":" startno
      }
      /^[[:space:]]*#/ { next }   # skip comment lines (prose mentions are not writes)
      { stripped = $0; sub(/\\[[:space:]]*$/, "", stripped) }
      cont == 0 { startno = NR; buf = stripped }
      cont == 1 { buf = buf " " stripped }
      /\\[[:space:]]*$/ { cont = 1; next }
      { if (buf ~ /label_swap[ \t]/ || buf ~ /itp_transition_state[ \t]/ || buf ~ /--(add|remove)-label/) emit_movement(buf); cont = 0 }
    ' "$path"
  done
}

WRITES_TMP="$(mktemp)"
MOVES_TMP="$(mktemp)"
DECLARED_MOVES_TMP="$(mktemp)"
trap 'rm -f "$WRITES_TMP" "$MOVES_TMP" "$DECLARED_MOVES_TMP"' EXIT
collect_writes | sort -u > "$WRITES_TMP"

if [ ! -s "$WRITES_TMP" ]; then
  fail "label-write scan found ZERO write sites in ${PIPELINE_FILES[*]} — the scanner is broken or SCRIPTS_DIR is wrong ($SCRIPTS_DIR)"
fi

UNDECLARED=0
while IFS=$'\t' read -r lbl site; do
  [ -z "$lbl" ] && continue
  if ! is_declared "$lbl"; then
    fail "label '$lbl' is WRITTEN at $site but is NOT declared in transitions.json (add a transition with add-label:$lbl / remove-label:$lbl, or add it to label_vocabulary)"
    UNDECLARED=$((UNDECLARED + 1))
  fi
done < "$WRITES_TMP"

check_variable_writes

if [ "$UNDECLARED" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  n_sites="$(wc -l < "$WRITES_TMP" | tr -d ' ')"
  info "all $n_sites literal label-write sites map to declared labels"
fi

# C.2 — every write SITE's (removes→adds) MOVEMENT is declared by a transition.
# This is what catches a new write that reuses EXISTING labels in an undeclared
# combination (the AC: "a PR adding a new label write without a transitions.json
# entry fails CI"). C.1 alone passes such a write because both labels exist.
declared_movements > "$DECLARED_MOVES_TMP"
collect_movements | sort -u > "$MOVES_TMP"

if [ ! -s "$MOVES_TMP" ]; then
  fail "movement scan found ZERO write sites in ${PIPELINE_FILES[*]} — the scanner is broken or SCRIPTS_DIR is wrong ($SCRIPTS_DIR)"
fi

UNDECLARED_MOVES=0
while IFS=$'\t' read -r sig site; do
  [ -z "$sig" ] && continue
  # grep -Fxq: the signature is a fixed string, full-line match against the
  # declared set. Here-string (not a pipe) for the same SIGPIPE reason as
  # is_declared above.
  if ! grep -Fxq -- "$sig" "$DECLARED_MOVES_TMP"; then
    rem="${sig%%|*}"; add="${sig#*|}"
    fail "label MOVEMENT '${rem:-(none)} -> ${add:-(none)}' is performed at $site but NO transition in transitions.json declares it (every label is known, but this remove→add combination is an undeclared transition — add a transitions.json entry whose actions[] are remove-label:${rem//,/ remove-label:} + add-label:${add//,/ add-label:})"
    UNDECLARED_MOVES=$((UNDECLARED_MOVES + 1))
  fi
done < "$MOVES_TMP"

if [ "$UNDECLARED_MOVES" -eq 0 ] && [ "$FAILED" -eq 0 ]; then
  n_moves="$(wc -l < "$MOVES_TMP" | tr -d ' ')"
  info "all $n_moves label-write movements map to declared transitions"
fi

# ---------------------------------------------------------------------------
# Check C.3 — per-transition CODE-SITE coverage (bidirectional).
# ---------------------------------------------------------------------------
# C.2 (movement) checks that each write site's remove→add SET is declared by
# SOME transition. That is necessary but NOT sufficient: two distinct transitions
# can share one movement, so deleting one of them is invisible to C.2 (the other
# still declares the movement). C.3 closes that gap by pinning every CODE-BEARING
# transition (actor ∉ {maintainer, github} — human/GitHub events have no pipeline
# code site) to a grep-stable code anchor in spec-codesite-map.json, and checking
# the correspondence in BOTH directions:
#   forward  — every code-bearing transition HAS a map entry whose anchor still
#              greps in its file (catches a new untracked transition, or a renamed/
#              removed code site = code drift);
#   reverse  — every map entry's key IS an existing transition id (catches a
#              DELETED transition row whose movement is shared elsewhere — the
#              dispatch-pending-dev-pr-exists repro: removing that row leaves its
#              spec-codesite-map.json entry orphaned → FAIL, even though
#              dispatch-review-aware-reroute-review still declares the same
#              pending-dev→pending-review movement).
# Anchors key on function names + distinguishing literals, NEVER line numbers
# (same robustness contract as Check B's spec-guard-map.json).
echo "=== Check C.3: every code-bearing transition maps to a resolvable code site (bidirectional) ==="

jq -e . "$CODESITE_MAP" >/dev/null 2>&1 || fail "spec-codesite-map.json is not valid JSON"

# The set of transition ids whose label writes live in pipeline CODE (not a human
# or GitHub event). These are exactly the ids that must appear in the map.
TRANS_IDS_TMP="$(mktemp)"
MAP_IDS_TMP="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$WRITES_TMP' '$MOVES_TMP' '$DECLARED_MOVES_TMP' '$TRANS_IDS_TMP' '$MAP_IDS_TMP'" EXIT
jq -r '.transitions[] | select(.actor != "maintainer" and .actor != "github") | .id' "$TRANSITIONS" | sort -u > "$TRANS_IDS_TMP"
jq -r '.code_sites | keys[]' "$CODESITE_MAP" 2>/dev/null | sort -u > "$MAP_IDS_TMP"

# Reverse — an orphaned map entry means its transition row was deleted/renamed.
while IFS= read -r mid; do
  [ -z "$mid" ] && continue
  if ! grep -Fxq -- "$mid" "$TRANS_IDS_TMP"; then
    fail "spec-codesite-map.json maps transition id '$mid' but transitions.json has NO such code-bearing transition (a transition row was deleted or renamed — drop/fix the map entry, or restore the transition). This is the write-SITE coverage gate: a removed row whose movement is still declared elsewhere is caught HERE, not by the movement check."
  fi
done < "$MAP_IDS_TMP"

# Forward — a code-bearing transition with no entry, or an entry whose anchor no
# longer greps, is unmapped/stale code drift.
N_MAPPED=0
while IFS= read -r tid; do
  [ -z "$tid" ] && continue
  entry="$(jq -c --arg t "$tid" '.code_sites[$t] // empty' "$CODESITE_MAP")"
  if [ -z "$entry" ]; then
    fail "code-bearing transition '$tid' (in transitions.json) has NO entry in spec-codesite-map.json — add {\"file\":..., \"anchor\":...} pinning it to its code write site (or, if it is a human/GitHub event, set its actor to maintainer/github)"
    continue
  fi
  csfile="$(jq -r '.file // ""' <<<"$entry")"
  anchor="$(jq -r '.anchor // ""' <<<"$entry")"
  if [ -z "$csfile" ] || [ -z "$anchor" ]; then
    fail "spec-codesite-map.json entry for '$tid' is missing file/anchor"
    continue
  fi
  target="$SCRIPTS_DIR/$csfile"
  if [ ! -f "$target" ]; then
    fail "code-site for '$tid' cites missing file: $csfile"
    continue
  fi
  # Fixed-string grep: the anchor literal must still appear in the cited file.
  if ! grep -Fq -- "$anchor" "$target"; then
    fail "code-site for '$tid' → anchor '$anchor' NOT found in $csfile (the code write site was renamed or removed — update the anchor, or the transition no longer reflects the code)"
  else
    N_MAPPED=$((N_MAPPED + 1))
  fi
done < "$TRANS_IDS_TMP"

if [ "$FAILED" -eq 0 ]; then
  info "all $N_MAPPED code-bearing transitions map to a resolvable code site"
fi

# ---------------------------------------------------------------------------
# Check C.4 — discovered-site reconciliation (the FORWARD site → manifest direction).
# ---------------------------------------------------------------------------
# C.2 checks each discovered site's MOVEMENT is declared by SOME transition;
# C.3 checks each declared transition resolves to a code anchor and that no map
# entry is orphaned. NEITHER iterates the DISCOVERED sites to confirm each is
# ACCOUNTED FOR, so a brand-new site whose movement already exists elsewhere
# (a second `label_swap "$n" "pending-dev" "pending-review"`) slips through both.
# C.4 closes that: the COUNT of literal write sites the scanner finds per
# (file, movement) MUST equal the count declared by the `sites[]` manifest. A new
# site bumps the discovered count above the manifest count → fail; a removed site
# drops below → fail; a (file, movement) discovered with no manifest entry → fail.
# The count is over CODE SITES (not transition rows): one site can back several
# rows (mark_stalled → two stalled transitions), one row can collapse several
# physical paths (dev-trap-noprorfail), so the count is the stable quantity.
echo "=== Check C.4: discovered label-write sites reconcile with the sites[] manifest (per file/movement count) ==="

# Manifest counts: sites[] grouped by "<file> <movement>" → count.
DECLARED_COUNTS_TMP="$(mktemp)"
DISCOVERED_COUNTS_TMP="$(mktemp)"
SITES_TMP="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$WRITES_TMP' '$MOVES_TMP' '$DECLARED_MOVES_TMP' '$TRANS_IDS_TMP' '$MAP_IDS_TMP' '$DECLARED_COUNTS_TMP' '$DISCOVERED_COUNTS_TMP' '$SITES_TMP'" EXIT
# One record per manifest site: "<file>\t<movement>\t<anchor>".
jq -r '(.sites // [])[] | "\(.file)\t\(.movement)\t\(.anchor)"' "$CODESITE_MAP" 2>/dev/null > "$SITES_TMP"
awk -F'\t' '{ c[$1" "$2]++ } END { for (k in c) print k "\t" c[k] }' "$SITES_TMP" | sort > "$DECLARED_COUNTS_TMP"

# Discovered counts: MOVES_TMP rows are "<movement>\t<file>:<lineno>"; regroup as
# "<file> <movement>\t<count>". (Re-derived from MOVES_TMP, NOT sort -u'd away —
# two sites with the same movement on different lines are two distinct records.)
if [ -s "$MOVES_TMP" ]; then
  while IFS=$'\t' read -r sig site; do
    [ -z "$sig" ] && continue
    printf '%s %s\n' "${site%%:*}" "$sig"
  done < "$MOVES_TMP" | sort | uniq -c \
    | while read -r cnt key; do printf '%s\t%s\n' "$key" "$cnt"; done | sort > "$DISCOVERED_COUNTS_TMP"
fi

if [ ! -s "$DECLARED_COUNTS_TMP" ]; then
  fail "spec-codesite-map.json has no sites[] manifest — Check C.4 cannot reconcile discovered sites (populate the sites[] array)"
fi

# Compare the two sorted "<file> <movement>\t<count>" tables key-by-key.
SITE_RECONCILED=1
while IFS=$'\t' read -r key disc; do
  [ -z "$key" ] && continue
  decl="$(grep -F -- "$key"$'\t' "$DECLARED_COUNTS_TMP" | head -1 | cut -f2)"
  if [ -z "$decl" ]; then
    fail "C.4: $disc label-write site(s) for '$key' discovered in the code, but the sites[] manifest declares NONE — a NEW write site (its movement may be declared elsewhere) needs a transitions.json row + a code_sites entry + a sites[] manifest entry"
    SITE_RECONCILED=0
  elif [ "$disc" != "$decl" ]; then
    fail "C.4: '$key' has $disc label-write site(s) in the code but the sites[] manifest declares $decl — a write site was added or removed; update transitions.json + spec-codesite-map.json (code_sites + sites[]) to match"
    SITE_RECONCILED=0
  fi
done < "$DISCOVERED_COUNTS_TMP"

# Reverse: a manifest (file, movement) with no discovered sites means a site was
# removed (or the manifest is stale) — also a drift.
while IFS=$'\t' read -r key decl; do
  [ -z "$key" ] && continue
  if ! grep -Fq -- "$key"$'\t' "$DISCOVERED_COUNTS_TMP"; then
    fail "C.4: the sites[] manifest declares $decl site(s) for '$key' but the scanner found NONE — the write site was removed or renamed; drop the manifest entry (and its transition row + code_sites entry) or restore the site"
    SITE_RECONCILED=0
  fi
done < "$DECLARED_COUNTS_TMP"

if [ "$SITE_RECONCILED" -eq 1 ] && [ "$FAILED" -eq 0 ]; then
  n_groups="$(wc -l < "$DECLARED_COUNTS_TMP" | tr -d ' ')"
  info "all discovered label-write sites reconcile with the sites[] manifest ($n_groups file/movement groups)"
fi

# ---------------------------------------------------------------------------
# Check C.5 — per-site anchor adjacency (concrete-site keying, P1.2).
# ---------------------------------------------------------------------------
# C.4 is a COUNT per (file, movement), so RELOCATING a write within the same file
# (same movement, count unchanged) is invisible — and C.3's transition anchors can
# be a whole function away from the write. C.5 binds each manifest site to a
# CONCRETE location: its `anchor` must (a) grep EXACTLY ONCE in its file (so it
# pins one spot) and (b) have a label-write of its `movement` within ±WINDOW lines.
# Moving the write out of its anchor's neighbourhood (the
# `handle_pending_dev_pr_exists` relocation repro) leaves the anchor with no
# adjacent matching write → fail. Anchors are grep-stable literals, not line
# numbers.
echo "=== Check C.5: every manifest site's anchor is unique and adjacent to a write of its movement ==="
C5_WINDOW=8

# A per-(file) map of "<start-lineno>\t<movement>" for every logical write site,
# reusing collect_movements' continuation-join + comment-skip semantics.
write_lines_for_file() {
  local f="$1" path="$SCRIPTS_DIR/$1"
  [ -f "$path" ] || return 0
  awk '
    function norm(csv,   n, a, i, j, t, s) {
      n = split(csv, a, ",")
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (a[j] < a[i]) { t = a[i]; a[i] = a[j]; a[j] = t }
      s = ""; for (i = 1; i <= n; i++) if (a[i] != "") s = (s == "" ? a[i] : s "," a[i]); return s
    }
    function movement(s,   rest, st, ln, tok, lbl, rem, add, i, isrem) {
      rem = ""; add = ""
      # Form 1 (label_swap) + Form 3 (itp_transition_state, [INV-87]): positional
      # #2=remove #3=add; skip $-variable operands (mirrors emit_movement so C.5
      # binds the same migrated sites C.4 counts).
      if (s ~ /label_swap[ \t]/ || s ~ /itp_transition_state[ \t]/) {
        rest = s; i = 0
        while (match(rest, /"[^"]*"/)) { st = RSTART; ln = RLENGTH; tok = substr(rest, st + 1, ln - 2); rest = substr(rest, st + ln); i++; if (substr(tok, 1, 1) == "$") tok = ""; if (i == 2 && tok != "") rem = tok; if (i == 3 && tok != "") add = tok }
        if (rem != "" || add != "") return norm(rem) "|" norm(add)
        return ""
      }
      rest = s
      while (match(rest, /--(add|remove)-label[ \t=]+(["'\''][a-z][a-z0-9-]*["'\'']|[a-z][a-z0-9-]*)/)) { st = RSTART; ln = RLENGTH; tok = substr(rest, st, ln); isrem = (tok ~ /--remove-label/); sub(/^--(add|remove)-label[ \t=]+/, "", tok); if (substr(tok, 1, 1) == "\"" || substr(tok, 1, 1) == "'\''") lbl = substr(tok, 2, length(tok) - 2); else lbl = tok; if (isrem) rem = (rem == "" ? lbl : rem "," lbl); else add = (add == "" ? lbl : add "," lbl); rest = substr(rest, st + ln) }
      if (rem != "" || add != "") return norm(rem) "|" norm(add)
      return ""
    }
    /^[[:space:]]*#/ { next }
    { stripped = $0; sub(/\\[[:space:]]*$/, "", stripped) }
    cont == 0 { startno = NR; buf = stripped }
    cont == 1 { buf = buf " " stripped }
    /\\[[:space:]]*$/ { cont = 1; next }
    { if (buf ~ /label_swap[ \t]/ || buf ~ /itp_transition_state[ \t]/ || buf ~ /--(add|remove)-label/) { mv = movement(buf); if (mv != "") print startno "\t" mv } cont = 0 }
  ' "$path"
}

C5_OK=1
WLINES_TMP="$(mktemp)"
# shellcheck disable=SC2064
trap "rm -f '$WRITES_TMP' '$MOVES_TMP' '$DECLARED_MOVES_TMP' '$TRANS_IDS_TMP' '$MAP_IDS_TMP' '$DECLARED_COUNTS_TMP' '$DISCOVERED_COUNTS_TMP' '$SITES_TMP' '$WLINES_TMP'" EXIT
C5_CUR_FILE=""
while IFS=$'\t' read -r sfile smv sanchor; do
  [ -z "$sfile" ] && continue
  target="$SCRIPTS_DIR/$sfile"
  if [ ! -f "$target" ]; then
    fail "C.5: site anchor cites missing file: $sfile"; C5_OK=0; continue
  fi
  # (a) anchor grep-unique in the file.
  n_occ="$(grep -Fc -- "$sanchor" "$target")"
  if [ "$n_occ" -eq 0 ]; then
    fail "C.5: site anchor '$sanchor' NOT found in $sfile — the write site was renamed/removed (or the manifest anchor is stale)"; C5_OK=0; continue
  elif [ "$n_occ" -gt 1 ]; then
    fail "C.5: site anchor '$sanchor' is AMBIGUOUS in $sfile ($n_occ matches) — pick a grep-unique literal so it pins ONE write site"; C5_OK=0; continue
  fi
  anchor_line="$(grep -Fn -- "$sanchor" "$target" | head -1 | cut -d: -f1)"
  # (b) a write of this movement within ±WINDOW of the anchor line.
  if [ "$C5_CUR_FILE" != "$sfile" ]; then write_lines_for_file "$sfile" > "$WLINES_TMP"; C5_CUR_FILE="$sfile"; fi
  adj=0
  while IFS=$'\t' read -r wl wmv; do
    [ "$wmv" = "$smv" ] || continue
    d=$(( wl > anchor_line ? wl - anchor_line : anchor_line - wl ))
    [ "$d" -le "$C5_WINDOW" ] && { adj=1; break; }
  done < "$WLINES_TMP"
  if [ "$adj" -ne 1 ]; then
    fail "C.5: site anchor '$sanchor' in $sfile (line $anchor_line) has NO '$smv' label write within ±$C5_WINDOW lines — the write was relocated away from its declared site, or the movement no longer matches. Re-anchor to the write's neighbourhood or update transitions.json + the manifest."
    C5_OK=0
  fi
done < "$SITES_TMP"

if [ "$C5_OK" -eq 1 ] && [ "$FAILED" -eq 0 ]; then
  n_manifest="$(wc -l < "$SITES_TMP" | tr -d ' ')"
  info "all $n_manifest manifest sites are uniquely anchored and adjacent to their write"
fi

# ---------------------------------------------------------------------------
# Check D — retracted-doc drift (#296/B2, #306).
# ---------------------------------------------------------------------------
# A migration that turns a documented "raw `gh` call" into a verb-routed call
# FALSIFIES any normative doc line still asserting it is raw. The pipeline-docs-gate
# only checks that SOME docs/pipeline/*.md changed — it cannot catch stale CONTENT.
# Per CLAUDE.md "docs are authoritative", a surviving false assertion is a drift bug.
#
# Today's retracted assertion: #296/B2 (#306) migrated check_deps_resolved's
# issue-body read behind itp_read_task, so the claim that it "remains a raw
# caller-side `gh` call" (the phrase `remains a raw caller-side`, which occurred
# EXACTLY ONCE in provider-spec.md — only for this read) MUST now be absent. This
# check runs in the SAME `spec-drift` CI job as A/B/C, so the named Spec Drift
# surface enforces the retraction deterministically (#306 review [BLOCKING]).
echo ""
echo "=== Check D: retracted normative provider-spec.md assertions stay retracted (#296/B2) ==="
if [ ! -f "$PROVIDER_SPEC" ]; then
  fail "Check D: provider-spec.md not found at '$PROVIDER_SPEC' — cannot verify the #296/B2 doc retraction"
else
  d_stale="$(grep -nF 'remains a raw caller-side' "$PROVIDER_SPEC" || true)"
  if [ -z "$d_stale" ]; then
    info "provider-spec.md no longer asserts a body read 'remains a raw caller-side' \`gh\` call (#296/B2 retraction holds)"
  else
    while IFS= read -r ln; do
      fail "Check D: stale 'remains a raw caller-side' assertion survives in provider-spec.md:${ln%%:*} — #296/B2 migrated check_deps_resolved's body read behind itp_read_task; retract this line. ($(printf '%s' "$ln" | cut -d: -f2- | sed 's/^[[:space:]]*//' | cut -c1-80)…)"
    done <<< "$d_stale"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "spec-drift: PASS — code and transitions.json are in sync."
  exit 0
else
  echo "spec-drift: FAIL — see the ::error:: lines above for the missing/stale pairs."
  exit 1
fi
