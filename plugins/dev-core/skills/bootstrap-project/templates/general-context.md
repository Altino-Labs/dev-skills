# general-context.md
> Shared technical context across all <project> agents.
> Every agent reads this file after `constitution.md` and before any task.

---

## About <project>

<3–5 lines: what the system does, who uses it, the ownership / multi-tenancy model
(e.g. "multi-tenant by organization: each organization is an isolated context; a user can
belong to several").>

Stack: <language + version>, <web framework>, <data access / ORM>, <database>, <auth provider>,
<frontend: none | web framework | mobile framework>, <hosting>.
(Exact versions: each app's manifest — don't trust this line over them.)
Repository layout: <single app | monorepo with <tool>> · apps: `<app-1>`, `<app-2>` · packages: `<pkg>`.

---

## Repository structure

```
<top-level folders, one line each with what lives there>
```

---

## Shared code — how to import

```
<how apps import shared types/utilities, e.g. the package name or module path>
```

Shared types, enums and DTOs are never redefined in an app — always imported from
`<shared package>`.

---

## Identity model

```
<who logs in> ≠ <who/what the data is about, if different>

<role/type dimension 1>: <VALUE_A> | <VALUE_B>     ← who the person is
<role/type dimension 2>: <VALUE_C> | <VALUE_D>     ← what they can do in a context
```

Permissions come from <how roles combine>. See `PROJECT.md` (user model and permission matrix).

---

## Authentication

<one paragraph: auth provider, how a request is authenticated on the server, anything that
must never be done (e.g. "never verify tokens with a shared secret — the provider signs with
asymmetric keys").>

---

## API conventions

- Wire casing: **<snake_case | camelCase>** in every field, identical to the shared types
- Success envelope: <wrapped in `{ data }` | not wrapped>; error format: <project envelope | RFC 9457>
- Lists are paginated (`dev-core:api-contracts`)
- Instants are UTC on the wire; the client sends its time zone on every request
  (`dev-core:date-time`)

---

## Domain vocabulary

| Term | Meaning |
|---|---|
| <Term> | <meaning in this project> |

---

## Canonical enums

Exact values live in `PROJECT.md` (enum table). **Never invent values** — a divergence between
the database, the code and the seed is a runtime error.

---

## Development cycle

<anything an agent must know to see its change take effect, e.g. "the API runs from compiled
output: rebuild and restart after editing source", "restart the dev server with a clean cache
before a manual check".>

---

## Commit conventions

Conventional Commits (`dev-core:git`): `feat`, `fix`, `refactor`, `test`, `chore`, `docs`,
`perf`. Never `wip`, `temp`, `fix stuff`, `updates`.

---

## Communication style

- **Concise** — no preamble, no unnecessary confirmations for explicit tasks
- **Direct code** — show the code; don't explain it line by line
- **Bullets over paragraphs**
- **Technical audience** — don't explain basic concepts
- **Language**: <language for conversation> · code, commits and PRs in <language>
- **Errors**: stop → report full context → wait for guidance
