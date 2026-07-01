# Test cases — cutover-guard #286-amendment (#343, INV-91)

The `#286-amendment` (#343): `check-provider-cutover.sh` MUST stop self-detecting
its own **infrastructure** lines — the `ALLOWLISTED_FILES=(…)` array declaration, the
guard's own primary matcher line (`grep -aE '(^|[^A-Za-z_-])gh ' …`), and the
generated baseline `_comment:` template — as baselined raw-gh survivors. These three
lines change content whenever the allowlist **policy** changes (the array directly;
the `_comment` because it embedded the allowlist file-list; the matcher line is the
guard's mechanical detector), so before the amendment editing the allowlist array
**self-trips Check 4 monotonicity**: the edited line's `(file,content)` signature
changes → the old signature "no longer found" **and** a NEW unbaselined signature
appears, so no allowlist disposition could land without hand-editing the baseline in
the same PR — the exact self-ratification pattern the guard exists to prevent (#296
names this the prerequisite for the final allowlist batch).

**Narrow scope**: the guard's **deliberate self-scan** of its own PASS/FAIL message
strings STAYS (a NEW raw `gh` added to the checker must still FAIL loud). Only the
three infrastructure lines whose content changes when the allowlist policy changes
are structurally exempt (R1) — the array declaration and matcher line via the
structural skip, and the generated baseline `_comment` template both structurally
skipped AND stabilized by dropping the embedded allowlist file-list so an allowlist
edit no longer churns its content (R2). The exemption keys on a **structural anchor at
top-of-line in this one file** (`file == "check-provider-cutover.sh"` AND the line
matches the array-assignment / primary-matcher shape) — NOT a magic comment an
arbitrary file could carry (no general escape hatch; TC-014 exists precisely because
generic escape hatches invite self-allowlisting).

Extends `tests/unit/test-provider-cutover.sh` (the scratch-copy pattern already used
by TC-CUTOVER-014/017). Credential-free (jq + coreutils), auto-discovered by the
`tests/unit/test-*.sh` CI glob. All pre-existing TC-CUTOVER assertions stay green.

## `tests/unit/test-provider-cutover.sh` — new TC-CUTAMEND cases

| ID | Requirement | Scenario | Expected |
|---|---|---|---|
| TC-CUTAMEND-001 | R1 | `--generate-baseline` against the real tree emits **no** signature whose `file == "check-provider-cutover.sh"` and whose trimmed content starts with `ALLOWLISTED_FILES=(` | the generated baseline has zero checker `ALLOWLISTED_FILES=(` survivor |
| TC-CUTAMEND-002 | R1 | `--generate-baseline` emits **no** signature whose `file == "check-provider-cutover.sh"` and whose content is the primary matcher line (`grep -aE '(^\|[^A-Za-z_-])gh ' …`) | the generated baseline has zero checker primary-matcher survivor |
| TC-CUTAMEND-003 | R1 | The scanner's structural skip is **file-scoped**: an `ALLOWLISTED_FILES=(gh …)`-shaped line and the primary-matcher-shaped line injected into a **different** file (scratch `setup-labels.sh`) are STILL caught as NEW unbaselined raw-gh | `exit 1`, names `setup-labels.sh:LINE` (no general escape hatch — the skip is not a magic comment) |
| TC-CUTAMEND-004 | R2 | The regenerated committed baseline (`providers/cutover-baseline.json`) carries **zero** `check-provider-cutover.sh` signatures for the array line and the matcher line, but STILL carries the checker's PASS/FAIL echo/fail self-scan signatures | grep the committed baseline: array-line + matcher-line absent; ≥1 `cutover-guard: PASS`/`NEW/unbaselined`/`baseline declares` self-scan signature present |
| TC-CUTAMEND-005 | R2 | The neutralized `_comment` template no longer embeds the allowlist file-list, so editing `ALLOWLISTED_FILES` does not churn the `_comment` signature: the committed `_comment` string contains no parenthesized allowlist file-list (`(scripts/gh, …)` / `(gh gh-with-token-refresh.sh …)`) | grep the committed `check-provider-cutover.sh` `_comment` template + the committed baseline `_comment`: no embedded allowlist file-list |
| TC-CUTAMEND-006 | R3 | **Self-scan preserved**: a NEW genuine raw `gh api user` added to a scratch `check-provider-cutover.sh` (NOT the array/matcher shape) still FAILs as unbaselined | `exit 1`, names `check-provider-cutover.sh:LINE` + `gh api user` |
| TC-CUTAMEND-007 | R4 | **Allowlist edit no longer self-trips (the amendment's whole point)**, real git fixture: (i) append a filename to `ALLOWLISTED_FILES` in a scratch checker, (ii) remove that file's own signatures from the scratch baseline (what a real allowlist PR does), (iii) regenerate the baseline from the edited tree, (iv) run the FULL guard (`--trusted-ref trusted-main` + `--require-trusted-ref`) | `exit 0`: Checks 1–4 pass with NO change to any `check-provider-cutover.sh` signature in the baseline; the edited array line is NOT a new unbaselined checker signature and Check 4 does NOT report the array line as `GREW` |
| TC-CUTAMEND-008 | R4 | **Regression pin** — the pre-amendment failure mode: with the amendment in place, editing ONLY `ALLOWLISTED_FILES` (append a name) + regenerating the baseline and running Check 4 vs the pre-edit trusted ref does NOT produce a `baseline GREW … check-provider-cutover.sh … ALLOWLISTED_FILES` monotonicity failure | `exit 0`, no `GREW` line mentioning `check-provider-cutover.sh` |

> Note (R1 anchor): the exemption is a per-file structural skip inside the
> per-file scan (`gh_lines_in` output filtered by `is_checker_infra_line` for
> `file == "check-provider-cutover.sh"` matching the array-assignment shape
> `^ALLOWLISTED_FILES=(`, the primary-matcher prefix `grep -aE '(^|[^…`, or the
> generator prefix `_comment:`), applied identically on the check path AND
> `--generate-baseline`. It is NOT a general annotation mechanism.
> Note (R3): TC-CUTAMEND-006 proves the checker is still scanned like any file for
> **genuine** new raw-gh — the amendment narrows the exemption to three
> infrastructure lines, it does NOT wholesale-allowlist the checker (TC-CUTOVER-014
> stays green).
> Note (net shrink): the committed baseline shrinks by exactly the three
> structurally-exempted signatures (array line + matcher line + `_comment` template);
> no other signature is added or removed (63 → 60 distinct, 69 → 66 occurrences).
