# Test Cases — agy `--model` support (validated pass-through)

Covers issue #190: the `agy` (Antigravity 2.0 CLI) branch in
`skills/autonomous-dispatcher/scripts/lib-agent.sh` stops warn-and-ignoring
`--model` and instead forwards it **after validating against `agy models`**.

The empirically-verified driver behind every case here: `agy -p --model "<x>"`
returns **rc 0 for ANY string** and silently falls back to its default model
(Gemini 3.5 Flash). So the wrapper cannot rely on agy to self-reject an invalid
id — it must validate wrapper-side, or a wrong-model verdict silently enters the
INV-40 unanimous-PASS merge gate. See [INV-50](../pipeline/invariants.md) and
[`agy-cli-support.md`](../pipeline/agy-cli-support.md).

## Strategy

Pure unit tests in `tests/unit/test-lib-agent-agy.sh` (extended, not replaced).
No live `agy` — an `agy` stub on `PATH` records argv to a recorder file, drains
stdin, and writes a fixed `--log-file` with a `Print mode: conversation=<UUID>`
line. For the model cases the stub ALSO answers the `agy models` subcommand with
a fixed listing (so `_agy_known_model` can enumerate), and an `agy-models-fail`
variant exits non-zero on `models` to exercise the enumeration-failure path.

`_agy_known_model` enumerates `agy models` ONCE per process (cached in a global)
and answers "is `<model>` a name agy accepts?" via a **fixed-string, whole-line**
match (`grep -Fxq`) so names with spaces/parens (`"Gemini 3.5 Flash (High)"`) are
literal and a prefix never matches.

## Test cases

| ID | Scenario | Setup | Expected |
|----|----------|-------|----------|
| **AGY-06a** | Known agy model → forwarded | `run_agent` with `model="Gemini 3.5 Flash (High)"`; stub `agy models` lists it | Stub argv contains `--model Gemini 3.5 Flash (High)` with the model as a **single argv element** (spaces/parens preserved); rc 0 |
| **AGY-06b** | Empty/unset model → no `--model` | `run_agent` with `model=""` | Stub argv does **not** contain `--model`; rc 0; no WARN to stderr |
| **AGY-06b2** | Enumerated-but-unknown model → omitted + WARN | `run_agent` with `model="claude-sonnet-4.6"` (not in stub's `agy models` list) | Stub argv does **not** contain `--model`; one-time WARN to stderr naming the value AND `AGENT_REVIEW_MODEL_AGY`; rc 0 |
| **AGY-06b3** | `agy models` enumeration failure → best-effort pass-through | `agy models` subcommand exits non-zero; `model="some-model"` | Stub argv **does** contain `--model some-model` (cannot prove invalid → don't drop); rc 0 |
| **TC-AGYM-KM** | `_agy_known_model` unit | stub `agy models` lists a fixed set | known name → rc 0; unknown → rc 1; prefix of a listed name (`"Gemini 3.5 Flash"` when list has `"... (High)"`) → rc 1 (whole-line); arg with regex metachars (`"Gemini.*"`) treated literally → rc 1; empty arg → rc 1 |
| **AGY-06c** | `resume_agent` `--conversation` path forwards model | sidecar present; `resume_agent` with `model="Gemini 3.5 Flash (High)"` | Stub argv contains `--conversation <UUID>` AND `--model Gemini 3.5 Flash (High)`; rc 0 |
| **AGY-06d** | `resume_agent` no sidecar → run_agent fallback threads model | no sidecar; `resume_agent` with `model="Gemini 3.5 Flash (High)"` | Falls back to `run_agent`; stub argv contains `--model Gemini 3.5 Flash (High)` (model threaded through fallback), no `--conversation` |
| **AGY-WARN-GONE** | Old warn-and-ignore string removed | source grep of `lib-agent.sh` | The literal `does not support --model` is **absent** (the warn-and-ignore can't silently return) |

## Regression (must still pass unchanged)

- **AGY-01..05, AGY-07, AGY-S1..S5** — stdin INV-34, structural flags, sidecar
  capture/resume/fallback, CWE-59 guards, INV-36 best-effort.
- **TC-PAM-\*** in `tests/unit/test-autonomous-review-per-agent-model.sh` — per-agent
  model resolution (tests resolution, not CLI argv; unaffected by this change).

## Acceptance

- `bash -n` clean on `lib-agent.sh` and the test file.
- Full `tests/unit/test-lib-agent-agy.sh` suite green.
- The cached `agy models` enumeration runs at most once per process (per
  `_LIB_AGENT_AGY_MODELS_CACHE`).
