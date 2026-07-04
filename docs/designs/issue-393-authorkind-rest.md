# Design — REST-sourced authorKind for the normalized comment shape (#393)

> 5th member of the BOT_LOGIN-empty bug class (siblings: #341 r13/r15, #389/#390).
> #390 gave the dispatcher a structural verdict anchor with an app-mode
> `authorKind != "human"` gate — but `authorKind` itself was derived from a
> GraphQL-shaped login that CANNOT satisfy it.

## Root cause

`itp_github_list_comments` reads `gh issue view --json comments` (GraphQL) and derives:

```
self  ⇔ login == $BOT_LOGIN          (BOT_LOGIN empty in the dispatcher → never)
bot   ⇔ login | endswith("[bot]")    (GraphQL STRIPS the suffix → never)
human ⇔ else                          (always, for App-authored comments)
```

REST (`/repos/{repo}/issues/{n}/comments`) returns `user.login = "<slug>[bot]"`
and `user.type = "Bot"` for the same comment — the data exists; the source API
was wrong for this derivation. Verified live: same comment, GraphQL `my-claw`,
REST `my-claw[bot]` + `type=Bot`.

Blast: #390's gate rejects every genuine verdict → `verdict=none` → INV-12 park
on EVERY app-mode remote review-FAIL (observed: Lane-GC P2 stuck 2h+). The
INV-105 breaker's `authorKind != "human"` idempotency check is likewise inert.

## Fix shape

**`itp_github_list_comments` switches its data source to REST**:

```
gh api --paginate --slurp "repos/$REPO/issues/$issue/comments" | jq '
  [ .[][]                                # --slurp wraps pages; flatten
    | { id: .id,                          # numeric — the URL-capture hack retires
        author: (.user.login // null),    # VERBATIM incl [bot] — what spec §3.3 [M5] always required
        authorKind: ( ... user.type=="Bot" → "bot"; login matches BOT_LOGIN raw-or-stripped → "self"; else "human"),
        body: (.body // ""),
        createdAt: (.created_at // null) }
  ] | sort_by(.createdAt // "", .id // 0)'
```

- `--slurp` (gh ≥2.92 confirmed) wraps each page in an outer array → `.[][]`
  flattens; plain `--paginate` would emit concatenated arrays jq reads as
  separate documents. Complete-set contract (§3.5) preserved.
- **author becomes verbatim-`[bot]`** — this ENFORCES the spec's existing
  contract ("user.login including the `[bot]` suffix verbatim") that the
  GraphQL leaf silently violated. Docs authority: spec wins over shipped code.
- `self`: compare against `BOT_LOGIN` raw AND `[bot]`-stripped (a wrapper that
  resolved BOT_LOGIN via `gh api user` gets the raw suffixed form for an App
  installation token... in practice `gh api user` 403s there, but token-mode
  PATs have no suffix in either API — the dual compare is pure tolerance).
- `authorKind`: `user.type == "Bot"` → bot. Robust to future GitHub login
  cosmetics; no string suffix sniffing.

**Consumers audited** (exact-eq `.author == BOT_LOGIN`): lib-review-poll
`_fetch_agent_verdict_body`, lib-dispatch INV-85 `select(.author == $dev)`,
classify_recent_review_verdict's BOT_LOGIN arm. All compare against BOT_LOGIN
resolved in the REVIEW WRAPPER's process via `gh api user --jq .login` — for a
GitHub App installation token that endpoint 403s (BOT_LOGIN stays empty →
these arms don't run); for token mode the PAT login is suffix-free in both
APIs. Where BOT_LOGIN IS resolvable it comes from the SAME REST-style
identity, so verbatim author matches. No consumer parses `id` from URLs.

**`_itp_github_state_read` (W1a comments field)**: today NO caller consumes
`.comments[].authorKind` from the state-read output (list_pending_dev requests
`number,labels,comments` but the tick only reads `.number`; the comments field
exists for future INV-85-style joins). Fixing it via a second REST call per
issue would multiply API cost (N issues × 1 extra call per tick). Decision:
**derive the state-read comments' authorKind with the same dual-form/bot-type
logic but from the ONLY data GraphQL exposes** — i.e. keep GraphQL there,
fix the derivation to also treat a `BOT_LOGIN`-stripped match as self, and
DOCUMENT that state-read `authorKind` cannot distinguish App bots (GraphQL
limitation) — it reports `human` for App authors and MUST NOT be used for
authenticity gates (spec note + code comment). The AUTHORITATIVE per-issue
read is `itp_list_comments` (REST). The degraded fixture mirrors
`itp_list_comments` (REST-shaped stub → same jq), keeping the conformance
runner's shape assertions meaningful.

## Tests

`tests/unit/test-itp-read-leaves.sh` — argv pin updated (gh api --paginate
--slurp ...), REST-shaped stub payloads, new: Bot-type normalization, verbatim
author, numeric id, 2-page slurp flatten, self dual-form. New regression in
`test-classify-recent-review-verdict.sh`: app-mode + BOT_LOGIN empty +
bot-authored anchored trailer ⇒ classifies (pre-fix: none). Docs: spec §3.3
[M5] + INV-90 + INV-105 note.
