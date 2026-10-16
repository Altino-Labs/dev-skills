# Changelog

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
