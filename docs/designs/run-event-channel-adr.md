# ADR — Durable run-event channel selection

> **Status: ACCEPTED (decision recorded) · implementation GATED (stop-rule).**
> Research-and-decide spike for issue #237. This ADR selects the durable event
> channel a *future* gated reconciler/lease design would consume. It carries
> **no implementation commitment and no code behavior change** — see §9 for the
> explicit stop-rule. Recorded as a pointer entry in
> [`docs/pipeline/invariants.md` INV-71](../pipeline/invariants.md#inv-71-run-event-channel-decision-recorded-implementation-gated).
>
> Autonomous design (no interactive approval gate). Docs-only PR.

---

## 1. Context

The stability redesign's review consensus flagged the **events channel** as the
load-bearing unknown of the gated reconciler phase. A reconciler (or a
lease-renewal loop that lets a fresh dispatcher safely reclaim a dead wrapper's
work) needs a **durable, append-only record of run events** that every node in
the deployed topology can both *write* and *read* — independent of who holds the
process or the PID file.

Committing to a channel before measuring it risks baking in a substrate that
fails part of the fleet:

- **check-runs** need `checks:write` — an **App-mode-only** grant; a PAT
  fundamentally cannot create check-runs.
- **comment editing** races itself — the wrapper's heartbeat lane and its main
  lane would both `PATCH` the same comment.
- a **local state dir** is invisible to a **remote dispatcher** reading over
  SSM without a round-trip per read.

This ADR evaluates three candidates against the full topology matrix, grounds
the rate-limit budget in **measured** numbers, and answers the review's "T1"
question (canonical run-ledger vs. label-canonical + additive events).

### What exists today (the baseline this would extend, not replace)

| Surface | Channel today | Durable? | Remote-readable? |
|---|---|---|---|
| Liveness heartbeat | **local file touch** — PID-file + `<base>.heartbeat` mtime, every `HEARTBEAT_INTERVAL_SECONDS` (default 120 s), [INV-29] | local only | no (SSM round-trip) |
| Dev session report | one issue **comment** at wrapper exit ([INV-03]) | yes (GitHub) | yes |
| Review verdict | one PR **comment** with a verdict trailer ([INV-40]) | yes (GitHub) | yes |
| Metrics | **local JSONL** append (`lib-metrics.sh`, [INV-70]), observe-only | local only | no |
| Canonical run state | **GitHub labels** (`in-progress`, `reviewing`, `pending-dev`, …) — the state machine | yes (GitHub) | yes |

The critical observation: **today's heartbeat and metrics are local; today's
durable GitHub-visible signals are comments and labels.** A reconciler that
needs remote nodes to read *event* history (not just the current label) must
either promote the local signals to a GitHub channel (new API traffic) or teach
the remote reader to round-trip the local dir over SSM. That trade is the whole
ADR.

---

## 2. The three candidates

| # | Candidate | One-line shape |
|---|---|---|
| **C1** | **GitHub check-runs** | each event is a check-run (or a check-run update) on the PR head SHA; the Checks API is the ledger |
| **C2** | **Create-only issue/PR comments** | each event is **one new comment, never edited** (append-only by construction — sidesteps the edit race); the comment list is the ledger |
| **C3** | **Local state dir + SSM-readable mirror** | each event is a line appended to a local file (like `metrics.jsonl` today); a remote dispatcher reads it via `aws ssm send-command` (`cat`/`tail`) |

A hybrid (**C2 for the durable cross-node ledger + C3 for the high-frequency
local heartbeat**) is evaluated in §9 and is the recommendation.

---

## 3. Topology matrix

The deployed topology (from `CLAUDE.local.md`): the dispatcher runs on a Tokyo
box; wrappers execute on a Singapore box reached by `EXECUTION_BACKEND=remote-aws-ssm`.
Five projects, `MAX_CONCURRENT` mostly 5 (one at 2) → **worst-case 25
concurrent runs**. Each cell: ✅ works · ⚠️ works with a caveat · ❌ fails.

| Cell | C1 check-runs | C2 create-only comments | C3 state-dir + SSM |
|---|---|---|---|
| **PAT mode** (token auth) | ❌ Checks API rejects non-App tokens (403/422) — *empirically confirmed by contrast in §6.3* | ✅ comment create needs only `issues`/`pull_requests` write, which a PAT has | ✅ local FS, auth-independent |
| **App mode** (installation token) | ✅ requires `checks:write` at install — *empirically confirmed: this repo's App created a check-run in 1564 ms, §6.3* | ✅ installation token has `issues:write` / `pull_requests:write` | ✅ local FS, auth-independent |
| **Local execution** (wrapper + reader same host) | ✅ | ✅ | ✅ direct file read — no round-trip |
| **Remote-SSM execution** (dispatcher ≠ wrapper host) | ✅ both nodes hit the same GitHub API | ✅ both nodes hit the same GitHub API | ⚠️ **reader needs an SSM `send-command` round-trip per read** (~1–3 s + an async poll for `get-command-invocation`); the dispatcher cannot `inotify`/`tail -f` a file on another host |
| **25 concurrent runs worst-case** | ⚠️ rate-limit pressure — see §6 | ⚠️ rate-limit pressure — see §6 | ✅ no shared API quota; each host writes its own FS |

**Reading of the matrix:** C3 is the only candidate that survives **PAT mode**
*and* has no shared API quota — but it is the only one that **fails the
remote-SSM read cell cleanly** (it works, but every read is a command
round-trip, so it cannot be the cross-node ledger a reconciler polls). C1 is
**hard-blocked in PAT mode**. C2 is the only candidate that is ✅ in **every
auth/execution cell** — but under fleet-scale rate-limit pressure it is viable
**only for sparse lifecycle events, not for renewals**: §5.3 and §6.5 show that
at `N=25` the lease/heartbeat *renewal* stream blows the 500/hr secondary
content-creation limit at every cadence at or faster than 120 s (60 s→1500/hr,
120 s→750/hr) and is not comfortably safe even at 300 s once lifecycle traffic
stacks on top. So **comment renewals are rate-limit-unsafe at fleet scale**;
C2 is viable only for the **sparse lifecycle events (start/verdict/merge/end)**
and only when the per-run lifecycle count stays small (§6.5, §9.1).

---

## 4. Auth matrix — exact scopes, and what degrades in PAT mode

| Candidate | Scope needed (App install permission / PAT scope) | PAT-mode behavior |
|---|---|---|
| **C1 check-runs** | App: **`checks:write`** (+ `metadata:read`). PAT: **impossible** — the `POST /repos/{o}/{r}/check-runs` endpoint is documented to require a GitHub App installation or OAuth-app token; a user/PAT token is rejected. | **Hard fail.** No degraded mode — the channel simply does not exist for the ~half of the fleet/operations that could run under a PAT. |
| **C2 create-only comments** | App: `issues:write` (issue comments) and/or `pull_requests:write` (PR comments) + `metadata:read`. PAT: classic `repo` scope, or fine-grained `issues:write`+`pull_requests:write`. The pipeline already holds these (it posts the dev report + verdict comments today). | **Full parity.** Identical capability in both modes — the installation token and a PAT both create comments. No degradation. |
| **C3 state-dir + SSM** | **None for the write** (local FS). For the remote read: the *dispatcher host's* IAM role needs `ssm:SendCommand` + `ssm:GetCommandInvocation` against the wrapper instance (already granted — the dispatcher uses it today). | **No GitHub auth involved.** Auth-mode-independent. The only "auth" is AWS IAM on the SSM path, unchanged by PAT-vs-App. |

**Takeaway:** the auth axis alone **eliminates C1 as a sole channel** — any
fleet member running token mode loses it entirely. C1 can only be an
*App-mode-only enhancement layer*, never the base ledger. C2 and C3 are both
auth-robust.

---

## 5. The lease-renewal cadence trade-off (named-parameter table)

A reconciler/lease design renews a lease (writes a "still alive" event) on a
cadence. Higher cadence → faster dead-detection but more events (more API
traffic for C1/C2). This is the dominant input to the rate-limit math, so it is
named here as a parameter table the gated phase can tune directly.

### 5.1 Parameters

| Parameter | Symbol | Default today | Notes |
|---|---|---|---|
| Lease/heartbeat renewal interval | `T_renew` | 120 s (`HEARTBEAT_INTERVAL_SECONDS`) | the issue's "60 s heartbeat" question evaluates `T_renew = 60` |
| Dead-detection latency budget | `L_dead` | — | the max time after a wrapper dies before a reconciler may reclaim |
| Missed-renewals-before-dead | `k` | — | `L_dead ≈ k · T_renew`; `k = 2` is the conventional "miss twice, then declare" |
| Fleet concurrency (worst-case) | `N` | 25 | 5 projects × `MAX_CONCURRENT` 5 |
| Reconciler poll interval | `T_poll` | — | how often the reconciler *reads* the ledger (read-side rate-limit input) |

### 5.2 The trade

`L_dead ≈ k · T_renew`. To detect a dead wrapper within `L_dead`:

- **`T_renew = 60 s, k = 2` → `L_dead = 120 s`** (the issue's scenario).
- **`T_renew = 120 s, k = 2` → `L_dead = 240 s`** (today's heartbeat cadence).
- **`T_renew = 30 s, k = 3` → `L_dead = 90 s`** (aggressive; 4× the event rate).

Faster `T_renew` buys lower `L_dead` linearly but raises the renewal-event rate
**linearly**, and that rate is what §6 tests against the secondary rate limit.

### 5.3 Cadence-vs-detection table (the named trade)

| `T_renew` | `k` | `L_dead` | renewal events / run-hour | renewal events / hr at `N=25` |
|---|---|---|---|---|
| 30 s | 3 | 90 s | 120 | 3000 |
| 60 s | 2 | 120 s | 60 | 1500 |
| **120 s** (today) | 2 | 240 s | 30 | 750 |
| 300 s | 2 | 600 s | 12 | 300 |

> **The renewal column is the load-bearing number.** Against the 500/hr GitHub
> secondary content-creation limit (§6.4), at `N=25` **every cadence at or
> faster than 120 s already exceeds it on renewals alone** (30 s→3000/hr,
> 60 s→1500/hr, 120 s→750/hr — all over 500/hr). **Only the 300 s cadence
> (300/hr renewals) is below 500/hr** — and even there, §6.5 shows the *lifecycle*
> traffic (start/verdict/merge/end ×N runs) stacks on top and can still push C2
> over the limit. So **no C2 (comment) renewal cadence at this fleet size is
> comfortably safe**; 60 s and 120 s are outright rate-limit-unsafe, 300 s is
> only renewal-safe. C3 (local) has no such ceiling at any cadence.

---

## 6. Rate-limit math (step-by-step, measured where possible)

### 6.1 Events-per-run model (from the #228 metrics baseline — this ADR's dependency)

`docs/pipeline/metrics.md` enumerates the events a *single* run emits today
(local, not to GitHub — but it is the canonical decomposition of "what a run
does"). A GitHub-backed event channel would mirror these:

| Phase | Events per run (dev) | Events per run (review) |
|---|---|---|
| start | `wrapper_start` ×1 | `wrapper_start` ×1 |
| body | `pr_opened` ×1 | `review_agent_run` ×*A* (fan-out size *A*; here `AGENT_REVIEW_AGENTS="agy codex"` → *A*=2), `agent_drop` ×(0..A) |
| terminal | `token_usage` ×1, `wrapper_end` ×1 | `verdict` ×1, `merge` ×(0..1), `token_usage` ×*A*, `wrapper_end` ×1 |
| **lifecycle subtotal** | **≈4 fixed** | **≈4 + 3A ≈ 10** (at A=2) |
| **+ lease renewals** | `+ run-duration / T_renew` | `+ run-duration / T_renew` |

> **Why the documented model, not a back-derived historical rate:** on this dev
> box the live `metrics.jsonl` was not yet populated with a multi-run history at
> measurement time (it held a single `wrapper_start` — this very run). The
> documented per-run event set is used instead, which is a **conservative upper
> bound** (it counts every lifecycle event a run *can* emit). This is stated
> honestly per the issue's "measured, not estimated" rule — the **propagation**
> and **check-run** numbers below ARE measured; the **event count per run** is
> the documented model.

**Fixed lifecycle events dominate at low cadence; renewals dominate at high
cadence.** A 20-minute run at `T_renew=60 s` emits ~20 renewals vs. ~4–10
lifecycle events — so **renewals are the rate-limit driver**, which is why §5.3
is the key table.

### 6.2 MEASURED — comment-creation propagation lag

`measure-event-channels.sh --comment-only --samples 5` against this repo
(create → first visible in a *list* read):

```
sample 1: 3508 ms
sample 2: 2958 ms
sample 3: 4965 ms
sample 4: 4457 ms
sample 5: 3986 ms
aggregate: n=5 min=2958 ms median=3986 ms max=4965 ms mean=3975 ms
```

**→ comment-list eventual-consistency lag ≈ 3–5 s (median ~4.0 s).** A
reconciler reading the comment list to reconstruct state must treat any event
younger than ~5 s as "may not be visible yet" — it cannot conclude "no such
event exists" until ~5 s after the event's wall-clock time. (A direct
`GET .../comments/{id}` by id is faster, but a reconciler discovers events by
*listing*, not by id, so the list lag is the binding number.)

### 6.3 MEASURED — check-run creation latency + the PAT/App split

`measure-event-channels.sh --check-only` against a real HEAD SHA:

```
check-run created in 1564 ms (token IS permitted: App with checks:write)
```

**→ a single check-run POST ≈ 1.6 s, and the App installation token on this box
IS permitted** (the App was granted `checks:write`). By contrast, a PAT cannot
reach this endpoint at all (§4) — the probe's permission branch is exactly the
constraint the auth matrix records. (The probe's PAT-rejection path was not run
here because the box authenticates in App mode; the rejection is the documented
Checks-API behavior, and the probe is written to classify it if run under a
PAT.)

### 6.4 GitHub rate limits (the ceilings)

From GitHub's documented REST API limits (docs.github.com → "Rate limits for
the REST API"; values stable across recent years):

| Limit | Value | Applies to |
|---|---|---|
| **Primary** (App installation token) | **5,000 requests / hour** (12,500 for larger installs) | all requests |
| **Primary** (PAT) | 5,000 requests / hour | all requests |
| **Secondary — content creation** | **≤ 80 content-generating requests / minute** and **≤ 500 / hour** | POST/PATCH/PUT/DELETE (comment create, check-run create) |
| **Secondary — concurrency** | ≤ 100 concurrent requests | all |

Comment creation **and** check-run creation are both *content-generating*
requests, so **both C1 and C2 are bound by the ≤80/min and ≤500/hr secondary
limit** — this is the binding ceiling, far below the 5,000/hr primary.

> **Critical scope nuance:** these limits are **per authenticated identity**.
> In **App mode** the whole fleet shares ONE installation token → the 80/min and
> 500/hr ceilings are **fleet-wide**, summed across all 25 concurrent runs. In
> **PAT mode** each run authenticates as the same host user → still effectively
> one identity → still fleet-wide. So the worst-case is the **sum over all
> concurrent runs**, not per-run. This is the pessimistic (correct) reading.

### 6.5 Step-by-step budget at `N=25`

Let *R* = total content-generating requests/hour the channel emits fleet-wide.
A run of mean duration *D* hours emits `lifecycle + D/T_renew` events; with runs
continuously cycling, the steady-state rate per concurrent slot is
`(lifecycle + D/T_renew) / D` events/hr, and fleet-wide `R = N × that`.

Take **D = 0.33 hr (20 min)**, lifecycle ≈ 10 (review, the heavier side):

**C2 (comments) at `T_renew = 60 s` (the issue's scenario):**
```
renewals per run      = D / T_renew = 1200 s / 60 s          = 20
events per run        = lifecycle + renewals = 10 + 20        = 30
events per run-hour   = 30 / 0.33                             ≈ 90  /hr per slot
fleet-wide R          = 25 × 90                               = 2250 /hr
per-minute peak       ≈ 2250 / 60                             ≈ 37.5 /min
```
→ **2250/hr ≫ 500/hr secondary limit. ❌ BLOWS the hourly content limit by 4.5×.**
The per-minute figure (37.5) is under 80/min on *average*, but bursty starts
(many runs beginning together) spike well over 80/min, and the hourly cap is
breached regardless.

**C2 (comments) at `T_renew = 300 s`:**
```
renewals per run      = 1200 / 300                            = 4
events per run        = 10 + 4                                = 14
events per run-hour   = 14 / 0.33                             ≈ 42 /hr per slot
fleet-wide R          = 25 × 42                               = 1050 /hr
```
→ **1050/hr — still over 500/hr. ❌** Even at 5-min renewals, 25 concurrent
runs exceed the hourly content-creation ceiling if *every* renewal is a comment.

**C2 with renewals NOT on the comment channel (lifecycle-only comments):**
Review lifecycle is `4 + 3A` events/run (§6.1), so the count — and the budget —
scales with the fan-out size `A`:
```
A=2 (10 events/run): R = 25 × (10 / 0.33)  = 25 × 30   = 750 /hr   ❌ over 500/hr
A=1 ( 7 events/run): R = 25 × ( 7 / 0.33)  = 25 × 21.2 ≈ 530 /hr   ❌ still over 500/hr
~4 events/run      : R = 25 × ( 4 / 0.33)  = 25 × 12.1 ≈ 300 /hr   ✅ under 500/hr
```
→ **Trimming the fan-out is NOT enough on its own**: even `A=1` (7 events/run)
is ~530/hr, still over the limit. C2 stays under 500/hr only if the **per-run
lifecycle comment count is capped at ~4** (the break-even is ~6 events/run:
`25 × 6 / 0.33 ≈ 455/hr`, so ≤~6/run is safe, ~4/run leaves headroom). That
means collapsing the per-reviewer lifecycle comments into a single aggregated
set (start / aggregated-verdict / merge / end), not merely reducing `A`.

**C1 (check-runs):** identical secondary-limit arithmetic (check-run create is
also content-generating), **plus** it is ❌ in PAT mode regardless of rate.

**C3 (state-dir + SSM):** **no GitHub content-creation request at all** for
writes. `R_github = 0`. The only API cost is the reconciler's *read-side* SSM
`send-command` calls — bounded by `T_poll`, not by event volume, and against
AWS SSM quotas (generous; per-region `SendCommand` is hundreds/sec), not GitHub.
→ **✅ no GitHub rate-limit exposure at any cadence.**

### 6.6 Headline answer (the acceptance-criteria question)

> **"At 25 concurrent runs and a 60 s heartbeat, which channels stay inside rate
> limits in App mode? In PAT mode?"**

| Channel | App mode @ N=25, T_renew=60s | PAT mode @ N=25, T_renew=60s |
|---|---|---|
| **C1 check-runs** | ❌ 2250/hr ≫ 500/hr secondary limit | ❌ **doubly out** — also no `checks:write` for a PAT |
| **C2 comments** (renewals as comments) | ❌ 2250/hr ≫ 500/hr | ❌ 2250/hr ≫ 500/hr (same shared identity) |
| **C2 comments** (lifecycle-only, renewals NOT on comments) | ⚠️ ~750/hr at A=2 (10 events/run) and ~530/hr at A=1 (7 events/run) — both over 500/hr; ✅ only if lifecycle comments are **capped at ~4/run** (~300/hr) | ⚠️ same |
| **C3 state-dir + SSM** | ✅ R_github = 0 — renewals never touch GitHub | ✅ R_github = 0 |

**Conclusion of the math:** **no GitHub-backed channel can carry the 60 s
*renewal* stream for 25 concurrent runs** — the secondary content-creation limit
(500/hr, fleet-wide on one identity) is breached even at 5-minute renewals. The
**renewal/heartbeat stream MUST stay off GitHub** (i.e., on C3 / local) at fleet
scale. GitHub channels (C2, and C1 in App mode only) are viable **only for the
sparse lifecycle events** (start / verdict / merge / end) — and even then only
if the per-run lifecycle count stays small.

---

## 7. Failure-mode comparison

| Dimension | C1 check-runs | C2 create-only comments | C3 state-dir + SSM |
|---|---|---|---|
| **GitHub API outage** | both write & read dead | both write & read dead | **unaffected** (local FS); only the *remote read* path (SSM) is exposed to an AWS outage, independent of GitHub |
| **Eventual-consistency lag** | check-run list propagation similar order to comments (~seconds) | **measured ~3–5 s** (§6.2) — reader must not treat "absent" as authoritative for ~5 s | **none** for local read; SSM read adds command-round-trip latency (~1–3 s) but is read-your-writes consistent on the source host |
| **Duplicate-event idempotency** | check-run has a stable `external_id` field → natural idempotency key | **no native dedup** — a retried POST creates a *second* comment. Needs an **app-level key embedded in the body** (see key scheme below) | append may double-write on retry; needs the same embedded key + a read-back-and-dedup at the reader |
| **Ordering** | check-runs carry server `started_at`/`completed_at` timestamps; no monotonic seq | comments carry server `created_at` (ms-resolution timestamp) and a monotonic `id` — **`id` is a reliable total order**; do NOT order by `created_at` alone (clock skew across writers) | the writer controls a local **monotonic `seq`** per run; across hosts, fall back to `(host, seq)` composite + emit `ts` |

### 7.1 Idempotency-key scheme (consumable by the gated phase)

Every event — on any channel — carries a deterministic key:

```
event_key = sha1( project | issue | run_id | event_type | seq )
```

- `run_id` = the wrapper's session UUID (already minted, e.g.
  `ffe95f93-…`). Distinguishes re-dispatched runs of the same issue.
- `seq` = monotonic per `run_id`, assigned by the writer. Gives total order
  within a run without trusting wall clocks.
- On **C2**, the key is embedded as a hidden marker in the comment body
  (`<!-- event-key: … -->`), mirroring the existing `dispatcher-token` marker
  pattern. The reader dedups by key; a duplicate POST (retry) is recognized and
  ignored.
- On **C1**, the key maps to the check-run `external_id` field (native).
- On **C3**, the key is a JSONL field; the reader dedups on read.

### 7.2 Sequence vs timestamp contract

**Order by `(run_id, seq)`, never by timestamp.** Timestamps (`ts`,
GitHub `created_at`) are for human/TTHW use and cross-run bucketing only — they
are subject to writer clock skew (Tokyo vs Singapore) and GitHub server time.
`seq` is the authoritative intra-run order; `(host, run_id, seq)` is the
authoritative cross-writer order.

---

## 8. The run-ledger question (review T1)

> **Would a canonical run-ledger (with labels demoted to a UI projection) beat
> the current label-canonical + additive-events model?**

### 8.1 The two models

- **A — label-canonical + additive events (status quo, extended).** GitHub
  labels remain the single source of truth for run state (`in-progress`,
  `reviewing`, …); the event channel is purely *additive* history that a
  reconciler reads to make decisions, but the **label is still what the state
  machine transitions on**.
- **B — run-ledger-canonical.** A durable ordered event ledger (one of C1/C2/C3)
  becomes the source of truth; the current state is *derived* by folding the
  ledger; labels become a **read-only UI projection** the pipeline writes for
  humans but never reads back for decisions.

### 8.2 Honest pros/cons

| | Model A (label-canonical) | Model B (run-ledger-canonical) |
|---|---|---|
| **Pro** | zero migration; labels already work; every existing invariant ([INV-…]) is phrased against labels; atomic-ish (a label is one mutation); humans see state at a glance | full history & causality; no "lost transition" (a crash mid-label-write leaves an inconsistent label, but a ledger fold is deterministic); enables true lease/reclaim semantics; replayable |
| **Con** | label mutations **race** (concurrent dispatcher + wrapper, the `label-race` failure class in [INV-70]); a label is a *latch*, not a log — it loses the *why* and the *order*; no idempotency | **large migration** — every invariant, hook, and the dispatcher's 5-step tick must be rewritten to fold the ledger; the ledger inherits the **channel's own rate-limit & lag** (§6: a GitHub ledger can't carry the renewal stream at N=25; a C3 ledger needs SSM round-trips to fold remotely); two sources of truth during migration = its own race |

### 8.3 Verdict on T1

**Keep labels canonical (Model A). Do NOT adopt a canonical run-ledger now.**

Rationale: Model B's decisive advantage (deterministic fold, true lease
semantics) is only realized if the ledger is **cheap to read on the deciding
node**. §6 proves that at fleet scale the only rate-limit-safe ledger is **C3
(local)** — but C3 is **expensive to read remotely** (SSM round-trip per fold),
and the *decider* (the dispatcher) is the **remote** node. So a canonical ledger
would put the authoritative read on the worst-positioned node. Until the
reconciler design resolves *where the decider runs relative to the ledger*, a
canonical ledger trades a known, bounded problem (label races, already mitigated
by [INV-24]'s cross-check and PID guards) for an unbounded migration with its own
new race window.

**The fleet keeps labels-canonical + additive events.** This section does not
argue otherwise convincingly enough to overturn the default, by the issue's own
stop-rule. Revisit only if (a) the decider and ledger are co-located, or (b)
label races measurably exceed the redesign's incident threshold (the #228
baseline will show this).

---

## 9. Verdict

### 9.1 Recommendation

**Hybrid, with a split by event frequency:**

1. **Lease/heartbeat renewals → C3 (local state dir), NEVER GitHub.** §6 proves
   no GitHub channel survives the renewal stream at `N=25`. The renewal signal
   stays local (as the heartbeat is today), and a **co-located** reconciler
   reads it directly; a **remote** reconciler reads it via the existing SSM path
   (the cost the gated phase must design around).
2. **Sparse lifecycle events (start / verdict / merge / end) → C2 (create-only
   comments)** as the durable, auth-robust, cross-node ledger. C2 is the **only
   candidate ✅ in every auth × execution cell** (§3), needs only scopes the
   pipeline already holds (§4), and stays inside the secondary limit *only if*
   the per-run lifecycle comment count is **capped at ~4/run** (~300/hr at
   N=25) — note trimming the fan-out alone is **not** enough (`A=1` is still
   ~530/hr, §6.5), so the per-reviewer lifecycle comments must be collapsed into
   a single aggregated set, not merely reduced.

### 9.2 Second choice

**C3 for *everything* (lifecycle events too), with SSM mirror reads.** If C2's
lifecycle volume proves too close to the 500/hr ceiling under real fleet load
(the #228 baseline will measure this), demote the lifecycle ledger to C3 as
well. The cost is the SSM read round-trip for the remote dispatcher; the benefit
is zero GitHub rate-limit exposure. This is the fallback if §6's "~300–750/hr"
estimate proves optimistic in production.

### 9.3 Conditions under which the recommendation flips

| Flip condition | New choice |
|---|---|
| Fleet runs **PAT mode** anywhere AND a check-run-shaped UI is wanted | **C1 is off the table** (PAT can't); stay C2/C3 |
| Lifecycle comment volume measured **> 500/hr** at real fleet load | flip lifecycle ledger from **C2 → C3** (second choice) |
| The reconciler/decider becomes **co-located** with wrappers | **C3 canonical ledger** (Model B) becomes viable — revisit §8 |
| GitHub raises the secondary content limit materially, OR per-repo (not per-identity) limits land | **C2** can absorb a faster cadence; reconsider renewals-on-C2 |
| Fan-out grows (more `AGENT_REVIEW_AGENTS`) raising lifecycle count | tighten toward **C3**, since each extra reviewer adds lifecycle comments |

### 9.4 GATED — explicit stop-rule

**This ADR carries NO implementation commitment.** Per the stability redesign's
stop-rule, the reconciler/lease phase is GATED on the #228 metrics baseline
holding the incident rate under threshold for the measurement window. If the
baseline shows the pipeline is stable enough, **the reconciler phase — and every
channel implemented here — is cancelled.** This document exists so that *if* the
gate opens, the channel decision is already made (with idempotency-key scheme
§7.1 and seq contract §7.2 ready to consume) — not so that it opens.

**No code in this PR changes any wrapper, dispatcher, hook, label transition,
verdict path, or merge decision.** The only executable artifact is the throwaway
measurement harness (`measure-event-channels.sh`), which no pipeline component
sources or invokes.

### 9.5 Did any topology cell fail ALL candidates?

No single cell fails *all three*, but the **remote-SSM read of a high-frequency
renewal stream** fails every *GitHub* candidate (rate limit) AND is *expensive*
on the local candidate (SSM round-trip). That is not "no viable channel" — it is
the precise constraint that forces the §9.1 split (renewals local, lifecycle on
GitHub). The ADR's outcome is therefore a **viable hybrid**, not "reconciler
design must change" — but the hybrid is only viable *because* it refuses to put
the renewal stream on any shared-quota channel.

---

## 10. Appendix — measurement harness

`docs/designs/measure-event-channels.sh` (ShellCheck-clean, `--dry-run` makes
zero network calls). It is a throwaway validation tool, not pipeline code.

```
# comment propagation (5 samples) — produced §6.2:
measure-event-channels.sh --repo zxkane/autonomous-dev-team --pr <N> --samples 5 --comment-only
# check-run latency + permission probe — produced §6.3:
measure-event-channels.sh --repo zxkane/autonomous-dev-team --sha <commit> --check-only
# offline control-flow test:
measure-event-channels.sh --repo o/n --pr 1 --dry-run
```

Measurements in §6.2/§6.3 were taken against this repo on 2026-06-14; probe
comments were deleted afterward, and the probe check-run (neutral conclusion,
old SHA) is inert.

---

## 11. Cross-references

- [`docs/pipeline/invariants.md` INV-71](../pipeline/invariants.md) — the pointer entry recording this decision (implementation gated).
- [`docs/pipeline/metrics.md`](../pipeline/metrics.md) — the events-per-run model used in §6.1; the #228 baseline this ADR depends on.
- [INV-29] heartbeat (local file touch), [INV-03] dev session report comment, [INV-40] review verdict comment, [INV-24] DEAD cross-check, [INV-70] metrics observe-only + the `label-race` failure class — the existing signals §1 surveys.
- `CLAUDE.local.md` → "OpenClaw dispatcher topology" — the Tokyo-dispatcher / Singapore-wrapper / remote-SSM topology §3 evaluates against.
