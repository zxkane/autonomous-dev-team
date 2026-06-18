#!/bin/bash
# gen-state-machine.sh — issue #236, executable-spec gate (CI-checker half).
#
# Generates the mermaid stateDiagram-v2 block in docs/pipeline/state-machine.md
# FROM docs/pipeline/transitions.json, so the hand-drawn diagram can never drift
# from the transition table again. The diagram lives inside a marker-delimited
# region; everything outside the markers is preserved byte-for-byte.
#
# This is a CI / dev tool. It is NOT sourced or executed by any dispatch-time
# wrapper, so a missing per-project symlink cannot crash a wrapper (unlike the
# lib-*.sh files the wrappers `source`). It depends only on jq + coreutils, so
# it runs on bare ubuntu-latest with no credentials.
#
# Modes:
#   gen-state-machine.sh            Rewrite the marker region in place.
#   gen-state-machine.sh --check    Regenerate to a temp file and diff against
#                                   the committed doc; exit non-zero on any drift
#                                   (prints a unified diff). Never mutates the doc.
#   gen-state-machine.sh --stdout   Print the generated marker region only.
#
# Options:
#   --transitions <path>   Override the transitions.json path (default: repo doc).
#   --doc <path>           Override the state-machine.md path (default: repo doc).
#
# Idempotence: running without --check twice is a no-op (the second run produces
# a byte-identical region). The unit test (tests/unit/test-spec-drift.sh) pins it.
#
# Marker contract (must appear exactly once each in the doc):
#   <!-- BEGIN GENERATED: state-machine ... -->
#   ```mermaid
#   ... generated ...
#   ```
#   <!-- END GENERATED: state-machine -->

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# scripts/ lives at <root>/skills/autonomous-dispatcher/scripts; the root is 3 up.
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

TRANSITIONS="$PROJECT_ROOT/docs/pipeline/transitions.json"
DOC="$PROJECT_ROOT/docs/pipeline/state-machine.md"

BEGIN_MARKER='<!-- BEGIN GENERATED: state-machine — edit docs/pipeline/transitions.json + run scripts/gen-state-machine.sh; do NOT hand-edit between the markers -->'
END_MARKER='<!-- END GENERATED: state-machine -->'

MODE="write"
while [ $# -gt 0 ]; do
  case "$1" in
    --check)       MODE="check" ;;
    --stdout)      MODE="stdout" ;;
    --transitions) TRANSITIONS="$2"; shift ;;
    --doc)         DOC="$2"; shift ;;
    -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "gen-state-machine.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || { echo "gen-state-machine.sh: jq is required" >&2; exit 3; }
[ -f "$TRANSITIONS" ] || { echo "gen-state-machine.sh: transitions file not found: $TRANSITIONS" >&2; exit 3; }

# ---------------------------------------------------------------------------
# Render the mermaid block (between, but not including, the BEGIN/END markers)
# from transitions.json. The order of edges follows the table order, so editing
# transitions.json is the ONLY way to change the diagram — which is the point.
# ---------------------------------------------------------------------------
render_region() {
  # Header + a blank line, then each transition's mermaid edge verbatim, then
  # the note blocks. jq emits the body; we wrap it in the fenced code block.
  local body
  body="$(jq -r '
    .diagram.header,
    "",
    (.transitions[].mermaid),
    "",
    (
      .diagram.notes[]?
      | "    note \(.side) of \(.of)",
        (.lines[] | "        \(.)"),
        "    end note",
        ""
    )
  ' "$TRANSITIONS")"
  # Strip a single trailing blank line jq leaves after the last note block so
  # the output is stable regardless of whether notes are present.
  printf '%s\n' "$BEGIN_MARKER"
  printf '```mermaid\n'
  # Remove trailing blank lines from body, then re-add exactly one newline.
  printf '%s\n' "$body" | sed -e :a -e '/^\s*$/{$d;N;ba}'
  printf '```\n'
  printf '%s\n' "$END_MARKER"
}

# ---------------------------------------------------------------------------
# Splice the rendered region into the doc, preserving everything outside the
# markers. Uses awk so no temp ordering hazards; reads the rendered region from
# a file descriptor to avoid quoting issues.
# ---------------------------------------------------------------------------
splice_doc() {
  local region_file="$1"
  [ -f "$DOC" ] || { echo "gen-state-machine.sh: doc not found: $DOC" >&2; exit 3; }
  awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v regionfile="$region_file" '
    BEGIN {
      # Read the replacement region into a single string.
      region = ""
      while ((getline line < regionfile) > 0) region = region line "\n"
      close(regionfile)
      n_begin = 0; n_end = 0
    }
    # An END seen before any BEGIN is out-of-order — fail loud rather than
    # silently mis-splice (the region would be classified as "outside").
    $0 == end && n_begin == 0 { n_end++; reversed = 1; next }
    $0 == begin { n_begin++; printf "%s", region; inside = 1; next }
    $0 == end   { n_end++; inside = 0; next }
    inside { next }
    { print }
    END {
      if (n_begin != 1 || n_end != 1 || reversed) {
        print "gen-state-machine.sh: expected exactly one BEGIN then one END marker (in order), found begin=" n_begin " end=" n_end (reversed ? " (END before BEGIN)" : "") > "/dev/stderr"
        exit 9
      }
    }
  ' "$DOC"
}

REGION_TMP="$(mktemp)"
trap 'rm -f "$REGION_TMP"' EXIT
render_region > "$REGION_TMP"

case "$MODE" in
  stdout)
    cat "$REGION_TMP"
    ;;
  write)
    NEW_TMP="$(mktemp)"
    splice_doc "$REGION_TMP" > "$NEW_TMP"
    mv "$NEW_TMP" "$DOC"
    echo "gen-state-machine.sh: regenerated mermaid region in $DOC"
    ;;
  check)
    NEW_TMP="$(mktemp)"
    if ! splice_doc "$REGION_TMP" > "$NEW_TMP" 2>"$NEW_TMP.err"; then
      cat "$NEW_TMP.err" >&2
      rm -f "$NEW_TMP" "$NEW_TMP.err"
      exit 9
    fi
    rm -f "$NEW_TMP.err"
    if diff -u "$DOC" "$NEW_TMP" >/dev/null 2>&1; then
      echo "gen-state-machine.sh: OK — state-machine.md mermaid is in sync with transitions.json"
      rm -f "$NEW_TMP"
      exit 0
    else
      echo "::error::state-machine.md mermaid has DRIFTED from transitions.json." >&2
      echo "Regenerate with: scripts/gen-state-machine.sh" >&2
      echo "--- committed state-machine.md" >&2
      echo "+++ regenerated from transitions.json" >&2
      diff -u "$DOC" "$NEW_TMP" >&2 || true
      rm -f "$NEW_TMP"
      exit 1
    fi
    ;;
esac
