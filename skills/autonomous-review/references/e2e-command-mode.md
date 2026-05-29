# E2E Command Mode

> **This reference applies only when `E2E_MODE=command` is set in `autonomous.conf`.** For browser-driven UI smoke testing, see `e2e-verification.md`.

This mode lets a project supply its own verify command instead of using Chrome DevTools MCP. It's the right shape for:

- **Backend pipelines** — the artifact-of-truth lives in S3 / DDB / a database row, not on a page.
- **CLI tools** — verification is "did the binary produce the expected output", not "is this button clickable".
- **Libraries** — `npm pack && npm install ./pkg && node -e ...`, no preview URL.
- **Infra-as-code / ML pipelines** — verify by reading deploy outputs, not by clicking around.

---

## Configuration

In `autonomous.conf`:

```bash
E2E_ENABLED="true"
E2E_MODE="command"
E2E_COMMAND='bash scripts/e2e-pr-stage.sh ${PR_NUMBER}'
E2E_COMMAND_TIMEOUT_SECONDS=3600
E2E_COMMAND_PRE_HOOKS='bash scripts/e2e-seed-pr-stage.sh ${PR_NUMBER}'   # optional
E2E_COMMAND_EVIDENCE_PARSER='bash scripts/e2e-evidence.sh'
```

The wrapper expands `${PR_NUMBER}` literally at render time (not in shell). Always single-quote the assignment so your shell doesn't eagerly expand the placeholder when sourcing the conf file.

| Field | Required | Purpose |
|---|---|---|
| `E2E_MODE=command` | yes | Selects this branch in the wrapper. |
| `E2E_COMMAND` | yes | The verify command. Stdout/stderr go to `/tmp/e2e-${PR_NUMBER}.log`. Exit code interpreted per Section "Exit-code semantics". |
| `E2E_COMMAND_EVIDENCE_PARSER` | yes | Reads the log, emits a markdown evidence block to stdout (see "Evidence block contract"). |
| `E2E_COMMAND_TIMEOUT_SECONDS` | no | Default 3600. Wrapper enforces via `timeout(1)`. Soft cap; for >60min E2E wait for the background-mode follow-up. |
| `E2E_COMMAND_PRE_HOOKS` | no | Runs before the verify command (e.g. seed test data). Failure aborts E2E. |

`E2E_ENABLED=true` with `E2E_MODE` unset is a fail-loud condition — projects must opt into a specific mode rather than implicitly inheriting `browser`.

---

## Project-side contract

The project supplies two scripts.

### 1. The verify command (`E2E_COMMAND`)

- Reads its arguments, including any rendered `${PR_NUMBER}`.
- Performs whatever real work the E2E entails (deploy a stage, submit a job, poll for completion, dump logs).
- Streams informative output to stdout/stderr.
- Exits 0 on success, non-zero on failure. Exit code 124 (from `timeout(1)`) signals TIMEOUT; the review agent (per Step 3 of the command-mode prompt block) treats it as FAIL but still runs the evidence parser to capture partial results.
- Has access to whatever credentials the wrapper has (GitHub App token via the wrapper's auth, plus whatever the project's per-stage IAM affords).
- Should be idempotent against retries — the wrapper may re-dispatch on subsequent ticks.

### 2. The evidence parser (`E2E_COMMAND_EVIDENCE_PARSER`)

- Takes the verify-command's log file as `$1`.
- Reads the log + any artifact-of-truth (S3 objects, DDB rows, local files) the verify command produced.
- Emits a markdown evidence block to stdout. The review agent (per the prompt instructions injected by `autonomous-review.sh`) pastes it verbatim into a PR comment via `gh pr comment`.
- The block MUST end with a SHA-bearing marker matching the PR's current HEAD commit:
  ```
  <!-- e2e-evidence: complete sha="<HEAD-SHA>" -->
  ```
  The review wrapper exposes the HEAD SHA via `${PR_HEAD_SHA}` in the prompt; the project's evidence parser MUST embed that SHA in the output. **The SHA binding is load-bearing for idempotency** — without it, a stale evidence comment from a prior commit would falsely satisfy a re-review of newer code. The review agent — not the wrapper — checks the SHA matches before reusing prior evidence; see Step 4 / Step 4b of the command-mode prompt block in `skills/autonomous-dispatcher/scripts/autonomous-review.sh`.
- Returns 0 on success, non-zero if the log is malformed or required artifacts are missing.

### Evidence block contract

The markdown block MUST contain:

1. A `## E2E Evidence` (or similar) top-level header.
2. A summary table mapping each acceptance-criterion item from the issue body to a verifiable result. The review agent uses this to mark issue checkboxes.
3. Pointers to authoritative artifacts (S3 keys, DDB rows, log timestamps) so the reviewer (human or agent) can spot-check.
4. The marker `<!-- e2e-evidence: complete sha="<PR-HEAD-SHA>" -->` as the LAST line. The SHA is required — see the "Idempotency" section.

Optional but recommended:

- Comparison against a baseline (prod / main-branch result).
- Visual confirmation section if the project requires human eyeballs (e.g. transcripts, generated images).
- A "What this evidence does NOT cover" section for known limitations.

The wrapper does NOT validate the structure beyond checking for the marker. The PR reviewer (human) and the review agent (LLM) are the structural reviewers — keep the format readable.

---

## Exit-code semantics

| `E2E_COMMAND` exit code | Agent action |
|---|---|
| 0 | run evidence parser → post comment → check evidence vs AC → PASS or FAIL based on coverage |
| 124 | TIMEOUT (from `timeout`). Run evidence parser anyway (some pipelines write artifacts before late-stage cleanup); evidence block must annotate timeout context; agent decides PASS/FAIL on partial evidence. |
| any other non-zero | **DO NOT** run the evidence parser (its input log is malformed). Post a failure comment with the verify-command exit code + a tail of the log file. FAIL. |

The "TIMEOUT but recoverable" path exists because backend pipelines often have late-stage tail-end errors (cleanup races, monitor-tool glitches) that fire AFTER the artifact has actually landed. The evidence parser, not the verify command, is the source of truth for whether the artifact is acceptable on `EXIT_CODE=124`.

The "skip parser on other failures" rule is critical: parsers are written to consume successful runs. Feeding them a half-written log from a hard failure leads to confusing parser crashes that mask the real failure cause.

---

## Onboarding example

A backend pipeline project wants to validate that a fix to its transcription worker produces N-cluster output instead of the old broken 2-cluster output. The fix lives behind a PR-stage deployment.

```bash
# autonomous.conf
E2E_ENABLED="true"
E2E_MODE="command"
E2E_COMMAND='bash scripts/e2e-pr-stage.sh ${PR_NUMBER}'
E2E_COMMAND_TIMEOUT_SECONDS=3600
E2E_COMMAND_PRE_HOOKS='bash scripts/e2e-seed-pr-stage.sh ${PR_NUMBER}'
E2E_COMMAND_EVIDENCE_PARSER='bash scripts/e2e-evidence.sh'
```

```bash
# scripts/e2e-seed-pr-stage.sh
#!/usr/bin/env bash
# Pre-hook: copy fixture data from prod to the per-PR stage tables.
set -euo pipefail
PR="${1:?PR number required}"
aws dynamodb get-item --table-name prod-Foo --key '{"pk":...}' --output json \
  | jq '.Item' > /tmp/prod-row.json
aws dynamodb put-item --table-name "pr-${PR}-Foo" --item file:///tmp/prod-row.json
```

```bash
# scripts/e2e-pr-stage.sh
#!/usr/bin/env bash
# Verify command: kick off the workflow, poll until terminal, dump logs.
set -euo pipefail
PR="${1:?PR number required}"
# ... submit, poll, assert, exit 0 on success ...
```

```bash
# scripts/e2e-evidence.sh
#!/usr/bin/env bash
# Evidence parser: read log + artifacts, emit markdown block.
set -euo pipefail
LOG="${1:?log file required}"

# Pull authoritative artifact metrics
CLUSTERS=$(aws s3 cp "s3://...transcripts.../raw.json" - | jq '[.segments[].speaker] | unique | length')
SPEAKER_MAP=$(aws s3 cp "s3://...transcripts.../verified.json" - | jq -r '.speaker_map')

# PR_HEAD_SHA is exported by the wrapper — read it from env.
HEAD_SHA="${PR_HEAD_SHA:?PR_HEAD_SHA must be set by the wrapper}"

cat <<EVIDENCE
## E2E Evidence (auto)

| Acceptance criterion | Result |
|---|---|
| raw.json has ≥3 distinct clusters | $([ "$CLUSTERS" -ge 3 ] && echo "✅ ($CLUSTERS)" || echo "❌ ($CLUSTERS)") |
| verified.json has ≥3 named speakers | $(...) |

S3 artifacts:
- s3://...transcripts.../raw.json
- s3://...transcripts.../verified.json

<!-- e2e-evidence: complete sha="${HEAD_SHA}" -->
EVIDENCE
```

---

## Idempotency

Subsequent review-tick wrappers re-render the prompt with the same `E2E_COMMAND`. To avoid burning compute on already-validated commits, the agent checks for an existing evidence comment on the PR whose marker SHA matches the current HEAD before invoking `E2E_COMMAND`.

**Match criterion:** the comment must contain the exact substring
```
e2e-evidence: complete sha="<current-PR-HEAD-SHA>"
```

A plain marker (without `sha="..."`) does NOT match — that would let stale evidence from a prior commit silently satisfy a re-review of newer code, which was a real footgun in the pre-SHA design.

If the comment SHA does not match the current HEAD SHA, the evidence is stale; the agent re-runs E2E from Step 1.

The MVP wrapper does NOT enforce this skip — it's the agent's responsibility per the prompt instructions in `autonomous-review.sh` (Step 4b of the command-mode prompt block). A future PR may move the skip into the wrapper itself (via a comment-grep + label combination similar to `reviewing` / `pending-review`).

---

## When NOT to use command-mode

- **Your project is a SaaS web app with a preview URL.** Use `browser` mode — that's what it's for.
- **Your verify command takes >60 minutes.** The MVP runs synchronously inside the agent session, which has its own stalled-detection. Wait for the background-mode follow-up (tracked separately).
- **You want the review agent to author evidence.** This mode requires the project to ship `E2E_COMMAND_EVIDENCE_PARSER`. The agent is the runner + judge, not the author.

---

## Cross-references

- `e2e-verification.md` — the browser-mode counterpart (Chrome DevTools MCP, screenshot upload, login flow).
- `decision-gate.md` — the PASS/FAIL gate the agent applies after E2E completes.
- `docs/pipeline/review-agent-flow.md` — the wrapper's overall flow including the E2E branch dispatch.
