---
name: bootstrap-project
description: >
  Step-by-step guide to set up a new project using the dev-patterns plugin plus a
  project-local .claude/ folder. Follow the phases in order. Each phase has a validation checkpoint before
  proceeding to the next.
---

# Bootstrap — New Project Setup

## Overview

```
Phase 1 — Install plugin + local .claude/  ~10 min
Phase 2 — Define the project      ~60 min
Phase 3 — Scaffold the monorepo   ~20 min
Phase 4 — Provision infrastructure ~90 min
Phase 5 — Validate                ~10 min
```

Total: ~3 hours for a fully operational project with AI agents ready to work.

---

## Phase 1 — Install the plugin and create the local `.claude/`

The framework is split in two layers:

| Layer | Where | What lives there |
|---|---|---|
| **Shared** | the `dev-core` and `dev-patterns` Claude Code plugins | `dev-core`: stack-agnostic skills (`dev-core:<skill>` — `git`, `pre-merge`, `resilience-patterns`, `secrets-rotation`), the 8 role agents (`dev-core:<agent>` — `architect`, `tech-lead`, `backend-developer`, `frontend-developer`, `dba`, `devops`, `qa`, `appsec`) and the safety hooks; `dev-patterns`: the TypeScript stack skills (`dev-patterns:<skill>`) and the lint hook |
| **Project** | the repo's own `.claude/` | constitution, general context, project-specific delta skills, project-only agents, per-agent context files |

### 1a. Install the plugins

Inside a Claude Code session at the new project root:

```
/plugin marketplace add Altino-Labs/dev-skills
/plugin install dev-core@dev-skills
/plugin install dev-patterns@dev-skills
```

Update later with `claude plugin update dev-core` and `claude plugin update dev-patterns`. Never copy plugin skills/agents into
the project — fix or extend them in the plugin repo so every project benefits.

### 1b. Create the local `.claude/`

```
.claude/
├── constitution.md          ← non-negotiable rules for agents (write once; rarely changes —
│                              the plugin does not ship one)
├── general-context.md       ← this project's context, identity model, vocabulary, import scope
├── README.md                ← structure guide for this project's .claude/
├── settings.json            ← permissions, project-only hooks (enable dev-core + dev-patterns here;
│                              the generic safety hooks ship with dev-core — don't copy them)
├── skills/
│   └── <project>-<skill>/   ← delta skills — ONLY project-specific additions to a plugin skill
│       └── SKILL.md
├── agents/                  ← project-only agents (e.g. tech-lead, backend-developer,
│                              frontend-developer, dba) — agents whose instructions depend
│                              on this codebase's real classes/paths
└── agent-context/
    └── <agent>.md           ← project-specific rules a PLUGIN agent reads at start
                               (e.g. agent-context/appsec.md for dev-core:appsec)
```

**Delta skill convention** — `.claude/skills/<project>-<skill>/SKILL.md`:

```markdown
---
name: <project>-<skill>
description: <Project>-specific complement to the dev-patterns:<skill> skill — <what it adds>. Invoke together with dev-patterns:<skill> whenever <same triggers as the plugin skill>.
---

# <Title> — <Project> specifics

> Base pattern: `dev-patterns:<skill>` (load it first). This file only adds what is specific to <Project>; on conflict, this file wins.

## § <heading of the plugin skill section>
<real paths, table/column names, ADR refs, defaults, decisions, incidents>
```

Create a delta only when there is real project-specific content (canonical reference files,
real table names, deliberate deviations from the generic pattern, dated status notes). Don't
restate the generic pattern. A brand-new project usually starts with **no** deltas — they
accumulate as decisions are made.

**`agent-context/<agent>.md`** — the plugin agents are generic; anything they must know about
this project (sensitive data categories, extra review rules, real paths of guards/fakes,
enum source of truth) goes here. Create one only when needed.

**Project-only agents** — the `dev-core` plugin already ships the 8 standard roles (`architect`,
`backend-developer`, `frontend-developer`, `dba`, `qa`, `tech-lead`, `appsec`, `devops`);
customize them through `agent-context/`, not by copying. Write a local agent under
`.claude/agents/` only for a role the plugin doesn't have. Plugin agents are namespaced
(`dev-core:<agent>`), so a local agent with the same name does not replace one — it
shows up as a second agent; avoid that.

### What you must write

The plugin ships no templates for these — write them for this project.

| File | Content |
|---|---|
| `constitution.md` | Non-negotiable rules agents must follow (e.g. never commit secrets, confirm destructive/production operations, layer boundaries) |
| `general-context.md` | "About this project", identity model, domain vocabulary, framework-level conventions |
| `me.md` (optional, per developer, usually gitignored) | Your name, team, focus and current branch |

### What you must create from scratch

| File | Description |
|---|---|
| `PROJECT.md` | Domain, business rules, permissions, enums, events, endpoints, UX spec |
| `INFRA.md` | Provisioned services, environment variables, bootstrap checklist |
| `.bootstrap-secrets` | Credentials for provisioning (gitignored — never commit) |
| `.bootstrap-secrets.example` | Template with keys and no values (committed) |

**Checkpoint 1:** `/plugin` lists `dev-core` and `dev-patterns` as installed and their skills show up as
`dev-core:<skill>` / `dev-patterns:<skill>`; all local items above exist. Proceed to Phase 2.

---

## Phase 2 — Define the project

### 2a. Write `general-context.md`

Start with an "About this project" section — a 3–5 line description:
- What the system does
- Who uses it
- The core multi-tenancy or ownership model (e.g. "multi-tenant by organization")
- The tech stack (only if different from the default)

Add an "Identity model" section with the project's actual user roles and types.

Add a "Domain vocabulary" table with this project's terms.

Then add the framework-level conventions agents should follow (auth pattern, API response rules,
commit conventions) — these rarely change once written.

---

### 2b. Create `PROJECT.md` — mandatory sections

All sections below are required. Agents will break or produce incorrect output if any is missing.

```markdown
# PROJECT.md — [Project Name]

## §1 — Overview
[2-3 sentences: what the system does, who uses it, business model]

## §2 — Architectural Decision Records (ADRs)
<!-- Promoted from the project's session log / decision notes (if it keeps one).
     Use the Nygard format: Context / Decision / Consequences.
     Never write a one-liner here — future agents need the reasoning, not just the title. -->

## ADR-001: [Short imperative title — what was decided]

**Date:** YYYY-MM-DD
**Status:** Accepted

**Context:**
[1–3 sentences: what situation or trade-off prompted this decision?]

**Decision:**
[1 paragraph: what was decided. State as a rule — "We will…" / "X must always…"]

**Consequences:**
- [What is now required]
- [What is now forbidden]
- [What becomes simpler or harder]

## §3 — Modules
[List all feature modules. Each agent reads this to know the full scope.]
- auth, users, [domain-module-1], [domain-module-2], ...

## §3b — Aggregate Map
[List every Aggregate Root with its boundary and key invariants (one row per root: root,
 entities inside the boundary, invariants it enforces). The Aggregate Map prevents Use Cases from crossing aggregate boundaries directly.]

## §3c — Context Map (fill when the system has 8+ aggregate roots)
[Group aggregates into Bounded Contexts. Shows which modules form a coherent sub-domain
 and how cross-context integration happens — always via Domain Events, never via direct Use Case calls.
 Based on Evans, Domain-Driven Design ch. 10.]

| Bounded Context | Aggregate Roots | Integration with other contexts |
|---|---|---|
| [ContextA] | [Root1, Root2] | Publishes [event.name] → [ContextB] subscribes |
| [ContextB] | [Root3, Root4] | Consumes [event.name] from [ContextA] |

If your system has fewer than 8 aggregate roots, skip this section and write "N/A — single bounded context."

## §4 — User Model
[Who logs in. What roles/types exist. How identity relates to data access.]

user_type:  [TYPE_A] | [TYPE_B]       ← who the person is
user_role:  [ROLE_A] | [ROLE_B]       ← what they can do

## §5 — Permissions Matrix
[Table: role × operation → allowed/denied. Every endpoint maps to a row here.]

| Operation | [ROLE_A] | [ROLE_B] |
|---|---|---|
| create X  | ✅        | ❌        |
| read X    | ✅        | ✅        |

## §6 — Business Rules
[Module by module. These are the rules agents must not violate.]

### [ModuleName]
- Rule 1
- Rule 2

## §7 — Enums
[CRITICAL: migrations and architecture reviews (DBA / tech-lead agents, if the project has them) use this as the source of truth for all enum values.]
[Never invent values outside this table.]

| Enum name | Values |
|---|---|
| status_enum | ACTIVE \| INACTIVE \| ARCHIVED |

## §8 — Domain Events Catalog
[Every event the system publishes. `dev-core:domain-events` references this.]

| Event name | Payload fields | Subscribers |
|---|---|---|
| entity.created | id, created_by, occurred_at | SendWelcomeEmailSubscriber |

## §9 — API Endpoints
[Every planned route. Whoever implements the backend (agent or human) uses this to know what to build.]

| Method | Path | Use Case | Permission |
|---|---|---|---|
| POST | /api/v1/[resource] | CreateResourceUseCase | [ROLE_A] |

## §10 — Scheduled Jobs and Alerts
[Cron jobs, alert triggers, push notifications. notifications-cron skill references this.]
If not applicable: "No scheduled jobs planned."

## §11 — Data Model
[Tables, key fields, relationships. Keep in sync with migrations.]

## §12 — Infrastructure
[Summary of services. Full details in INFRA.md.]

## §13 — UX Requirements
[Screen-by-screen UX spec. Frontend implementers and the mobile-ux-patterns skill reference this.]

### §13.1 — List-first pattern
[Confirm all list screens follow: scrollable list → + button top-right → empty state → modal form]

### §13.5 — Section title standard
[Confirm font size, weight, color for section titles across all screens]

### §13.6 — No duplicate title
[Confirm the tab header is the only place a screen title appears]

### [ScreenName]
[UX description: what the user sees, what they can do, role-based visibility]
```

---

### 2c. Fill `me.md` (optional)

```
Name:         [your name]
Team:         [backend | frontend | fullstack | devops]
Focus:        [project name]
Architecture: [e.g. NestJS + Fastify · Expo SDK + expo-router · Supabase · Turborepo pnpm]
Branch:       [current branch]
Task:         [what you are working on]
```

`Architecture` helps agents avoid mixing up stack-specific patterns when multiple projects
are open simultaneously. One line is enough — list runtime, frontend framework, database and
monorepo tool.

**Checkpoint 2:** `general-context.md` and `PROJECT.md` (all §1–§13) are filled (plus `me.md`, if used).
Have a colleague, `dev-core:tech-lead` or `dev-core:architect` review `PROJECT.md` for missing sections before proceeding.

---

## Phase 3 — Scaffold the monorepo

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
│   └── mobile/       ← Expo SDK + expo-router
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
├── .claude/          ← project-local layer (constitution, context, deltas, agents, agent-context)
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
    "dev":   { "cache": false, "persistent": true }
  }
}
```

**`packages/shared-types/package.json`**
```json
{
  "name": "@your-app/shared-types",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "scripts": { "build": "tsc" }
}
```

Replace `@app` with your actual package scope (e.g. `@acme`, `@myproject`).

**Required dev dependencies — add to `apps/api/package.json`**

```json
{
  "devDependencies": {
    "@golevelup/ts-jest": "^0.5.0",
    "@stryker-mutator/core": "^8.0.0",
    "@stryker-mutator/jest-runner": "^8.0.0"
  }
}
```

`@golevelup/ts-jest` provides `createMock<T>()` used in every Use Case unit test (see `dev-patterns:test-patterns`).
`@stryker-mutator/*` is required for mutation testing before merging domain code (see `dev-patterns:test-patterns` → `stryker-mutation.md`).

**Seed the `test/fakes/` directory immediately** — these fakes are shared across all modules and must exist before writing the first test:

```
apps/api/test/fakes/
  strict-event-bus.ts       ← propagates subscriber errors (integration tests)
  capturing-event-bus.ts    ← records events without running subscribers
  in-memory-unit-of-work.ts ← runs the callback directly; no transaction
```

Copy the canonical implementations from `dev-core:test-patterns` — `contract-event-tests.md`
("Event Bus test fakes") and `mock-patterns.md` ("IUnitOfWork test pattern").

**Complete scope update checklist — every occurrence must match or the build breaks silently:**

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
the `dev-patterns` skills and agents use `@app/` as an illustrative placeholder in code
snippets. Agents read `.claude/general-context.md` as the authority for imports and will use
whatever scope is declared there. No delta skill is needed just for the package scope.

**Checkpoint 3:** `pnpm install` runs without errors. `pnpm build` completes on all packages.

---

## Phase 4 — Provision infrastructure

Follow this order — services have dependencies between them.

### Step 1 — Supabase (database + auth)
1. Create project at supabase.com
2. Note: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`
3. Install Supabase CLI: `pnpm add -g supabase`
4. Link project: `supabase link --project-ref <ref>`
5. Run skill `supabase-setup` for RLS and Auth configuration

### Step 2 — Railway (API hosting)
1. Create project and service at railway.app
2. Connect to the GitHub repository
3. Set root directory to `apps/api`
4. Configure environment variables (from `.bootstrap-secrets`)
5. Run skill `railway-nestjs` for Dockerfile and health check

### Step 3 — GitHub repository + Actions
1. Create repository (private)
2. Push initial commit
3. Add repository secrets (from `.bootstrap-secrets`)
4. Run skill `github-actions-monorepo` for CI/CD pipelines

### Step 4 — Cloudflare (DNS + SSL)
1. Add domain to Cloudflare
2. Point DNS to Railway
3. Run skill `cloudflare-setup` for SSL, security headers, rate limiting

### Step 5 — Expo EAS (mobile builds)
1. `npx eas-cli login`
2. `npx eas-cli build:configure` inside `apps/mobile`
3. Run skill `expo-eas` for build profiles and OTA config

### Optional services (add when needed)
| Service | Skill | When |
|---|---|---|
| Upstash Redis | `cache` or `jobs-queues` | When adding caching or async jobs |
| Resend | `resend-email` | When sending transactional email |
| Sentry | `dev-core:logging-observability` + `dev-patterns:logging-observability` | Before first staging deploy |

**Checkpoint 4:** API responds at `/health`. Supabase migrations run without error. Mobile app builds locally with `npx expo start`.

---

## Phase 5 — Validate setup

Run through every item. Setup is complete only when all pass.

### Framework readiness
- [ ] `PROJECT.md` has all sections §1–§13 filled (no empty sections)
- [ ] `general-context.md` "About this project" describes this project (not a placeholder)
- [ ] `me.md`, if used, has real values (not brackets)
- [ ] Package scope (`@app/`) is consistent across all 4 files that reference it

### Code
- [ ] `pnpm build` — zero TypeScript errors across all workspaces
- [ ] `pnpm test` — zero failures (even if there are only 2-3 bootstrap tests)
- [ ] First migration runs with `supabase db push` without error

### Test infrastructure
- [ ] `apps/api/test/fakes/strict-event-bus.ts` exists and implements `IEventBus`
- [ ] `apps/api/test/fakes/capturing-event-bus.ts` exists and implements `IEventBus`
- [ ] `apps/api/test/fakes/in-memory-unit-of-work.ts` exists and implements `IUnitOfWork`
- [ ] `@golevelup/ts-jest` is in `devDependencies` — `import { createMock } from '@golevelup/ts-jest'` resolves
- [ ] `apps/api/test/helpers/assert-snake-case.ts` exists (copy from `dev-patterns:test-patterns` → `contract-tests-http.md`)

### Infrastructure
- [ ] API responds at `https://[domain]/health` (or Railway URL if domain not configured yet)
- [ ] Supabase Auth creates a test user successfully
- [ ] Mobile app renders the first screen on a simulator

### Agent readiness
- [ ] `dev-core` and `dev-patterns` plugins installed; a plugin skill (e.g. `dev-patterns:clean-architecture`) loads
- [ ] Ask `dev-core:architect` to plan the first module — it must read `PROJECT.md` without errors
- [ ] Create the first migration (`dev-core:dba` agent, with the `migrations` skill) — it must reference `PROJECT.md §7` enums correctly
- [ ] `dev-core:appsec` can read the project files (and `.claude/agent-context/appsec.md`, if created) without reporting "file not found"

**Setup is complete when all items above are checked.**
