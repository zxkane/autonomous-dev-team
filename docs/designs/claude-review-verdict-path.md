# Design Canvas - Claude Review Verdict Path

Feature: Unattended Claude review verdict reporting
Date: 2026-07-21
Status: Approved

## UI Mockup / Wireframe

No user interface changes. This feature changes the review wrapper's process,
filesystem, and verdict-channel behavior.

## Component Architecture

```text
autonomous-review.sh
  |
  +-- provisions per-member artifact and body directories
  |
  +-- lib-review-claude.sh
  |     +-- appends review-only Claude permission arguments through the
  |         production fan-out mutation seam
  |     +-- recognizes a canonical verdict in a session-bound JSONL capture
  |     +-- executes the production per-member fallback/post/refetch seam
  |
  +-- Claude Code 2.1.216, permission mode auto
  |     +-- --add-dir <artifact-run-dir>
  |     +-- --add-dir <body-lane-dir>
  |     +-- --allowedTools
  |           +-- Bash(bash scripts/write-verdict-artifact.sh:*)
  |           +-- Bash(bash scripts/write-verdict-body.sh:*)
  |           +-- Bash(bash scripts/post-verdict.sh:*)
  |
  +-- write-verdict-artifact.sh
  |     +-- reads JSON from stdin
  |     +-- writes a private temp file beside the final artifact
  |     +-- atomically renames the temp file into place
  |
  +-- write-verdict-body.sh
  |     +-- reads body text from stdin
  |     +-- writes only to VERDICT_BODY_FILE
  |
  +-- post-verdict.sh
        +-- posts the canonical human-facing verdict comment
```

## Data Flow Diagram

```text
wrapper mints paths
      |
      v
operator review args + review-only injected args
      |
      v
Claude runs with a session-suffixed stream-json capture
      |
      +--> helper writes atomic typed artifact --------+
      |                                                |
      +--> helper writes body -> post-verdict comment  |
                                                       v
wrapper resolution: artifact > comment > final text fallback
                                      |
                                      +-- rc must be 0
                                      +-- artifact must not be malformed
                                      +-- result record must be valid JSON,
                                          non-error, string-valued, and bound
                                          to the current session capture
                                      +-- first line must start exactly with
                                          Review PASSED or Review findings:
```

## Design Notes

- The injection is assembled in the review fan-out after operator-provided
  `AGENT_REVIEW_EXTRA_ARGS[_CLAUDE]`, then consumed through the existing
  `AGENT_DEV_EXTRA_ARGS` review-member alias. The adapter and every dev launch
  remain unchanged.
- Both wrapper orchestration paths live in sourceable production functions:
  `_claude_review_apply_permission_injection` mutates the two adapter aliases,
  and `_claude_apply_final_text_fallback` owns post-poll resolution. Unit and
  fleet E2E fixtures invoke these exact functions rather than reproducing their
  branches.
- Deterministic stdin helpers were selected for both files. They make the Bash
  allowlist narrow and keep artifact publication atomic without granting
  arbitrary shell redirection or a general Write tool.
- Injection is active only for Claude review members in `auto`. It is skipped in
  `bypassPermissions`; `plan` logs a loud warning and remains unsupported.
- Injection also requires both minted directories to exist and refuses the
  lane allocator's `/tmp` failure sentinel, so allocation failure cannot widen
  the filesystem grant to the temporary root.
- Every Claude review member uses a session-suffixed capture. The fallback never
  reads the reusable default log, so a prior round cannot cast a vote.
- The final-text recognizer is deliberately narrower than
  `_classify_verdict_body`: it has a `none` result and accepts only canonical,
  anchored first-line verdict grammar from the final valid result record.
- A wrapper-owned fallback post uses `post-verdict.sh` and records
  `claude-finaltext-fallback` only in memory and logs. It adds no visible source
  marker to the comment.
- Failure modes remain fail-safe: nonzero launch rc, malformed artifacts,
  malformed JSONL, error results, missing/non-string result fields, ambiguous
  prose, and failed wrapper posts do not produce a fallback vote.
