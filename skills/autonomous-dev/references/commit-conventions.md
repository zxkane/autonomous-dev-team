# Commit and Branch Conventions

Standards for branch naming, commit messages, and PR management.

## Branch Naming Convention

| Type | Pattern | Example | Use Case |
|------|---------|---------|----------|
| Feature | `feat/<name>` | `feat/user-config-api` | New functionality |
| Bug fix | `fix/<name>` | `fix/websocket-connection` | Bug repairs |
| Refactor | `refactor/<name>` | `refactor/openresty-container` | Code restructuring |
| Documentation | `docs/<name>` | `docs/runtime-routing` | Documentation updates |
| Test | `test/<name>` | `test/e2e-isolation` | Test additions |
| Chore | `chore/<name>` | `chore/update-deps` | Maintenance tasks |

### Branch Name Guidelines

- Use lowercase with hyphens
- Keep names concise but descriptive
- Avoid special characters
- Include ticket/issue number if applicable: `feat/GH-123-user-auth`

## Commit Message Format

```
type(scope): description

[optional body]

[optional footer]
```

### Types

| Type | Description | Example |
|------|-------------|---------|
| `feat` | New feature | `feat(auth): add Cognito user pool` |
| `fix` | Bug fix | `fix(runtime): correct URL rewriting` |
| `docs` | Documentation | `docs(readme): update deployment steps` |
| `refactor` | Code refactoring | `refactor(edge): extract Lambda handler` |
| `test` | Tests | `test(e2e): add user isolation tests` |
| `chore` | Maintenance | `chore(deps): update CDK to v2.100` |
| `perf` | Performance | `perf(query): optimize database queries` |
| `style` | Formatting | `style(lint): fix eslint warnings` |
| `ci` | CI/CD changes | `ci(workflow): add security scan` |

### Scopes

Define scopes based on your project structure. Common examples:

| Scope | Area |
|-------|------|
| `auth` | Authentication |
| `api` | API endpoints |
| `ui` | User interface |
| `db` | Database |
| `security` | Security configurations |
| `test` | Testing infrastructure |
| `e2e` | End-to-end tests |
| `design` | Design canvas/Pencil files |

### Message Guidelines

- Use imperative mood: "add" not "added" or "adds"
- Keep first line under 72 characters
- Don't end with period
- Capitalize first letter after type/scope

**Good examples**:
```
feat(auth): add user-scoped settings storage
fix(runtime): correct localhost URL rewriting
docs(readme): update deployment prerequisites
test(e2e): add TC-019 secrets isolation test
design(ui): create login page mockup in Pencil
```

**Bad examples**:
```
Added new feature.              # Past tense, vague, has period
fix stuff                       # No scope, too vague
FEAT(AUTH): ADD USER AUTH       # All caps
feat(auth): added user auth.    # Past tense, has period
```

## PR Checks Reference

### CI Checks

| Check | Description | Common Failures |
|-------|-------------|-----------------|
| `build-and-test` | TypeScript build + Jest + pytest | Compilation errors, test failures |
| `security-checks` | npm audit, secrets scan | Vulnerable dependencies |
| `infrastructure-scan` | Checkov, cfn-lint | IaC best practices |
| `dependency-check` | OWASP dependency check | Known vulnerabilities |

### Reviewer Bots

| Bot | Purpose | Response Strategy |
|-----|---------|-------------------|
| Amazon Q Developer | Security and code review | Fix issues or explain design decisions |
| Codex | AI code review | Fix issues or explain design decisions |
| Dependabot | Dependency updates | Review and merge if safe |

### Check Status Values

| Status | Meaning | Action |
|--------|---------|--------|
| `SUCCESS` | Check passed | Proceed |
| `FAILURE` | Check failed | Fix issues |
| `PENDING` | Still running | Wait |
| `SKIPPED` | Not applicable | Ignore |

## PR Title Conventions

Follow the same format as commit messages:

```
type(scope): brief description
```

Keep under 72 characters.

**Examples**:
```
feat(user-config): add user configuration API
fix(security): implement user-scoped settings stores
docs(e2e): add TC-019 and TC-020 test cases
design(dashboard): create analytics dashboard mockup
```

## PR Description Template

```markdown
## Summary
<1-3 bullet points describing the change>

## Design
- [ ] Design canvas created (`docs/designs/<feature>.pen`)
- [ ] Design approved by user

## Changes
- List of specific changes made

## Test Plan
- [ ] Unit tests pass (`npm run test`)
- [ ] E2E tests verified
- [ ] Manual verification completed

## Related Issues
Closes #<issue_number>
```

## Merge Strategy

1. **Squash and merge** - Default for feature branches
2. **Rebase and merge** - For clean history
3. **Merge commit** - Rarely used, preserves full history

Before merging:
- All CI checks must pass
- All review threads must be resolved
- At least one approval (if required)
- Design canvas approved (if applicable)
