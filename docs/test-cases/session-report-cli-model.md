# Test cases — Session Report + Reviewed HEAD agent/model annotation (#128)

Covers the dev wrapper's `**Agent Session Report (Dev)**` heredocs and the
review wrapper's `Reviewed HEAD: ...` trailer gaining `Agent` / `Model`
attribution so historical issue threads tell us which CLI / model produced
each run when `AGENT_CMD` is rotated between rounds (multi-CLI deployments).

Dev-side cases extend `tests/unit/test-autonomous-dev-cleanup-startup-failure.sh`
(harness extracts `cleanup()` from `autonomous-dev.sh`, stubs `gh`, varies
env per case). Review-side case lives in
`tests/unit/test-autonomous-review-reviewed-head-annotation.sh` (parallel
function-extraction harness for the trailer-emit block).

Run via:

```bash
bash tests/unit/test-autonomous-dev-cleanup-startup-failure.sh
bash tests/unit/test-autonomous-review-reviewed-head-annotation.sh
```

## TC-CL-004 — startup-failure path emits Agent + Model fields

**Intent**: Forensic attribution for the failure-before-agent-runs path. A
multi-CLI deployment must see which CLI was attempted and what model was
configured even when the wrapper exits before invoking the agent.

**Setup**:
- `AGENT_RAN=false`, `ISSUE_NUMBER=42`, exit 1.
- `AGENT_CMD=codex`, `AGENT_DEV_MODEL=gpt-5.1-codex-max`.
- Run `cleanup` via the existing harness.

**Expected**:
- The captured `gh issue comment` body contains `Agent: codex`.
- Body contains `Model: gpt-5.1-codex-max`.
- Body still contains the pre-existing markers (`Agent Session Report (Dev)`,
  `Mode: startup-failure`).

## TC-CL-005 — normal-exit path emits Agent + Model fields with long bedrock model id

**Intent**: Lock in the new fields on the success path and stress quoting
with a representative long bedrock model id so a future refactor that
introduces single-quote / backslash issues fails loudly.

**Setup**:
- `AGENT_RAN=true`, `ISSUE_NUMBER=42`, `MODE=new`, exit 0.
- `AGENT_CMD=opencode`,
  `AGENT_DEV_MODEL=amazon-bedrock/global.anthropic.claude-opus-4-7`.

**Expected**:
- Comment body contains `Agent: opencode`.
- Comment body contains `Model: amazon-bedrock/global.anthropic.claude-opus-4-7`.
- Comment body still contains `Mode: new` and `Agent Session Report (Dev)`.

## TC-CL-006 — empty `AGENT_DEV_MODEL` set-but-empty renders `Model: <default>` (adjacency-tightened)

**Intent**: When `AGENT_DEV_MODEL` is exported as the empty string — the
default-configured case for every deployment that doesn't override
`lib-agent.sh:42`'s `AGENT_DEV_MODEL=""` — the report must render
`Model: <default>` rather than `Model: ` with empty trailing whitespace.
This pins **two** load-bearing parameter-expansion choices that point in
opposite directions:

- The **wrapper** uses colon-minus (`${AGENT_DEV_MODEL:-<default>}`) so
  that both unset and set-but-empty render `<default>`. Without the
  colon, the dominant default-configured case would render `Model:`
  with no value.
- The **harness** (`run_cleanup`) uses non-colon (`${7-sonnet}`) for its
  positional defaults so a missing arg renders `sonnet` ("test author
  asked for the default") while a passed `""` propagates as empty
  ("test author asked for the empty path"). Without the non-colon form
  the test loses the ability to exercise the wrapper's empty-string
  branch at all.

A reflexive cleanup PR that "unifies" the two onto a single operator
would silently break this case.

**Setup**:
- `AGENT_RAN=true`, `ISSUE_NUMBER=42`, `MODE=new`, exit 0.
- `AGENT_CMD=gemini`, `AGENT_DEV_MODEL=""` (set but empty).

**Expected**:
- The recorded gh argv contains the **adjacent** substring
  `"- Agent: gemini\n- Model: <default>"` (the gh stub preserves heredoc
  newlines inside the single argv it records; bare-substring asserts on
  `Model: <default>` alone could match unrelated occurrences if a
  future refactor introduced one).

## TC-CL-007 — empty `AGENT_CMD` renders `Agent: claude` fallback

**Intent**: Lock in the `:-claude` fallback in the heredoc. `lib-agent.sh:41`
collapses an empty `AGENT_CMD` to `claude` already; this regression-pins
the wrapper-side fallback so the two never disagree.

**Setup**:
- `AGENT_RAN=true`, `ISSUE_NUMBER=42`, `MODE=new`, exit 0.
- `AGENT_CMD=""` (set but empty), `AGENT_DEV_MODEL=sonnet`.

**Expected**:
- Comment body contains `Agent: claude` (the `:-claude` fallback fires).
- Comment body contains `Model: sonnet`.

## TC-CL-008 — exit-1 normal path also emits the new fields

**Intent**: Defence against accidentally gating the new fields on
`exit_code -eq 0`. The annotation belongs in both branches of the success
heredoc (this wrapper has only one normal-exit heredoc shared between
success and failure branches, but a future split must not strip the
fields from the failure side).

**Setup**:
- `AGENT_RAN=true`, `ISSUE_NUMBER=42`, `MODE=new`, exit 1.
- `AGENT_CMD=claude`, `AGENT_DEV_MODEL=sonnet`.

**Expected**:
- Comment body contains `Agent: claude` and `Model: sonnet`.
- Pre-existing `Exit code: 1` line still present.

## TC-RHA-001 — `Reviewed HEAD` trailer contains agent + model

**Intent**: Behavioural test for the review-side annotation. Promote the
prior static grep idea to a function-extraction harness mirroring the dev
cleanup test. Catches three bugs that the static grep missed:

- wrong default fallback (the `:-sonnet` dead-code bug from the issue body
  — `lib-agent.sh:43` already defaults `AGENT_REVIEW_MODEL` to `sonnet`, so
  Option A drops the trailer-side `:-<default>` and writes the variable
  directly).
- broken backtick escaping (a refactor that doubles or drops a backtick
  silently breaks the dispatcher's `Reviewed HEAD: \`<sha>\`` regex).
- annotation accidentally landing in a different `--body` after a
  consumer-side refactor (e.g. a verdict comment that got the trailer
  text grafted onto it).

**Setup**:
- Extract the `if [[ -n "$LATEST_COMMENT" && -n "$PR_HEAD_SHA" ]]; then ...
  fi` block from `autonomous-review.sh`.
- Stub `gh` to record argv to `$GH_RECORD`.
- Set `LATEST_COMMENT="Review PASSED"`, `PR_HEAD_SHA=deadbeef`,
  `ISSUE_NUMBER=42`, `SESSION_ID=test-session`, `REPO=acme/widget`,
  `AGENT_CMD=opencode`, `AGENT_REVIEW_MODEL=sonnet`.

**Expected**:
- The recorded gh argv contains the `--body` value
  `Reviewed HEAD: \`deadbeef\` (issue #42, session \`test-session\`, agent \`opencode\`, model \`sonnet\`)`.
- The dispatcher's anchor pattern `Reviewed HEAD: \`deadbeef\`` is
  preserved at the start of the body (the trailing parenthesised metadata
  must not perturb the leading SHA backtick-pair).

## Static-analysis pin (TC-CL-STATIC-001)

`grep` the harness for the literal `agent_cmd="${6-claude}"` /
`agent_dev_model="${7-sonnet}"` non-colon positional defaults so a
reflexive `${6:-claude}` "cleanup" fails the suite — the wrapper's
empty-string branch becomes untestable without the non-colon form. The
companion wrapper-side colon-minus (`${AGENT_DEV_MODEL:-<default>}`) is
verified end-to-end by TC-CL-006 itself; a wrapper-side flip would
surface there before this static pin.

## Out of scope

- E2E coverage. Lives entirely in shell unit-test territory like the rest
  of `lib-dispatch.sh` testing.
- Pre-existing `AGENT_CMD=""` collapse-to-`claude` bug from `lib-agent.sh:41`.
  TC-CL-007 documents the current behaviour, not a fix.
