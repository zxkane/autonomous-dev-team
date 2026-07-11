# Design: PR-diff-size (over-reach) signal for the review prompt (issue #452)

## Problem

Anthropic's Loop Engineering guidance names two failure modes to watch for when running
autonomous loops: **stall** (agent stuck) and **over-reach** (agent doing too much). This
pipeline's stall detection is thorough (grace window, near-success cross-checks, PID
heartbeat), but over-reach is unmonitored — as long as CI is green and a PR exists, the
mechanical gates approve it. A dev agent could expand a small issue into a sweeping
multi-file change and still pass. The review side already has requirement-drift detection
(reading issue comments for scope changes), but that catches *changed* requirements, not an
*oversized* diff against unchanged requirements.

## Decisions

| # | Question | Decision |
|---|---|---|
| Q1 | Hard gate or advisory? | Advisory only. Diff size is a heuristic proxy for "did this PR grow beyond what the issue described" — large diffs are sometimes correct (migrations, refactors, this repo's own provider-seam series). `over_reach` must never be read by any verdict-aggregation code path or `_classify_*_gate` function. |
| Q2 | Where to read diff stats? | Through the provider seam, not a raw `gh pr view`. `autonomous-review.sh` is in `check-provider-cutover.sh`'s `CALLER_FILES` list (INV-91) — a raw call there is CI-blocked. Added a new dedicated verb, `chp_pr_diffstat PR DIMENSIONS-CSV`, rather than overloading `chp_pr_view`'s existing field vocabulary, so callers can request only the dimension(s) they need. |
| Q3 | Per-member or per-round computation? | Once per review round, before the fan-out. `build_review_prompt()` is called once per fan-out member; computing this per-member would redundantly re-read the provider seam and duplicate the metrics row. |
| Q4 | Config shape? | Two independent keys, `PR_DIFF_SOFT_CAP_FILES` / `PR_DIFF_SOFT_CAP_LINES`, each a positive integer. Empty/unset/invalid (`0`, negative, non-numeric) normalizes identically to "disabled" for that key — silent degrade, never a startup error. Both unset (the default) = feature fully disabled, byte-identical `build_review_prompt()` output, zero provider-seam calls, zero metrics events. |
| Q5 | Threshold comparison? | `over_reach = (FILES cap set AND changed_files > FILES cap) OR (LINES cap set AND changed_lines > LINES cap)` — strict `>` (never `>=`), OR across dimensions. |
| Q6 | GitHub read path? | A single `gh pr view --json additions,deletions,changedFiles` answers both dimensions regardless of which is requested — zero marginal cost either way. |
| Q7 | GitLab read path — one cost or two? | Asymmetric, pay-only-if-configured. `files` reads `changes_count` off the already-fetched base MR view (parsing the capped `"1000+"` string down to the integer `1000`) at zero extra cost. `lines` requires a **second**, separate GraphQL `diffStatsSummary` call — issued only when `PR_DIFF_SOFT_CAP_LINES` is actually configured. This is a cost trade-off, not a missing capability: both dimensions are supported on both hosts, so no `.caps` capability-off flag is declared. |
| Q8 | GitLab GraphQL auth? | GitLab's GraphQL endpoint authenticates via `Authorization: Bearer`, not the REST `PRIVATE-TOKEN` header the rest of `chp-gitlab.sh`'s leaves use — this is the first GraphQL call site in that file, so it gets its own transport primitive (`_gl_graphql` in `lib-gitlab-transport.sh`) rather than reusing `_gl_api`/`_gl_http`. |
| Q9 | Failure behavior? | Fail-open per dimension. A read failure (rc≠0, empty, unparseable) leaves that dimension's stat unset; `review_diff_over_reach` never contributes `true` for an unset/non-numeric stat. Independent failure domains on GitLab: a GraphQL failure degrades only `lines` — it must not suppress a `files` result already read successfully from the base MR view. |
| Q10 | Prompt injection shape? | A new pure helper, `review_diff_soft_cap_prompt_note`, mirroring the existing `review_protected_paths_prompt_rule` pattern in `lib-review-classify.sh` — an `echo`-only function producing a markdown snippet, interpolated into `build_review_prompt()`'s heredoc via `$(...)`. Empty output when `over_reach=false`, so the disabled/under-cap case renders byte-identical to pre-change. |
| Q11 | Observability? | Exactly one new `pr_diff_soft_cap` metrics event per enabled review round (via `metrics_emit`), not folded into the per-fan-out-member `review_agent_run` event (which fires once per agent — folding a PR-level flag into it would duplicate the value N times and corrupt `metrics-report.sh`'s aggregation). |

## Implementation shape

```
autonomous-review.sh (once per review round, before the fan-out loop):
  files_cap  = _diff_cap_normalize "$PR_DIFF_SOFT_CAP_FILES"
  lines_cap  = _diff_cap_normalize "$PR_DIFF_SOFT_CAP_LINES"
  dims       = review_diff_soft_cap_dimensions_needed "$files_cap" "$lines_cap"
  if [ -n "$dims" ]; then
    stats      = chp_pr_diffstat "$PR" "$dims"          # provider seam
    over_reach = review_diff_over_reach "$changed_files" "$changed_lines" "$files_cap" "$lines_cap"
    note       = review_diff_soft_cap_prompt_note "$over_reach" ...   # interpolated into build_review_prompt()
    metrics_emit pr_diff_soft_cap side=... pr=... over_reach=... changed_files=... changed_lines=... files_cap=... lines_cap=...
  fi
```

- `lib-review-diffcap.sh` — new pure decision lib (no I/O), mirrors `lib-review-classify.sh` /
  `lib-review-mergeable.sh`: `_diff_cap_normalize`, `review_diff_soft_cap_dimensions_needed`,
  `review_diff_over_reach`, `review_diff_soft_cap_prompt_note`.
- `lib-code-host.sh` + `providers/chp-github.sh` + `providers/chp-gitlab.sh` — new
  `chp_pr_diffstat PR DIMENSIONS-CSV` verb. Returns a normalized JSON object carrying only the
  requested key(s) (`changed_files`, `changed_lines`); a dimension is omitted, never fabricated
  as `0`/`null`, when the provider could not determine it.
- `providers/lib-gitlab-transport.sh` — new `_gl_graphql` transport primitive (Bearer auth), plus
  an optional `_gl_graphql_hook` override point so a `GITLAB_TRANSPORT_HOOK`-only installation
  (no `GITLAB_TOKEN`) can still answer the GraphQL call through its own transport. Hook output is
  captured (not streamed) and validated as exactly one non-null JSON object before use — a
  multi-document or malformed response fails closed rather than leaking a partial/garbled result.
- `lib-metrics.sh` — new numeric field names (`changed_files`, `changed_lines`, `files_cap`,
  `lines_cap`) added to the hardcoded `num_keys` allow-list so they serialize as JSON numbers.

## Guards preserved

INV-91 (provider-seam-only I/O — `check-provider-cutover.sh` stays green, no raw `gh pr view`
added to `autonomous-review.sh`). INV-70 (metrics emission is observe-only — a `pr_diff_soft_cap`
emit failure can never change the wrapper's exit code, label transition, or verdict). INV-116
(the GitLab `_gl_http`/`_gl_api` two-layer transport contract is unchanged; `_gl_graphql` is a
sibling primitive alongside it, not a modification).

## New invariant

This work adds **INV-124**: the PR-diff-size (over-reach) signal is a default-off, fail-open
soft signal never read by verdict aggregation (`docs/pipeline/invariants.md`).

## Out of scope

Hard-gating or auto-failing on diff size. Semantic scope analysis (comparing diff content
against issue requirements) — this is diff-size only. Prescribing a single cross-repo default
threshold value in code (both caps ship unset; `autonomous.conf.example` documents this repo's
own historical p90 — `PR_DIFF_SOFT_CAP_FILES=40` / `PR_DIFF_SOFT_CAP_LINES=3000` — as a labeled,
non-universal example only).
