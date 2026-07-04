# Test cases — REST-sourced authorKind for the normalized comment shape (#393)

Fixture-driven; run under `env -u PROJECT_DIR bash`. The regression class:
GraphQL strips `[bot]` from App logins and exposes no author type, so a
suffix-sniffing derivation classifies every App comment as `human`.

- `tests/unit/test-itp-read-leaves.sh` — the leaf's shape + source pins.
- `tests/unit/test-classify-recent-review-verdict.sh` — the end-to-end gate.

| Test ID | Scenario | Expected |
|---|---|---|
| TC-GT-COMMENTS | Leaf argv pin | `gh api --paginate --slurp repos/<repo>/issues/N/comments` (REST — deliberate #393 source change; SHAPE is the contract) |
| TC-SHAPE-FIELDS/SORT/ID-NUM | Normalized shape over a 2-page REST fixture | exactly `{id,author,authorKind,body,createdAt}`; ascending createdAt; numeric REST `.id`; `--slurp` page-flattening pinned by the 2-page fixture |
| TC-SHAPE-AUTHOR | App-bot author | VERBATIM `<slug>[bot]` (spec §3.3 [M5] — the GraphQL leaf silently violated this) |
| TC-SHAPE-KIND | self/bot/human | `user.type==Bot` → bot; BOT_LOGIN matches raw OR `[bot]`-stripped → self; `user.type==User` → human |
| TC-393-APPKIND | App comment, `BOT_LOGIN=""` (dispatcher process state) | `authorKind=bot` — pre-#393 yielded `human`, inert-ing the #390 gate |
| TC-393-001 | End-to-end classify: app mode + BOT_LOGIN empty + App-authored anchored trailer | classifies `failed-substantive` (pre-#393: `none` → INV-12 park; the observed 2h-stuck live incident) |
| TC-SHAPE-INV85/INV05 | Equivalence: GraphQL-era baseline vs REST-fed normalization | identical selections (exact-eq author, cutoff counts, sort_by-last) |
