# Test Cases — Pluggable Execution Backend (PR-9)

## TC-EB-001: dispatch() routes to local backend (default)

**Given** `EXECUTION_BACKEND` unset (or `=local`) and a stubbed `dispatch-local.sh` that records argv
**When** `dispatch dev-new 99` is called from `dispatcher-tick.sh`
**Then** the stub recorded `dev-new 99` and the remote driver was NOT invoked.

## TC-EB-002: dispatch() routes to remote-aws-ssm backend

**Given** `EXECUTION_BACKEND=remote-aws-ssm` and a stubbed `dispatch-remote-aws-ssm.sh` that records argv
**When** `dispatch dev-new 99` is called
**Then** the stub recorded `dev-new 99` and `dispatch-local.sh` was NOT invoked.

## TC-EB-003: dispatch() rejects unknown backend

**Given** `EXECUTION_BACKEND=bogus`
**When** `dispatch dev-new 99` is called
**Then** rc != 0, stderr names the bad value, no driver was invoked.

## TC-EB-004: dispatcher-tick.sh source-of-truth uses dispatch()

**Given** the source of `dispatcher-tick.sh`
**When** grepping for direct `bash .../dispatch-local.sh` invocations in step 2/3/4 bodies
**Then** none found — all dispatching goes through the `dispatch()` helper.

## TC-EB-005: dispatch-remote-aws-ssm.sh requires SSM_INSTANCE_ID

**Given** required env var `SSM_INSTANCE_ID` unset
**When** `dispatch-remote-aws-ssm.sh dev-new 99` runs
**Then** rc != 0, stderr explains the missing var, `aws` was NOT called.

## TC-EB-006: dispatch-remote-aws-ssm.sh requires SSM_REMOTE_PROJECT_DIR / _PROJECT_ID

**Given** SSM_INSTANCE_ID set, but SSM_REMOTE_PROJECT_DIR or SSM_REMOTE_PROJECT_ID unset
**When** the script runs
**Then** rc != 0, stderr names the missing var.

## TC-EB-007: dispatch-remote-aws-ssm.sh validates issue number / session id / project id

**Given** issue=`abc` (non-numeric) or session=`bad;chars` or project_id=`with/slash`
**When** the script runs
**Then** rc != 0, validation diagnostic in stderr.

## TC-EB-008: dispatch-remote-aws-ssm.sh defaults

**Given** SSM_REMOTE_USER, SSM_REMOTE_SHELL unset (and SSM_REGION unset, SSM_REMOTE_PROFILE empty)
**When** the script builds INNER_CMD (verified by stubbing aws)
**Then** SSM_REMOTE_USER defaults to `ubuntu`, SSM_REMOTE_SHELL to `bash`, SSM_REGION to `ap-southeast-1`, no `source $PROFILE` prefix.

## TC-EB-009: dispatch-remote-aws-ssm.sh honors SSM_REMOTE_PROFILE

**Given** SSM_REMOTE_PROFILE=`/home/ubuntu/.bash_aliases`
**When** the script builds INNER_CMD
**Then** the constructed command starts with `source /home/ubuntu/.bash_aliases; `.

## TC-EB-010: dispatch-remote-aws-ssm.sh uses jq --arg for JSON escaping (CWE-78)

**Given** the source of `dispatch-remote-aws-ssm.sh`
**When** grepping for the SSM `--parameters` construction
**Then** the command JSON is built via `jq -n --arg cmd ... '[$cmd]'`, NOT via literal string interpolation.

## TC-EB-011: dispatch-remote-aws-ssm.sh propagates aws failure

**Given** stubbed `aws` returning rc=2
**When** the script runs
**Then** rc != 0, stderr explains the failure with instance/region context.

## TC-EB-012: dispatch-remote-aws-ssm.sh requires aws + jq on PATH

**Given** `aws` (or `jq`) removed from PATH via `env -u`
**When** the script runs
**Then** rc != 0, stderr names the missing dependency.

## TC-EB-013: multi-tick handles inline-block project

**Given** dispatcher.conf with `PROJECTS+=( '<inline block with REPO=...>' )`
**When** multi-tick runs
**Then** it eval's the block in a subshell, exports the vars, and invokes dispatcher-tick.sh with the right env (REPO, EXECUTION_BACKEND, SSM_INSTANCE_ID propagated; REPO_OWNER/REPO_NAME auto-derived).

## TC-EB-014: multi-tick auto-derives REPO_OWNER and REPO_NAME

**Given** inline block contains only `REPO=myorg/projB` (no REPO_OWNER, no REPO_NAME)
**When** multi-tick processes it
**Then** the subshell has `REPO_OWNER=myorg` and `REPO_NAME=projB`.

## TC-EB-015: multi-tick rejects inline block with non-assignment line

**Given** inline block contains `rm -rf /` mixed with valid assignments
**When** multi-tick processes it
**Then** the block is rejected before eval, warning logged, sibling projects continue.

## TC-EB-016: multi-tick warns and skips inline block missing REPO

**Given** inline block has PROJECT_ID but no REPO
**When** multi-tick processes it
**Then** that project is skipped with a clear warning, rc=0 overall.

## TC-EB-017: multi-tick mixed local + remote projects

**Given** PROJECTS containing one path entry (existing local project) and one inline block (remote project)
**When** multi-tick runs
**Then** both projects' ticks are attempted; local goes via source-autonomous.conf path, remote goes via inline-eval path; per-project failure isolation preserved.

## TC-EB-018: backwards compat — dispatcher-tick.sh standalone unchanged

**Given** the existing PR-8 single-project entry (path string in PROJECTS)
**When** multi-tick processes it
**Then** behavior is byte-identical to PR-8: source autonomous.conf via AUTONOMOUS_CONF env override, run dispatcher-tick.sh in subshell, exit code captured.

## TC-EB-019: source-of-truth — dispatch-local.sh byte-identical

**Given** main branch's dispatch-local.sh and PR-9's dispatch-local.sh
**When** diffed
**Then** zero changes. Backwards compat is structural.
