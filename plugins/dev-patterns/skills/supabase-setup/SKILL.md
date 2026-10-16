---
name: supabase-setup
description: >
  Reusable patterns for Supabase configuration (PostgreSQL, Auth, RLS, Storage).
  Invoke automatically when configuring Supabase, implementing RLS policies,
  configuring Auth, defining Storage buckets, or using connection pooling.
---

# Supabase Setup

> Supporting files (condensed, topic-grouped copies of sections below — read the one
> matching the task when you don't need the whole file):
> - [rls-security.md](rls-security.md) — RLS, admin client, bytea/pgcrypto, auth triggers, ES256 guard
> - [gotchas.md](gotchas.md) — seed scripts, CLI quirks, PostgREST quirks, timestamps, token refresh

## Initial database configuration

```sql
-- Enable required extensions (run once per project)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- sensitive data encryption

-- Default timezone
ALTER DATABASE postgres SET timezone TO 'UTC';
```

---

## Projects per environment

Create **one Supabase project per environment** — never share between staging and production:

```
<project>-staging     ← isolated database, auth, and storage
<project>-production  ← isolated database, auth, and storage
```

---

## Connection pooling — which connection for which job

| Job | Connection |
|---|---|
| App runtime with a direct Postgres client (`pg`, an ORM) in containers / serverless | **Transaction pooler, port 6543** |
| Migrations, `supabase db push`, schema dumps, anything with DDL, prepared statements, `LISTEN`/`NOTIFY` or session state | **Direct connection (5432)** or the **session pooler** |
| App that only talks to Supabase through `supabase-js` (HTTP / PostgREST) | **None** — no `DATABASE_URL` needed |

```bash
# ✅ App runtime — transaction pooler (copy the exact string from the dashboard's Connect panel)
DATABASE_URL=postgresql://<user>:<pass>@<pooler-host>:6543/postgres?pgbouncer=true

# ✅ Migrations / db push — direct connection (or the session pooler)
MIGRATION_DATABASE_URL=postgresql://<user>:<pass>@db.<project-ref>.supabase.co:5432/postgres

# ❌ Wrong — direct connection as the runtime pool of many containers (exhausts connections)
# ❌ Wrong — running migrations through the transaction pooler (breaks prepared statements / DDL)
```

---

## Auth — required panel settings

```
Email confirmations:          enabled
Secure email change:          enabled
JWT expiry:                   3600 (1 hour)
Refresh token rotation:       enabled
Refresh token reuse interval: 10 seconds
```

---

## bytea columns — never insert raw text

PostgreSQL silently accepts a `text` value cast to `bytea`: `'hello'::bytea` = `\x68656c6c6f`. No error is raised. The consequence is data corruption that is invisible at write time and only discovered at read time.

**Rule:** never pass a plain TypeScript `string` to a column declared as `bytea`. Always encrypt first via the appropriate RPC function or application-level encryption, and always decrypt on read before returning to the client.

```typescript
// ❌ Wrong — supabase-js accepts this, PostgreSQL casts silently, data is corrupted
await supabase.from('users').update({ secret_value: 'raw-plain-text' });

// ✅ Correct — encrypt first (via your project's encrypt RPC), then store the bytea result
const { data: encrypted } = await supabase.rpc('encrypt_text', {
  plain_value: 'raw-plain-text',
  enc_key: process.env.DATA_ENCRYPTION_KEY,
});
await supabase.from('users').update({ secret_value: encrypted });
```

**On read:** PostgREST returns `bytea` values as hex strings prefixed with `\x` (e.g. `\x3132...`). If you return this string to the frontend without decrypting, the frontend receives garbage. Always decrypt on the backend before returning the response:

```typescript
// After select('*'), record.secret_value === '\x3132...' (raw bytea hex)
const { data: decrypted } = await supabase.rpc('decrypt_text', {
  encrypted_value: record.secret_value,
  enc_key: process.env.DATA_ENCRYPTION_KEY,
});
// Now decrypted === 'raw-plain-text' — safe to return
```

**Graceful fallback:** `pgp_sym_decrypt` throws if the data was not PGP-encrypted (e.g. legacy records stored without encryption). Wrap in `try/catch` and return `null` — the user will re-enter the value.

---

## RLS — Row Level Security

RLS must be **active on every table** from creation. Never create a table without defining policies.

```sql
-- Minimum pattern for every new table
ALTER TABLE <table> ENABLE ROW LEVEL SECURITY;

-- Base policy: user accesses only their own data
CREATE POLICY "user_isolation" ON <table>
  FOR ALL USING (user_id = auth.uid());
```

### Multi-tenant RLS — required pattern with SECURITY DEFINER

**WARNING:** A policy **on the members table** that subqueries the members table recurses
infinitely. Use `SECURITY DEFINER` helpers to break the cycle — and for role/type predicates
too. See the `migrations` skill for the complete pattern.

```sql
-- Step 1: create helper function BEFORE the policies
CREATE OR REPLACE FUNCTION public.get_tenant_ids_for_user(user_uuid uuid)
RETURNS SETOF uuid
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public
AS $$
  SELECT tenant_id FROM public.tenant_members
  WHERE user_id = user_uuid AND accepted_at IS NOT NULL
$$;

-- Step 2: use the function in the policies — members READ; the API (service_role) writes
CREATE POLICY "tenant_member_read" ON <data_table>
  FOR SELECT TO authenticated
  USING (tenant_id IN (SELECT public.get_tenant_ids_for_user(auth.uid())));

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON <data_table> FROM anon, authenticated;

-- Service role bypasses RLS for administrative operations
CREATE POLICY "service_role_access" ON <data_table>
  FOR ALL TO service_role USING (true);
```

A `FOR ALL` member policy would let every member insert/update/delete through PostgREST,
bypassing the API's role matrix. Add write policies only when clients must write directly, and
only mirroring the role matrix (role predicates through a `SECURITY DEFINER` helper). Check
`authenticated`'s table privileges in CI — query in the `migrations` skill ("Required base
policies").

### Lock down grants on SECURITY DEFINER functions that take raw parameters

Supabase's project scaffold runs `ALTER DEFAULT PRIVILEGES ... GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role` — **every new function is executable by `anon` (the public API key shipped in the mobile bundle) unless revoked.** This is harmless for functions like `get_tenant_ids_for_user` above (it only ever gets called as `auth.uid()`, and RLS scopes it to `authenticated`), but it's a real hole for any function that takes a caller-supplied value with no internal `auth.uid()` check — e.g. generic `pgp_sym_encrypt`/`decrypt` wrappers. Anyone holding the anon key can call it directly via `/rest/v1/rpc/<fn>`, bypassing your API's auth entirely.

```sql
-- Any function with no internal auth.uid() check and no RLS-policy dependency:
REVOKE ALL ON FUNCTION public.<fn>(<args>) FROM PUBLIC, anon, authenticated;
-- service_role keeps EXECUTE implicitly (superuser-adjacent) — only revoke it too if you truly never call it from the API.

-- A function referenced inside RLS policies (like get_tenant_ids_for_user) needs
-- `authenticated` to keep EXECUTE — Postgres requires it to evaluate the policy.
-- Only revoke PUBLIC and anon in that case.
```

Typical incident this pattern catches: generic pgcrypto `encrypt`/`decrypt` wrappers (no auth check) left callable by `anon` for months. **This is not a one-off** — in practice the same bug recurs across many function kinds before anyone notices, and it tends to be caught by manual audit, not tooling: membership-check helpers (`is_member_of_<tenant>(p_tenant_id, p_user_id)`), "ids for user" helpers that take a `user_uuid` parameter, and stock/counter mutators (`increment_<x>_stock`/`decrement_<x>_stock`). The worst variant has **no explicit grant line at all** — it is exposed purely by the schema-wide default, which makes it easy to miss in review since there's no `GRANT ... TO anon` line to spot.

**Structural fix — change the default, then verify in CI.** Instead of remembering a `REVOKE`
per function, flip the default once in a migration, so new functions start closed and each
exposure becomes an explicit, reviewable `GRANT`:

```sql
-- Run as the role that creates your functions/tables (normally postgres, i.e. migrations)
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated, PUBLIC;

-- Then grant deliberately, e.g. a helper referenced by RLS policies:
GRANT EXECUTE ON FUNCTION public.get_tenant_ids_for_user(uuid) TO authenticated;
```

`ALTER DEFAULT PRIVILEGES` only affects objects created **afterwards** — revoke on the existing
functions once as well. Then make the audit query below (and the table-privilege query in the
`migrations` skill) a **CI check** against a database migrated from scratch: the job fails when
`anon` / `PUBLIC` holds `EXECUTE` on a function, or `authenticated` holds a table privilege,
that is not in a committed allowlist.

**Checklist for every new SECURITY DEFINER function, before merging the migration:**
1. Does it take a caller-supplied id (`p_user_id`, `p_tenant_id`, `p_item_id`, ...) with no internal check that it matches `auth.uid()` or is reachable through the caller's own membership? If yes, it's a candidate for direct-RPC abuse — either add the internal check (e.g. an `is_member_of_<tenant>` helper that compares against `auth.uid()` internally) or revoke `anon`/`authenticated`/`PUBLIC` entirely if the API only ever calls it via `service_role`.
2. Is it referenced inside any RLS policy's `USING`/`WITH CHECK` clause? If yes, `authenticated` must keep `EXECUTE` (Postgres requires it to evaluate the policy) — only revoke `PUBLIC` and `anon`. If no, revoke all three; nothing outside `service_role` should ever need to call it.
3. Run this after every migration that adds a function, to catch anything the default privileges quietly exposed without an explicit `GRANT` line to spot in review:
   ```sql
   SELECT routine_name, grantee, privilege_type
   FROM information_schema.routine_privileges
   WHERE routine_schema = 'public' AND grantee IN ('anon', 'PUBLIC')
   ORDER BY routine_name;
   ```
   Anything in that result that isn't deliberately public (e.g. a function meant to be called by unauthenticated preview flows) is a bug. One legitimate row you will see and can ignore: trigger functions like `handle_new_user` (the `on_auth_user_created` trigger) — Postgres grants them `PUBLIC`/`anon` EXECUTE too, but PostgREST never exposes a function whose return type is `trigger` as an RPC endpoint, so it isn't reachable via `/rest/v1/rpc/<fn>` regardless of the grant. Check `SELECT prorettype::regtype FROM pg_proc WHERE proname = '<fn>'` if unsure whether a flagged function is actually RPC-reachable.

---

## Admin client (service_role) in supabase-js — required configuration

The service_role client **must** have explicit headers. Without them, RLS is NOT bypassed:

```typescript
// ✅ Correct — explicit headers guarantee RLS bypass
createClient(url, serviceRoleKey, {
  global: {
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
    },
  },
  auth: { autoRefreshToken: false, persistSession: false },
});

// ❌ Wrong — supabase-js v2 does not set Authorization automatically
createClient(url, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
});
```

---

## Supabase CLI v2 — getting JWT keys for supabase-js

The Supabase CLI v2 exposes keys in the `sb_publishable_*` / `sb_secret_*` format in `supabase status`,
but `supabase-js` needs the classic JWT keys (`eyJ...`) to work correctly.

```bash
# ✅ Correct — use the -o env flag to get JWT keys in classic format
supabase status -o env | grep -E "ANON_KEY|SERVICE_ROLE_KEY|JWT_SECRET"

# Expected output:
# ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
# SERVICE_ROLE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
# JWT_SECRET="super-secret-jwt-token-with-at-least-32-characters-long"
```

Add these keys to the API `.env`:
```bash
SUPABASE_URL=http://127.0.0.1:54321
SUPABASE_ANON_KEY=eyJ...         # classic JWT — NOT sb_publishable_*
SUPABASE_SERVICE_ROLE_KEY=eyJ... # classic JWT — NOT sb_secret_*
SUPABASE_JWT_SECRET=super-secret...
```

**Note:** CLI v2 also uses ES256 (ECDSA) to sign tokens for authenticated users.
Verify tokens with `supabase.auth.getUser(token)` — never with `jwt.verify(token, jwtSecret)`.

### NestJS integration — JwtAuthGuard pattern

`passport-jwt` defaults to HS256 and **fails silently** with ES256 tokens (returns 401 with
no useful error, making it look like the token is invalid when it is not).

The correct guard implements `CanActivate` directly:

The single source for this guard (error codes, module registration, `@Public()`) is
`dev-patterns:auth-security` → backend-auth. Minimal shape:

```typescript
// ✅ Correct — algorithm-agnostic (works with ES256), honours @Public(), checks the scheme
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(
    private readonly supabase: SupabaseService,
    private readonly reflector: Reflector,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    // Registered as a global guard: public routes (login, register, health) must pass through
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(), context.getClass(),
    ]);
    if (isPublic) return true;

    const request = context.switchToHttp().getRequest();
    const authHeader: string | undefined = request.headers['authorization'];
    if (!authHeader?.startsWith('Bearer ')) throw new UnauthorizedException('Missing token');
    const token = authHeader.slice(7);

    const { data, error } = await this.supabase.client.auth.getUser(token);
    if (error || !data?.user) throw new UnauthorizedException('Invalid or expired token');

    request.user = { id: data.user.id, email: data.user.email };
    return true;
  }
}

// ❌ Wrong — passport-jwt uses HS256 by default, fails silently with ES256
@Injectable()
export class JwtAuthGuard extends AuthGuard('jwt') {}
```

---

## Development user seed — Admin API required

Inserting directly into `auth.users` via SQL **does not work for login**. The auth service
does not recognize passwords inserted via PostgreSQL's `crypt()` and returns 401 on all logins.

```bash
# ✅ Correct — create user via Admin API (authenticates normally afterwards)
SERVICE_KEY=$(supabase status -o env 2>/dev/null | grep '^SERVICE_ROLE_KEY=' | cut -d'=' -f2- | tr -d '"')
curl -s -X POST "http://127.0.0.1:54321/auth/v1/admin/users" \
  -H "apikey: $SERVICE_KEY" \
  -H "Authorization: Bearer $SERVICE_KEY" \
  -H "Content-Type: application/json" \
  -d '{"email":"dev@test.com","password":"dev123","email_confirm":true}'

# ❌ Wrong — user exists in the database but cannot log in
INSERT INTO auth.users (email, encrypted_password, ...)
VALUES ('dev@test.com', crypt('dev123', gen_salt('bf')), ...);
```

**Also:** psql meta-commands (`\set`, `\copy`) do not work with `supabase db reset`.
User seeding must be in a separate shell script, not in `seed.sql`.

---

## supabase status -o env — correct key format

The output includes quotes around values. Always use `tr -d '"'` when extracting:

```bash
# ✅ Correct — anchored grep + tr -d '"' + 2>/dev/null
SUPABASE_URL=$(supabase status -o env 2>/dev/null | grep '^API_URL=' | cut -d'=' -f2- | tr -d '"')
SERVICE_KEY=$(supabase status -o env 2>/dev/null | grep '^SERVICE_ROLE_KEY=' | cut -d'=' -f2- | tr -d '"')
ANON_KEY=$(supabase status -o env 2>/dev/null | grep '^ANON_KEY=' | cut -d'=' -f2- | tr -d '"')

# ❌ Wrong — without tr -d '"', the URL becomes "http://..." (with quotes), breaking curl
```

---

## supabase db query — CLI v2.104+ returns JSON

Starting with Supabase CLI v2.104, `supabase db query` returns JSON, not tabular text:

```json
{ "boundary": "abc", "rows": [{"id": [23, 143, ...]}], "warning": "..." }
```

**Rules:**
1. Use `RETURNING id::text` (not `RETURNING id`) — `uuid` is returned as a byte array without the cast
2. Extract IDs with python3, never with `grep -E '^[0-9a-f]'`:

```bash
# Helper function for seed.sh — extracts id from the first row of the JSON result
db_id() {
  supabase db query "$1" 2>/dev/null | python3 -c "
import sys, json, re, uuid as _uuid
raw = sys.stdin.read().strip()
try:
    rows = json.loads(raw).get('rows', [])
    if rows:
        val = rows[0].get('id') or rows[0].get('id::text') or list(rows[0].values())[0]
        if isinstance(val, list) and len(val) == 16:
            val = str(_uuid.UUID(bytes=bytes(val)))
        print(str(val).strip())
except Exception:
    m = re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', raw)
    print(m.group(0) if m else '', end='')
"
}

# Usage:
RECORD_ID=$(db_id "INSERT INTO public.records (...) VALUES (...) RETURNING id::text;")
```

For INSERTs without capturing return value, use a simple wrapper:
```bash
db() { supabase db query "$1" 2>&1 | grep -v "Connecting\|new version\|recommend\|available"; }
db "INSERT INTO public.record_members (...) VALUES (...);"
```

---

## GoTrue is unreachable ~5-8s after supabase db reset

`supabase db reset` restarts containers. Calling the Admin API immediately returns 502.
Wait before creating users:

```bash
# Wait for GoTrue to be ready
until curl -s http://127.0.0.1:54321/auth/v1/health 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('version') else 1)" 2>/dev/null
do sleep 2; done
echo "GoTrue ready."
```

If it keeps failing after 30s: `supabase stop && supabase start` — Kong may not have
refreshed the upstream after the internal containers restarted.

---

## Storage — bucket configuration

```sql
-- Default policy: user accesses only their own files
CREATE POLICY "user_storage_access"
ON storage.objects FOR ALL
USING (auth.uid()::text = (storage.foldername(name))[1]);
```

Recommended bucket structure by content type:

```
avatars/      ← profile photos — public with RLS
attachments/  ← private documents — authenticated access
reports/      ← generated files — private, configurable lifecycle
```

---

## `SUPABASE_URL=http://127.0.0.1:...` breaks public Storage URLs on a physical device

`getPublicUrl(bucket, path)` (supabase-js) builds the returned URL by simple string
concatenation off the client's own configured `SUPABASE_URL` — whatever that value is gets baked
verbatim into every public URL, including ones stored in the database (e.g. `users.avatar_url`,
written once at upload time, not recomputed on read).

**Symptom:** an image (avatar, or anything else served via a public bucket URL) loads fine in the
iOS Simulator or on web, but silently fails to load when testing on a **physical device** over the
same LAN as the dev Mac — no error surfaces unless the component has an explicit `onError`
handler, so it just looks like "the image is missing" or "the upload didn't work".

**Cause:** `SUPABASE_URL=http://127.0.0.1:54321` is correct for the API server talking to its own
local Supabase instance (same machine), but `127.0.0.1` means something different to whoever reads
a URL built from it — on a physical phone on the same WiFi, `127.0.0.1` resolves to the phone
itself, not the Mac. Same class of gotcha `EXPO_PUBLIC_API_URL` already has to avoid (it needs the
Mac's LAN IP, e.g. `192.168.x.x`, not `localhost`) — `SUPABASE_URL` needs it too, because anything
derived from it (public Storage URLs specifically) ends up in front of the same physical-device
audience.

```bash
# ❌ Works in Simulator/web, silently broken on a physical device on the same LAN
SUPABASE_URL=http://127.0.0.1:54321

# ✅ Same LAN IP already used for EXPO_PUBLIC_API_URL
SUPABASE_URL=http://192.168.x.x:54321
```

**Already-broken URLs stay broken until fixed directly** — since the public URL is computed once
at upload time and stored as a literal string, changing `SUPABASE_URL` only fixes *future*
uploads. Repair existing rows directly:

```sql
UPDATE users SET avatar_url = REPLACE(avatar_url, 'http://127.0.0.1:54321', 'http://192.168.x.x:54321')
WHERE avatar_url LIKE 'http://127.0.0.1:54321%';
```

Same pattern applies to any other column storing a `getPublicUrl()` result. After editing `.env`,
restart the API process — env vars are only read at startup, not hot-reloaded even under
`start:dev`'s watch mode (it watches source files, not `.env`).

---

## Backups

Which backups you get depends on the plan, and plans change — **check the current Supabase
pricing and backups docs** before relying on any of this, and record what the project actually
has in its infrastructure doc:
- Whether automatic daily backups are included, and their retention, depend on the plan.
- **Point-in-time recovery (PITR) is a paid add-on**, not something a plan turns on by itself.
  For production data you cannot afford to lose a day of, budget for it and enable it.
- Independently of the plan, keep your own periodic logical dump (`supabase db dump` /
  `pg_dump`, through the direct connection) in storage you control.

**Restore procedure:**
1. Supabase Dashboard → Backups → select the backup / point in time
2. Restore to staging (or a scratch project) first to validate
3. Restore to production with a maintenance window

**Restore drill:** a backup nobody has restored is a hope, not a backup. On a schedule (e.g.
quarterly) and after any change to the backup setup, restore the latest backup into a scratch
project, run a smoke check (row counts on key tables, a login, a read through the API), time
it, and record the date and duration.

---

## Sensitive data encryption with pgcrypto

```sql
-- Store
INSERT INTO my_table (sensitive_field)
VALUES (pgp_sym_encrypt('value', current_setting('app.encryption_key')));

-- Retrieve
SELECT pgp_sym_decrypt(sensitive_field::bytea, current_setting('app.encryption_key'))
FROM my_table WHERE id = $1;
```

---

## Required environment variables

```bash
# Backend
DATABASE_URL=                        # only with a direct Postgres client — transaction pooler, port 6543
MIGRATION_DATABASE_URL=              # CI / migrations only — direct (5432) or session pooler
SUPABASE_URL=                        # https://<ref>.supabase.co
SUPABASE_ANON_KEY=                   # anon client (stateless, persistSession: false)
SUPABASE_SERVICE_ROLE_KEY=           # service_role key (never expose on frontend)
SUPABASE_JWT_SECRET=                 # only if you verify HS256 tokens locally — prefer auth.getUser() (see ES256 note)
<DOMAIN>_ENCRYPTION_KEY=             # pgcrypto key for bytea columns, if any — one key per data domain
                                     # (e.g. BILLING_ENCRYPTION_KEY, DOCUMENTS_ENCRYPTION_KEY), so one
                                     # compromise or rotation doesn't touch every encrypted column

# Frontend (public — no sensitive data)
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
EXPO_PUBLIC_SUPABASE_URL=
EXPO_PUBLIC_SUPABASE_ANON_KEY=
```

---

## Free tier limits

```
Database:  500MB
Auth:      50,000 active users/month
Storage:   1GB
Backups:   depends on the plan — check the current pricing page (see "Backups")
```

**Trigger for Pro ($25/month):** database > 400MB or > 50k auth users.

---

## PostgREST — ambiguous FK: multiple foreign keys to the same target

**Symptom:** `Could not embed because more than one relationship was found for 'X' and 'Y'` → HTTP 500.

**Cause:** the table has two or more FKs pointing to the same target table (e.g. `user_id` and
`invited_by` both referencing `users`). PostgREST cannot infer which FK to use for the join.

**Solution:** use an explicit hint with the constraint name:

```typescript
// ❌ Ambiguous → PGRST201 (plain join)
.select('*, users(full_name, email)')

// ❌ Also ambiguous → PGRST201 (!inner does NOT resolve the ambiguity)
.select('role, users!inner(user_type)')

// ✅ Correct — explicit FK constraint name, works with or without !inner
.select('*, users!my_table_user_id_fkey(full_name, email)')
.select('role, users!my_table_user_id_fkey(user_type)')
```

**`!inner` does not resolve ambiguity** — it only changes cardinality (filters out rows where the join returns nothing). The FK disambiguation must come from the constraint name hint, regardless of `!inner`.

**Finding constraint names:**

```sql
SELECT constraint_name FROM information_schema.table_constraints
WHERE table_name = 'my_table' AND constraint_type = 'FOREIGN KEY';
```

Supabase generates constraint names as `{table}_{column}_fkey` by default.

**When to apply:** any table with audit columns (`invited_by`, `created_by`, `updated_by`,
`resolved_by`, `deleted_by`) that point to the same target table as another FK.
Check before any join on tables with audit columns.

---

## timestamptz — Supabase returns `+00:00`, not `.000Z` — never compare as string

When inserting `"2026-06-22T08:00:00.000Z"` into a `timestamptz` column, Supabase/PostgREST
returns `"2026-06-22T08:00:00+00:00"`. String comparison between the two **always fails
silently** — no error is raised, the comparison simply returns false.

**Typical symptom:** a record is saved successfully, but the UI does not reflect the change
after a refetch (badge never appears, status does not update). The bug is hidden because there
is no error — the query just does not find a match.

```typescript
// ❌ Never — string comparison of timestamps fails silently
bookings.find(b => b.scheduled_time === scheduledTime)
// "2026-06-22T08:00:00+00:00" !== "2026-06-22T08:00:00.000Z" → always false

// ✅ Always — compare numeric epoch
const scheduledMs = new Date(scheduledTime).getTime();
bookings.find(b => new Date(b.scheduled_time).getTime() === scheduledMs)
```

**When to apply:** any `find()`, `filter()`, or `===` that compares dates from database fields
(`confirmed_at`, `scheduled_time`, `created_at`, etc.) with dates constructed in code.
Always use `.getTime()` on both sides.

---

## JWT access token expiry — refresh with mutex for concurrent requests

Supabase access tokens expire after `jwt_expiry` seconds (default: 3600 = 1 hour). After expiry,
all requests return 401 and the app appears empty without clear feedback.

**Solution:** intercept 401 in `apiRequest` and attempt an automatic refresh with a mutex to
handle concurrent requests:

```typescript
let refreshPromise: Promise<string | null> | null = null;

async function attemptRefresh(): Promise<string | null> {
  if (refreshPromise) return refreshPromise; // wait for the in-progress refresh
  refreshPromise = (async () => {
    try {
      // Use the app's token storage wrapper (SecureStore on native) — never AsyncStorage
      // directly: AsyncStorage maps to localStorage on web and is unencrypted on native.
      const refresh_token = await tokenService.getRefreshToken();
      if (!refresh_token) return null;
      const res = await fetch(`${BASE_URL}/auth/refresh`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ refresh_token }),
      });
      if (!res.ok) return null;
      const { access_token } = await res.json();
      await tokenService.setAccessToken(access_token);
      return access_token;
    } catch { return null; }
    finally { refreshPromise = null; }
  })();
  return refreshPromise;
}

// In apiRequest: after receiving 401, call attemptRefresh() and retry
export async function apiRequest<T>(path: string, options: RequestInit = {}): Promise<T> {
  const res = await fetch(url, { ...options, headers });
  if (res.status === 401) {
    const newToken = await attemptRefresh();
    if (!newToken) { clearAuthAndRedirect(); throw new Error('Session expired'); }
    const retry = await fetch(url, {
      ...options,
      headers: { ...headers, Authorization: `Bearer ${newToken}` },
    });
    if (!retry.ok) throw new Error('Request failed after token refresh');
    return retry.json();
  }
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}
```

**Why the mutex matters:** if 10 queries fail with 401 simultaneously, the mutex ensures only
1 refresh call is made — the other 9 await the same promise result.

## on_auth_user_created trigger — always use upsert in user repository

If the schema defines a trigger that syncs `auth.users → public.users` on INSERT, calling `admin.auth.admin.createUser()` fires the trigger **synchronously**. By the time application code calls `users.create`, the row already exists. A plain `INSERT` fails with `duplicate key value violates unique constraint "users_pkey"`.

**Fix:** use `upsert` in the user repository so the real `full_name` and `user_type` overwrite the trigger stub:

```typescript
// ❌ Fails — trigger already inserted a stub row with empty full_name
await supabase.admin.from('users').insert({ id, email, full_name, user_type });

// ✅ Correct — overwrites trigger stub with real data
await supabase.admin.from('users').upsert(
  { id, email, full_name, user_type },
  { onConflict: 'id' },
);
```

Pass `user_metadata` to `createUser` so the trigger stub already has the correct values (defence in depth):

```typescript
await supabase.admin.auth.admin.createUser({
  email,
  password,
  email_confirm: true,
  user_metadata: { full_name, user_type },
});
```

**If the trigger needs to branch on something the caller passed to `createUser`
(e.g. routing the new row to a different table), read it from `user_metadata`,
never from `app_metadata`.** Observed live against GoTrue (re-verify after a major upgrade):
`admin.createUser({ app_metadata: { role: 'ADMIN' } })` does **not** have the
caller-supplied `app_metadata` merged into the row yet at the moment the
`AFTER INSERT` trigger fires — GoTrue inserts the row with its own managed
defaults (`provider`/`providers`) first, and merges the caller's `app_metadata`
in afterward, asynchronously to the trigger. The value the trigger sees is
just `{provider, providers}`, no matter what was passed. The final row **does**
end up with the right `app_metadata` — a `SELECT` after the request returns
shows it correctly — it just isn't there yet for `NEW.raw_app_meta_data` to
read. `user_metadata` (`NEW.raw_user_meta_data`) has no such gap — that's
what makes `full_name` available above.

```sql
-- ❌ NEW.raw_app_meta_data->>'role' is NULL here even when the caller passed
-- app_metadata: { role: 'ADMIN' } — the merge hasn't happened yet.
IF NEW.raw_app_meta_data->>'role' = 'ADMIN' THEN ...

-- ✅ user_metadata is available synchronously — pass the routing signal here instead.
IF NEW.raw_user_meta_data->>'is_staff' = 'true' THEN ...
```

This doesn't weaken authorization: keep `app_metadata.role` as the actual
permission claim everywhere it's checked (guards read it from the JWT at
request time, long after creation, so the timing gap never touches that) —
just don't expect the trigger itself to see it.

---

## `auth.admin.deleteUser()` swallows the real error on 5xx — call the Admin API directly for error-sensitive deletes

`supabase-js`'s `auth.admin.deleteUser(id)` classifies **any** 5xx response
as a generic `AuthRetryableFetchError` and discards the parsed response
body — including a genuinely useful error like a foreign-key violation.
Verified live: GoTrue's actual response when the delete is blocked by
`ON DELETE RESTRICT` is `{"code":"23503","message":"...violates foreign
key constraint..."}`, but `supabase-js` returns
`{ message: "{}", name: "AuthRetryableFetchError", status: 500 }` — no way
to tell an FK violation apart from a database outage or anything else.

If the caller needs to react differently to different failure reasons
(e.g. "block with a friendly message" vs "this is a real server error"),
bypass the wrapper and call the Admin API directly:

```typescript
// ❌ Real error body discarded on any 5xx — can't distinguish FK violation
// from a genuine server error
const { error } = await supabase.admin.auth.admin.deleteUser(userId);
if (error) { /* error.message is useless here, error.code is undefined */ }

// ✅ Gets GoTrue's actual response body
const res = await fetch(
  `${process.env.SUPABASE_URL}/auth/v1/admin/users/${userId}`,
  {
    method: 'DELETE',
    headers: {
      apikey: process.env.SUPABASE_SERVICE_ROLE_KEY!,
      Authorization: `Bearer ${process.env.SUPABASE_SERVICE_ROLE_KEY}`,
    },
  },
);
if (!res.ok) {
  const body = await res.json().catch(() => ({}));
  if (body.code === '23503') { /* FK violation — handle explicitly */ }
}
```

Only worth the detour when the caller actually branches on the failure
reason. For a fire-and-forget delete where any failure is handled the
same way, the SDK method is fine.

---

## Supabase singleton client in NestJS — always disable persistSession

The `supabase.client` (anon key) is a NestJS singleton. With `persistSession` enabled (default), `signInWithPassword()` stores the authenticated session in memory. A subsequent `signIn()` call for a **different user** from a different request reuses the stale in-memory session and returns the **wrong `userId`** — causing `users.create` to fail with a duplicate key on the previous user's ID.

**Fix:** always disable `persistSession` on the anon client in server-side code:

```typescript
// ✅ Correct — stateless: every signIn returns a fresh response
this.client = createClient(url, anon, {
  auth: { autoRefreshToken: false, persistSession: false },
});

// ❌ Wrong — default persistSession=true pollutes singleton with user sessions
this.client = createClient(url, anon);
```

**Also:** never use `client.auth.signUp()` in a server-side singleton — it both stores the session AND requires `persistSession: false` to be safe. Use `admin.auth.admin.createUser()` for user creation and `signInWithPassword()` (on the stateless client) for token generation.

---

## Port conflict on `supabase start`

**Error:** `Bind for 0.0.0.0:54322 failed: port is already allocated`

Another Supabase project is using the same ports. Find it and stop it before starting the current project.

```bash
# Identify the active project by container name
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep supabase
# Output shows: supabase_db_<project_id>

# Stop the old project (project_id comes from its supabase/config.toml)
supabase stop --project-id <project_id>

# Start the correct project
supabase start
```

The `project_id` in the Docker container name matches the `project_id` field in the project's `supabase/config.toml`.

---

## PostgREST — join alias with `:` is not valid syntax

`select('role, user_type: users(user_type)')` — the `:` alias form for joins **does not exist** in PostgREST. It silently returns no data or throws a parse error.

**Correct:** use the standard embed syntax without alias, then extract the field in application code:
```typescript
// ❌ Invalid
.select('role, user_type: users(user_type)')

// ✅ Correct — embed the relation, destructure in code
.select('role, users(user_type)')
// then: const userType = row.users?.user_type
```

---

## Seed timestamps — local time to UTC

When seeding historical data with timestamps at specific local times, **never** use `NOW() + TIME 'HH:MM'`
— this *adds* hours to the current timestamp, it does not *set* a specific time.

**Wrong:**
```sql
NOW() - INTERVAL '1 day' + TIME '19:00'  -- adds 19h to NOW(), does NOT set it to 19:00
```

**Correct:** use `CURRENT_DATE` cast as timestamp and add a UTC interval computed from the target timezone:

```sql
-- Formula: UTC interval = local_hour - UTC_offset
--   (UTC-3 → add 3h; UTC+5:30 → subtract 5h30m)
-- UTC-3 (e.g. America/Argentina/Buenos_Aires): 07:00 local → INTERVAL '10h' | 12:00 → '15h' | 19:00 → '22h'
-- UTC+5:30 (Asia/Kolkata):                     09:00 local → INTERVAL '3h30m'
-- Zones with DST: the offset depends on the date — compute it per row or avoid DST-boundary dates.

-- "3 days ago at 19:00 local (UTC-3)":
(CURRENT_DATE - 3)::timestamp + INTERVAL '22h'

-- "3 days ago at 07:08 local (UTC-3, 8-minute offset)":
(CURRENT_DATE - 3)::timestamp + INTERVAL '10h8m'
```

**Verify after seeding:**
```sql
SELECT created_at AT TIME ZONE '<target_tz>' FROM my_table LIMIT 5;
-- Confirm the local time matches what you intended
```

**When to apply:** any `seed.sh` or `seed.sql` that inserts historical rows with time-specific timestamps. Always compute the UTC offset for the target timezone before writing the intervals.

---

## PostgREST — `!inner` join always returns an array, even for single rows

`.select('*, entity_members!inner(user_id, role)')` returns `entity_members` as an array `[]`, never as a plain object — even when exactly one row matches.

Always normalize before accessing fields:

```typescript
const member = Array.isArray(row.entity_members)
  ? row.entity_members[0]
  : row.entity_members;
const { entity_members: _em, ...entity } = row;
return { ...entity, role: member?.role ?? 'MEMBER' };
```
