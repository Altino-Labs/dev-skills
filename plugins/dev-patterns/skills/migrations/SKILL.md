---
name: migrations
description: >
  Supabase/PostgreSQL implementation layer of dev-core:migrations — statement order with RLS
  and SECURITY DEFINER helpers, cross-table policies, pgcrypto search_path, timestamptz vs
  date and date backfills, generated columns, soft delete, Storage, seeding via the Admin API,
  the Supabase CLI's migration-table quirks and baseline squashing. Invoke automatically
  (together with dev-core:migrations) when creating or altering any table, column, index, or
  RLS policy in a Supabase/PostgreSQL project.
---

# Migrations — Supabase/PostgreSQL

**Load `dev-core:migrations` first.** It holds the stack-agnostic concepts (immutability,
forward-only vs reversible, model-first tools, statement ordering, expand/contract,
NOT NULL in phases, batched backfills, concurrent indexes, testing migrations). This skill
adds the Supabase/PostgreSQL specifics; where the two overlap, the sections below are the
PostgreSQL-flavoured version of the same rule.

## Non-negotiable principles

1. Every schema change lives in a versioned migration — **never alter the database manually**
2. Migrations are **immutable** once applied in production
3. Every migration has `up` and `down` comments
4. Migrations run automatically on deploy via CI/CD

## File naming

```
<timestamp>_<description_in_snake_case>.sql
```

## MANDATORY ORDER within a migration

```
1. CREATE TABLE
2. CREATE INDEX
3. CREATE FUNCTION SECURITY DEFINER   ← AFTER tables exist
4. ALTER TABLE ... ENABLE ROW LEVEL SECURITY
5. CREATE POLICY                      ← AFTER functions exist
```

**PostgreSQL validates table references in SQL functions at creation time.**
Creating `get_entity_ids_for_user` before `entity_members` exists causes:
`ERROR: relation "public.entity_members" does not exist`

Therefore, SECURITY DEFINER functions must be created in the `entity_members` migration
(20...003), after the table exists — not in a separate earlier migration.

## Cross-table policies — separate into dedicated migration

RLS policies that do `SELECT FROM another_table` can only be created **after
that table exists**. Do not mix cross-table policies into the referencing table's migration.

**Correct pattern:**

```
20...002_create_users.sql           ← only: CREATE TABLE + RLS + service_role policy
20...003_create_entities.sql        ← only: CREATE TABLE + RLS + service_role policy
20...004_create_memberships.sql     ← CREATE TABLE + RLS + service_role + SECURITY DEFINER functions
20...014_cross_table_policies.sql   ← ALL policies that reference memberships
```

```sql
-- 20...014_cross_table_policies.sql
-- Create only after ALL referenced tables exist

-- SELECT only: writes go through the API (service_role) — see "Required base policies" below
CREATE POLICY "entities_member_read" ON public.entities FOR SELECT TO authenticated
  USING (id IN (SELECT public.get_entity_ids_for_user(auth.uid())));

CREATE POLICY "orders_member_read" ON public.orders FOR SELECT TO authenticated
  USING (entity_id IN (SELECT public.get_entity_ids_for_user(auth.uid())));

-- ... other tables with entity_id
```

Each table must already have the `service_role` policy in its own migration.
Only policies that reference the membership table go into the dedicated migration.

## RLS — Infinite recursion: SECURITY DEFINER pattern

**NEVER** subquery `entity_members` inside a policy **on `entity_members` itself** (or in a
policy on another table that `entity_members`' own policies read back): evaluating the policy
re-applies the same policy — infinite recursion. A policy on a child table that subqueries
`entity_members` doesn't recurse by itself, but it is still evaluated under `entity_members`'
RLS (slower, and it breaks as soon as that table's policies change), so use the helpers
everywhere.

Wrap **role/type predicates** (owner-only, admin-only, "member of type X") in a
`SECURITY DEFINER` helper as well (`is_owner_of_entity` below) instead of inlining
`role = 'OWNER'` subqueries in policies — one tested definition, no recursion, no RLS-on-RLS.

### Helper functions (create AFTER entity_members)

```sql
CREATE OR REPLACE FUNCTION public.get_entity_ids_for_user(user_uuid uuid)
RETURNS SETOF uuid
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public
AS $$
  SELECT entity_id FROM public.entity_members
  WHERE user_id = user_uuid AND accepted_at IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION public.is_owner_of_entity(user_uuid uuid, p_entity_id uuid)
RETURNS boolean
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.entity_members
    WHERE user_id = user_uuid AND entity_id = p_entity_id
      AND role = 'OWNER' AND accepted_at IS NOT NULL
  )
$$;
```

### Using functions in policies

```sql
-- ✅ Correct
CREATE POLICY "member_read" ON entities
  FOR SELECT TO authenticated USING (id IN (SELECT public.get_entity_ids_for_user(auth.uid())));

-- ✅ Child tables (orders, records, etc.)
CREATE POLICY "member_read" ON orders
  FOR SELECT TO authenticated USING (entity_id IN (SELECT public.get_entity_ids_for_user(auth.uid())));

-- ✅ Role predicate through the helper
CREATE POLICY "owner_update" ON entities
  FOR UPDATE TO authenticated
  USING (public.is_owner_of_entity(auth.uid(), id))
  WITH CHECK (public.is_owner_of_entity(auth.uid(), id));

-- ❌ WRONG in a policy on entity_members — infinite recursion
entity_id IN (SELECT entity_id FROM entity_members WHERE user_id = auth.uid())
```

### entity_members INSERT — without querying the table itself

Only if clients insert memberships directly. When the API is the only writer (the default
below), skip this policy and keep only the `service_role` one — as written, it lets any
authenticated user add themselves to any entity.

```sql
CREATE POLICY "members_self_insert" ON entity_members
  FOR INSERT WITH CHECK (user_id = auth.uid());

CREATE POLICY "members_service_role" ON entity_members
  FOR ALL TO service_role USING (true);
```

## pgcrypto — required search_path in Supabase

In Supabase (local and cloud), pgcrypto lives in the `extensions` schema, not in `public`.
Functions that use `pgp_sym_encrypt` / `pgp_sym_decrypt`:

```sql
-- ✅ Correct
CREATE OR REPLACE FUNCTION public.encrypt_value(plain_value text, enc_key text)
RETURNS text LANGUAGE sql SECURITY DEFINER STABLE
SET search_path = public, extensions   -- ← extensions REQUIRED
AS $$
  SELECT encode(pgp_sym_encrypt(plain_value, enc_key)::bytea, 'base64')
$$;

-- ❌ Wrong — pgp_sym_encrypt not found
SET search_path = public
```

## RLS — Required base policies for all tables with entity_id

A `FOR ALL` member policy gives **every member** INSERT/UPDATE/DELETE straight through
PostgREST with the public key — bypassing the server-side role matrix that
`dev-core:auth-security` requires. When the API is the only writer (the usual case in this
stack), members get **read** access only and every write goes through the API with
`service_role`:

```sql
ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;

-- Members read their entities' rows
CREATE POLICY "<table>_member_read" ON <table>
  FOR SELECT TO authenticated
  USING (entity_id IN (SELECT public.get_entity_ids_for_user(auth.uid())));

-- No direct writes through PostgREST: the API (service_role) is the only writer
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON <table> FROM anon, authenticated;

-- Required: admin client uses service_role which bypasses RLS via this policy
CREATE POLICY "<table>_service_role" ON <table>
  FOR ALL TO service_role USING (true);
```

Add a write policy (and the matching `GRANT`) only when clients must write directly, and only
mirroring the role matrix exactly — e.g. `FOR UPDATE ... USING (public.is_owner_of_entity(...))`
for an owner-only action, never "any member". To make new tables start closed, flip the
default once: `ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE INSERT, UPDATE, DELETE,
TRUNCATE ON TABLES FROM anon, authenticated;` (affects tables created afterwards only).

**CI check** — on a database migrated from scratch, fail the job if this returns a row that is
not in a committed allowlist:

```sql
SELECT table_name, grantee, privilege_type
FROM information_schema.role_table_grants
WHERE table_schema = 'public'
  AND grantee IN ('anon', 'authenticated')
  AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
ORDER BY table_name, grantee, privilege_type;
```

## Date and time — always `timestamptz` (UTC)

Every date/time column must use `timestamptz`. Never `timestamp without time zone` or bare `timestamp`.

**Rule:** the database stores UTC. The presentation layer converts to the user's timezone. Never convert to local time before inserting.

```sql
-- ✅ Correct
created_at   timestamptz NOT NULL DEFAULT now(),
confirmed_at timestamptz,

-- ❌ Wrong — stores local time, breaks multi-timezone users silently
confirmed_at timestamp NOT NULL,
```

For calendar-date fields with no time component (birth dates, scheduled dates, report periods), use `date`:

```sql
birth_date   date NOT NULL,
start_date   date,
purchased_at date DEFAULT CURRENT_DATE,
```

**Caution:** Supabase JS client serializes `date` columns as midnight UTC (`"YYYY-MM-DDT00:00:00Z"`).
Display with a date-only parser (e.g. a shared `fromIsoDate()` util that keeps the
`YYYY-MM-DD` part), never `new Date()` — which shifts it to the previous day in UTC- timezones.

**Rule: event dates use `timestamptz`, not `date`.**

A `date` column has no timezone component. At 23:30 in UTC-3, `toISOString()` already
returns the next UTC day — PostgreSQL extracts that as the wrong calendar date.

```sql
-- ✅ Correct — event/action timestamps
performed_at  timestamptz NOT NULL DEFAULT now(),
end_date      timestamptz,
start_date    timestamptz,

-- ✅ OK — pure calendar concepts without timezone ambiguity
birth_date            date NOT NULL,   -- a birthday is a date, not a moment
due_date              date,            -- a calendar date chosen by a person, not a moment
contract_end_date     date,            -- a contractual calendar date
```

The frontend always sends `new Date().toISOString()` (UTC). The display layer converts
with `formatDate(iso, tz)` / `formatTime(iso, tz)`. See `mobile-ux-patterns` (timezone-aware
date/time display).

**Migrating `date` → `timestamptz`: always backfill with a real local time.**

A bare `::timestamptz` cast converts `DATE '2026-06-26'` to midnight UTC
`"2026-06-26T00:00:00Z"`. In UTC-3, that represents `"2026-06-25 21:00"` — the previous
day — breaking every timezone-aware comparison in the frontend.

```sql
-- ❌ Wrong — midnight UTC, shows as previous day in UTC- timezones
ALTER TABLE t ALTER COLUMN col TYPE timestamptz USING col::timestamptz;

-- ✅ Correct — interpret existing DATE as noon local time, then store as UTC
-- Example with a UTC-3 primary timezone ('<App/Timezone>' = e.g. 'America/Argentina/Buenos_Aires'):
-- DATE '2026-06-26' → "2026-06-26T15:00:00Z" (noon local = 12:00 + 3h)
-- new Date("2026-06-26T15:00:00Z").toLocaleDateString('sv-SE',
--   { timeZone: '<App/Timezone>' }) === "2026-06-26"  ✓
ALTER TABLE t
  ALTER COLUMN col TYPE timestamptz
  USING ((col::text || 'T12:00:00')::timestamp AT TIME ZONE '<App/Timezone>');
```

Use the **app's primary timezone** (not UTC) in the `AT TIME ZONE` clause. Using noon (12:00)
avoids any DST or day-boundary edge case.

---

## Date uniqueness — no `::date` expressions in UNIQUE

A UNIQUE constraint on a `timestamptz` column is fine (see "UNIQUE constraint to prevent
double-submission"). What is invalid is a unique **expression** that casts it to a day:
`timestamptz::date` depends on the session timezone, so it is not immutable and cannot be
indexed.

```sql
-- ✅ Correct — UNIQUE on the timestamptz column itself (same instant = duplicate)
UNIQUE (entity_id, recorded_at)

-- ✅ Correct — "one per calendar day": store the local day in its own date column
recorded_on date NOT NULL,
UNIQUE (entity_id, recorded_on)

-- ❌ Wrong — timestamptz::date is not immutable, cannot back a UNIQUE index
CREATE UNIQUE INDEX ON t (entity_id, (recorded_at::date));
```

For "one per day", compute `recorded_on` in the app's timezone (or as a generated column with
an explicit zone, e.g. `(recorded_at AT TIME ZONE '<app-timezone>')::date`, which is immutable).

## Extensions

```sql
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
```

## 3-phase pattern for NOT NULL column on existing table

```
Migration 1: add nullable column
Migration 2: populate existing data
Migration 3: alter to NOT NULL
```

## `GENERATED ... STORED` columns — `ADD COLUMN` locks the whole table

`ALTER TABLE t ADD COLUMN c ... GENERATED ALWAYS AS (expr) STORED` must compute and write
`expr` for every existing row immediately — Postgres cannot add a stored generated column
lazily. That means a full table rewrite under an `ACCESS EXCLUSIVE` lock, which blocks ALL
reads and writes on the table (not just the new column) for the whole duration.

**Safe when the table is empty or small** (pre-production, or scoped per-tenant so no
single table ever holds more than a few hundred rows) — the rewrite is sub-second and
there's no concurrent traffic to block. A typical legitimate use: accent-insensitive search
columns (`name_search`/`search_text` = `GENERATED ALWAYS AS (public.immutable_unaccent(lower(...))) STORED`)
added across many tables **before production had any real data**.

**Not safe once a table has real production rows and concurrent traffic.** The same
`ALTER TABLE` could hold the lock for minutes on a large table — a real outage for whatever
feature depends on it, triggered by an unrelated deploy, not a bug in the generated
expression itself.

**If you need to add this kind of derived search column to a table that already has
production data:** don't `ADD COLUMN ... STORED`. Instead:

```sql
-- 1. Functional index, CONCURRENTLY — no ACCESS EXCLUSIVE lock, doesn't block reads/writes.
CREATE INDEX CONCURRENTLY idx_t_search_trgm ON public.t
  USING gin (public.immutable_unaccent(lower(col)) extensions.gin_trgm_ops);

-- 2. A view exposing the expression as a real column, so PostgREST can filter on it
--    (PostgREST only filters real table/view columns, never an arbitrary SQL expression
--    inline in .ilike()/.or()) — security_invoker so it inherits the base table's RLS
--    instead of running as the view owner (PG15+; confirm the Supabase image supports it).
CREATE VIEW public.t_searchable WITH (security_invoker = true) AS
  SELECT *, public.immutable_unaccent(lower(col)) AS col_search FROM public.t;
```

Query `t_searchable` instead of `t` for that specific search path; everything else keeps
using the base table. More moving parts than a generated column, but it's what actually
avoids the lock.

## Soft delete

Add a nullable `deleted_at timestamptz` column instead of allowing a real `DELETE`, whenever
the entity might still be referenced by other rows via FK (even `ON DELETE SET NULL` loses
the referenced row's own data — a soft-deleted supplier's name/tax ID stays readable from a
still-existing `orders.supplier_id` join; a hard-deleted one doesn't):

```sql
ALTER TABLE public.<table>
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz;
```

No index needed unless the table is large — the `deleted_at IS NULL` filter runs on every
read anyway and Postgres handles a nullable-column scan fine at small/medium scale.

**Business-rule guard before allowing delete** — soft delete is not "always allowed just
because it's non-destructive." Pick one of two shapes depending on the entity:

- **Status-gated** (e.g. `appointments`, `orders`): only allow delete while
  the entity is still in an open/mistake-correctable status (`REQUESTED`/`SCHEDULED`).
  Once it reaches a terminal status (`COMPLETED`, `CANCELLED`) it's history —
  block the delete with a `BusinessRuleViolationException`, point the user at the existing
  cancel/deactivate flow instead.
- **Linked-record-gated** (e.g. `suppliers`, `categories`): block delete if any other
  table still references this row (`hasLinkedRecords` — one `.select('id').limit(1)`
  query per related table, fail-closed on query error: `if (error) return true`). Never
  delete + let dependent rows dangle.

**Critical gotcha — filter `deleted_at` on *every* id-keyed query, not just find/list.**
It's easy to add `.is('deleted_at', null)` to `findById`/`findByProject` and stop there.
But `update`, `cancel`, `deactivate`/`reactivate` (any mutating method that goes straight
to `.eq('id', id)`) also need the same filter — otherwise a soft-deleted row can still be
edited, cancelled, or reactivated by anyone who retained its id (cached in a mobile app,
browser history, an open tab), and the mutation's `.select('*').single()` response
re-exposes the "deleted" row's data. Audit every repository method that takes a bare `id`
when adding soft delete to a table, not just the ones a first pass happens to touch.

## Storage — Supabase

Enable Storage in the Supabase Dashboard **before** applying migrations that create buckets.
The `storage` schema does not exist if Storage is disabled.

## Development data seed — use Admin API, not SQL

Inserting users directly into `auth.users` via SQL **does not work for authentication**.
Supabase Auth does not recognize the password inserted via `crypt()` through PostgreSQL —
the auth service maintains additional internal state that is not populated via a direct INSERT.

**Never do:**
```sql
-- ❌ User is created in the database but cannot log in
INSERT INTO auth.users (id, email, encrypted_password, ...)
VALUES (..., crypt('password', gen_salt('bf')), ...);
```

**Correct pattern — shell script calling the Admin API:**
```bash
# supabase/seed.sh
SERVICE_KEY=$(supabase status -o env | grep SERVICE_ROLE_KEY | cut -d= -f2 | tr -d '"')

curl -s -X POST "http://127.0.0.1:54321/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"dev@example.com","password":"dev123","email_confirm":true}'
```

Split the seed by *how safe it is to run against a remote environment*, not just by
file format. Recommended split (three scripts under `supabase/`):
- `seed-lib.sh` — shared functions only (e.g. `create_user`/`create_staff` via Admin API),
  sourced by both scripts below, never run directly.
- `seed-essential.sh` — the minimum for the platform to be usable: just the staff/admin
  account. No demo data. Safe to run against staging/production too, because it takes
  no remote default — remote runs require `SUPABASE_URL`/`SERVICE_ROLE_KEY`/`ADMIN_EMAIL`/
  `ADMIN_PASSWORD` explicitly exported, so an accidental run with nothing exported
  resolves to local (via `supabase status -o env`), never a remote project by mistake.
- `seed.sh` — local-only. Runs `seed-essential.sh` first, then adds full demo data
  (fake customers, orders, projects, etc.). Never run this against a remote
  environment.

**Also important:** psql commands like `\set`, `\copy`, and `\include` do not work
with `supabase db reset` — the runner uses libpq, not the interactive psql client.
Always use hardcoded values or an external shell script for dynamic data.

## Expand/contract pattern

```
Phase 1 — Expand:   new structure (old code ignores it)
Phase 2 — Migrate:  code uses new structure
Phase 3 — Contract: remove old structure
```

## UNIQUE constraint to prevent double-submission

Any table that records a user action keyed on `(resource_id, timestamp)` — confirmations, readings, log entries — must have a UNIQUE constraint. Without it, a double-tap or network retry creates duplicate rows with no error.

```sql
-- ✅ Add alongside the table creation
ALTER TABLE action_logs
  ADD CONSTRAINT uq_action_log_slot UNIQUE (resource_id, scheduled_at);

-- Or inline in CREATE TABLE
CREATE TABLE action_logs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_id   uuid NOT NULL REFERENCES resources(id),
  performed_by  uuid NOT NULL REFERENCES users(id),
  scheduled_at  timestamptz NOT NULL,
  -- ...
  CONSTRAINT uq_action_log_slot UNIQUE (resource_id, scheduled_at)
);
```

The constraint rejects the duplicate at the database level, which is safer than application-level deduplication.

---

## `supabase db push --local` — conflict with already-applied migrations

`supabase db push --local` keeps an internal version-control table. If the local database was populated some other way (manual reset, direct psql, or migrations applied one by one), the Supabase CLI's internal state can diverge from the real database state — resulting in an error when it tries to re-apply existing migrations:

```
ERROR: relation "table_name" already exists (SQLSTATE 42P07)
```

**Workaround:** apply the new migration directly via psql, bypassing the Supabase CLI:

```bash
psql postgresql://postgres:postgres@127.0.0.1:54322/postgres \
  -f supabase/migrations/<timestamp>_migration_name.sql
```

The local Supabase database's default port is **54322** (not 54321 — that one is the REST API/PostgREST).

**When to use:** when `supabase db push --local` fails on an older migration (not the one you created), use psql directly only for the new migration. The older migrations are already applied.

**Prevention:** for new projects, use `supabase migration up` instead of `db push` — it respects the recorded state without trying to re-apply already-confirmed migrations.

## Squashing migrations into a single baseline — pre-production only, and only with empirical validation

A pre-production MVP with no real data in any environment (not even staging/production) is the only
scenario where it is worth consolidating dozens of incremental migrations into a single
`<timestamp>_baseline.sql`. Record the decision (and how many files were squashed) in the
project's spec / ADR file (e.g. `PROJECT.md`), if it has one.

**Non-negotiable prerequisite:** confirm that no remote environment (staging/production) has
real data that depends on the migration history before even considering this — a squash
breaks the version-control table (`supabase_migrations.schema_migrations`) of any
environment that already has the old migrations applied.

**`supabase db dump --local` (without `--schema`) only captures the `public` schema.** Triggers on
`auth.users` (e.g. `on_auth_user_created`) and policies/buckets on `storage.objects` are left
out — recreate them by hand in the baseline from the original migrations. Running
`--schema auth,storage` to see what is there is NOT the solution: it also dumps
all of Supabase's internal tables (auth.users, auth.sessions, storage.buckets, etc.),
which are already provisioned in any new project — copy only the customizations (the trigger, the
policies, the bucket INSERTs), never the platform tables' definitions.

**Never trust the dump "by eye" — validate by diff.** Before actually swapping the
migration files:
1. `pg_dump --schema-only --schema=public --schema=auth --schema=storage` of the database BEFORE.
2. Apply the candidate baseline to a test database (`supabase db reset --local` after
   moving the old migrations to an archive folder).
3. Same `pg_dump` on the database AFTER, `diff` against the "before".
4. Acceptable differences: `\restrict`/`\unrestrict` tokens (random on every dump) and
   small divergences in Supabase-internal functions/columns (`storage.foldername()`,
   new columns in `auth.*`) caused by newer Docker images pulled on reset — they are not
   ours and don't need to be in the baseline. Any difference in **our** table/column/policy
   is a bug in the baseline — do not proceed until the diff is clean.

**`supabase/seed.sh` may have rotted** if it doesn't run often — columns/tables
removed in later migrations (e.g. a discontinued module) leave the seed broken from
that point on. Running the full seed end to end is, in practice, the strongest integration
test of the baseline: if it completes without error, the schema supports the application's real
flow, not just the list of tables.

**Rollout order, never simultaneous:** local (validated by diff + seed) → staging → production,
one at a time, each only after confirming the previous one. Remote databases without real data don't
need a destructive `db reset` — use `supabase migration repair` to only realign the
version-control table with the new set of files, without touching the schema itself (which
should already match, validated locally).
