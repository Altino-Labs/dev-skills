---
name: bootstrap-project
description: >
  The TypeScript-stack phase of a new project's bootstrap, run from dev-core:bootstrap-project
  when its stack ADR picks the dev-patterns stack (NestJS/Fastify, Supabase/Postgres,
  Expo/React Native, Next.js, pnpm + Turborepo). Covers the PROJECT.md sections the
  dev-patterns skills read, the monorepo scaffold (layout, package scope, test fakes, dev
  dependencies) and the stack's service-by-service provisioning, each with a checkpoint.
---

# Bootstrap — TypeScript stack phase

> **Run `dev-core:bootstrap-project` first.** It owns everything stack-agnostic: ingesting the
> spec, choosing the stack as an ADR, installing the plugins and the project's `.claude/`
> layer, the `AGENTS.md` / `CLAUDE.md` / constitution / `SESSION.md` templates, the repository
> and CI baseline, and the infrastructure order (staging first, production deferred, backups
> with a restore drill, secrets inventory). This skill is the **stack phase** it calls when
> ADR-001 chose the `dev-patterns` stack: it replaces "Scaffold" in that skill's Phase 4 and
> adds the concrete services to its Phase 5. Don't repeat the dev-core steps here.

## Overview

```
Step 1 — PROJECT.md sections the stack skills read   (during dev-core Phase 3)
Step 2 — Scaffold the monorepo                       (dev-core Phase 4, "Scaffold")
Step 3 — Stack services                              (dev-core Phase 5, in its order)
Step 4 — Validate the stack                          (with dev-core Phase 6)
```

---

## Step 1 — `PROJECT.md` sections the stack skills read

`PROJECT.md` (or its split into `project/*.md` — `ADR.md`, `MODULES.md`, `DATA-MODEL.md`,
`API.md`, `INFRA.md`, `UX.md`…, with `PROJECT.md` as the index) is described in
`dev-core:bootstrap-project` → Phase 3. The `dev-patterns` skills and the `dev-core` agents
look for these sections, wherever they live:

| Section | Read by | Notes |
|---|---|---|
| Overview | every agent | 2–3 sentences: what, for whom, business model |
| ADRs | `dev-core:tech-lead`, `dev-core:architect` | Nygard format (Context / Decision / Consequences); ADR-001 = the stack |
| Modules | `dev-core:architect`, `dev-core:domain-events` (aggregator modules) | every feature module |
| Aggregate map (+ context map at 8+ roots) | `dev-core:clean-architecture` | root, entities inside, invariants |
| User model + permissions matrix | `dev-patterns:auth-security`, `dev-core:appsec` | role × operation; every endpoint maps to a row |
| Business rules | every implementer | per module |
| Enums | `dev-core:dba`, `dev-patterns:migrations` | the **only** source of enum values |
| Domain events catalog | `dev-patterns:domain-events` | name, payload, subscribers |
| API endpoints | `dev-core:backend-developer` | method, path, use case, permission |
| Scheduled jobs and alerts | `dev-patterns:notifications-cron`, `dev-patterns:jobs-queues` | or "No scheduled jobs planned" |
| Data model | `dev-core:dba` | kept in sync with migrations |
| Infrastructure | `dev-core:devops` | summary; details in `INFRA.md` |
| UX requirements | `dev-core:frontend-developer`, `dev-patterns:mobile-ux-patterns` | **optional** — the project's own UX decisions, when it has any; the skills don't impose a house UX |

**Checkpoint 1:** the sections above exist (a section may say "N/A" with a reason, never be
silently missing); `dev-core:architect` can plan the first module from them.

---

## Step 2 — Scaffold the monorepo

### Directory structure

```
[project-root]/
├── apps/
│   ├── api/
│   │   ├── src/
│   │   │   ├── common/           ← guards, filters, interceptors, decorators (intra-api shared)
│   │   │   │   ├── guards/
│   │   │   │   ├── filters/
│   │   │   │   ├── interceptors/
│   │   │   │   └── decorators/
│   │   │   └── [modules]/        ← feature modules (auth, orders, …)
│   │   └── test/
│   │       ├── fakes/            ← StrictEventBus, CapturingEventBus, InMemoryUnitOfWork
│   │       ├── factories/        ← EntityFactory per domain module
│   │       ├── helpers/          ← assertSnakeCase, db seed helpers
│   │       └── contracts/        ← one contract spec per controller
│   ├── mobile/       ← Expo SDK + expo-router
│   └── admin-web/    ← Next.js (optional — e.g. an admin panel)
├── packages/
│   ├── shared-types/ ← DTOs, enums, interfaces
│   ├── utils/        ← pure functions, date helpers
│   └── ui/           ← design tokens (optional)
├── supabase/
│   ├── migrations/       ← SQL migrations
│   ├── seed-lib.sh       ← shared functions (create user/staff via Admin API)
│   ├── seed-essential.sh ← staff/admin account only — the only one safe to run
│   │                        against staging/production too (see migrations skill)
│   └── seed.sh           ← local-only: runs seed-essential.sh, then adds demo data
├── .claude/          ← project layer — see dev-core:bootstrap-project, Phase 2
├── turbo.json
├── pnpm-workspace.yaml
└── package.json
```

### Required config files

**`pnpm-workspace.yaml`**
```yaml
packages:
  - 'apps/*'
  - 'packages/*'
```

**`turbo.json`** (minimal)
```json
{
  "$schema": "https://turbo.build/schema.json",
  "tasks": {
    "build": { "dependsOn": ["^build"], "outputs": ["dist/**"] },
    "test":  { "dependsOn": ["^build"] },
    "lint":  {},
    "type-check": { "dependsOn": ["^build"] },
    "dev":   { "cache": false, "persistent": true }
  }
}
```

Every app and package defines `lint`, `type-check` and `test` scripts — turbo skips an app
without the script silently (`dev-core:bootstrap-project` → CI baseline;
`dev-patterns:github-actions-monorepo`).

**`packages/shared-types/package.json`**
```json
{
  "name": "@your-app/shared-types",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "scripts": { "build": "tsc" }
}
```

Replace `@your-app` with your actual package scope (e.g. `@acme`, `@myproject`).

**Dev dependencies of `apps/api`** — install the **current major** of each, with
`pnpm --filter api add -D …` (never a bare install at the root):

- `@golevelup/ts-jest` (or Vitest's `vi.fn` helpers on the ESM + Vitest track) — `createMock<T>()`
  for Use Case unit tests (`dev-patterns:test-patterns`).
- `@stryker-mutator/core` + the runner for your test runner — mutation testing, **report-only
  first**: a scheduled workflow with no `thresholds.break`, never a merge gate until the scores
  have settled (`dev-core:test-patterns` → "Mutation testing";
  `dev-patterns:test-patterns` → `stryker-mutation.md`).

**Seed the `test/fakes/` directory immediately** — these fakes are shared across all modules and must exist before writing the first test:

```
apps/api/test/fakes/
  strict-event-bus.ts       ← propagates subscriber errors (integration tests)
  capturing-event-bus.ts    ← records events without running subscribers
  in-memory-unit-of-work.ts ← runs the callback directly; no transaction
```

Copy the canonical implementations from `dev-core:test-patterns` — `contract-event-tests.md`
("Event Bus test fakes") and `mock-patterns.md` ("IUnitOfWork test pattern").

**Package scope checklist — every occurrence must match or the build breaks silently:**

| File | What to change |
|---|---|
| `packages/shared-types/package.json` | `"name": "@acme/shared-types"` |
| `packages/utils/package.json` | `"name": "@acme/utils"` + dep `"@acme/shared-types": "workspace:*"` |
| `packages/ui/package.json` | `"name": "@acme/ui"` + dep `"@acme/utils": "workspace:*"` |
| `apps/api/package.json` | deps `"@acme/shared-types"` and `"@acme/utils"` |
| `apps/mobile/package.json` | deps `"@acme/shared-types"`, `"@acme/utils"`, `"@acme/ui"` |
| `apps/mobile/metro.config.js` | resolver alias `@acme/shared-types → ../../packages/shared-types/src` |
| `.claude/general-context.md` | Import examples (`import { … } from '@acme/shared-types'`) |

**Plugin files — do NOT modify per project:**
the `dev-patterns` skills use `@app/` as an illustrative placeholder in code snippets. Agents
read `.claude/general-context.md` as the authority for imports and will use whatever scope is
declared there. No delta skill is needed just for the package scope.

Per-app setup: `dev-patterns:nestjs-fastify` (API), `dev-patterns:feature-slice` (mobile and
web — including a development build instead of Expo Go once there are native modules),
`dev-patterns:shared-kernel` (packages).

**Checkpoint 2:** `pnpm install` runs without errors; `pnpm build`, `pnpm lint`,
`pnpm type-check` and `pnpm test` complete with one task per app/package in turbo's output.

---

## Step 3 — Stack services

Provision in the order of `dev-core:bootstrap-project` → Phase 5 (staging first, production
deferred), one confirmed step at a time. What each step means on this stack:

| dev-core step | Service | Skill |
|---|---|---|
| Database | Supabase project in the region ADR-001 chose; `supabase link`; RLS and Auth config | `dev-patterns:supabase-setup`, `dev-patterns:migrations` |
| Backups | Confirm the plan's backups; back up Storage files too | `dev-patterns:supabase-setup` |
| Hosting + deploy | The API on **the container host chosen in the stack ADR** (e.g. Cloud Run, Fly, Render) from the Dockerfile; health checks (liveness vs readiness); graceful shutdown; scheduled jobs via an external tick if the host scales to zero | `dev-patterns:railway-nestjs` (Dockerfile, health, shutdown — portable to any container host), `dev-patterns:jobs-queues` → "Scheduled jobs" |
| Hosting + deploy | Web apps on their host (e.g. Vercel); public env vars spelled out literally so they are inlined | `dev-patterns:auth-security` (Next.js BFF for an admin app), `dev-patterns:logging-observability` |
| CI/CD | GitHub Actions: CI on every PR; staging deploy on merge (migrate → API → health check → web / OTA) | `dev-patterns:github-actions-monorepo` |
| Error tracking | Sentry in the API, Next.js and Expo, privacy defaults on | `dev-patterns:logging-observability` |
| DNS / edge | Cloudflare: SSL Full (strict), headers; **Bot Fight Mode blocks CI and serverless calls** — health checks and server-to-server calls use the origin URL, protected by an origin-auth header | `dev-patterns:cloudflare-setup` |
| Mobile builds | Expo EAS: profiles (development / staging / production), channels, OTA | `dev-patterns:expo-eas` |

### Optional services (add when needed)
| Service | Skill | When |
|---|---|---|
| Upstash Redis | `cache` or `jobs-queues` | When adding caching or async jobs |
| Resend | `resend-email` | When sending transactional email |

**Checkpoint 3:** the API answers its liveness and readiness routes on staging; Supabase
migrations apply from an empty database without error; the mobile app runs on a simulator.

---

## Step 4 — Validate the stack

Together with the checklist of `dev-core:bootstrap-project` → Phase 6:

### Code
- [ ] `pnpm build`, `pnpm lint`, `pnpm type-check`, `pnpm test` — zero errors, one task per app/package
- [ ] First migration runs with `supabase db push` (and from an empty local database) without error
- [ ] Package scope (`@your-app/`) is consistent across every file in the checklist above

### Test infrastructure
- [ ] `apps/api/test/fakes/strict-event-bus.ts` exists and implements `IEventBus`
- [ ] `apps/api/test/fakes/capturing-event-bus.ts` exists and implements `IEventBus`
- [ ] `apps/api/test/fakes/in-memory-unit-of-work.ts` exists and implements `IUnitOfWork`
- [ ] The mock helper resolves (`import { createMock } from '@golevelup/ts-jest'`, or the Vitest equivalent)
- [ ] `apps/api/test/helpers/assert-snake-case.ts` exists (copy from `dev-patterns:test-patterns` → `contract-tests-http.md`)
- [ ] The mutation-testing workflow exists, scheduled and report-only

### Infrastructure
- [ ] API healthy at its staging URL (custom domain or the host's own URL)
- [ ] Supabase Auth creates a test user successfully
- [ ] Mobile app renders the first screen on a simulator

### Agent readiness
- [ ] `dev-patterns` installed; a stack skill (e.g. `dev-patterns:clean-architecture`) loads
- [ ] `dev-core:dba` creates the first migration with enum values taken from `PROJECT.md`'s enums table

**The stack phase is complete when all items above are checked.**
