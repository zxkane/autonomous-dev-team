# Full-wrapper scope enrollment (#522)

| ID | Scenario | Required result |
| --- | --- | --- |
| TC-WRS-001 | Explicit-user linger probe and doctor | Both pass the actual username; override cannot bypass refusal |
| TC-WRS-002 | Recorded scope backend, successful handshake | PID is a session/PGID leader, scope membership and registry precede payload; stdin, argv and rc 37 preserved |
| TC-WRS-003 | Registration failure before payload | Exactly one PGID fallback execution, with valid PID publication and registry |
| TC-WRS-004 | Payload prints `Failed to` and exits 37 | No fallback or second execution |
| TC-WRS-005 | Scope registry failure | Unacknowledged scope child never executes payload; PGID fallback executes once |
| TC-WRS-006 | Portable backend | No systemd-run launch; timeout, launcher, stdin and PID contracts preserved |
| TC-WRS-007 | Scoped timeout | Return 124, with one payload execution |
| TC-WRS-008 | Parallel invocations | Distinct registered agent scopes; reap includes every scope |
| TC-WRS-009 | Registration fails while lane closes | Fallback admission refuses payload under the reap lock |
| TC-WRS-010 | Hard-controlled closed-lane refusal | Control-plane rc 93, no payload |
| TC-WRS-011 | Bootstrap abort wins atomic decision | Confirmed pre-ack abort retries once through PGID; a committed go cannot replay |
| TC-WRS-012 | TERM-resistant failed registration | Verified child/group cleanup escalates within a bound; no indefinite wait |
| TC-WRS-013 | Cleanup cannot read a live child's identity | Unknown is not termination; refuse wait and replay |
| TC-WRS-E2E-001 | Real wrapper, real user manager, re-setsid escape | Both agent and escapee in owned cgroup before wrapper SIGKILL; guardian empties scope and leaves no live fixture |
| TC-WRS-E2E-002 | Real wrapper, rejected scope registration | Payload runs once under PGID fallback and guardian reaps it |

Hermetic shims verify launch protocol and contracts, not kernel containment.
The real E2E requires the host's existing explicit-user Linger=yes and user bus.
Every fixture uses an isolated state root and only task-owned processes/units;
its outputs are excluded from production observation evidence. Existing timeout,
turn-control, launcher, prompt-stdin, credential-split and Lane-GC suites remain
required regression checks.
