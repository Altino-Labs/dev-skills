# dev-skills

A Claude Code marketplace with two plugins: skills, agents and safety hooks that are not tied to
any single project, versioned in git and installable in any repository.

| Plugin | For | Contains |
|---|---|---|
| **`dev-core`** | **any project** — any language, framework or cloud | stack-agnostic skills, the 8 role agents, the safety hooks |
| **`dev-patterns`** | TypeScript full-stack projects on this stack: NestJS/Fastify, Supabase/Postgres, Expo/React Native, pnpm monorepo, Railway/Cloudflare/EAS/GitHub Actions | the stack skills and the TypeScript lint hook |

Who installs which:

- **Any project:** `dev-core`.
- **TypeScript full-stack on the stack above:** `dev-core` + `dev-patterns`.
- **Another stack:** `dev-core`, plus your own stack plugin if you write one (see
  [Creating a stack plugin for another stack](#creating-a-stack-plugin-for-another-stack)).

## Getting started with `dev-core` (any stack)

1. Get read access to this repository (see [Access](#access)) and install `jq` (see
   [Requirements](#requirements)).
2. In a Claude Code session inside your project:
   ```
   /plugin marketplace add Altino-Labs/dev-skills
   /plugin install dev-core@dev-skills
   ```
   Restart the session so the skills, agents and hooks load.
3. Tell Claude about your project in its `CLAUDE.md` (or `AGENTS.md`): the stack (language,
   framework, database, hosting), the folder layout, how to run tests and lint, and your team's
   rules (for example when Claude may push or open PRs). The agents and skills read it before
   giving stack-specific advice.
4. Optional, as the project grows:
   - `.claude/agent-context/<agent>.md` — extra rules for one agent (e.g. `appsec.md`, `qa.md`).
   - `.claude/skills/<project>-<skill>/SKILL.md` — a *delta skill* with what is specific to your
     project for a given skill (real paths, tables, conventions). It is loaded together with
     `dev-core:<skill>` and wins on conflict. See [Per-project convention](#per-project-convention).
5. Use it: the skills trigger on their own when the work matches (e.g. creating an entity loads
   `dev-core:clean-architecture`, writing a test loads `dev-core:test-patterns`). You can also
   ask for an agent by name — e.g. "use the `dev-core:architect` agent to plan the orders
   module" — or run the review gate before merging ("run `dev-core:pre-merge`").

`dev-patterns:bootstrap-project` is a fuller setup guide, but it assumes the TypeScript stack of
`dev-patterns`. For any other stack, start from the templates below.

### Templates (any stack)

A minimal `CLAUDE.md`:

```markdown
# <Project name>

Stack: <language + version>, <web framework>, <ORM / data access>, <database>, <test runner>,
<hosting / deploy platform>. Frontend: <none | web framework | mobile framework>.
Layout: <how modules are organised, e.g. app/<module>/{domain,application,infrastructure,api}>.
Commands: test `<cmd>`, lint `<cmd>`, type-check `<cmd>`, run locally `<cmd>`.
API conventions: casing <snake_case | camelCase>, success envelope <wrapped in { data } | not
wrapped>, error format <project envelope | RFC 9457 Problem Details>.
Team policy: <when Claude may commit / push / open PRs>, <anything that needs human approval>.
```

A delta skill, `.claude/skills/<project>-<skill>/SKILL.md`:

```markdown
---
name: <project>-<skill>
description: <Project>-specific complement to dev-core:<skill> — <what it adds>. Invoke together
  with dev-core:<skill> whenever <same trigger as the base skill>.
---

# <Skill> — <Project> specifics

> Base pattern: `dev-core:<skill>` (load it first). This file only adds what is specific to
> <Project>; on conflict, this file wins.

- Real paths, class names, tables, ADRs and defaults for this project.
- Decisions that differ from the base skill, each with its reason.
```

### Portability notes

The `dev-core` examples are TypeScript read as pseudo-code. Common translations:

| Concept in the skills | Python | Java / Kotlin | C# / .NET | Go |
|---|---|---|---|---|
| Domain exceptions with a stable `code` | exception classes | exception classes | exception classes | typed error values + `errors.As` |
| Exact money | `Decimal` | `BigDecimal` | `decimal` | a decimal library (e.g. shopspring/decimal) |
| Optimistic lock | SQLAlchemy `version_id_col` | JPA `@Version` | EF Core concurrency token / `RowVersion` | `WHERE version = ?` by hand |
| Eager loading (avoid N+1) | `selectinload` / `select_related` | `JOIN FETCH` / `@EntityGraph` | `Include` | explicit JOIN |
| Composable query specs | SQLAlchemy expressions | Spring Data `Specification<T>` | `Expression<Func<T,bool>>` | query builder |
| Correlation / trace context | OpenTelemetry + `contextvars` | OpenTelemetry + MDC | OpenTelemetry + `ILogger` scopes | OpenTelemetry + `context.Context` |
| Wire casing in one place | Pydantic `alias_generator` | Jackson `SNAKE_CASE` | `JsonNamingPolicy.SnakeCaseLower` | struct tags |
| Isolate failures per task | `asyncio.gather(..., return_exceptions=True)` | `CompletableFuture` + `handle` | `Task.WhenAll` + per-task try/catch | goroutines + per-task error collection (not `errgroup`) |
| Event-name constants | `StrEnum` | `enum` | `enum` / `const` | `const` |
| Migrations | Alembic / Django | Flyway / Liquibase | EF Core migrations | golang-migrate / goose |

## What's included (v1.0.1)

### `dev-core` (`plugins/dev-core/`)

**Skills** (12): `api-contracts`, `auth-security`, `clean-architecture`, `domain-events`,
`error-handling`, `git`, `logging-observability`, `migrations`, `pre-merge`,
`resilience-patterns`, `secrets-rotation`, `test-patterns` — referenced as `dev-core:<skill>`.

**Agents** (8): `appsec`, `architect`, `backend-developer`, `dba`, `devops`,
`frontend-developer`, `qa`, `tech-lead` — referenced as `dev-core:<agent>`. They are
stack-neutral: each one reads the project's context files (`AGENTS.md`/`CLAUDE.md`,
`.claude/constitution.md`, `.claude/general-context.md`, `.claude/agent-context/<agent>.md` —
all optional), learns the project's stack from them, and loads the matching stack skill (e.g.
`dev-patterns:<skill>`) and the project's delta skill when they exist.

**Hooks** (2, PreToolUse) — see [Hooks](#hooks).

> Code examples in `dev-core` are framework-free TypeScript, meant to be read as pseudo-code and
> translated to your language (see [Portability notes](#portability-notes)). TypeScript-only
> mechanics are labelled as such, and the agents name `dev-patterns` skills as the example for
> TypeScript projects. The rules themselves apply to any stack.

### `dev-patterns` (`plugins/dev-patterns/`)

**Skills** (24): `api-contracts`, `auth-security`, `bootstrap-project`, `cache`,
`clean-architecture`, `cloudflare-setup`, `domain-events`, `error-handling`, `expo-eas`,
`expo-router`, `feature-slice`, `github-actions-monorepo`, `jobs-queues`,
`logging-observability`, `migrations`, `mobile-ux-patterns`, `nestjs-fastify`,
`notifications-cron`, `railway-nestjs`, `react-native-web`, `resend-email`, `shared-kernel`,
`supabase-setup`, `test-patterns` — referenced as `dev-patterns:<skill>`.
`clean-architecture`, `test-patterns`, `error-handling`, `domain-events`,
`logging-observability`, `api-contracts`, `auth-security` and `migrations` here are the implementation layers
of `dev-core:clean-architecture` (NestJS + Supabase), `dev-core:test-patterns` (Jest/Vitest +
NestJS + Supabase), `dev-core:error-handling` (NestJS/Fastify), `dev-core:domain-events`
(NestJS + Supabase), `dev-core:logging-observability` (NestJS/Fastify + Sentry),
`dev-core:api-contracts` (NestJS/Fastify + Supabase), `dev-core:auth-security` (NestJS +
Supabase + Expo) and `dev-core:migrations` (Supabase/PostgreSQL) — each tells Claude to load the
core skill first.

`nestjs-fastify`, `test-patterns` and `shared-kernel` cover **two lines**: NestJS 11 +
CommonJS + Jest and NestJS 12 + ESM + Vitest — each section says which one it applies to.
Projects don't migrate because of the plugin; they migrate when they decide to.

**Hooks** (1, PostToolUse) — see [Hooks](#hooks).

## Requirements

- `bash` and `git`
- `jq` — required by all hooks (they read the hook event as JSON from standard input). Without
  it, the two `dev-core` safety hooks ask for confirmation on every call and the `dev-patterns`
  lint hook is skipped with a warning. Install with `brew install jq` or `apt install jq`.
- ESLint — only for the `dev-patterns` lint hook, and only in TypeScript projects that have an
  ESLint config and ESLint installed locally.

## Access

The repository is private. To install the plugins you need:

- read access to `Altino-Labs/dev-skills` (be added as a collaborator
  or organization member), and
- git authenticated for private GitHub repositories on your machine (e.g. via
  `gh auth login` or an SSH key).

## Install in a project

Inside a Claude Code session, in the project where you want to use it:

```
/plugin marketplace add Altino-Labs/dev-skills
/plugin install dev-core@dev-skills
```

For a TypeScript full-stack project on the `dev-patterns` stack, also:

```
/plugin install dev-patterns@dev-skills
```

## Update

To update after this repository receives new commits (from any folder):

```
claude plugin marketplace update dev-skills
claude plugin update dev-core
claude plugin update dev-patterns     # if installed
```

That only updates the **user**-scope install. A project that has a plugin
installed at **project** scope stays on the old version until you run, from
inside that project's folder:

```
claude plugin update dev-core --scope project
claude plugin update dev-patterns --scope project     # if installed
```

To see which installs exist and which version each one is on, look at the
`dev-core@dev-skills` / `dev-patterns@dev-skills` entries in
`~/.claude/plugins/installed_plugins.json` (`scope`, `projectPath`, `version`).
Only delete an old version from `~/.claude/plugins/cache/dev-skills/<plugin>/`
once no entry points to it anymore. Open sessions only pick up the new version
after a restart.

After `claude plugin install` / `update` / `uninstall` with `--scope project`, check the diff of
the project's `.claude/settings.json` before committing it: the CLI rewrites that file and can
update only the entry it touched — leaving other plugins or the marketplace declaration on an
old name or address — and reorder its keys. Fix any stale `enabledPlugins` /
`extraKnownMarketplaces` entries by hand.

## Hooks

Active in every project with the plugin enabled. The scripts read the event as JSON from
standard input.

**`dev-core`**

| Hook | When | What it does |
|---|---|---|
| `check-destructive-command.sh` | before `Bash` | asks for confirmation on: recursive `rm` with any target outside the project or on the project root (all flag forms, every target, `~`/relative/`..` paths resolved, no sibling-prefix match); destructive SQL sent to a DB client (`DROP TABLE/DATABASE/SCHEMA`, `TRUNCATE`, `DELETE FROM` without `WHERE`); framework DB resets (Django `flush`, Alembic `downgrade`, Rails `db:drop/reset`, Laravel `migrate:fresh`, Flyway/Liquibase clean, EF `database drop`, Prisma `migrate reset`, `dropdb`, Redis `FLUSHALL`, Mongo `dropDatabase`, `supabase db reset --linked`); production deploys (Railway/EAS/Vercel/Fly/Firebase/Pulumi/gcloud/az/aws/SAM/CDK/Serverless with a `prod` target, `cdk deploy --all`, `git push` to `heroku`/`prod*` remotes, Kubernetes mutations on a prod context/namespace); deploys whose target cannot be read (`fly deploy` without `--app`, `kubectl` mutations without `--context`, `firebase deploy` without `--project`); always-destructive infra commands (`terraform destroy`/`apply -auto-approve`, `helm uninstall`, `pulumi destroy`, `cdk destroy`, `gcloud … delete`, `aws … delete-*`/`terminate-instances`/`s3 rm --recursive`, `az … delete`, Docker volume prunes); force-push to `main`/`master` and `git reset --hard` to a remote branch |
| `check-secret-exposure.sh` | before `Write`/`Edit` | asks for confirmation if the content looks like a secret: well-known token formats (Stripe, AWS, GitHub, Slack, Google, OpenAI, Anthropic, SendGrid, Twilio), JWTs and private keys — in every file, markdown included; a literal assigned with `=`, `:=` or `:` to a secret-looking name (`password`, `secret`, `token`, `api_key`, `access_key`, `private_key`, `*_KEY`, e.g. `SECRET_KEY`, `spring.datasource.password`) — quoted anywhere, unquoted in config files (`.env`, YAML, `.properties`, shell…); .NET `Password=…;` connection strings; URLs with credentials (`scheme://user:pass@`). Env references (`${…}`, `process.env`, `os.environ`) and obvious placeholders are ignored; `.env.example`/`.sample`/`.template` only get the token-format check |

**`dev-patterns`**

| Hook | When | What it does |
|---|---|---|
| `run-linter.sh` | after `Write`/`Edit` on `.ts`/`.tsx` | runs ESLint on the file, if the project has a config; returns the errors to Claude |

Tests: `bash plugins/dev-core/hooks/tests/run-tests.sh` feeds JSON events to both scripts and asserts
ask/allow for 165 cases (bash 3.2+ and `jq`; passes on macOS/BSD and Linux/GNU).

Known limitations — these hooks are a safety net against accidents, not a sandbox:

- They are regex-based and can be bypassed deliberately (variables, aliases, scripts, `cd` into a
  directory in a previous command, encoded or split secrets).
- Quoted text containing spaces is treated as prose and ignored by the command patterns (so a
  commit message mentioning `kubectl delete -n production` does not ask). Commands passed as a
  string to `bash -c`/`sh -c`/`eval`/`ssh`/`watch`, and `"$(…)"` substitutions, are still checked;
  unquoted heredoc bodies are checked as if they were commands (false positives, safe direction).
- SQL is only checked when a known DB client (`psql`, `mysql`, `sqlite3`, `sqlcmd`…) is in the
  command; SQL run from files (`psql -f`) or from application code is not seen.
- A "production signal" is any value containing `prod` — `my-products` also matches.
- Unquoted secret values in source code are not flagged (they are usually expressions); a
  quoted, long, non-placeholder value assigned to a secret-looking name may be a false positive
  (e.g. a translation string without spaces).

Plugin hooks and project hooks **both** run (there is no deduplication): a project should not
repeat these in its own `.claude/settings.json` — only hooks specific to it.

## Per-project convention

Each project keeps its own local `.claude/` for anything specific to its domain — these plugins
are only the common base.

- **Skill complement (delta skill):** `.claude/skills/<project>-<skill>/SKILL.md`
  (e.g. `<project>-migrations`, `<project>-git`) with only what is specific to the project —
  real paths, tables, ADRs, defaults, policies (such as when to push or open PRs). Loaded
  together with the plugin skill (`dev-core:<skill>` or `dev-patterns:<skill>`); on conflict,
  the complement wins. See [Templates](#templates-any-stack) for a minimal one.
- **Agent context:** `.claude/agent-context/<agent>.md` with the project rules (and stack
  details) the `dev-core` agents should read.
- Kept out of the plugins: audit/security skills tightly coupled to a project's domain (e.g. a
  project-specific audit checklist).

## Creating a stack plugin for another stack

Mirror the layout of `plugins/dev-patterns/`: a `.claude-plugin/plugin.json`, one
`skills/<skill>/SKILL.md` per topic (with a description that says when to invoke it), and
optionally `hooks/hooks.json` for stack tooling such as a linter. Either add it to
`.claude-plugin/marketplace.json` here, or keep it in its own repository/marketplace. Install it
next to `dev-core`; the agents pick up its skills through the project's context files.

## Roadmap

See [ROADMAP.md](ROADMAP.md) for planned work and [CHANGELOG.md](CHANGELOG.md) for releases.

## License

MIT — see [LICENSE](LICENSE).
