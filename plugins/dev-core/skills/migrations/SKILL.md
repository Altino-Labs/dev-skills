---
name: migrations
description: >
  Database schema migrations for any stack and any relational database: every change in a
  versioned migration, immutability once applied or shared, forward-only vs reversible,
  SQL-first vs model-first tools (Alembic autogenerate, Django makemigrations, EF Core
  migrations, Prisma — review and hand-edit what they generate), statement ordering,
  zero-downtime changes with expand/contract (adding NOT NULL in phases, renaming a column,
  batched backfills, concurrent index creation, never mixing schema and large data changes),
  data-access policies (row-level security or equivalent) reviewed with each table, double-
  submission UNIQUE constraints, and testing migrations. Invoke automatically when creating
  or altering any table, column, index, constraint or data-access policy, or reviewing a
  migration, in any language, framework or migration tool.
---

# Migrations

> **How to read the examples.** The SQL here is standard SQL unless labelled **(PostgreSQL)**
> — translate it to the project's database and migration tool. Engine- and platform-specific
> patterns (statement order with row-level security helpers, cross-table policies, extension
> schemas, seeding through an auth provider's admin API, the CLI's version table quirks) live
> in stack plugins — e.g. `dev-patterns:migrations` and `dev-patterns:supabase-setup` for
> Supabase/PostgreSQL — and in the project's own delta skill
> (`.claude/skills/<project>-migrations/`), when they exist. Load them together with this skill.

## Non-negotiable principles

1. **Every schema change lives in a versioned migration** in the repository — never alter a
   shared database by hand (console, ad-hoc SQL). A manual change is invisible to every other
   environment and to the next developer.
2. **Migrations are immutable once applied to a shared environment** (staging, production) or
   merged to a branch others pull. Fix a mistake with a **new** migration; editing an applied
   one makes environments silently diverge, and tools that checksum migrations (Flyway,
   Liquibase, Django, EF Core) refuse to run.
3. **Migrations run automatically on deploy** (CI/CD step or the app's startup migrator), in
   order, once — never "remember to run this by hand".
4. **One logical change per migration**, named after it, following the tool's naming
   convention (e.g. `<timestamp>_<snake_case_description>.sql`, `V12__add_order_status.sql`,
   `0012_add_order_status.py`).
5. **Data-access policies are part of the table.** When the project enforces access in the
   database (row-level security in PostgreSQL, SQL Server security policies) or in a policy
   layer, every new table ships with its policies in the same change and is reviewed with it —
   never "add RLS later" (`dev-core:auth-security`, `appsec` agent).

## Forward-only vs reversible

| | Reversible (`up` + `down`) | Forward-only |
|---|---|---|
| How | The tool runs the inverse (Alembic `downgrade`, Rails `down`, EF Core `Down()`, Flyway undo) | Only forward migrations; a bad change is fixed by a new forward migration |
| Good for | Local development, reverting an unreleased change | Production — a `down` that drops a column also drops the data written since |
| Rule | Write `down` when the tool expects it, and test it | Even then, **document** how to revert (as a comment) for each migration |

Pick one stance per project and record it. In production, prefer **roll forward**: a
down-migration is rarely exercised and often destroys data. Every migration still documents
its inverse — as code or as a comment — so a reviewer can see what undoing it would take.

When the inverse cannot run without losing data (a dropped column or table, a lossy type
change, a destructive backfill), say so explicitly at the top of the migration instead of
leaving the `down` blank:

```sql
-- down: NOT REVERSIBLE (data loss) — drops column orders.legacy_notes and its data.
--       To undo: restore the column from a backup taken before this migration.
```

## SQL-first vs model-first tools

- **SQL-first** (Flyway, Liquibase, golang-migrate, dbmate, Supabase CLI, plain `.sql`
  files): the migration file **is** the change. Write it by hand.
- **Model-first** (Alembic autogenerate, Django `makemigrations`, EF Core
  `dotnet ef migrations add`, Prisma `migrate dev`, Rails generators, TypeORM/Drizzle
  generate): **the change starts in the model classes**, and the tool generates the migration
  from the diff. Then:
  1. **Read and review the generated migration** — it is code that runs against production,
     not a build artifact. Commit it.
  2. **Hand-edit what autogeneration misses or gets wrong:** renames (detected as drop + add —
     data loss), partial / expression / concurrent indexes, check constraints, triggers,
     views, row-level security policies, enum value changes, and **data migrations**
     (backfills) — add them as explicit operations (`op.execute(...)`, `RunPython`/`RunSQL`,
     `migrationBuilder.Sql(...)`, a custom SQL step).
  3. Never edit the database or the generated file in a way the model doesn't reflect — the
     next autogenerate would "undo" it. Keep model and migrations in sync (the tool's check
     command, e.g. `makemigrations --check`, `alembic check`, in CI).

## Statement order inside a migration

Objects can only reference what already exists:

```
1. Tables (and their columns, keys, constraints)
2. Indexes
3. Functions / procedures that read those tables
4. Enable the data-access mechanism (e.g. row-level security)
5. Policies that call those functions
```

A policy or function that reads **another** table goes in a migration that runs **after**
that table exists — never in the referencing table's migration if the referenced one comes
later (some engines, e.g. PostgreSQL for SQL functions, validate references at creation
time). Stack specifics (security-definer helpers to avoid policy recursion, dedicated
cross-table-policy migrations): the stack plugin.

---

## Zero-downtime changes — expand / contract

While a deploy rolls out, **old and new application code run against the same schema**. A
migration must therefore be compatible with the code version before it and the one after.
Any breaking change is split into phases, each deployed separately:

```
Phase 1 — Expand:   add the new structure; old code ignores it, new code may write both
Phase 2 — Migrate:  backfill existing rows; switch reads/writes to the new structure
Phase 3 — Contract: once no deployed code uses the old structure, remove it
```

### Adding a NOT NULL column to a table with data

Never add `NOT NULL` without a default to a populated table in one step — it fails (or locks
and rewrites the table) on existing rows.

```
Migration 1: add the column as nullable (or with a constant default the engine applies cheaply)
Migration 2: backfill existing rows (in batches — see below); new code writes the column
Migration 3: add the NOT NULL constraint
```

On large tables, validate the constraint without a long exclusive lock where the engine
supports it — **(PostgreSQL)** `ADD CONSTRAINT ... CHECK (col IS NOT NULL) NOT VALID`, then
`VALIDATE CONSTRAINT`, then `SET NOT NULL`.

### Renaming a column (or a table)

A plain `RENAME` breaks every running instance of the old code instantly. Use expand/contract:

```
1. Expand:   add the new column; write to both old and new (application dual-write or a trigger)
2. Backfill: copy old → new for existing rows (batched)
3. Switch:   deploy code that reads the new column
4. Contract: stop writing the old column, then drop it in a later release
```

The same applies to changing a column's type in a way that isn't a cheap, compatible cast.

### Backfills — in batches, and separate from schema changes

- **Never mix a schema change and a large data change in one migration.** Long-running
  `UPDATE`s inside the schema migration's transaction hold locks for the whole run and make
  the migration impossible to retry safely. Schema in one migration; the backfill as its own
  migration (or a one-off job) after it.
- **Backfill in batches** (e.g. 1 000–10 000 rows per statement, keyed on the primary key),
  committing between batches, so no single statement holds locks or bloats the log for
  minutes. Make it **idempotent** (`WHERE new_col IS NULL`) so it can be re-run after a
  failure.

```sql
-- One batch; repeat until 0 rows are updated (loop in the job, or the tool's data migration)
UPDATE orders
   SET status_code = legacy_status
 WHERE id IN (SELECT id FROM orders WHERE status_code IS NULL ORDER BY id LIMIT 5000);
```

- Backfills that convert values with meaning (time zones, units, currencies) state the
  assumption explicitly in the migration — e.g. converting a `date` column to a timestamp must
  pick a deliberate local time in the app's primary time zone, not silently assume midnight
  UTC (which shows as the previous day in negative-offset time zones).

### Indexes on populated tables

Creating an index normally blocks writes to the table for the duration. On tables with
production traffic, build it **without blocking** where the engine supports it:

- **(PostgreSQL)** `CREATE INDEX CONCURRENTLY` — cannot run inside a transaction, so it goes in
  its own migration with the tool's "no transaction" option (Alembic
  `autocommit_block()`, Django `AddIndexConcurrently` + `atomic = False`, Flyway
  `executeInTransaction=false`, golang-migrate a separate file).
- **(SQL Server)** `WITH (ONLINE = ON)` (edition-dependent); **(MySQL/InnoDB)**
  `ALGORITHM=INPLACE, LOCK=NONE`.

The same caution applies to any statement that rewrites the whole table (adding a stored
generated column, some type changes): cheap on an empty table, an outage on a large one.

---

## Constraints that protect data

- **Prefer database constraints to application checks** for invariants the database can
  express: foreign keys, `UNIQUE`, `CHECK`, `NOT NULL`. They hold under concurrency and for
  every writer.
- **Double-submission:** any table that records a user action keyed on a natural slot
  (`(resource_id, scheduled_at)`, `(order_id, step)`) gets a `UNIQUE` constraint — a double tap
  or a network retry then fails cleanly instead of creating a duplicate row.

```sql
ALTER TABLE action_logs
  ADD CONSTRAINT uq_action_log_slot UNIQUE (resource_id, scheduled_at);
```

- **Timestamps of events are stored with time zone / in UTC** (`timestamptz` in PostgreSQL,
  `datetimeoffset` in SQL Server, UTC `DATETIME` by convention in MySQL); pure calendar
  concepts (birth date, due date) use a `date` type.
- **Enum / lookup values are copied from the project's canonical enums table**, never
  invented.

---

## Testing migrations

- **CI applies every migration from an empty database** (the same path a new environment
  takes) and fails on any error.
- **Model-first tools: CI checks that models and migrations are in sync** (no pending
  autogenerated changes).
- **Reversible migrations: CI runs up → down → up** at least for the new migrations.
- **Data migrations get a test** with representative rows (including `NULL`s and edge
  values) asserting the converted result.
- **Repository integration tests run against the migrated schema**, not a hand-built one
  (`dev-core:test-patterns` → `repository-integration-tests.md`).
- Before a risky change, rehearse on a copy of production-sized data and measure lock time.

## Anti-patterns

- Editing a migration that already ran on a shared environment
- Changing the shared database by hand "just this once"
- `RENAME COLUMN` / `DROP COLUMN` in the same release as the code change that stops using it
- `ADD COLUMN ... NOT NULL` without a default on a populated table
- A multi-million-row `UPDATE` inside the schema migration
- Accepting a model-first tool's generated rename-as-drop+add without reading it
- A new table without its data-access policies
