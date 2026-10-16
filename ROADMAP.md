# Roadmap

Planned work. Released changes are in [CHANGELOG.md](CHANGELOG.md).

## Stack-plugin cleanup (`dev-patterns`)

- Link the remaining supporting files from their `SKILL.md` (`nestjs-fastify/routing-guards.md`,
  `migrations/advanced-migrations.md`, `jobs-queues/legacy-bull.md`,
  `shared-kernel/boundaries.md`, `shared-kernel/shared-types-lifecycle.md`).
- `jobs-queues` / `cache`: BullMQ needs a Redis TCP connection; don't pair it with Upstash's REST
  credentials.
- `railway-nestjs` and `github-actions-monorepo`: move examples from Node 20 + npm to the Node
  version and package manager the rest of the plugin uses (Node 24 + pnpm).
- `shamefully-hoist` guidance: make `feature-slice`, `expo-router` and `expo-web-setup` agree.
- Split `mobile-ux-patterns` (≈4.7k lines) into supporting files, and present its "absolute
  rules" as an overridable house style.

## Ideas

- More stack plugins next to `dev-patterns` (e.g. Python/FastAPI, Java/Spring), following
  "Creating a stack plugin for another stack" in the README.
