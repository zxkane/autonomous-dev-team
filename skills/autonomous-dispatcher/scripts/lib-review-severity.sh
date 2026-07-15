#!/bin/bash
# lib-review-severity.sh — severity-aware blocking ratchet (issue #449, R1).
#
# The review loop's per-agent classification (`_codex_review_classify_stdout`,
# `_classify_verdict_body`) is binary pass/fail with no severity concept — any
# blocking finding fails the round, forever, regardless of how many rounds have
# already run. On a PR whose finding-space is effectively unbounded (eventual
# consistency, races on destructive paths), every fix legitimately creates the
# surface for the next, lower-probability finding, and the loop never converges.
#
# This lib adds a severity vocabulary (P0-P3) and a pure ratchet decision
# (`shouldBlockFinding`) that loosens the blocking floor as the round number
# increases, PLUS the extraction helpers that read a severity tag out of an
# agent's raw findings text. It does NOT change `_aggregate_review_verdicts`
# (lib-review-aggregate.sh) — the filter here runs BEFORE aggregation and
# demotes a `fail` to `pass` when the highest severity found is below the
# current round's floor, producing the same pass/fail/unavailable/timed-out
# vocabulary aggregation already expects.
#
# Severity vocabulary:
#   P0 — catastrophic (data loss/corruption, security, unrecoverable)
#   P1 — clear correctness/reliability merge blocker
#   P2 — narrower but real correctness/reliability gap
#   P3 — low-severity residual risk or test gap tightly related to the change
#   none — no severity tag found (untagged prose, or a legacy-format body)
#
# Default blocking-floor matrix (round buckets):
#   round 1-2 → P0, P1, P2, P3 all block
#   round 3-4 → P0, P1, P2 block; P3 does not
#   round 5+  → P0, P1 block; P2, P3 do not
#   "none" (untagged) → ALWAYS blocks, at every round — fail-safe: an agent
#   that reports a finding without a severity tag (non-compliant prompt
#   following, or a legacy-format body) must never silently bypass the
#   ratchet by omitting the tag. Only a POSITIVELY identified low-severity
#   tag can ever be demoted.

# shouldBlockFinding <round> <severity>
#
# Pure decision function. rc-boolean contract (mirrors ci_is_green): rc 0 =
# "blocks at this round", rc 1 = "does not block at this round". A
# non-numeric/empty round defaults to 1 (the strictest floor — never silently
# widen the blocking floor on a malformed round value).
shouldBlockFinding() {
  local round="${1:-}" severity="${2:-}"
  [[ "$round" =~ ^[0-9]+$ ]] || round=1

  case "$severity" in
    P0|P1)
      return 0
      ;;
    P2)
      [[ "$round" -le 4 ]] && return 0
      return 1
      ;;
    P3)
      [[ "$round" -le 2 ]] && return 0
      return 1
      ;;
    *)
      # "none" or any unrecognized token — fail-safe, always blocks.
      return 0
      ;;
  esac
}

# _review_extract_highest_severity <text>
#
# Echo the highest-priority severity tag found in <text> — checked in
# P0 > P1 > P2 > P3 order so a body carrying multiple tags reports the most
# severe one. Echoes `none` when no `[P0]`-`[P3]` tag is present at all, OR
# when <text> contains a numbered finding line (`N. ...`) that carries NO
# tag — a per-finding scan, not a whole-body scan: a body with one correctly
# tagged `[P3]` finding and one UNTAGGED finding must not let the tagged
# finding's low severity mask the untagged one (which — per the "none" branch
# below — is fail-safe and always blocks). Without this, a global "highest
# tag found anywhere" scan would report `P3` for that body and demote the
# whole verdict, silently dropping the untagged finding's block at a
# late round.
#
# The numbered-list check applies to the generic post-verdict.sh path and
# the artifact-rendered body (`lib-review-artifact.sh::_verdict_body_from_
# artifact_json`), both of which render findings as `N. ...` lines. A body
# with NO numbered lines at all (the codex free-form capture, whose findings
# are `[Pn] ...` lines with no numbering) falls back to the whole-text scan —
# detecting "an untagged finding" in unstructured prose is not reliably
# possible, so that path keeps the original highest-tag-anywhere behavior
# (unchanged from the codex path's existing classify_stdout gate, which the
# codex prompt already instructs to tag EVERY finding).
#
# Works on ANY findings text: a codex `codex review` stdout capture, or a
# generic numbered-list verdict body. Pure (no I/O beyond grep/awk over the
# argument string); rc 0 always.
_review_extract_highest_severity() {
  local text="${1:-}"
  local _numbered_lines
  _numbered_lines=$(grep -E '^[[:space:]]*[0-9]+\.[[:space:]]' <<<"$text" 2>/dev/null || true)
  if [[ -n "$_numbered_lines" ]]; then
    # Per-finding scan: any numbered line missing a [P0]-[P3] tag → none
    # (fail-safe — an untagged finding must never be masked by a sibling
    # finding's lower, correctly-tagged severity).
    if grep -vE '\[P[0123]\]' <<<"$_numbered_lines" 2>/dev/null | grep -q '.'; then
      printf 'none\n'
      return 0
    fi
    text="$_numbered_lines"
  fi
  if grep -qF '[P0]' <<<"$text" 2>/dev/null; then
    printf 'P0\n'
  elif grep -qF '[P1]' <<<"$text" 2>/dev/null; then
    printf 'P1\n'
  elif grep -qF '[P2]' <<<"$text" 2>/dev/null; then
    printf 'P2\n'
  elif grep -qF '[P3]' <<<"$text" 2>/dev/null; then
    printf 'P3\n'
  else
    printf 'none\n'
  fi
  return 0
}

# _review_apply_severity_filter <verdict> <text> <round>
#
# The pre-aggregation severity filter (R1's "Hook Point"). Consumes ONE
# agent's already-classified verdict token (`pass`|`fail`|`unavailable`|
# `timed-out`) plus its raw findings text and the current review round, and
# echoes the (possibly demoted) verdict token — the SAME vocabulary
# `_aggregate_review_verdicts` already expects, so aggregation itself is
# unchanged.
#
# Only ever DEMOTES `fail` → `pass` (never promotes pass → fail, and never
# touches `unavailable`/`timed-out` — those are launch/timeout outcomes with
# no findings text to score). A `fail` is demoted iff the highest severity tag
# found in <text> does NOT block at <round> per `shouldBlockFinding`. rc 0
# always.
_review_apply_severity_filter() {
  local verdict="${1:-}" text="${2:-}" round="${3:-1}"
  if [[ "$verdict" != "fail" ]]; then
    printf '%s\n' "$verdict"
    return 0
  fi
  local sev
  sev=$(_review_extract_highest_severity "$text")
  if shouldBlockFinding "$round" "$sev"; then
    printf 'fail\n'
  else
    printf 'pass\n'
  fi
  return 0
}

# _review_region_has_terminal_tag <region-text>
#
# rc-boolean (rc 0 = a `[P0]` or `[P1]` literal tag is present somewhere in
# <region-text>; rc 1 = it is not). Pure substring scan — deliberately NOT
# `_review_extract_highest_severity`'s per-finding extraction, which has its
# OWN fail-safe: any numbered `N. ...` line with no `[P0]`-`[P3]` tag
# anywhere collapses the WHOLE scan to `none` (correct for a FINDINGS list,
# [issue #449]'s own fix for a masked untagged finding). `<region-text>`
# (`_codex_review_full_response_region`) is NOT a findings list — it
# includes reasoning/tool-call turns, which routinely contain ordinary
# numbered prose with no severity concept at all (e.g. codex reciting the
# review checklist: "1. Design canvas: found in docs/designs/"). Applying
# the findings-list fail-safe to that prose would collapse the region's
# extraction to `none` for a great many ORDINARY clean reviews — and `none`
# is itself P0/P1-class per this file's own vocabulary — permanently
# defeating corroboration (never demotes, even for a genuinely clean P2-only
# review) far beyond the narrow, accepted residual this fix documents. A
# bare tag-presence scan sidesteps that fail-safe entirely: it only answers
# "is there textual evidence of a terminal-floor tag in the wider region",
# which is exactly the corroboration question, without inheriting a
# fail-safe designed for a different (findings-list) shape of text.
#
# Fail-closed on empty/unset input (rc 0 — treated as "cannot rule out a
# terminal tag") rather than fail-open: this helper's ONLY consumer refuses
# a demotion on rc 0, so an unreadable/empty region text must never silently
# permit a demotion it could not actually verify. In practice this never
# fires on the codex-stdout-fallback lane: `_codex_review_full_response_
# region` shares its header/first-marker validation with the tail helper
# and its own fail-safe returns the ORIGINAL (non-empty) capture whenever
# structure is missing, so a call site that already extracted a real
# severity from the tail always has non-empty region text too.
_review_region_has_terminal_tag() {
  local region_text="${1:-}"
  [[ -n "$region_text" ]] || return 0
  grep -qE '\[P[01]\]' <<<"$region_text" 2>/dev/null
}

# _review_region_terminal_severity <region-text>
#
# Echoes the highest-priority terminal-floor tag (`P0` > `P1`) literally
# present in <region-text>, or `none` if neither appears. Companion to
# `_review_region_has_terminal_tag` for callers that need the SPECIFIC tag
# (e.g. for `AGENT_HIGHEST_SEVERITY` reporting) rather than a bare
# yes/no — callers should gate on `_review_region_has_terminal_tag` first;
# this function's `none` fall-through exists only so a direct call is still
# well-defined, not as an invitation to skip the gate. Pure; rc 0 always.
_review_region_terminal_severity() {
  local region_text="${1:-}"
  if grep -qF '[P0]' <<<"$region_text" 2>/dev/null; then
    printf 'P0\n'
  elif grep -qF '[P1]' <<<"$region_text" 2>/dev/null; then
    printf 'P1\n'
  else
    printf 'none\n'
  fi
  return 0
}

# _review_apply_severity_filter_corroborated <verdict> <tail-text> <region-text> <round>
#
# Issue #490: the codex-stdout-fallback lane's ONLY input to
# `_review_apply_severity_filter` is `<tail-text>` — the structurally
# stripped text strictly after the LAST turn marker
# (`_codex_review_strip_prompt_echo`, [INV-132]). Final-response content that
# QUOTES tool/reviewed-file output can legitimately contain a line of the
# exact turn-marker shape (column-0, exact word, unfenced,
# blank-line-preceded); such a quoted line wins the LAST-marker search and
# discards every finding before it, including a genuine `[P0]`/`[P1]`. Three
# prior hardening rounds narrowed the marker heuristic itself and each
# produced the same adjacent hole — an unstructured text interleave has no
# textual marker discipline with a floor. The fix changes the demotion
# SEMANTICS instead: require agreement between two independent scans before
# ever trusting a demotion on this lane.
#
# `<tail-text>` is the same narrow, LAST-marker-bounded text
# `_review_apply_severity_filter` already scores (`S_tail`).
# `<region-text>` is the WIDER region from the FIRST codex-role turn marker
# to EOF — every codex-role turn (reasoning, tool-call, AND final-response
# turns), never just the final response
# (`_codex_review_full_response_region`, `adapters/codex.sh`).
#
# Behavior: identical to `_review_apply_severity_filter` EXCEPT when it is
# about to demote (S_tail does not block at <round>): in that case, ALSO
# require `_review_region_has_terminal_tag` to be FALSE for `<region-text>`.
# If a `[P0]`/`[P1]` tag IS present in the region, the demotion is refused —
# the agent's verdict stays `fail` for this round — because a genuine
# terminal-floor finding is structurally guaranteed to be somewhere in the
# wider region (the region starts at the FIRST codex-role turn, immediately
# after the echoed prompt — nothing on this lane can ever precede it, so a
# quoted marker deeper in the transcript can only ever EXCLUDE a real
# finding from the narrower tail, never from this region).
#
# Consequence — never a false PASS, sometimes an extra non-converging round:
#   - the hijack shape: S_tail=P2 (the discarded [P1] sits before the quoted
#     marker), region contains a literal `[P1]` → refused → stays `fail`
#     (fail-closed; the scenario this fix exists for).
#   - a clean P2-only capture: S_tail=P2, no `[P0]`/`[P1]` tag anywhere in
#     the region (even if the region's reasoning turns contain untagged
#     numbered prose — irrelevant to the bare tag scan) → corroborated →
#     demotes normally (no over-correction).
#   - documented residual: a reasoning/tool-trace turn that ITSELF quotes a
#     P0/P1 tag (e.g. codex reading a PRIOR review comment via `gh`, which
#     quoted a `[P1]`) also trips the region's tag scan even when the actual
#     final response is only P2/P3 — demotion is suppressed for THAT round
#     too. This is the safe direction (the loop continues / eventually stalls
#     to an operator via INV-127), never a false PASS — accepted rather than
#     chased with a fourth heuristic rung (out of scope per issue #490).
_review_apply_severity_filter_corroborated() {
  local verdict="${1:-}" tail_text="${2:-}" region_text="${3:-}" round="${4:-1}"
  if [[ "$verdict" != "fail" ]]; then
    printf '%s\n' "$verdict"
    return 0
  fi
  local sev_tail
  sev_tail=$(_review_extract_highest_severity "$tail_text")
  if shouldBlockFinding "$round" "$sev_tail"; then
    printf 'fail\n'
    return 0
  fi
  # About to demote (sev_tail alone does not block at this round — in
  # practice always P2/P3, since P0/P1/"none" always block via
  # shouldBlockFinding's own case arms and would have returned above).
  # Corroborate against the wider region before trusting it.
  if _review_region_has_terminal_tag "$region_text"; then
    printf 'fail\n'
  else
    printf 'pass\n'
  fi
  return 0
}

# _review_highest_severity_corroborated <tail-text> <region-text> <round>
#
# The severity counterpart to `_review_apply_severity_filter_corroborated`
# — echoes the token `AGENT_HIGHEST_SEVERITY[i]` should record for a
# codex-stdout-fallback agent, mirroring that function's own branch
# structure (issue #490, pr-test-analyzer finding) so the two never
# disagree about which text drove a decision:
#
#   - `<tail-text>`'s own severity already blocks at `<round>` (P0, P1,
#     "none", or a P2/P3 within its blocking rounds) → echo THAT severity.
#     No corroboration was consulted for this agent's verdict, so nothing
#     from the region should be attributed to it.
#   - Otherwise (a demotion was evaluated): if the region carries a literal
#     `[P0]`/`[P1]` tag (the demotion was REFUSED), echo the region's own
#     terminal tag (`_review_region_terminal_severity`) — this is the ONLY
#     case where the region's severity, not the tail's, must be reported:
#     `AGENT_HIGHEST_SEVERITY` feeds [INV-127]'s `_aggregate_has_p0p1_fail`
#     gate, and that gate must see P0/P1-class evidence for a refused
#     demotion or the round-cap breaker can never trip on this lane —
#     silently turning the documented "eventually stalls to an operator"
#     residual into an unbounded loop instead.
#   - Otherwise (the demotion was corroborated, verdict → `pass`) → echo
#     `<tail-text>`'s severity. The verdict pair `_aggregate_has_p0p1_fail`
#     reads is `(pass, <this>)`, which its own case arms never treat as
#     fail-relevant regardless of the value, so this choice is cosmetic
#     (log-line/body-render text) — but the tail's own P2/P3 is still the
#     ACCURATE description of what was found, whereas the region's severity
#     could over-report (see `_review_region_has_terminal_tag`'s own
#     documentation of why the region must never be scored with the full
#     per-finding extractor).
#
# Pure; rc 0 always.
_review_highest_severity_corroborated() {
  local tail_text="${1:-}" region_text="${2:-}" round="${3:-1}"
  local sev_tail
  sev_tail=$(_review_extract_highest_severity "$tail_text")
  if shouldBlockFinding "$round" "$sev_tail"; then
    printf '%s\n' "$sev_tail"
    return 0
  fi
  if _review_region_has_terminal_tag "$region_text"; then
    _review_region_terminal_severity "$region_text"
  else
    printf '%s\n' "$sev_tail"
  fi
  return 0
}

# _review_severity_prompt_block <round>
#
# Renders the shared severity-tagging instruction text injected into BOTH the
# codex prompt branch and the generic post-verdict.sh instruction block
# (R1's "extend both existing paths, not just codex's"). Defines all four
# severity tags and gives round-1-vs-round>1 wording: round 1 asks for
# exhaustive enumeration; round>1 asks the agent to re-verify existing
# blocking findings first and states explicitly that a newly-discovered
# finding below the current round's floor is expected to be reported as a
# non-blocking note, not omitted (R1's "avoid any wording that could be read
# as 'do not look for new problems'"). Pure text rendering — no I/O. rc 0
# always.
_review_severity_prompt_block() {
  local round="${1:-1}"
  [[ "$round" =~ ^[0-9]+$ ]] || round=1

  local floor_desc
  if [[ "$round" -le 2 ]]; then
    floor_desc="P0, P1, P2, and P3 all block this round."
  elif [[ "$round" -le 4 ]]; then
    floor_desc="P0, P1, and P2 block this round; a P3 finding is reported as a non-blocking note (still visible to the operator) but does NOT fail the review."
  else
    floor_desc="Only P0 and P1 block this round; a P2 or P3 finding is reported as a non-blocking note (still visible to the operator) but does NOT fail the review."
  fi

  cat <<SEVERITY_BLOCK
Tag EACH finding with its severity, inline, using EXACTLY one of these four
markers (this is review round ${round}):

- \`[P0]\` — catastrophic: data loss/corruption, security, unrecoverable. Always blocks.
- \`[P1]\` — a clear correctness/reliability merge blocker. Always blocks.
- \`[P2]\` — a narrower but real correctness/reliability gap.
- \`[P3]\` — a low-severity residual risk or test gap tightly related to the change.

Style/doc/general suggestions are never tagged and never block.

This round's blocking floor: ${floor_desc}

$(if [[ "$round" -le 1 ]]; then
cat <<'ROUND1'
Enumerate findings EXHAUSTIVELY this round — do not stop at the first few or
rank by only the top-N; this is the first pass and later rounds will assume
you already covered the surface thoroughly.
ROUND1
else
cat <<'ROUNDN'
Re-verify each EXISTING blocking finding first — confirm it is still present
before re-reporting it. Still look for NEW problems: if you find one below
this round's blocking floor (e.g. a P3 at round 5), REPORT it as a
non-blocking note — do NOT omit it just because it will not block this
round.
ROUNDN
fi)
SEVERITY_BLOCK
}
