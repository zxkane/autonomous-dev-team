# Design — ITP write-leaf migration (#283)

Migrate every Issue-Tracker **write** leaf behind the ITP verb seam introduced by
#280 (dispatch skeleton) and #281 (read leaves), with **ZERO behavior change**.
This is the write half of the GitHub-refactor-only first deliverable of the
pluggable ITP/CHP providers work (`docs/pipeline/provider-spec.md`, the authority).

## Scope (5 write verbs)

Provider impls land in `providers/itp-github.sh`; the `itp_*` shims already exist
in `lib-issue-provider.sh` (#280). Only the innermost `gh` leaf moves; all
INV-coupled logic (marker text, retry, dedup, idempotency, fail-closed rc) stays
caller-side (spec §3.1 mapping appendix).

| Verb | GitHub leaf (byte-identical) | Replaces | Cap gate |
|---|---|---|---|
| `itp_github_transition_state ISSUE REMOVE ADD` | `gh issue edit … --remove-label R --add-label A` (empty side omits the flag) | `label_swap` (lib-dispatch.sh) | — |
| `itp_github_post_comment ISSUE BODY` | `gh issue comment ISSUE --repo $REPO --body BODY` | every `gh issue comment` site (agent + dispatcher markers) | `marker_channel` |
| `itp_github_edit_comment ISSUE COMMENT_ID BODY` | `gh api -X PATCH …/issues/comments/ID -f body=BODY` | lib-review-e2e.sh INV-46 SHA stamp | `edit_comment` |
| `itp_github_mark_checkbox ISSUE NEW_BODY` | `gh api …/issues/ISSUE --method PATCH --field body=NEW_BODY` | mark-issue-checkbox.sh PATCH leaf | `body_checkbox` |
| `itp_github_provision_states NAME COLOR DESC` | `gh label view`/`gh label create --color hex --description d` | setup-labels.sh create loop | `label_colors` |

## INV numbering — REFERENCE INV-89, do NOT mint a new INV

The issue body predates the merge of #278/#279 and says "new INV-NN (next free =
INV-86)" + "REFERENCE INV-88 (marker_channel choke-point)". Both are **stale**:
- #278 took **INV-86** (PR↔issue binding); #279 took **INV-87..90**.
- The marker-channel **write** choke-point is **INV-89** — *already authored by
  #279* ("every machine marker — agent AND dispatcher (INV-18/INV-39 included) —
  is posted only through the declared `marker_channel`").

Per the docs-are-authoritative rule, this PR does **NOT** create a new invariant.
It flips **INV-89**'s Status from SPEC-DEFINED → IMPLEMENTED-for-GitHub-(#283),
updates its Producer/Consumer/Tests, and adds the AC-required cross-references to
INV-89 from INV-18 / INV-39 / INV-46 / INV-25.

## Cut lines (per spec §7.1 taxonomy)

### `label_swap` (a, separable leaf) → `itp_transition_state`
`label_swap()` body becomes `itp_transition_state "$issue_num" "$remove" "$add"`.
The `[ -n "$remove" ]`/`[ -n "$add" ]` guards stay caller-side (they decide which
flags to pass); `itp_github_transition_state` rebuilds the same `args=()` and emits
the byte-identical `gh issue edit`. The `label_swap` **callers** (literal
`label_swap "$n" "X" "Y"`) are untouched → the spec-drift C.4/C.5 Form-1
discovery is preserved.

### `mark_stalled` inline `gh issue edit` → `label_swap`
`mark_stalled` had an inline `gh issue edit … --remove-label "pending-dev"
--add-label "stalled"` (NOT via `label_swap`). To route the transition through
the single choke-point (INV-87/INV-89, spec mapping `mark_stalled → itp_transition_state`)
**and** keep the spec-drift gate green, it is folded into a literal `label_swap
"$issue_num" "pending-dev" "stalled"` call. This:
- routes the transition through `itp_transition_state` transitively (via `label_swap`),
- keeps the write discoverable by Form-1 (`label_swap` literal labels) so the C.4
  count for `pending-dev|stalled` is unchanged,
- requires the `spec-codesite-map.json` `sites[]` anchor for that movement to move
  from the now-removed `--add-label "stalled"` literal to the `label_swap` call
  (same-PR per the #274 spec-drift discipline).

This is a pure behavior-preserving refactor: same labels, same order, same single
bundled atomic edit (`label_swap` is `gh issue edit … "${args[@]}"`).

### The 18 `gh issue comment` sites (a, separable leaves) → `itp_post_comment`
Each site's BODY (including the verbatim INV-18 `<!-- dispatcher-token: … -->`
and INV-39 `<!-- dep-block:… -->` HTML markers) is composed CALLER-side and passed
as the BODY arg. `itp_github_post_comment` emits `gh issue comment ISSUE --repo
$REPO --body BODY` byte-identically. The dedup reads (`itp_list_comments | jq …`),
the `2>/dev/null || true` fail-safe suffixes, and the retry-`&&` chains stay
caller-side. AC: `grep -c 'gh issue comment' lib-dispatch.sh` == 0.

> The two `mark_stalled` / `handle_completed_session_routing` **orchestrators**
> remain caller-side glue (their routing decisions, `dispatch dev-new`, log
> truncate, `pid_alive` stay put) — only their comment/label **leaf I/O** moves
> behind the verbs, exactly as spec §7.1(b) prescribes. The orchestrator
> restructuring itself is owned by `entangled-orchestrators-golden-trace`.

### INV-46 SHA stamp (a, separable leaf) → `itp_edit_comment`
lib-review-e2e.sh `:486` PATCH → `itp_edit_comment "$PR_NUMBER" "$_comment_id"
"$new_body"`. The GET-comment-id (`:461`) and GET-body (`:473`) READ leaves are
**out of scope** (itp-reads territory). When `itp_caps edit_comment` == 0 the
caller falls back to re-posting **the full report body WITH the SHA marker
appended** (`$_new_body`, the same body the PATCH path would write) as a fresh
comment via `itp_post_comment` — NOT a marker-only post. `_fetch_sha_evidence`
returns the `last` SHA-marked comment's FULL body to the dual-signal E2E gate, so
a marker-only fallback would pass the gate with no report/screenshots/AC (the
marker-only-fabrication hole [INV-46] closes; review [P1] r3). For GitHub
(`edit_comment=1`) the PATCH path is taken unchanged — same idempotent SHA-marker
skip and fail-closed return.
lib-review-e2e.sh self-sources `lib-issue-provider.sh` (readlink-f BASH_SOURCE
idiom) because `autonomous-review.sh` does not source it.

### `mark-issue-checkbox.sh` PATCH (a) → `itp_mark_checkbox`
The GET-body + `- [ ]`→`- [x]` awk rewrite + not-found/already-checked exit codes
(0/1/2) stay caller-side. Only the final `gh api … --method PATCH --field body=`
leaf moves into `itp_github_mark_checkbox ISSUE NEW_BODY`. The branch keys on the
`body_checkbox` **capability** (`itp_caps body_checkbox`), NOT `declare -F
itp_mark_checkbox` — the shim is always defined after the seam is sourced, so a
`declare -F` check never falls back and a backend without the leaf would crash with
`itp_<p>_mark_checkbox: command not found` (review [P1] r4). `body_checkbox=1` →
markdown-checkbox path (`itp_mark_checkbox`, the only live branch); `body_checkbox=0`
→ the documented native-subtask remap, defined-not-implemented this PR → fail
LOUD-but-clean (no missing-leaf crash). When `itp_caps` is absent (script run
standalone without the skill tree) the inline `gh api` PATCH is the self-contained
fallback. The script sources the provider seam.

> **AC reconciliation (`itp_mark_checkbox` arity).** The issue AC shows
> `itp_mark_checkbox "$ISSUE_NUMBER" "$CHECKBOX_TEXT"` *and* "the awk body rewrite
> stays caller-side". Those are mutually exclusive if the verb only receives the
> selector. The load-bearing clause is "PATCH leaf → `itp_mark_checkbox`; keep awk
> caller-side", so the verb is the **PATCH primitive** receiving the already-
> rewritten body: `itp_mark_checkbox ISSUE NEW_BODY`. Honored: PATCH leaf moves,
> awk + exit codes stay caller-side, `body_checkbox` is the documented branch.

### `setup-labels.sh` create loop (a) → `itp_provision_states`
The 9-label `name|color|description` table stays caller-side. The per-label
view-or-create leaf moves into `itp_github_provision_states NAME COLOR DESC`,
emitting the byte-identical `gh label view` / `gh label create --color hex
--description d`. The branch keys on the `label_colors` **capability** (`itp_caps
label_colors`), NOT `declare -F itp_provision_states` (same shim-always-defined
trap as the checkbox case, review [P1] r4). `label_colors=1` → `itp_provision_states`
emits the `--color` hex (the only live branch); `label_colors=0` → the documented
color-omitted path, defined-not-live this PR → fail LOUD-but-clean (no missing-leaf
crash). When `itp_caps` is absent the inline gh-label leaf is the self-contained
fallback. The script sources the provider seam.

## Repo-wide ITP-issue-comment cutover (post-review expansion)

A review pass flagged [BLOCKING/P1] that the INV-89 Rule ("EVERY machine marker …
posted only through the declared `marker_channel`" / "the single choke-point for
**ALL** machine markers" — authored by #279/#281, normative) was satisfied only in
`lib-dispatch.sh`, while `autonomous-dev.sh`, `autonomous-review.sh`,
`dispatcher-tick.sh`, and `lib-review-verdict.sh` still emitted raw `gh issue
comment`. A `marker_channel=text` / non-GitHub provider would bypass the seam for
those session-report and verdict-trailer markers. The finding is correct: the
spec's "ALL" is a repo-wide contract, not a lib-dispatch.sh-local one.

Resolution (zero behavior change): route **every machine-marker ISSUE comment** in
those four files through `itp_post_comment` too —
- `autonomous-dev.sh`: 5 sites (2 heredoc session-report bodies + 3 resume-fallback markers),
- `autonomous-review.sh`: 17 sites (verdict / diagnostic / held / smoke comments + the Reviewed-HEAD trailer capture),
- `dispatcher-tick.sh`: 9 sites (PTL / crash / no-PR / pending-review markers),
- `lib-review-verdict.sh`: 1 site (`emit_verdict_trailer`'s `<!-- review-verdict: … -->`).

Each file gains a guarded `lib-issue-provider.sh` self-source (mirroring
`lib-dispatch.sh` / `lib-review-e2e.sh`) so `itp_post_comment` resolves even when the
file is sourced standalone or by the review wrapper (which does not source
`lib-dispatch.sh`). All sites use `--repo "$REPO"` (global), which the verb hardcodes,
so the emitted `gh issue comment … --body` argv is byte-identical. `$REPO` is loaded
at wrapper startup (`load_autonomous_conf`), so the verb's `$REPO` read is always in
scope — the verdict-trailer unit test now exports `REPO` to match (it previously
relied on the local `$repo` param the pre-cutover code used).

**Still out of scope** (unchanged): `gh pr comment` / review-thread replies (CHP,
owned by chp-pr-lifecycle); and the CI **cutover-guard lint** that mechanically
rejects future raw-gh (owned by the cutover-guard-lint sibling — this PR does the
migration; that sibling adds the enforcing lint).

## No new entry-point script
Every change is to an existing entry script (`setup-labels.sh`,
`mark-issue-checkbox.sh`) or a `lib-*.sh` / `providers/*.sh` sourced via the
readlink-f skill tree (INV-14/INV-65). No `install-project-hooks.sh` re-run is
required on consumers (Step 1 `npx skills update -g` alone). PR carries no
`## Post-install` note (lib/provider-only changes).

## Test strategy (mirrors `tests/unit/test-itp-read-leaves.sh`)
`tests/unit/test-itp-write-leaves.sh`:
1. **Golden-trace** per write leaf — record the exact `gh` argv emitted, assert
   byte-identical (incl. transition empty-REMOVE/empty-ADD flag omission; the
   INV-18 `dispatcher-token` + INV-39 `dep-block` marker bodies verbatim).
2. **Dispatch routing** — `itp_<verb>` → `itp_github_<verb>` under `ISSUE_PROVIDER=github`.
3. **`.caps` parse** — `edit_comment=1`, `body_checkbox=1`, `label_colors=1`,
   `marker_channel=html` from `itp-github.caps`.
4. **Capability-branch** via the named degraded fake provider (`edit_comment=0`
   fallback re-posts the full report body + marker, never marker-only — driven
   through the real `_stamp_browser_evidence_marker`; `body_checkbox=0` /
   `label_colors=0` fallbacks).
5. **`marker_channel` regression** — `itp_github_post_comment` does not strip
   `<!-- … -->` (pins INV-18/INV-39 survival).
6. **Function-mock shim audit** — no function is renamed → existing function-level
   mocks (`label_swap`, `post_dispatch_token`, …) still bind; `grep -c 'gh issue
   comment' lib-dispatch.sh` == 0.

The whole existing unit suite + conformance suite MUST pass UNCHANGED (run with
`env -u PROJECT_DIR` for CI parity).
