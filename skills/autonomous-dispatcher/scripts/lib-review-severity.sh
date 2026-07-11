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
