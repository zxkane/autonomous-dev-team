# Pre-fan-out E2E actionability test cases

| ID | Scenario | Expected result |
|---|---|---|
| TC-E2E-ACT-001 | Browser and command lanes start | Both inherit the wrapper-private classification path. |
| TC-E2E-ACT-002 | Non-zero lane rc, sidecar absent | Classification remains `dev-actionable=true`. |
| TC-E2E-ACT-003 | Valid `dev-actionable=false` | Current-HEAD `e2e-failed` disposition and `failed-substantive dev-actionable=false` are required before pending-dev; dispatcher stalls with no DEV dispatch or pending-review bounce. |
| TC-E2E-ACT-004 | Valid `dev-actionable=true` | Existing bounded same-HEAD correction routing dispatches DEV. |
| TC-E2E-ACT-005 | Malformed, oversized, symlink, directory, or other unsafe sidecar | Classification fails closed to `false`. |
| TC-E2E-ACT-006 | Human-spoofed, stale, abbreviated, or wrong-issue disposition | Strict routing parser ignores it. |
| TC-E2E-ACT-007 | PR HEAD changes after disposition | New HEAD transitions to pending-review and no DEV is dispatched against stale evidence. |
| TC-E2E-ACT-008 | Required disposition or verdict write fails | No `reviewing -> pending-dev` transition occurs. |
| TC-E2E-ACT-009 | Existing INV-92, INV-98, #351, #453, and #540 suites | All remain green. |
