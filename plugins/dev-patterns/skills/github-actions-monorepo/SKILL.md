---
name: github-actions-monorepo
description: >
  Reusable CI/CD patterns with GitHub Actions for NestJS + React Native/Next.js monorepos.
  Invoke automatically when configuring CI pipelines, automatic deploys,
  branch protection, secrets, or approval environments on GitHub.
---

# GitHub Actions — Monorepo CI/CD

## Workflow structure

```
.github/workflows/
├── ci.yml                ← lint + typecheck + tests + build (every PR)
├── deploy-staging.yml    ← automatic deploy when merging to develop
└── deploy-production.yml ← deploy with manual approval when merging to main
```

---

## ci.yml — Quality pipeline

```yaml
name: CI

on:
  pull_request:
    branches: [main, develop]

jobs:
  quality:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Lint
        run: npm run lint

      - name: Type check
        run: npm run typecheck

      - name: Unit tests
        run: npm run test:unit

      - name: Build
        run: npm run build

      - name: Integration tests
        run: npm run test:integration
        env:
          DATABASE_URL: ${{ secrets.TEST_DATABASE_URL }}
```

**Make sure "Type check" really covers every app.** In a turbo/pnpm monorepo
`pnpm type-check` only runs in packages that define a `type-check` script — an app
without one is silently skipped, and the step still passes. This hides real gaps:
- **Expo / React Native app:** its `build` is usually a no-op in CI and Jest (Babel)
  strips types, so without its own `"type-check": "tsc --noEmit"` its types are
  **never** checked in CI.
- **NestJS API:** `nest build` checks `src/` but not test files.

Give every app `"type-check": "tsc --noEmit"` and confirm the turbo summary lists all of
them (e.g. `Tasks: 5 successful, 5 total`). For an Expo app with typed routes, generate
the route types first — see `expo-router` §21.

---

## deploy-staging.yml — Automatic deploy

```yaml
name: Deploy Staging

on:
  push:
    branches: [develop]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Install and test
        run: npm ci && npm run test

      - name: Deploy to Railway (staging)
        run: railway up --service api-staging
        env:
          RAILWAY_TOKEN: ${{ secrets.RAILWAY_TOKEN }}

      - name: Run migrations (staging)
        run: npm run migrate
        env:
          DATABASE_URL: ${{ secrets.STAGING_DATABASE_URL }}

      - name: Health check
        run: sleep 15 && curl --fail ${{ secrets.STAGING_API_URL }}/health/ready
```

---

## deploy-production.yml — Deploy with manual approval

```yaml
name: Deploy Production

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: production     # blocks until manual approval on GitHub

    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: 'npm'

      - name: Install and test
        run: npm ci && npm run test

      - name: Deploy to Railway (production)
        run: railway up --service api-production
        env:
          RAILWAY_TOKEN: ${{ secrets.RAILWAY_TOKEN }}

      - name: Run migrations (production)
        run: npm run migrate
        env:
          DATABASE_URL: ${{ secrets.PROD_DATABASE_URL }}

      - name: Health check
        run: sleep 15 && curl --fail ${{ secrets.PROD_API_URL }}/health/ready

      - name: Notify on failure
        if: failure()
        run: echo "Deploy failed — check logs and trigger rollback if necessary"
```

---

## Branch protection — configure on GitHub

```
Branch: main
  ✓ Require pull request reviews (minimum 1 approval)
  ✓ Require status checks to pass (CI required)
  ✓ Require branches to be up to date before merging
  ✓ Restrict direct pushes (no one pushes directly)

Branch: develop
  ✓ Require status checks to pass (CI required)
```

---

## Required GitHub secrets

| Secret | Description |
|---|---|
| `RAILWAY_TOKEN` | Railway deploy token |
| `TEST_DATABASE_URL` | Database for integration tests |
| `STAGING_DATABASE_URL` | Staging database |
| `PROD_DATABASE_URL` | Production database |
| `STAGING_API_URL` | Staging API URL for health check |
| `PROD_API_URL` | Production API URL for health check |
| `SENTRY_AUTH_TOKEN` | For source map uploads |

`STAGING_API_URL`/`PROD_API_URL` are illustrative. If the health-check target is a fixed,
public URL per environment, `curl` it directly in the workflow instead of creating a secret —
secrets that nothing varies end up dead and stale. Use a secret only if the target URL
genuinely varies per environment/deploy, and periodically prune secrets no workflow reads.

---

## Production environment with manual approval

Configure at GitHub → Settings → Environments → `production`:

```
Required reviewers: [your user or team]
Wait timer: 0 minutes
```

This blocks the deploy until someone approves manually in the GitHub Actions UI.

---

## Complete deploy flow

```
Developer opens PR
        ↓
CI runs (lint + typecheck + tests + build) — must pass
        ↓
Code review (minimum 1 approval)
        ↓
Merge to develop → automatic deploy to staging
        ↓
QA validates on staging
        ↓
PR from develop → main
        ↓
Manual approval (GitHub environment protection)
        ↓
CI runs again on main
        ↓
Deploy to production (Railway + migrations)
        ↓
Automatic health check (/health/ready)
        ↓
✓ Deploy complete
```
