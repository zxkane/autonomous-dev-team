# Fix mermaid layout error in dev-agent-flow.md

## Problem

After PR #66 merged, `docs/pipeline/dev-agent-flow.md` viewed on github.com (main branch) shows two empty mermaid boxes with an error message: *"Could not find a suitable point for the given distance"*. This is a runtime layout error from mermaid's d3-curve module — different from the parse errors caught and fixed during PR-66 review.

The same blocks rendered fine on the PR head before merge — likely a difference in viewscreen.githubusercontent.com's mermaid build / cache behavior between feature branches and main.

## Root cause hypothesis (informed but not confirmed)

The error is from mermaid 10.x's edge-label-position-on-curve calculation. Two things in the current blocks are known triggers in mermaid issue trackers:

1. **`<br/>` inside `sequenceDiagram` message text.** The Lifecycle block has one such case:
   ```
   D->>W: nohup autonomous-dev.sh --issue N --mode new<br/>(or --mode resume --session ID)
   ```
   Mermaid sequenceDiagram supports `<br/>` in messages, but the layout pass that places the message label on the arrow can fail to find a valid anchor when the label is multi-line on a particular arrow length.

2. **Multiple `<br/>` in a single flowchart `[]` node label, especially the tall `to_dev_no_pr` node.**
   ```
   to_dev_no_pr[comment 'exited 0 but no PR'<br/>remove in-progress<br/>add pending-dev]
   ```
   Three lines of label text in one node, plus hyphenated terms, gives the layout engine a label box whose curve-anchor computation may fail to find a "suitable point" along its incoming edge.

I am not 100% certain which one is the trigger — mermaid's error doesn't pinpoint the offending block. Fix is to rewrite both, since a single PR cycle on github.com is the only way to verify.

## Fix

**Block 1 (sequenceDiagram, "Lifecycle")**: replace the one `<br/>` in message text with a parenthetical on the same line, accepting a slightly long message. Sequence diagram horizontal width can absorb it; the layout error path is specifically about *vertical* label placement on the message arrow.

**Block 2 (flowchart, "Exit trap")**: collapse multi-line node labels to single lines. Use word-spacing instead of explicit line breaks. The flowchart still reads clearly because the node ID + the surrounding edges convey the structure.

Specifically:

- `to_dev_no_pr[comment 'exited 0 but no PR'<br/>remove in-progress<br/>add pending-dev]` → `to_dev_no_pr[no PR exited 0 — to pending-dev]`
- `to_review[remove in-progress<br/>remove pending-dev<br/>add pending-review]` → `to_review[to pending-review]`
- `to_dev_fail[remove in-progress<br/>add pending-dev]` → `to_dev_fail[to pending-dev]`
- The `enter([trap fires<br/>exit_code captured])` and `refresh[refresh GH App token<br/>just in case]` and `session_report[post Agent Session Report<br/>session_id, exit_code, mode, log path]` get similar single-line treatment.

The information lost from the labels is restated in the prose immediately after the diagram (the existing "Trap contract details" section already does this), so no semantic loss.

## Validation

1. Push branch to GitHub.
2. View `https://github.com/zxkane/autonomous-dev-team/blob/<sha>/docs/pipeline/dev-agent-flow.md` via chrome-devtools MCP.
3. Confirm both mermaid blocks render as actual diagrams (no empty box, no error overlay, no parse error text).
4. If error persists, suspect block 1 (sequenceDiagram with `<br/>` in message) and rewrite that one too.

## Lesson for CONTRIBUTING.md

This is a 4th mermaid landmine to add to the existing 3. It's about *layout*, not *syntax* — `bash -n`-style checks won't catch it, and even visual rendering during PR review can be cached / non-deterministic across the GitHub renderer's branch cache. **Add to CONTRIBUTING.md**:

> 4. **Avoid `<br/>` inside sequenceDiagram message text and minimize `<br/>` count in flowchart node labels.** Mermaid 10.x's d3-curve label placement can intermittently fail with "Could not find a suitable point for the given distance" — the failure mode is non-deterministic and can succeed on a feature branch but fail on main. Prefer single-line message/node labels.

Add this in the same fix PR.

## Risk

Very low — docs only. If the fix doesn't address the root cause, the symptom (empty mermaid boxes) is still no worse than the current state on main.
