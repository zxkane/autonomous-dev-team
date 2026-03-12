# GitHub Actions CI Setup Guide

This document provides the complete GitHub Actions CI workflow configuration.

## Why Manual Setup?

GitHub requires tokens with `workflow` scope to create or modify workflow files via API.
This is a security measure to prevent unauthorized workflow modifications.

## Adding the CI Workflow

### Steps

1. Create directory in your repository: `.github/workflows/`
2. Create file: `.github/workflows/ci.yml`
3. Copy the following content into the file

### CI Workflow Configuration

```yaml
name: CI

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

# Cancel in-progress runs for the same branch
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    name: Lint & Type Check
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run linter
        run: npm run lint

      - name: Run type check
        run: npm run typecheck

  test:
    name: Unit Tests
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run tests
        run: npm test -- --coverage

      - name: Upload coverage report
        uses: codecov/codecov-action@v4
        if: always()
        with:
          token: ${{ secrets.CODECOV_TOKEN }}
          files: ./coverage/lcov.info
          fail_ci_if_error: false

  build:
    name: Build
    runs-on: ubuntu-latest
    needs: [lint, test]
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Build
        run: npm run build

      - name: Upload build artifacts
        uses: actions/upload-artifact@v4
        with:
          name: build
          path: dist/
          retention-days: 7
```

## E2E Test Configuration (Optional)

If you need E2E tests, add the following job to the configuration above:

```yaml
  e2e:
    name: E2E Tests
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Install Playwright browsers
        run: npx playwright install --with-deps

      - name: Download build artifacts
        uses: actions/download-artifact@v4
        with:
          name: build
          path: dist/

      - name: Run E2E tests
        run: npm run test:e2e

      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 7
```

## Customization

Based on your project requirements, you may need to adjust:

1. **Node.js version**: Modify the `node-version` parameter
2. **Package manager**: If using yarn or pnpm, modify the installation commands accordingly
3. **Test commands**: Adjust test commands based on your `package.json`
4. **Build output directory**: Change `dist/` to your actual output directory
5. **Branch names**: If your main branch isn't `main` or `master`, adjust accordingly

## Required Secrets

To use the CI workflow, you need to configure the following GitHub secrets:

### CODECOV_TOKEN (Optional but Recommended)

For secure coverage report uploads:

1. Sign up at [codecov.io](https://codecov.io) and connect your repository
2. Get your repository upload token from Codecov
3. Add it as a GitHub secret:
   - Go to your repository → Settings → Secrets and variables → Actions
   - Click "New repository secret"
   - Name: `CODECOV_TOKEN`
   - Value: Your Codecov upload token

> **Note**: Without the token, coverage uploads may fail or be vulnerable to security issues.
