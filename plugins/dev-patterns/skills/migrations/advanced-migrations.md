---
# Advanced migration patterns: multi-phase NOT NULL, Supabase Storage, seed via Admin API, expand/contract, and UNIQUE constraints.
# Referenced by SKILL.md — do not duplicate content there.
---

## 3-phase pattern for NOT NULL column on existing table

```
Migration 1: add nullable column
Migration 2: populate existing data
Migration 3: alter to NOT NULL
```

---

## Storage — Supabase

Enable Storage in the Supabase Dashboard **before** applying migrations that create buckets.
The `storage` schema does not exist if Storage is disabled.

---

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

---

## Expand/contract pattern

```
Phase 1 — Expand:   new structure (old code ignores it)
Phase 2 — Migrate:  code uses new structure
Phase 3 — Contract: remove old structure
```

---

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
