# Issue #321 — migrate the final-2 comment-scanner reads behind `itp_list_comments`

## Goal

Migrate the last two raw-`gh issue view --json comments` **comment-scanner** leaves in the
dispatcher/review libs behind the already-shipped `itp_list_comments` provider verb (#296
"final-2-marker-scanners" batch — the last first-tier batch). This removes the last
"read issue comments to find a marker" raw-`gh` sites and shrinks
`scripts/providers/cutover-baseline.json` by exactly **2 entries**.

| Site | File:fn | Invariant | Risk |
|------|---------|-----------|------|
| **S1** | `dispatcher-tick.sh` — INV-12 PTL idempotency marker count | [INV-12] | LOW — `contains()` literal, engine-agnostic |
| **S2** | `lib-review-poll.sh` — `_fetch_agent_verdict_body` | [INV-20] (actor+window) / [INV-40] (per-agent) | **HIGHEST — a broken selector silently drops EVERY agent's verdict to `unavailable`** |

## Context

`itp_list_comments ISSUE` (provider verb, GitHub leaf `itp_github_list_comments`, #281) returns
ISSUE-level comments as the [INV-90] normalized array, sorted **ascending** by `createdAt`:

```
[{ id, author, authorKind, body, createdAt }]
```

- `id`     — REST **numeric** comment id (parsed from the comment `url`'s `issuecomment-<n>`).
- `author` — `.author.login` verbatim incl. any `[bot]` suffix (a stable machine handle).
- `body`, `createdAt` — verbatim; `createdAt` is gh's ISO-8601 UTC string.

The verb already unwraps gh's `{comments:[…]}` envelope, so a migrated caller iterates `.[]`
(not `.comments[]`) and reads `.author` (not `.author.login`).

## S1 — `dispatcher-tick.sh` INV-12 PTL idempotency scanner (byte/shape-equivalent)

**Before:**

```bash
if gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[].body | select(contains(\"${notice_marker}\"))] | length" \
    2>/dev/null | grep -q '^0$'; then
  itp_post_comment "$issue_num" "…(${notice_marker})"
fi
```

**After:**

```bash
_ptl_notice_count="$(itp_list_comments "$issue_num" 2>/dev/null \
  | jq -r "[.[].body | select(contains(\"${notice_marker}\"))] | length" 2>/dev/null)"
if [ "${_ptl_notice_count:-}" = "0" ]; then
  itp_post_comment "$issue_num" "…(${notice_marker})"
fi
```

- `.comments[]` → `.[]` (the verb unwraps the envelope).
- `contains()` is a **literal substring** test — engine-agnostic; **no RE2/Oniguruma divergence**.
- **Fail-closed preserved**: on any read error / empty fetch the count is empty/non-`"0"`, so
  the `= "0"` guard is false → the notice is **NOT** re-posted. This is identical in spirit to the
  old `grep -q '^0$'` (a fetch error → no `^0$` line → guard false → no post). Posting the notice a
  second time would be the only failure mode, and the guard stays closed against it. The marker
  itself is the dedup key, so even an over-conservative "count unknown → skip" is safe (the next
  tick re-checks).

## S2 — `lib-review-poll.sh` `_fetch_agent_verdict_body` (behavior-equivalent, 4 fixes)

This is the verdict-authenticity choke-point. The old path ran the comment `select` through **gh's
embedded jq (gojq → Go RE2, ASCII-only case folding)**; the migrated path runs it through
**system jq (Oniguruma, Unicode case folding)** via `itp_list_comments | jq`. That is a real
regex-engine boundary, so the rewrite carries four behavior-preservation fixes — all verified
on-box against **system jq 1.6** and a real read-only `gh -q` call.

The three **case-SENSITIVE** predicates stay UNCHANGED — they carry no boundary / whitespace /
character-class and no `"i"` flag, so RE2 ≡ Oniguruma for them (verified on-box: a case-sensitive
`test("Review PASSED")` does NOT Unicode-fold long-s):

- `test("Review Session")` (BOT_LOGIN-set path)
- `test("Review Session.*<sid>")` (BOT_LOGIN-empty session-id fallback)
- `test("Review Agent: <agent>")` (the [INV-40] per-agent discriminator)

**Fix 1 — `.author.login` → bare `.author`, `.comments[]` → `.[]`.** The normalized array exposes
`author` (= `.author.login` verbatim, [INV-85]) at top level. Exact-eq is regex-irrelevant.

**Fix 2 — verdict match: `test(_VERDICT_RE; "i")` → `(.body | ascii_downcase | test("<lc _VERDICT_RE>"))`,
drop the `"i"` flag.** Oniguruma `"i"` does Unicode **simple** case-folding — it would widen the
literal ASCII keywords to also match U+212A (Kelvin `K`) / U+017F (long-s `ſ`), a false-positive
widening at the authenticity gate that RE2's ASCII fold never made (verified on-box: `Review PAſSED`
matches `review passed` under Oniguruma `"i"`). `ascii_downcase` (ASCII-only) on BOTH the data and
the pattern restores RE2 parity. The **shell-side** lowercase of `_VERDICT_RE` MUST be
`LC_ALL=C tr '[:upper:]' '[:lower:]'`, NOT bash `${v,,}`: `_VERDICT_RE` contains an uppercase `I`
("Review FA**I**LED"), and bash `,,` under a Turkish locale folds `I` → dotless `ı` ≠ the
data-side `failed` → the most common verdict would silently drop.

**Fix 3 — `// empty` on the verdict jq.** `[…] | last | .body` over a no-match selection yields jq
`null`, which `jq -r` prints as the literal 4-char string `null` (verified on-box). The OLD `gh -q`
path emitted EMPTY on a null result. The caller treats any non-empty body as "verdict present"
(`[[ -n "$body" ]]`), so a literal `null` would mis-resolve a no-verdict poll. `// empty` restores
the empty-string-on-no-match contract.

**Fix 4 — `[[ -z "$_vre_lc" ]] && return 0` before building the jq.** An empty pattern makes
`test("")` match EVERY body (fail-OPEN; verified on-box). Guard returns an empty body so an
unset/empty `_VERDICT_RE` fails CLOSED.

**Plus — caller-side re-sort `sort_by(.createdAt // "", .id // 0) | last`.** `createdAt` is
whole-second, so two same-agent verdicts in the same second tie; `.id` (REST numeric comment id,
monotone with post order) gives `| last` a deterministic total order. Re-sorting an
already-ascending array is idempotent — the [INV-90] verb contract (stable ascending `createdAt`)
is untouched; this only adds `.id` as the tie-break key.

**After (shape):**

```bash
_fetch_agent_verdict_body() {
  local _agent="$1" _sid="$2"
  # Lazy, in-function self-source of the ITP seam (see "Self-source guard" below).
  if ! declare -F itp_list_comments >/dev/null 2>&1; then …readlink -f → lib-issue-provider.sh… fi
  # Fix 4: empty _VERDICT_RE → fail CLOSED.
  local _vre_lc; _vre_lc="$(printf '%s' "${_VERDICT_RE:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ -z "$_vre_lc" ]] && return 0
  local _auth_predicate _agent_predicate _verdict_jq
  if [[ -n "${BOT_LOGIN:-}" ]]; then
    _auth_predicate="(.author == \"${BOT_LOGIN}\") and (.createdAt >= \"${WRAPPER_START_TS}\") and (.body | test(\"Review Session\"))"
  else
    _auth_predicate="(.createdAt >= \"${WRAPPER_START_TS}\") and (.body | test(\"Review Session.*${_sid}\"))"
  fi
  _agent_predicate="(.body | test(\"Review Agent: ${_agent}\"))"
  _verdict_jq="[ .[] | select(${_auth_predicate} and ${_agent_predicate} and (.body | ascii_downcase | test(\"${_vre_lc}\"))) ] | sort_by(.createdAt // \"\", .id // 0) | last | .body) // empty"
  itp_list_comments "$ISSUE_NUMBER" 2>/dev/null | jq -r "(${_verdict_jq}" 2>/dev/null || true
}
```

### Self-source guard — LAZY (in-function), not top-level

`autonomous-review.sh` sources `lib-review-poll.sh` (line 60) **before** `lib-issue-provider.sh`
(line 207). A top-level `declare -F itp_list_comments`-gated self-source (the `lib-review-verdict.sh`
idiom) would self-source the seam at lib-load time — changing the production source order. So the
guard goes **inside `_fetch_agent_verdict_body`** (it covers both entry paths into the function: the
poll loop and the observe-loop comment branch), needed only for standalone unit sourcing —
production is unaffected because by the time the poll runs, the wrapper has already sourced the seam.

## Scope rationale — S1 + S2 stay in ONE PR

Both migrate behind the SAME already-shipped verb (`itp_list_comments`), neither adds a new verb or
entry-point script, and `cutover-baseline.json` is one artifact whose regeneration is cleaner as one
atomic step than two sequential rebases against a moving baseline. S1 and S2 share no code, so
splitting buys no isolation while doubling the rebase-against-moving-baseline surface.

## Rollback + silent-failure detection

`_fetch_agent_verdict_body` is the verdict choke-point — a subtle break is SILENT (verdicts drop to
`unavailable`, reviews stall, nothing crashes). Revert is a clean single-commit `git revert` (lib +
2 baseline lines + docs; no schema coupling) then `npx skills update -g`. Detection signal
post-update: watch the FIRST review tick for a broad spike in `unavailable` verdicts across projects.

## Self-hosting / post-merge

LIVE-wrapper files (`lib-review-poll.sh` + `dispatcher-tick.sh`) — dev in a worktree only; the
dispatcher serializes same-file LIVE-wrapper batches. NO new entry-point script (lib + a baseline
data file + docs) → **no `install-project-hooks.sh` re-run**; Step-1 `npx skills update -g`
(autonomous-dispatcher) suffices.

## Out of scope

- `dispatcher-tick.sh` timeline `gh api .../timeline` read → needs a NEW `itp_label_event_ts` verb
  (separate second-tier #296 item). Its `cutover-baseline.json` entry STAYS.
- Other #296 mint-verb tiers (chp_pr_comment family, itp_read_comment, etc.) — separate issues.
- No change to `_VERDICT_RE` itself, the poll cadence, INV-43 windowing, or the classify logic.
