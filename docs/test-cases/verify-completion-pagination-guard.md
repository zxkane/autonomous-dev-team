# Test cases — verify-completion.sh fail-closed truncation guard (#412)

Hermetic: `gh`, `git`, and `jq`-availability are controlled via a PATH-front
stub dir; the real hook script runs unmodified end-to-end (stdin fed,
exit code + stderr asserted). All fixtures satisfy the hook's preconditions:
non-main branch, PR number found, CI `completed`/`success` (so control flow
reaches the unresolved-thread check).

| ID | Fixture | Expect |
|---|---|---|
| TC-VCP-001 | `hasNextPage:true`, page-1 threads ALL resolved | exit 2 (block); stderr carries the truncation message (mentions >100 threads / cannot verify), NOT the numeric "unresolved review thread(s)" message |
| TC-VCP-002 | `hasNextPage:true`, page-1 has 2 unresolved threads | exit 2 (block); truncation message (sentinel wins before counting) |
| TC-VCP-003 | `hasNextPage:false`, 0 unresolved (all resolved/outdated) | exit 0, no block — byte-preserved current behavior |
| TC-VCP-004 | `hasNextPage:false`, 2 unresolved threads | exit 2; EXISTING "Unresolved Review Comments" message with count 2 — byte-preserved current behavior |
| TC-VCP-005 | GraphQL failure (`gh api graphql` exits 1 / `.data == null`) | exit 0 — today's fail-open posture unchanged (out of scope to change) |
| TC-VCP-006 | Response WITHOUT `pageInfo` at all (old-shape defensive) | treated as single page; same as TC-VCP-003/004 by unresolved count |
| TC-VCP-007 | Source-shape pin (no fixture — greps the hook source) | both `reviewThreads` queries carry `pageInfo { hasNextPage }` (grep-count parity; covers the details query too, R1) |

Run: `env -u PROJECT_DIR bash tests/unit/test-verify-completion-pagination.sh`
