# Changelog

## v1.1.0

Lessons from a production project's last rounds, promoted so a new project — on any stack —
starts with them: a stack-agnostic bootstrap with templates, the audit protocol, privacy
compliance (GDPR/LGPD), the time-zone model, and fixes where the plugins had drifted from
practice.

### `dev-core`

- **New `bootstrap-project`** — stack-agnostic project bootstrap: index the spec into
  `docs/SPEC-INDEX.md` (parallel agents for large material, contradictions listed, not guessed),
  record the stack as ADR-001, install plugins, write durable context (`AGENTS.md`, `CLAUDE.md`,
  `PROJECT.md`, `SESSION.md`/`ROADMAP.md`), CI baseline covering every app, then infrastructure one
  confirmed step at a time (backups with a real restore test, secrets-rotation cadence, error
  tracking with privacy defaults, production deferred behind approval). Ships templates for
  `AGENTS.md`, `CLAUDE.md`, `constitution.md` (with working agreements), `general-context.md` and
  `SESSION.md`.
- **New `audit`** — full-repository audit protocol: dimensions in parallel, one globally numbered
  findings list persisted and committed before any fix, one issue per finding, PRs batched by
  dimension, deferrals recorded. Never "fix" a finding by shrinking the docs to fit.
- **New `privacy-compliance`** — GDPR and LGPD side by side (legal bases incl. health data, rights,
  DPO, breach notice, transfers), a per-new-field checklist, a go-live checklist and the versioned
  Terms/Privacy acceptance pattern. Engineering guidance, not legal advice.
- **New `date-time`** — instants in UTC, the subject's zone apart from the viewer's, IANA names
  only, the client's zone on every request, scheduled jobs on the stored zone, local-noon
  backfills, date tests pinned west of UTC.
- **`git`** — `Closes` once per issue; GitHub ignores negation next to an issue number;
  `git status --short` right before each commit; check whether the PR merged before *every*
  commit (was: before pushing); batching rules.
- **`domain-events`** — time- and level-triggered notifications are scheduled scans of current
  state, not event subscribers.
- **`resilience-patterns`** — scheduled jobs on scale-to-zero hosts: an external OIDC-authenticated
  tick, a schedule registry, leased run log, alerts on job failure and on a missing tick, one mode
  switch so both never fire. The `devops` agent points to it.
- **`auth-security`** — Origin/Referer verification as an accepted CSRF defence; host-only cookies;
  a backend-for-frontend for admin web apps.
- **`appsec` agent** — immutable audit trail for sensitive actions; loads `privacy-compliance`.
- **`migrations`** — a CI guard that fails destructive/contract statements without a
  `-- contract-ok: <reason>` marker.
- **`test-patterns`** — security boundaries: mocks must still assert tenant/user filters; database
  privilege tests on a real database in CI.

### `dev-patterns`

- **`bootstrap-project`** — now the TypeScript-stack phase called from `dev-core:bootstrap-project`.
  No default host (chosen in the stack ADR; Railway no longer suggested), Stryker report-only first,
  no stale version pins, no copied `.claude/agents/`, UX section optional, `project/*.md` split allowed.
- **`notifications-cron`** — rewritten around scheduled scans for reminders and level alerts
  (mark-sent-after-success, per-episode keys); push receipts kept.
- **`jobs-queues`** — `@nestjs/schedule` with in-process cron switched off when the external tick
  is on; OIDC guard; shared lease helper.
- **`nestjs-fastify`** — the zone comes in an `X-Timezone` header with an IANA name (offsets and
  unknown zones → 400), not `?tz=`; subject routes use the stored zone. `utcRangeForLocalDate`
  fixed for 23/25-hour DST days.
- **`feature-slice`** — subject vs viewer zone; `X-Timezone` in the shared HTTP client; a
  development build instead of Expo Go once there are native modules; restart Metro with `--clear`
  when it misses edits.
- **`auth-security`** — Next.js BFF for an admin app; Origin guard and host-only cookies.
- **`cloudflare-setup`** — Bot Fight Mode blocks datacenter traffic (CI, serverless) with no
  per-path exception on Free: health checks and server-to-server calls go to the origin, protected
  by an origin-auth header. `github-actions-monorepo` notes it on health checks.
- **`domain-events/outbox-supabase`** — broken link fixed.

## v1.0.3

### `dev-patterns`

- **`github-actions-monorepo`** — "Type check" gains a warning on framework-generated types:
  Next.js writes `.next/types` (globals like `RouteContext`, `PageProps`) and Expo Router
  `.expo/types` only when their dev server or build runs, so a local `tsc --noEmit` can pass
  while CI's fresh checkout fails. Type the context explicitly or generate the types in the
  script, and type-check without the generated folder before pushing. From a real PR whose
  proxy route used `RouteContext`: green locally, `Cannot find name 'RouteContext'` in CI.

## v1.0.2

Lessons from two more rounds of a real project: an aggregator-module exception to the
cross-module read rule, and error tracking in client apps (web and mobile).

### `dev-core`

- **`domain-events`** — "Core principle" gains an **aggregator modules** exception for modular
  monoliths: explicitly named modules whose job is to combine others (to-do, reports, schedulers,
  notification sweeps, admin) may read other modules through their repository interfaces. Every
  other module stays strict, enforced by an import-boundary lint rule with per-file, reasoned
  exceptions. Found by an audit where ~40 cross-module reads were almost all such aggregators,
  and per-module query facades would have been ceremony.
- **`clean-architecture/domain-services`** — the module boundary rule points to that exception.
- **`logging-observability`** — new "Error tracking in client apps": prove the tracker's config
  reached the shipped artifact (not only the tests), type the SDK options with the SDK's own
  type, re-read privacy defaults on every SDK major, and watch the tracker's quota. From a real
  rollout where Sentry shipped switched off, then collecting IPs, then blind on a spent quota.

### `dev-patterns`

- **`logging-observability`** — new "Sentry in the clients — Next.js and Expo": public env vars
  are inlined only when spelled out literally; `@sentry/nextjs` 11 replaced `sendDefaultPii` with
  `dataCollection` (restrictive baseline included); wiring without the wizard; the Expo config
  plugin is only for source maps; reading a `429 error_usage_exceeded`.
- **`expo-eas`** — the env-var gotcha points to the literal-spelling rule.

## v1.0.1

Corrections from a full audit of a real project using both plugins. No new skills.

### `dev-core`

- **`api-contracts`** — decoded cursor fields are validated (UUID id; timestamp or safe-text
  sort value) before any filter is built; never interpolate unvalidated values into a filter
  string. Bounded, unpaginated lists (the "active" slice) return `{ items: [...] }`, never a bare
  array (bare arrays tolerated only in non-wrapping projects that already use them).
- **`error-handling`** — envelope table gains the bounded-list row, consistent with the above.
- **`auth-security`** — refresh-token entropy example is 32 random bytes (a UUID v4 has 122
  random bits); guidance for refresh tokens owned by an external auth provider.
- **`clean-architecture`** — states that a transport status code lives only in a stack's
  mirror exception classes, read only by the edge.
- **`domain-events`** — limits for orchestrator / composition modules (published use cases and
  query APIs only, never repositories).
- **`migrations`** — `-- down: NOT REVERSIBLE (data loss)` convention.
- **`resilience-patterns`** — retry only idempotent operations or with an idempotency key,
  `isRetryable` option on `withRetry`, request-path retry budget; database and email rows of
  the policy table updated.
- **`secrets-rotation`** — `PORT` in the `.env.example`; rotation buckets for Vercel, Expo,
  Supabase and Resend credentials; opaque-token generation uses 32 random bytes.

### `dev-patterns`

- **`railway-nestjs`** — listen on `PORT`; Dockerfile on Node 24 with pnpm via corepack and
  `pnpm deploy --prod`, `USER node`, `HEALTHCHECK`; readiness returns 503 when a critical
  dependency fails; health paths include the global prefix; GitHub App auto-deploy and
  config-as-code; outdated pricing replaced by a pointer to the current plans.
- **`github-actions-monorepo`** — actions pinned by commit SHA, `permissions: contents: read`,
  `concurrency`, `timeout-minutes`, Node 24 + pnpm, deploy order with `needs:` (migrate → API →
  health check → frontends/OTA), pinned global CLIs, health check with retry, Dependabot for
  actions; notes on alternative branch flows, `railway up` vs the Railway GitHub App, and
  environment reviewers depending on the plan.
- **`supabase-setup`** — Supabase guard example honours `@Public()` and checks the `Bearer `
  scheme; which connection (transaction pooler, direct/session) for runtime vs migrations;
  backups section no longer states plan specifics, adds a restore drill; default-privilege
  revoke for functions plus a CI privilege check; one encryption key per data domain;
  multi-tenant RLS is read-only for members when the API is the only writer.
- **`migrations`** — base member policies are `FOR SELECT` with writes revoked from
  `authenticated` (write policies only mirroring the role matrix) and a CI check of table
  privileges; UNIQUE on `timestamptz` is valid (only `::date` expressions are not); the
  recursion rule is scoped to policies on the membership table, with role predicates in
  `SECURITY DEFINER` helpers.
- **`api-contracts`** — validating `decodeCursor`; warning against interpolating into `.or()`;
  the active slice returns `{ items }`.
- **`auth-security`** — refresh-token generation (32 random bytes); `@supabase/ssr`
  `createBrowserClient` cookie caveat and the server-side (BFF) alternative.
- **`nestjs-fastify`** — use-case examples throw the plugin's domain / persistence exceptions;
  corrected `@IsEnum` vs `@IsIn` explanation.
- **`feature-slice`** — HTTP client reads the error envelope (`error.code` / `error.message`)
  and keeps `code` on the thrown error; non-zero `staleTime` default with the cost of `0`.
- **`expo-eas`** — `eas env:*` instead of `eas secret:*`; pinned `eas-cli` (setup and CI);
  `cli.version` floor guidance; fingerprint pitfall for lockfile rewrites.
- **`test-patterns`** — runner table keyed by module system + runner, with the
  NestJS 12 + CommonJS + Jest 30 row.
- **`clean-architecture`** — mirror exception classes carry `statusCode` for the filter only.

## v1.0.0

First public release of the marketplace, with two plugins.

### `dev-core` — any stack

- **Skills (12):** `api-contracts`, `auth-security`, `clean-architecture`, `domain-events`,
  `error-handling`, `git`, `logging-observability`, `migrations`, `pre-merge`,
  `resilience-patterns`, `secrets-rotation`, `test-patterns`. Examples are framework-free
  TypeScript read as pseudo-code, with portability notes for Python, Java/Kotlin, C#/.NET and Go.
- **Agents (8):** `appsec`, `architect`, `backend-developer`, `dba`, `devops`,
  `frontend-developer`, `qa`, `tech-lead`. Stack-neutral; each loads its core skills first and
  learns the project's stack from its context files.
- **Safety hooks (2):** ask before destructive commands (recursive deletes outside the project,
  destructive SQL, framework database resets, production deploys and destroys across common
  clouds and platforms, force pushes to `main`) and before writing content that looks like a
  secret (assignments in common config formats, credential URLs, well-known token formats).
  Covered by a 165-case test suite (`plugins/dev-core/hooks/tests/run-tests.sh`) that runs on
  macOS and Linux.

### `dev-patterns` — TypeScript full-stack

- **Skills (24)** for NestJS/Fastify, Supabase/Postgres, Expo/React Native, a pnpm monorepo and
  deploys on Railway/Cloudflare/EAS/GitHub Actions — including the NestJS/Supabase/Expo
  implementation layers of eight `dev-core` skills.
- **Hook (1):** ESLint on written TypeScript files, when the project has a config.
