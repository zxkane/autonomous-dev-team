# Design Canvas - Review Permission-Mode Warning

Feature: Review permission-mode startup warning
Date: 2026-07-21
Status: Approved

## Component Architecture

```text
autonomous.conf
  |
  v
autonomous-review.sh
  |- rebind AGENT_REVIEW_CMD
  |- resolve REVIEW_AGENTS_LIST
  |- resolve Claude extra args
  |- call pure warning predicate
  |- log unsafe configuration
  `- list/post issue comments through the ITP seam
        |
        `- fingerprint marker deduplicates the same unsafe configuration

lib-review-permmode.sh
  |- pure warning predicate
  |- pure canonical fingerprint
  `- pure marker lookup
```

## Data Flow Diagram

```text
mode + resolved fleet + resolved Claude extra args + injection + fallback
  |
  v
predicate -> ok   -> no comment read or write
          -> warn -> log warning
                    |
                    v
              hash mode/fleet/knobs
                    |
                    v
              list issue comments
                |- marker found -> no new comment
                `- marker absent -> post warning + marker
```

## Design Notes

- The check runs only after the review wrapper has rebound `AGENT_REVIEW_CMD`
  and constructed `REVIEW_AGENTS_LIST`; raw `AGENT_CMD` is not authoritative.
- `plan` always warns for a fleet containing Claude. For other non-bypass
  modes, final-text fallback suppresses the warning, and permission injection
  suppresses it only in `auto`.
- Resolved Claude extra args are intentionally accepted but ignored by the
  decision. Static `--allowedTools`, settings, or launcher grants cannot be
  proven to cover the complete per-run reporting sequence.
- `CONF_PERMMODE_WARN=false` returns before predicate evaluation, hashing, or
  issue-comment reads and writes.
- The marker hashes mode, ordered resolved fleet, injection state, and fallback
  state. Only self-authored markers deduplicate; malformed provider output
  fails closed without posting a potentially duplicate comment. Safe runs post
  no marker, so unsafe -> safe -> the same unsafe
  fingerprint is indistinguishable from a repeated unsafe run and does not
  produce another comment.
- The warning comment carries the standard run footer, and provider I/O starts
  only after the wrapper cleanup trap is installed.
- Comment transport failures remain non-fatal because this feature is a
  warning, not a startup refusal.
