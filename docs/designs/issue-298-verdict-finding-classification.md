# #298 — Review-verdict per-finding actionability classification

```
status: DESIGN — understand→design→verify done (live-code-verified); pending user approval before implementation
issue: #298 (follow-up to the #286 deadlock retrospective; sibling of #297 circuit-breaker)
scope: review wrapper EMITS per-finding classification + dispatcher routes only dev-actionable findings to dev-resume
out-of-scope: PASS-merge path (INV-52/INV-79); new label-state-machine edges (the halt is #297)
```

## 1. Problem & motivation

A review verdict today is verdict-level only (`passed` / `failed-substantive` / `failed-non-substantive`). It cannot say *who can fix a finding*. So a finding the dev agent **provably cannot act on** — e.g. "edit `.github/workflows/ci.yml`" when the agent's GitHub-App token lacks `workflows` scope (the exact #286 deadlock) — is emitted as a `failed-substantive` blocking finding, and the dispatcher re-dispatches `dev-new` forever on something no dev-resume can satisfy.

#298 gives each blocking finding an actionability classification, and routes only dev-actionable findings back to dev. Non-actionable findings escalate (reusing the existing `stalled` escalation), so the loop can't form.

**Relationship to the existing INV-85 guard (review P2-3 — the value-add must be honest).** The #286 "re-dispatch dev-new forever" framing is no longer literally true: INV-85 Branch A (`dev_report_bot_unfixable`, lib-dispatch.sh ~1573) already **reactively** bounds it — it detects the dev agent's `Resource not accessible by integration` 403 on a protected-path/PR-metadata edit and escalates to `mark_stalled`, bounded N=1 per HEAD. So #298 is NOT "fix an unbounded loop" — it is the **proactive, review-side** complement: (a) skip the first wasted dev-new round-trip (INV-85 only fires *after* a dev agent burns a cycle hitting the 403), and (b) cover non-actionable findings the dev agent would never signal with that exact 403 string (e.g. a finding that asks for a CODEOWNERS change, or any protected path the dev agent simply wouldn't attempt). The incremental machinery (5 schema fields + a trailer token + a new lib + classification rules) is justified by (a)+(b) over the existing reactive guard — not by a loop that is otherwise unbounded.

## 2. The load-bearing constraint (discovered during design)

**The dispatcher cannot read the verdict artifact at routing time.**
- `classify_recent_review_verdict` (`lib-dispatch.sh:841`) and `handle_completed_session_routing` (`lib-dispatch.sh:947+`) route purely off the `<!-- review-verdict: … -->` **comment trailer** — verified: zero `runs/` / artifact-filesystem reads in `lib-dispatch.sh` or `dispatcher-tick.sh`; the dispatcher has no run-id.
- Under the production topology (`EXECUTION_BACKEND=remote-aws-ssm`) the artifact is written on the **Singapore wrapper box** while routing runs on the **Tokyo dispatcher box** — the dispatcher physically cannot `cat` it.

**Consequence (the central design decision):** the rich per-finding objects ride the **artifact** (humans + future on-box consumers); the dispatcher routes off a single coarse boolean **`dev-actionable=true|false`** folded into the **trailer** the review wrapper already emits. Artifact = rich-but-local; trailer = coarse-but-portable. This is the only design that works on the real topology.

## 3. Design

### 3.1 Artifact schema — rich per-finding home (agent-authored)
Add five **optional** properties to `definitions.finding` in `docs/pipeline/schemas/verdict-artifact.schema.json` (keep `additionalProperties:false`; do NOT touch the `allOf` FAIL⇔≥1-blocking rule):

```json
"actionable_by_dev_agent":   { "type": "boolean" },
"requires_human":            { "type": "boolean" },
"requires_privileged_token": { "type": "boolean" },
"blocking_for_merge":        { "type": "boolean" },
"recommended_next_owner":    { "type": "string", "enum": ["dev_agent","human","maintainer"] }
```

A non-actionable finding still lives in `blockingFindings` (it genuinely blocks merge); `actionable_by_dev_agent:false` is what diverts *routing*, NOT array membership — so the FAIL⇔≥1-blocking invariant is byte-identical.

**Defaults (zero-regression keystone):** absent `actionable_by_dev_agent` ⇒ **`true`**; absent `blocking_for_merge` ⇒ membership in `blockingFindings`; absent `requires_*` ⇒ `false`; absent `recommended_next_owner` ⇒ `dev_agent`. A legacy artifact omitting all five behaves exactly as today.

### 3.2 jq structural validator — MUST be widened (packaged-skill default path)
`lib-review-artifact.sh` `_validate_verdict_artifact_jq`'s `is_finding` (≈line 141) hard-codes `(keys - ["title","detail","file","line"]) | length == 0`. New keys would be rejected → `malformed` → verdict dropped (Clause V1). Extend the allow-list AND add type/enum checks for the five fields. This is the default path in deployed skills (the schema file lives under `docs/`, outside the skill tree).

### 3.3 Trailer — the dispatcher-portable signal
Extend `emit_verdict_trailer` (`lib-review-verdict.sh:33-63`). New grammar (only on `failed-substantive`):
```
<!-- review-verdict: failed-substantive [cause=<tok>] [dev-actionable=true|false] -->
```
`dev-actionable` = aggregate **OR** over blocking findings: `true` iff ≥1 blocking finding has effective `actionable_by_dev_agent=true`. `dev-actionable` is a **separate key**, so the `cause` whitelist (`^[a-z0-9-]+$`, line 53) is untouched. **Default = omit the token ⇒ dispatcher treats as `true`** (legacy wrapper / artifact absent ⇒ today's behavior). Adding an optional token to the function body does NOT add a call site → the five `emit_verdict_trailer` count-pin tests (`=13`) stay green.

### 3.4 Classification (review-agent side)
- **Protected-paths list** — new lib `skills/autonomous-dispatcher/scripts/lib-review-classify.sh` (a **lib**, so no installer re-run):
  ```sh
  : "${REVIEW_PROTECTED_PATHS:=.github/workflows/** CODEOWNERS .github/CODEOWNERS}"
  review_path_is_protected() { ...extglob match over REVIEW_PROTECTED_PATHS... }
  ```
  Documented as a conf override in `autonomous.conf.example`. This is the primary, deterministic policy surface.
- **Token-scope probe** — read the **config var** `AGENT_TOKEN_PERMISSIONS` (`lib-auth.sh:74`, defaults to `{"contents":"write","issues":"write","pull_requests":"read"}` — no `workflows`). No API call, no sidecar, no daemon edit:
  ```sh
  agent_token_has_workflow_scope() { jq -e 'has("workflows")' <<<"$AGENT_TOKEN_PERMISSIONS" 2>/dev/null; }  # fail-open rc1 when absent
  ```
- **Per-finding rule the agent applies:**
  ```
  if finding path matches REVIEW_PROTECTED_PATHS:
      requires_privileged_token = (path under .github/workflows/** AND token lacks workflows scope)
      actionable_by_dev_agent   = false ; requires_human = true ; recommended_next_owner = "maintainer"
  else:
      actionable_by_dev_agent   = true  ; recommended_next_owner = "dev_agent"
  ```
- **Wrapper recomputes the aggregate `dev-actionable` DURING the resolution loop (while `_art_json` is live), stashed into a NEW surviving global array — NOT at the emit site [corrected per review P1-2].** Critical: the per-agent artifact snapshot dir is `rm -rf`'d at `autonomous-review.sh:3006-3016` ("nothing reads these files past this point"), which runs BEFORE the substantive-FAIL `emit_verdict_trailer` (~line 3532). `_art_json` is a loop-local var (~2377); `AGENT_ARTIFACT_SNAPSHOTS[$_i]` holds only a path string to a now-deleted file. So re-reading the snapshot at the emit site would always return `absent` → aggregate defaults `true` → **the feature would be inert**. Instead: in the resolution loop (~2366-2391, where `_art_json` is live and BEFORE the 3016 cleanup), compute each agent's effective aggregate `actionable_by_dev_agent` from `_art_json` and store it in a new global `declare -a AGENT_DEV_ACTIONABLE=()` (sibling of `AGENT_VERDICT_BODIES`). The substantive-FAIL emit then derives the trailer token from `AGENT_DEV_ACTIONABLE[$_i]` (a surviving global), not from the deleted file. This is also TOCTOU-safe (mirrors INV-49) — the aggregate is computed from the validated artifact, not trusted from an agent-emitted summary, so a buggy agent can't forge `dev-actionable=true` on a protected-path finding.

### 3.5 Dispatcher routing — no new label edge
- **Function:** `handle_completed_session_routing`, `failed-substantive)` case (`lib-dispatch.sh:1000`).
- **Parse:** widen the trailer regex (`lib-dispatch.sh:882`) to capture optional `dev-actionable`; `classify_recent_review_verdict` gains an **optional** 5th out-param (default `"true"` when token absent).
- **Branch B′** (between Branch B end ≈1070 and Branch C dev-new ≈1103-1105):
  ```
  if [ "$_dev_actionable" = "false" ]; then
     <idempotent per-HEAD operator @${REPO_OWNER} notice, reason=non_actionable_finding>
     mark_stalled "$issue_num"   # REUSES the existing pending-dev→stalled site (INV-85) — NOT a new edge
     return 0                    # Branch C dev-new never reached
  fi
  # else fall through to Branch C — unchanged
  ```
- **"Escalate to human" for #298 = don't dev-resume + reuse the existing `mark_stalled` + an idempotent operator notice carrying `reason=non_actionable_finding`** (distinct from retry-exhaustion's `reason=max_retries_exceeded`, so the two `stalled` sources are auditable and #297 can later split the terminal state). No halt label / counter / new state — that is **#297**. Reusing `mark_stalled` adds a new *call site* of the existing `pending-dev→stalled` transition, not a new edge. **(llm-team-decided, §8.1.)**

## 4. The five verify-pass corrections (all folded in above)

The adversarial verify pass against the live code caught five landing hazards; the design above already incorporates them. Recorded explicitly so implementation doesn't regress to the naive version:

1. **[was BLOCKING] INV triage tag vocabulary.** `test-spec-drift.sh:584-593` only accepts `_Triage (issue #236): [machine-checked: <path> | design-rationale | superseded]_` within 2 lines of the `## INV-N:` heading. **INV-92** (allocated to #298 per §8.2 — INV-86..91 are ALL already taken, verified) MUST use `[machine-checked: tests/unit/<the new dispatcher test>]` — NOT `[P1]`. After #298 lands, update #297's body to claim **INV-93**.
2. **[was BLOCKING] do NOT edit spec-codesite-map.json / spec-guard-map.json.** `check-spec-drift.sh` C.4 reconciles the COUNT of literal `--add-label "stalled"` write sites against the manifest. Branch B′ adds a *call* to `mark_stalled()`, not a new physical `--add-label "stalled"` write → discovered count stays 1. Adding a manifest entry makes manifest(2) > discovered(1) → C.4 RED. Reuse the existing `pending-dev→stalled` movement; touch NO spec map, NO transitions.json, NO state-machine.md.
3. **[was BLOCKING] optional 5th arg, guarded.** `classify_recent_review_verdict` has 8+ existing callers passing only 4 args (`test-classify-recent-review-verdict.sh:127…`). A bare `printf -v "$5"` crashes them under `set -e`. Implement as: `local _da_var="${5:-}"; … ; [ -n "$_da_var" ] && printf -v "$_da_var" '%s' "$_dev_actionable"`.
4. **[was MAJOR] token probe via config var, not API sidecar.** The naive sidecar plan would require editing the detached `gh-token-refresh-daemon.sh` (race-prone). The scope is deterministically in `AGENT_TOKEN_PERMISSIONS` — `jq -e 'has("workflows")'`. Simpler and correct.
5. **[was MAJOR; SUPERSEDED by P1-2 below] emit-site categorization.** The four non-aggregate `failed-substantive` emit sites (crash-trap, E2E gate, missing-bot, merge-conflict) are genuinely dev-actionable → hardcode `dev-actionable=true` (fail-open). Only the agent-posted-FAILED-verdict aggregate emit carries the artifact-derived token. **CORRECTION (P1-2):** the recompute does NOT happen at the emit site re-reading `AGENT_ARTIFACT_SNAPSHOTS[$_i]` — that file is deleted by the line-3006-3016 cleanup before the emit. The aggregate is computed in the resolution loop (~2366-2391, `_art_json` live) into a new global `AGENT_DEV_ACTIONABLE[]`; the emit reads that array. See §3.4. **All line numbers in this doc are STALE (≈+30 to +160 lines vs the author's snapshot) — re-anchor by symbol/function, not line: actual emit sites ≈806/1544/3217/3298/3532; trailer regex ≈lib-dispatch.sh:912; AGENT_TOKEN_PERMISSIONS ≈lib-auth.sh:90.**

(MINOR) `recommended_next_owner` = `maintainer`, mapped to the same `@${REPO_OWNER}` mention INV-85 uses, so both escalations read consistently.

## 5. Zero-behavior-regression argument

Every new signal is additive with a fail-open default equal to current behavior:
1. **PASS path** untouched; schema `allOf` unchanged ⇒ PASS artifacts validate identically.
2. **Common case (all findings actionable):** wrapper emits `dev-actionable=true` (or omits); dispatcher regex captures it but Branch B′'s `if = "false"` is false ⇒ falls straight through to Branch C `dispatch dev-new` — today's exact path.
3. **Legacy wrapper / artifact absent / malformed:** no token ⇒ `_dev_actionable` defaults `"true"` ⇒ Branch C (matches the `dev_report_bot_unfixable` fail-open convention, `lib-dispatch.sh:1525-1530`).
4. **Schema/jq:** all five fields optional ⇒ a verdict artifact omitting them validates exactly as before.
5. **Existing tests** stay green; no `emit_verdict_trailer` / `classify` call-count pin changes (no new call sites; optional arg guarded).

The ONLY behavior change fires when a `failed-substantive` verdict carries an explicit `dev-actionable=false` — a state today's wrappers never emit. Strictly additive.

## 6. Files touched

| File | Type | Change |
|---|---|---|
| `lib-review-classify.sh` | **NEW lib** | protected-paths matcher + `agent_token_has_workflow_scope` (config-var probe) |
| `lib-review-artifact.sh` | lib | jq validator allow-list + type checks; comment renderer surfaces owner |
| `lib-review-verdict.sh` | lib | `emit_verdict_trailer` gains optional `dev-actionable` token |
| `lib-dispatch.sh` | lib | trailer regex widen; `classify_recent_review_verdict` optional 5th arg; Branch B′ |
| `autonomous-review.sh` | entry (edit) | prompt template/rules; aggregate recompute + emit at line 3373; hardcode `=true` at 754/1460/3121/3199 |
| `autonomous.conf.example` | data | `REVIEW_PROTECTED_PATHS` doc |
| `docs/pipeline/schemas/verdict-artifact.schema.json` | spec | 5 optional finding fields |
| `docs/pipeline/invariants.md` | spec | INV-92 (machine-checked triage tag) |
| `docs/pipeline/review-agent-flow.md` | spec | classification step |
| `tests/unit/test-review-classify.sh` (new), `test-review-artifact.sh`, `test-classify-recent-review-verdict.sh`, `test-handle-completed-session-routing.sh` | tests | §7 |

**Post-install: NONE.** Only a new `lib-*.sh` is added (resolved via `readlink -f` skill tree) + edits to existing files. After merge: **Step 1 only** (`npx skills update -g`), no installer re-run, no `## Post-install` note. (INV-92 is allocated to #298 up front per §8.2 — INV-86..91 are all taken; after #298 lands, #297's body is updated to claim INV-93 — no rebase-renumber gamble.)

## 7. Test plan

**Review-side** (`test-review-classify.sh` new + `test-review-artifact.sh`):
- `review_path_is_protected`: `.github/workflows/ci.yml`→0, `src/foo.ts`→1, `CODEOWNERS`→0.
- `agent_token_has_workflow_scope`: `{"workflows":"write",...}`→0; default perms (no workflows)→1.
- jq validator: accepts all 5 fields with valid types; rejects `recommended_next_owner:"banana"` / `actionable_by_dev_agent:"yes"`; still accepts legacy `{title}`-only finding.
- aggregate trailer derivation: protected-path blocking finding ⇒ `dev-actionable=false`; normal blocking ⇒ `=true`; field omitted ⇒ no token.

**Dispatcher-side** (`test-classify-recent-review-verdict.sh` + `test-handle-completed-session-routing.sh`):
- `classify_recent_review_verdict` parses `dev-actionable=false`; absent ⇒ default `true`; 4-arg legacy callers still work (optional-arg guard).
- `handle_completed_session_routing` `failed-substantive` + `dev-actionable=false` ⇒ posts escalation + `mark_stalled`, NO `dispatch dev-new`.
- `+ dev-actionable=true` (HEAD-progress) ⇒ Branch C `dispatch dev-new` (regression).
- `+ no token` (legacy) ⇒ Branch C (fail-open regression).
- idempotency: second tick same HEAD + `false` ⇒ no duplicate notice.

## 8. Decisions (RESOLVED)

1. **`escalate to human` minimal behavior → A + structured reason (RESOLVED).** A 7/8-model llm-team panel (session `issue298-escalate-decision`, zero dissent) chose **option A**: on a `failed-substantive` verdict with `dev-actionable=false`, call the existing `mark_stalled()` (the already-present `pending-dev→stalled` transition — a new *call site*, NOT a new label edge), AND tag the notice with a structured `reason=non_actionable_finding` (distinct from retry-exhaustion's `reason=max_retries_exceeded`). Rationale: option B (leave it `pending-dev`, don't dev-resume) is a fatal *soft loop* — the issue hangs in `pending-dev` forever, is invisible to the operator, and gets re-scanned every tick; the "remember-it-was-skipped" marker that B would need IS the #297 circuit-breaker, so B is neither smaller nor cleaner. A reuses an existing terminal-state action primitive; #297 owns the *detect-non-convergence + halt mechanism*, a separate concern. The `reason` field dissolves the `stalled` semantic ambiguity and seeds #297's future terminal-state split. **§3.1 and §3.5 below are updated to carry the `reason` field.**
2. **INV number → #298 takes INV-92, #297 takes INV-93 (RESOLVED by operator; numbers corrected per review P1-1).** The operator's original "#298=86 / #297=87" was based on a stale "max INV-85" — **verified against the live `invariants.md`, INV-86 through INV-91 are ALL already allocated; the only true gap below max is INV-47.** So #298 uses **INV-92** (next free above max), and after #298 implements, **update #297's body** to use **INV-93**. No rebase-renumber gamble — numbers allocated up front against the verified current max.
3. **Channel: new `dev-actionable` token + schema fields vs. a simpler `cause=non-actionable-finding` (RESOLVED — review P2-4).** A materially smaller variant exists: emit `failed-non-substantive cause=non-actionable-finding` (the `cause` whitelist `^[a-z0-9-]+$` already accepts it) — **zero regex widening, zero schema change, zero new lib, zero dispatcher-parse change**, and `failed-non-substantive` already routes through `REVIEW_RETRY_LIMIT → mark_stalled`. **Rejected** because: (a) `failed-non-substantive` currently bounces to `pending-review`, not the semantically-correct `stalled`, and conflates "infra blip" with "non-actionable finding" — overloading it muddies two distinct meanings the dispatcher already treats differently; (b) it carries NO per-finding data, so the artifact loses the rich `requires_human`/`recommended_next_owner` info that humans + future on-box consumers (and #297) will want; (c) it can't express the mixed case (some findings actionable, some not) — the aggregate-OR is the correct routing signal, which a single coarse `cause` can't carry while also being honest at the finding level. The chosen design costs more now but is the semantically-correct, extensible channel. (If the operator prefers the minimal stopgap, the `cause`-token variant is a valid smaller PR — flagged here so the trade-off is explicit, not hidden.)
