# Design: W1d chp_ci_status + chp_mergeable normalized-token contracts (#399, #347 phase-2)

## Problem

`providers/chp-github.sh`'s `chp_github_ci_status` and `chp_github_mergeable`
leaves are focused-raw `gh` passthroughs (#282):

- `ci_is_green` (`lib-dispatch.sh:2787`) composes
  `chp_ci_status "$pr_num" --json state -q '[.[].state]'` and applies the
  `length > 0 and all(. == "SUCCESS")` gate caller-side. The tokens
  `green`/`pending`/`failed`/`none` the spec claims are never actually
  produced — the caller only distinguishes green (rc 0) from not-green (rc
  1). A GitLab leaf would have to emulate `gh`'s per-check `state` vocabulary
  AND the jq projection.
- The mergeable poll (`autonomous-review.sh:3491`) composes
  `chp_mergeable "$PR_NUMBER" -q '.mergeable'` and consumes the raw token via
  `_classify_mergeable_gate` (INV-44). The `-q` is a jq program a GitLab leaf
  would have to emulate; the leaf already hardcodes `--json mergeable`
  (chp-github.sh:78) but the caller's `-q '.mergeable'` still crosses the
  seam.

## Decision

Normalize both leaves to a pinned token contract; the caller passes only the
PR positional and consumes a single token on stdout. No `gh` flags and no jq
programs cross the seam.

```
chp_ci_status <pr> → stdout: exactly one of `green|pending|failed|none`
  Decision order:
    (1) zero checks                              → `none`
    (2) any ∈ {FAILURE,ERROR,CANCELLED,TIMED_OUT} → `failed`
    (3) any ∈ {PENDING,QUEUED,IN_PROGRESS,EXPECTED,SKIPPED}
        or any state not otherwise listed        → `pending`
    (4) else (all SUCCESS, ≥1)                    → `green`
  Rule 2 beats rule 3 (FAILURE+SKIPPED → `failed`).
  SKIPPED lands in `pending` (SKIPPED ≠ SUCCESS; the old gate was
  all(=="SUCCESS")).
  rc-quirk: `gh pr checks` exits non-zero for failing/pending/no-checks
  cases even on parseable JSON. The leaf inspects stdout — parseable JSON
  array → derive token regardless of gh's rc (empty array → `none`); no
  parseable JSON → leaf rc≠0.

chp_mergeable <pr> → stdout: exactly one of `MERGEABLE|CONFLICTING|UNKNOWN`
  Byte-identical to GitHub's raw `mergeable` values, so
  `lib-review-mergeable.sh` (`_classify_mergeable_gate`/`_pr_open_gate`,
  INV-44/INV-54) ships byte-unchanged. rc≠0 on query failure; the caller's
  existing `|| echo ""` failure wrapper maps that to the classifier's
  empty-string→`block-nonsubstantive` branch.
```

This is a **deliberate shape change** — the pre-#399 byte-identical-argv
constraint is explicitly LIFTED for these two verbs. Same posture as W1a
(#371).

## Why not byte-identical (like #282's original #367-correction)

A byte-identical passthrough works when the caller's jq program IS the
contract. Here the jq program buries the token vocabulary INSIDE the leaf
(the CHP seam's whole reason to exist): a GitLab leaf mapping
`head_pipeline.status` null → `none` and its own status vocabulary would
have to synthesize a fake `gh pr checks` state array purely so the caller's
jq works on it — an infinite-mile per-provider transformation the seam is
meant to prevent. Same rationale as W1a: the byte-identical anchor is
useful when the caller's jq encodes the contract; here it hides the
contract instead.

## Caller shape

`ci_is_green` keeps its NAME + rc-boolean contract (documented mock seam,
spec §7.3.3; `test-dispatcher-tick-app-auth.sh:104` function-mocks it). The
new body preserves the existing capture-then-test structure:

```
ci_is_green() {
  local pr_num="$1"
  local ci_token ci_err_file ci_err_content
  ci_err_file=$(mktemp)
  if ci_token=$(chp_ci_status "$pr_num" 2>"$ci_err_file"); then
    rm -f "$ci_err_file"
  else
    ci_err_content=$(cat "$ci_err_file")
    rm -f "$ci_err_file"
    [ -n "$ci_err_content" ] && \
      echo "WARN: CI-status query (chp_ci_status) failed for PR #${pr_num}: ${ci_err_content}" >&2
    ci_token=""
  fi
  [[ "$ci_token" == "green" ]]
}
```

Do NOT inline `[[ $(chp_ci_status "$pr_num") == green ]]` — that discards
the mktemp/WARN transport-failure path (TC-DSAP-014/015 pin the WARN
wording).

The mergeable poll drops `-q '.mergeable'`:

```
MERGEABLE_STATUS=$(chp_mergeable "$PR_NUMBER" 2>/dev/null || echo "")
```

UNKNOWN-retry loop, `_classify_mergeable_gate`, `_pr_open_gate` byte-unchanged.

## Behavior parity (R4)

Captured in `tests/unit/fixtures/w1d-parity/`:

- `ci-decision-golden.json` — for every fixture class (all-success × 2,
  mixed-pending, mixed-failure, skipped-success, empty, transport-error,
  plus the rc-quirk cases) OLD and NEW `ci_is_green` return the same rc.
  The `_note` fields document the R2 rc-quirk distinction: OLD's `-q
  '[.[].state]'` produced `[]` on stdout for the gh-rc-quirk-with-data
  case → OLD rc 1; NEW derives the token from the JSON payload → NEW
  matches OLD on the fixtures documented in this file (rc parity holds),
  but the NEW leaf gains the ability to distinguish `none` from
  transport-failure that OLD collapsed to the same rc-1 outcome.
- `mergeable-classifier-golden.json` — for every TC-MG-CLS input,
  `_classify_mergeable_gate` returns the byte-unchanged value.

The parity harness (`tests/unit/test-w1d-ci-status-mergeable-parity.sh`) is
the golden proof: it drives the NEW leaf against every row and diffs
against the goldens.

## Conflict cluster (see PR body's `Conflict notes`)

Touches `docs/pipeline/provider-spec.md`, `chp-github.sh`, `lib-dispatch.sh`,
`autonomous-review.sh`, `coverage.conf`, `cap-map.conf`, three test files
(`test-chp-pr-lifecycle.sh`, `test-autonomous-review-mergeable-gate.sh`,
`test-stale-alive-with-pr.sh`), the conformance runner + its README, and the
runner self-test (`test-provider-conformance-runner.sh`). Serialized behind
#398 (W1c2) via `Dependencies`.

## Out of scope

- The 3 review-agent prompt heredocs instructing the agent to run `gh pr
  checks` itself (autonomous-review.sh:1178/1238/1426) — prompt-prose,
  phase-3 per #347; already exempted by the FINAL-AC grep.
- `_classify_mergeable_gate` / `_pr_open_gate` semantics
  (INV-44/INV-54) — byte-unchanged.
- `verify-completion.sh`'s raw `gh pr checks` (autonomous-common hook,
  outside the CHP seam).
- W1(e)/W1(f) — subsequent slices.
- Writing any non-GitHub leaf (phase-3).
