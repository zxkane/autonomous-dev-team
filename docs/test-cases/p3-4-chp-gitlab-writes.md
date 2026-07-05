# Test Cases — P3-4: GitLab CHP write leaves + `chp_file_url` (#419)

**Scope.** Complete `providers/chp-gitlab.sh` with the ten remaining CHP verbs
implemented by this PR (`chp_gitlab_create_pr`, `chp_gitlab_approve`,
`chp_gitlab_merge`, `chp_gitlab_pr_comment`, `chp_gitlab_reply_review_comment`,
`chp_gitlab_resolve_thread`, `chp_gitlab_close_keyword`, `chp_gitlab_commit_file`,
`chp_gitlab_trigger_bot`, `chp_gitlab_count_reviews_by_login`) PLUS the NEW
`chp_file_url` verb (both leaves — `chp_github_file_url` in `chp-github.sh`
byte-identical to the current `upload-screenshot.sh:114` hardcode, and
`chp_gitlab_file_url` in `chp-gitlab.sh` — plus the shim in `lib-code-host.sh`
and the ONE-line rewrite in `upload-screenshot.sh`). `chp_gitlab_request_changes`
is DELIBERATELY ABSENT (cap `rest_request_changes=0`, R8).

**Harness.** `tests/unit/test-chp-gitlab-writes.sh` is hermetic. Each case defines
a **test-local `_gl_api` stub** (the same one P3-3's `test-chp-gitlab-reads.sh`
uses — models the FROZEN #416 signature: `_gl_api [--method M] [--paginate]
[--body JSON] [--tolerate-status CSV] [--status-out FILE] <path>`, sets
`GL_API_STATUS` per invocation, records argv for shape assertions, honors
`_GL_API_FAIL_AT` mid-sequence failure), THEN sources
`providers/chp-gitlab.sh`. Every assertion is leaf-contract-vs-spec (write
shape, positional validation, fail-CLOSED, cross-seam coupling); callers
already abstract behind `chp_<verb>` (phase-2, #347).

**Conventions.**
- Each TC pins the exact leaf argv, the fixture payload sequence (when
  applicable), the expected `_gl_api` invocation trace, and the expected
  leaf stdout / rc.
- "fail-CLOSED" = leaf returns rc≠0 with **no partial stdout**.
- "fail-SAFE (echo 0 rc 0)" = the [INV-94] `chp_count_reviews_by_login`
  contract — ANY failure yields `echo 0; return 0`, so the caller's
  `-eq 0` MISSING decision never sees a non-numeric.
- Recorded `_gl_api` argv is pipe-joined (see the test's `_GL_API_CALL_LOG`).
- `GITLAB_PROJECT` is stored ALREADY URL-encoded (`myGroup%2FmyProject` in
  tests). `GITLAB_HOST=gitlab.example.test`.
- Fixtures live under `tests/provider-conformance/fixtures/payloads/`
  named `gitlab-chp-write-<verb>-<variant>.json` with `.meta` sidecars
  naming `gitlab_version=17.x`.

---

## R2 — `chp_gitlab_create_pr HEAD_BRANCH TITLE BODY`

`POST /projects/${GITLAB_PROJECT}/merge_requests` after resolving the default
branch via `GET /projects/${GITLAB_PROJECT}` → `.default_branch` (one probe per
invocation — no cache, stale-cache hazard). Body:
`{source_branch, target_branch:<default_branch>, title, description, squash:true, remove_source_branch:true}`
(CONTRACT-FIXED per W1e). BODY MAY be empty (title-only broker create is
legitimate — the #400 caller-trace lesson). Positional validation: HEAD_BRANCH
and TITLE non-empty (rc 2 loud, NO HTTP).

| ID | Scenario | Payload seq | Expected _gl_api trace | Expected stdout | Expected rc |
|----|----------|-------------|------------------------|-----------------|-------------|
| TC-P34-001 | happy path — default branch resolved, MR created | `{default_branch:"main"}` → `{web_url:"…", iid:99}` | `GET /projects/myGroup%2FmyProject` then `POST --body <mr-json> /projects/myGroup%2FmyProject/merge_requests` (POST body has `target_branch="main"`, `squash:true`, `remove_source_branch:true`) | web_url from response (opaque) | 0 |
| TC-P34-002 | empty BODY is legitimate | same as 001 with `description:""` in POST body | POST body contains `"description":""` (verbatim) | web_url | 0 |
| TC-P34-003 | default-branch fetch fails → fail-CLOSED | `_gl_api` rc≠0 on invocation #1 | 1 call (`GET /projects/…`) — no POST | empty | ≠0 |
| TC-P34-004 | POST create fails | first `_gl_api` OK, second rc≠0 | 2 calls; POST fired but rc≠0 | empty | ≠0 |
| TC-P34-005 | HEAD_BRANCH empty → rc 2 loud, NO HTTP | (none) | 0 `_gl_api` calls | empty | 2 |
| TC-P34-006 | TITLE empty → rc 2 loud, NO HTTP | (none) | 0 `_gl_api` calls | empty | 2 |

---

## R3 — `chp_gitlab_approve PR BODY` (TWO calls, ordering load-bearing)

Two calls: (1) `POST /projects/…/merge_requests/:iid/approve` — the LOAD-BEARING
action, feeds `chp_gitlab_count_reviews_by_login`; (2) `POST /projects/…/notes`
with `{body}` — diagnostic only. Approve-OK + note-FAIL → rc 0 with WARN on
stderr (wrapper PASS tolerates note-only failure). Approve-FAIL → rc≠0, note
NOT attempted. PR must match `^[0-9]+$` (rc 2 loud), BODY non-empty (rc 2 loud).

| ID | Scenario | Payload seq | Expected _gl_api trace | Expected stdout | Expected rc |
|----|----------|-------------|------------------------|-----------------|-------------|
| TC-P34-007 | both OK — approve first, then note | 2× rc0 payloads | `POST /projects/…/merge_requests/42/approve` then `POST /projects/…/merge_requests/42/notes --body <body>` | (opaque) | 0 |
| TC-P34-008 | approve OK, note FAILS → rc 0 + WARN | approve rc0, `_GL_API_FAIL_AT=2` | 2 calls (same order) | (opaque) | 0 |
| TC-P34-009 | approve FAILS → rc≠0, note NOT attempted | `_GL_API_FAIL_AT=1` | EXACTLY 1 call (`…/approve`) — no note POST | empty | ≠0 |
| TC-P34-010 | PR="" → rc 2 NO HTTP | (none) | 0 calls | empty | 2 |
| TC-P34-011 | PR="abc" (non-numeric) → rc 2 NO HTTP | (none) | 0 calls | empty | 2 |
| TC-P34-012 | BODY="" → rc 2 NO HTTP | (none) | 0 calls | empty | 2 |

---

## R4 — `chp_gitlab_merge PR` — squash + remove-source-branch

`PUT /projects/…/merge_requests/:iid/merge` with body
`{squash:true, should_remove_source_branch:true}`. 405/409/422 responses
surface as-is with the response `.message` preserved through the seam (the
caller's first-500-chars excerpt for the #145 rebase-marker path). PR
`^[0-9]+$` validation (rc 2 loud). [M4]/[INV-33]: `merge_closes_issue=1`
default-branch caveat lives in the caps comment (§5.1) — the caller-side
cap check is UNCHANGED.

| ID | Scenario | Payload | Expected _gl_api trace | Expected stdout | Expected rc |
|----|---------|---------|------------------------|-----------------|-------------|
| TC-P34-013 | happy merge | `{state:"merged", iid:42}` | 1 call: `PUT --body {"squash":true,"should_remove_source_branch":true} /projects/…/merge_requests/42/merge` | response body preserved (contains "merged") | 0 |
| TC-P34-014 | 405 not-mergeable — response `.message` preserved | `_GL_API_STATUS=405`, response body `{"message":"405 Method Not Allowed"}`, `_GL_API_FAIL_AT=1` (transport rc≠0 pass-through per §3.5) | 1 call | empty stdout (`_gl_api` failed) | ≠0 |
| TC-P34-015 | 409 conflict — surface | `_GL_API_STATUS=409`, `_GL_API_FAIL_AT=1` | 1 call | empty stdout | ≠0 |
| TC-P34-016 | PR="" → rc 2 NO HTTP | (none) | 0 calls | empty | 2 |
| TC-P34-017 | PR="abc" → rc 2 NO HTTP | (none) | 0 calls | empty | 2 |

---

## R5 — `chp_gitlab_pr_comment PR --body <string>` (AUDITED positional shape)

**Audit result (matches R5):** all 7 GitHub `chp_pr_comment` call sites
(`lib-review-e2e.sh:351,387,394,409,620` + `autonomous-review.sh:3604,3813`)
pass `--body <string>` — no `--body-file`, no `--edit-last`. The GitLab leaf
parses exactly that shape and POSTs `{body}` to `/projects/…/merge_requests/:iid/notes`.
The GitHub leaf stays byte-identical (unchanged this PR).

| ID | Scenario | Payload | Expected _gl_api trace | Expected stdout | Expected rc |
|----|---------|---------|------------------------|-----------------|-------------|
| TC-P34-018 | happy comment | `{id:1234, body:"…"}` | 1 call: `POST --body {"body":"hello world"} /projects/…/merge_requests/42/notes` | (opaque) | 0 |
| TC-P34-019 | body with special chars (JSON encoded via jq) | `{"body":"line1\nline2\"q\""}` in POST body | 1 call — POST body carries valid JSON | (opaque) | 0 |
| TC-P34-020 | _gl_api fails | (none) | 1 call — rc≠0 | empty | ≠0 |
| TC-P34-021 | PR="" → rc 2 NO HTTP | (none) | 0 calls | empty | 2 |
| TC-P34-022 | missing --body → rc 2 NO HTTP | (none) | 0 calls | empty | 2 |

---

## R6 — `chp_gitlab_reply_review_comment PR COMMENT_ID BODY` (discussions walk + synthesized URL)

GitLab replies attach to a DISCUSSION, not a bare note id. Walk `GET
/projects/…/merge_requests/:iid/discussions` (paginated) to find the discussion
whose `.notes[]` contains `.id == COMMENT_ID`, then `POST
/projects/…/discussions/:discussion_id/notes` with the body. Echo `{id, url}`
parity with GitHub. GitLab's created-note response has `.id` but no
`html_url` → synthesize `url = "https://${GITLAB_HOST}/<decoded-project-path>/-/merge_requests/${pr}#note_${id}"`
using the RAW slash-bearing project path (percent-DECODED from `GITLAB_PROJECT`
— browser URLs use the raw path, NOT the URL-encoded API id).

| ID | Scenario | Payload seq | Expected _gl_api trace | Expected stdout | Expected rc |
|----|---------|-------------|------------------------|-----------------|-------------|
| TC-P34-023 | happy walk — comment on page 2 of discussions | disc-p1 (no match) → disc-p2 (has match; discussion id `d99`) → POST note `{id: 5678}` | 3 calls: `--paginate /projects/…/discussions` walk (transport merges pages), then `POST --body {body} /projects/…/discussions/d99/notes` | `{"id":5678,"url":"https://gitlab.example.test/myGroup/myProject/-/merge_requests/42#note_5678"}` | 0 |
| TC-P34-024 | comment id NOT found in any discussion → rc≠0 | disc pages with no matching note id | walk fully, then rc≠0 (no POST) | empty | ≠0 |
| TC-P34-025 | mid-walk failure → rc≠0 (MANDATORY fixture) | disc-p1 OK, `_GL_API_FAIL_AT=2` at page 2 of `--paginate` (transport surfaces this as rc≠0 on the paginate call) | 1 call → rc≠0 no POST | empty | ≠0 |
| TC-P34-026 | encoded project decodes for the synthesized URL | `GITLAB_PROJECT="my%2Egroup%2Fnested%2Fproj"`, walk finds match | walk + POST | URL contains `my.group/nested/proj` (percent-decoded) | 0 |

---

## R7 — `chp_gitlab_resolve_thread THREAD_ID` (compound-id decode)

Decodes the P3-3 compound `<mr-iid>:<discussion-id>` (pinned in §3.2 [M8]).
Malformed (no colon, non-numeric iid, empty discussion) → rc 2 loud NO HTTP.
`PUT /projects/…/merge_requests/:iid/discussions/:discussion_id` body
`{resolved:true}`. Echoes response `.resolved` verbatim (parity with GitHub
GraphQL `isResolved`). The single-positional `chp_resolve_thread <thread-id>`
seam contract is PRESERVED — no `resolve-threads.sh` change.

| ID | Scenario | Input | Payload | Expected _gl_api trace | Expected stdout | Expected rc |
|----|---------|-------|---------|------------------------|-----------------|-------------|
| TC-P34-027 | happy decode + PUT | `"42:8f1e2d3c"` | `{resolved:true}` | 1 call: `PUT --body {"resolved":true} /projects/…/merge_requests/42/discussions/8f1e2d3c` | `true` | 0 |
| TC-P34-028 | PUT fails | `"42:d99"` | (none, `_gl_api` rc≠0) | 1 call | empty | ≠0 |
| TC-P34-029 | malformed — no colon → rc 2 NO HTTP | `"42d99"` | (none) | 0 calls | empty | 2 |
| TC-P34-030 | malformed — non-numeric iid → rc 2 NO HTTP | `"abc:d99"` | (none) | 0 calls | empty | 2 |
| TC-P34-031 | malformed — empty discussion → rc 2 NO HTTP | `"42:"` | (none) | 0 calls | empty | 2 |
| TC-P34-032 | malformed — empty input → rc 2 NO HTTP | `""` | (none) | 0 calls | empty | 2 |

---

## R8 — `chp_gitlab_request_changes` DELIBERATELY ABSENT (`rest_request_changes=0`)

No leaf ships. Assertions live at the caps-manifest layer and the shim
`chp_has_leaf` check.

| ID | Scenario | Assertion |
|----|---------|-----------|
| TC-P34-033 | leaf ABSENT | `declare -F chp_gitlab_request_changes` rc≠0 |
| TC-P34-034 | shim reports leaf-absent | with `CODE_HOST=gitlab`, `chp_has_leaf request_changes` returns rc≠0 |
| TC-P34-035 | caps declaration | `chp_gitlab.caps` has `rest_request_changes=0` |

---

## R9 — `chp_gitlab_close_keyword ISSUE` — render `Closes #N`

`printf 'Closes #%s' "$issue"` — identical to the GitHub leaf's render. GitLab
parses the same keyword; auto-close on merge-to-default per the caps caveat
(§5.1). Caller-side `_render_close_keyword` branch logic UNCHANGED.

| ID | Input | Expected stdout |
|----|-------|-----------------|
| TC-P34-036 | `42` | `Closes #42` |
| TC-P34-037 | `1` | `Closes #1` |

---

## R10 — `chp_gitlab_commit_file REPO BRANCH FILE_PATH CONTENT_BASE64 MESSAGE`

Files API single-call collapse of the GitHub 8-call git-Data-API dance.
Provider-specific bootstrap the leaf owns:

1. Preflight `_gl_api --tolerate-status 404 …/repository/branches/${branch_urlenc}`
   — the redirect-to-tempfile invocation (NOT `$(…)` capture) so `GL_API_STATUS`
   survives (P3-1 CONTRACT NOTE);
2. If `GL_API_STATUS=404` → probe default branch, then `POST
   …/repository/branches?branch=…&ref=…` (both dynamic pieces `_gl_urlencode`'d);
3. Preflight file existence with `_gl_api --tolerate-status 404
   …/repository/files/${path_urlenc}?ref=${branch_urlenc}` — 200 → PUT update,
   404 → POST create;
4. `POST` or `PUT` `…/repository/files/${path_urlenc}` with
   `{branch, encoding:"base64", content, commit_message}`;
5. Follow-up `GET …/repository/commits?ref_name=${branch_urlenc}&per_page=1` →
   `.[0].id` (one extra read); **the success token is the commit SHA**
   (upload-screenshot.sh reads it only for logging; the extra GET is cheaper
   overall than propagating a new "success token" convention through the
   caller). Documented in leaf header.

Every dynamic path/query component `_gl_urlencode`'d (branch names like
`feat/x` have `/`). Large-body handling: build the JSON via jq into a temp
file (avoids ARG_MAX). Temp-file cleanup uses the INV-99 self-disarming
function-scoped RETURN trap: `trap 'rm -f …; trap - RETURN' RETURN`. Fail-CLOSED
on any of the up-to-five calls (repo positional threading + injection-safe
via `_gl_urlencode`).

| ID | Scenario | Payload seq / `GL_API_STATUS` seq | Expected _gl_api trace | Expected stdout | Expected rc |
|----|---------|-----------------------------------|------------------------|-----------------|-------------|
| TC-P34-038 | branch exists + file new — POST create | branch probe 200 → file probe 404 → POST create → commits GET returns `[{id:"abcdef1"}]` | 4 calls | `abcdef1` | 0 |
| TC-P34-039 | branch exists + file exists — PUT update | branch probe 200 → file probe 200 → PUT update → commits GET | 4 calls | `abcdef1` | 0 |
| TC-P34-040 | branch absent → bootstrap → then POST create | branch probe 404 → default-project GET `{default_branch:"main"}` → POST create branch → file probe 404 → POST create → commits GET | 6 calls | `abcdef1` | 0 |
| TC-P34-041 | INV-99 RETURN-trap self-disarm across 2 invocations in ONE shell | invoke twice consecutively; assert (a) temp files cleaned after each; (b) no `set -u` `unbound variable` between calls; (c) the RETURN trap does NOT fire on the surrounding `chp_commit_file` shim's own return | 2× full traces | both SHAs | 0, 0 |
| TC-P34-042 | commit_file POST fails | branch OK, file probe OK, POST rc≠0 | 3 calls | empty | ≠0 |
| TC-P34-043 | slash-bearing branch percent-encoded | branch `feat/x` — recorded `_gl_api` argv shows `feat%2Fx` in the path | 4 calls with `feat%2Fx` observed | commit SHA | 0 |
| TC-P34-044 | slash-bearing file path percent-encoded | `path/to/f.png` → `path%2Fto%2Ff.png` in argv | 4 calls | commit SHA | 0 |

---

## R11 — `chp_file_url REPO BRANCH FILE_PATH` — NEW verb, both leaves

Pure string render, no HTTP. Both leaves take (REPO, BRANCH, FILE_PATH)
positionals.

- `chp_github_file_url REPO BRANCH FILE_PATH` → `https://github.com/${REPO}/blob/${BRANCH}/${FILE_PATH}`
  — byte-identical to the current `upload-screenshot.sh:114` hardcode.
  **REPO positional is HONORED**, not ignored.
- `chp_gitlab_file_url REPO BRANCH FILE_PATH` → `https://${GITLAB_HOST}/<decoded-project-path>/-/blob/${BRANCH}/${FILE_PATH}`
  — browser URLs use the RAW (slash-bearing) project path, NOT the URL-encoded
  `GITLAB_PROJECT` API id. The leaf percent-DECODES `GITLAB_PROJECT` (or REPO
  when it differs) to render the browser URL.

The shim `chp_file_url` lives in `lib-code-host.sh` (one-line forward to
`chp_${CODE_HOST}_file_url "$@"`), self-guarding pattern (leaf-absent → WARN
+ rc 1) mirroring `chp_commit_file`. `upload-screenshot.sh:114` is rewritten
to `chp_file_url "$REPO" "$BRANCH" "$FILE_PATH"`. A caller-branch alternative
is REJECTED (a github-gated raw URL outside `providers/` accumulates exactly
the class the seam exists to remove).

| ID | Provider | REPO | BRANCH | FILE_PATH | GITLAB_PROJECT | Expected stdout |
|----|---------|------|--------|-----------|----------------|-----------------|
| TC-P34-045 | github | `owner/repo` | `screenshots` | `pr-42/TC-1.png` | — | `https://github.com/owner/repo/blob/screenshots/pr-42/TC-1.png` |
| TC-P34-046 | github | `zxkane/foo-bar` | `feat/x` | `docs/a.md` | — | `https://github.com/zxkane/foo-bar/blob/feat/x/docs/a.md` — byte-identical to today's `upload-screenshot.sh` hardcode |
| TC-P34-047 | gitlab | (empty; leaf uses `GITLAB_PROJECT`) | `screenshots` | `pr-42/TC-1.png` | `myGroup%2FmyProject` | `https://gitlab.example.test/myGroup/myProject/-/blob/screenshots/pr-42/TC-1.png` |
| TC-P34-048 | gitlab | `otherGroup%2Fother` (REPO overrides `GITLAB_PROJECT`) | `main` | `README.md` | `myGroup%2FmyProject` | `https://gitlab.example.test/otherGroup/other/-/blob/main/README.md` |
| TC-P34-049 | gitlab | (empty) | `feat/x` | `path/to/f.png` | `myGroup%2Fnested%2Fproj` | `https://gitlab.example.test/myGroup/nested/proj/-/blob/feat/x/path/to/f.png` (RAW slash path, NOT URL-encoded) |
| TC-P34-050 | shim | shim dispatch: `CODE_HOST=github` and `CODE_HOST=gitlab` invoke the correct leaf | — | — | — | shim dispatch behavior matches leaf |
| TC-P34-051 | upload-screenshot rewrite | `upload-screenshot.sh:114` now reads `chp_file_url "$REPO" "$BRANCH" "$FILE_PATH"` | — | — | — | grep-anchored source assertion |

---

## R12 — `chp_gitlab_trigger_bot PR TRIGGER` — safety-net no-op (`review_bots=0`)

Cap `review_bots=0` — the caller's `parse_review_bots` short-circuits at cap=0
BEFORE the leaf. The leaf itself is a safety net: `return 0` echoing nothing.

| ID | Scenario | Expected |
|----|---------|----------|
| TC-P34-052 | leaf returns rc 0 with no HTTP | 0 `_gl_api` calls, empty stdout, rc 0 |
| TC-P34-053 | caller short-circuit at cap 0 | with the caller check `chp_caps review_bots -eq 0`, the leaf is NEVER reached (verified by a separate integration path — caller-side, not this suite) |

---

## R13 — `chp_gitlab_count_reviews_by_login REPO PR LOGIN` (INV-94)

`GET /projects/:repo/merge_requests/:pr/approvals` — SINGLE-PAGE bounded (no
`--paginate`). Count `.approved_by[]` where `.user.username == LOGIN`. Login
JSON-encoded into the jq program (injection-safe — mirrors GitHub leaf). ANY
failure → `echo 0; return 0` (parity with GitHub — the caller's `^[0-9]+$`
gate + `-eq 0` MISSING decision expects 0-on-failure, NEVER rc≠0). Data-source
citation: GitLab has no review objects; approvals are the closest semantic
(pinned in leaf header + spec §5.1).

| ID | Scenario | Payload | LOGIN | Expected stdout | Expected rc |
|----|---------|---------|-------|-----------------|-------------|
| TC-P34-054 | 2 approvers matching | `{approved_by:[{user:{username:"bot-a"}},{user:{username:"other"}}]}` | `bot-a` | `1` | 0 |
| TC-P34-055 | 0 matches | same, ask for `nobody` | `nobody` | `0` | 0 |
| TC-P34-056 | login with special chars (`github-actions[bot]`-style) | `{approved_by:[{user:{username:"github-actions[bot]"}}]}` | `github-actions[bot]` | `1` | 0 |
| TC-P34-057 | injection-safe: login containing `"` | payload has approver with that literal username | `evil"; injection` | `0` (no match — no jq widen) | 0 |
| TC-P34-058 | `_gl_api` rc≠0 → echo 0 rc 0 (fail-SAFE) | (none) | `bot-a` | `0` | 0 |
| TC-P34-059 | malformed JSON response → echo 0 rc 0 | `{not: json` | `bot-a` | `0` | 0 |
| TC-P34-060 | empty approved_by | `{approved_by:[]}` | `bot-a` | `0` | 0 |

---

## R14 — Spec updates same PR

- **§3.2** — new `chp_file_url REPO BRANCH FILE_PATH` row + note the shim in
  `lib-code-host.sh` and the `upload-screenshot.sh:114` rewrite.
- **§5.1** — new subsection **"GitLab CHP write leaves (#419, P3-4)"** covering:
  two-call approve ordering + failure posture; merge `PUT` shape + 405/409/422
  surface; `chp_pr_comment` audited `--body <string>` shape; discussions walk
  + synthesized note-anchor URL (RAW project path); compound `thread_id` decode
  (mirror of P3-3 M8 pin); `chp_gitlab_close_keyword` render + default-branch
  caveat cross-reference; commit-file bootstrap + preflight design +
  self-disarming RETURN trap + `_gl_urlencode` per component + commit-SHA
  echo decision; **file-URL render** (RAW project path, byte-identical GitHub
  render); trigger-bot no-op; approvals source citation.
- **Mapping appendix** — one row per GitLab write verb + the new `chp_file_url`
  row (both arms).

| ID | Assertion |
|----|-----------|
| TC-P34-061 | Spec §3.2 contains ``| `chp_file_url REPO BRANCH FILE_PATH` |`` row |
| TC-P34-062 | Spec §5.1 has a new "P3-4" write leaves subsection anchor |
| TC-P34-063 | Mapping appendix has GitLab write-verb rows + `chp_file_url` rows |
| TC-P34-064 | `docs/pipeline/provider-spec.md` CONTRACT-PENDING set is unchanged (empty) after this PR |

---

## R15 — Conformance completion + expected per-axis counts

- Drop `--expect-absent` interim flags for verbs IMPLEMENTED here
  (`chp_gitlab_request_changes` stays LEAF-ABSENT via its
  `rest_request_changes=0` governing cap, NOT via expect-absent).
- **Coverage.conf changes** (audit + add rows):
  - `chp_pr_comment=asserted` — was previously implicit github-only; add row.
  - `chp_commit_file=asserted` — new row.
  - `chp_count_reviews_by_login=asserted` — new row.
  - `chp_trigger_bot=asserted` (SKIP-per-cap on gitlab; still counted asserted).
  - `chp_file_url=asserted` — NEW verb, new row on both axes.
- **cap-map.conf** — new rows: `chp_pr_comment=-`, `chp_commit_file=-`,
  `chp_count_reviews_by_login=-`, `chp_trigger_bot=review_bots`,
  `chp_file_url=-`.
- **Runner axes** — `pcf_resolve_provider_dir` learns `gitlab → skills/…/providers`
  (both leaves live in-tree once P3-2 + this PR merge). `_gl_api` is NOT modeled
  by the runner's stub `gh` — the runner exercises the caller-side dispatch
  contract via shim; per-leaf behavior is proven by
  `tests/unit/test-chp-gitlab-writes.sh` (hermetic + fixture-driven).

**Expected per-axis asserted-verb counts after P3-4** (state in PR body):

| Axis | Prior count | Δ this PR | Post-P3-4 count | SKIP set on axis |
|------|------------|-----------|-----------------|------------------|
| github/github | 25 (24 asserted + `chp_close_keyword` render) | +5 (chp_pr_comment, chp_commit_file, chp_count_reviews_by_login, chp_trigger_bot, chp_file_url) | **30 asserted** | 0 |
| gitlab/gitlab | 0 (no gitlab arm previously) | +25 (P3-3 reads → asserted) +5 (this PR's write additions to coverage.conf) — 2 (chp_request_changes SKIP via cap, chp_trigger_bot SKIP via cap) | **28 asserted**, 2 SKIP | `chp_request_changes` (rest_request_changes=0), `chp_trigger_bot` (review_bots=0) |
| github/gitlab (split) | — | — | — | (out of scope — validated by test-provider-*-runner.sh, not this PR) |

| ID | Assertion |
|----|-----------|
| TC-P34-065 | `--itp gitlab --chp gitlab` runs `pending=0` (parent #414 AC1 lands here) |
| TC-P34-066 | `--itp github --chp github` remains PASS on every asserted verb (+ new `chp_file_url` row) |
| TC-P34-067 | Post-P3-4 asserted-verb counts match the table above |
| TC-P34-068 | Coverage.conf `pending` set is EMPTY (spec CONTRACT-PENDING set is empty) |

---

## R16 — Fixtures under `tests/provider-conformance/fixtures/payloads/`

All new fixtures carry `.meta` sidecars naming `gitlab_version=17.x`.

| Fixture (payloads/gitlab-chp-write-*.json) | Purpose | TC coverage |
|-------|---------|-------------|
| `create-pr-project.json` | `{default_branch:"main"}` | TC-P34-001/002 |
| `create-pr-response.json` | `{web_url, iid:99}` | TC-P34-001/002 |
| `approve-approve-ok.json` | `{approved_by:[…]}` | TC-P34-007/008 |
| `approve-note-ok.json` | `{id:99, body:"…"}` | TC-P34-007 |
| `merge-response.json` | `{state:"merged", iid:42}` | TC-P34-013 |
| `merge-405-body.json` | `{"message":"405 Method Not Allowed"}` | TC-P34-014 |
| `pr-comment-response.json` | `{id:1234, body:"…"}` | TC-P34-018/019 |
| `reply-discussions-p1.json` | 20 discussions, none with target note id | TC-P34-023/024 |
| `reply-discussions-p2.json` | 20 discussions, one carrying note id | TC-P34-023 |
| `reply-note-response.json` | `{id:5678}` | TC-P34-023 |
| `resolve-thread-response.json` | `{resolved:true}` | TC-P34-027 |
| `commit-file-branch-exists.json` | 200 GET branch | TC-P34-038/039 |
| `commit-file-file-exists.json` | 200 GET file | TC-P34-039 |
| `commit-file-create-response.json` | `{file_path, branch}` (Files API create/update) | TC-P34-038/039 |
| `commit-file-commits.json` | `[{id:"abcdef1"}]` — commits list first-page | TC-P34-038 |
| `commit-file-project-default.json` | `{default_branch:"main"}` (for the bootstrap branch) | TC-P34-040 |
| `commit-file-branch-create-response.json` | `{name:"screenshots", commit:{…}}` | TC-P34-040 |
| `count-reviews-approvals-two.json` | two `approved_by` entries | TC-P34-054 |
| `count-reviews-approvals-empty.json` | `{approved_by:[]}` | TC-P34-060 |
| `count-reviews-approvals-injection.json` | approver username with special chars | TC-P34-056/057 |

---

## Cross-references

- **§3.2** (spec) — verb table rows for every CHP write verb + the new `chp_file_url`
- **§5.1** (spec) — GitLab CHP writes subsection (this PR)
- **[M4]/[INV-33]** — `merge_closes_issue=1` default-branch caveat pinned in caps
- **[INV-94]** — `chp_count_reviews_by_login` fail-SAFE (echo 0 rc 0)
- **[INV-96]** — `chp_reply_review_comment` discussions walk
- **[INV-99]** — `chp_commit_file` self-disarming RETURN trap
- **#329 audit** — `chp_pr_comment` `--body <string>` shape confirmed across all 7 GitHub call sites
- **#280 §5.1** — GitLab caps definitions
- **#416** — FROZEN transport contract (`_gl_api`, `_gl_urlencode`, `GL_API_STATUS`)
