# Changelog

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
