# Operational Gotchas and PostgREST Quirks
> Sub-file of `supabase-setup` skill. Read when debugging seed scripts, PostgREST
> query errors, port conflicts, timestamp comparisons, or JWT refresh issues.

---

## Development user seed — Admin API required

Inserting directly into `auth.users` via SQL **does not work for login**. The auth service does not recognize passwords inserted via PostgreSQL's `crypt()` and returns 401 on all logins.

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

**Also:** psql meta-commands (`\set`, `\copy`) do not work with `supabase db reset`. User seeding must be in a separate shell script, not in `seed.sql`.

---

## supabase status -o env — correct key extraction

The output includes quotes around values. Always use `tr -d '"'` when extracting:

```bash
# ✅ Correct — anchored grep + tr -d '"' + 2>/dev/null
SUPABASE_URL=$(supabase status -o env 2>/dev/null | grep '^API_URL=' | cut -d'=' -f2- | tr -d '"')
SERVICE_KEY=$(supabase status -o env 2>/dev/null | grep '^SERVICE_ROLE_KEY=' | cut -d'=' -f2- | tr -d '"')

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

For INSERTs without capturing return value:
```bash
db() { supabase db query "$1" 2>&1 | grep -v "Connecting\|new version\|recommend\|available"; }
db "INSERT INTO public.record_members (...) VALUES (...);"
```

---

## GoTrue is unreachable ~5-8s after supabase db reset

`supabase db reset` restarts containers. Calling the Admin API immediately returns 502. Wait before creating users:

```bash
until curl -s http://127.0.0.1:54321/auth/v1/health 2>/dev/null | python3 -c \
  "import sys,json; d=json.load(sys.stdin); exit(0 if d.get('version') else 1)" 2>/dev/null
do sleep 2; done
echo "GoTrue ready."
```

If it keeps failing after 30s: `supabase stop && supabase start` — Kong may not have refreshed the upstream after the internal containers restarted.

---

## Port conflict on `supabase start`

**Error:** `Bind for 0.0.0.0:54322 failed: port is already allocated`

Another Supabase project is using the same ports. Find it and stop it:

```bash
# Identify the active project by container name
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep supabase
# Output shows: supabase_db_<project_id>

# Stop the old project (project_id comes from its supabase/config.toml)
supabase stop --project-id <project_id>

supabase start
```

---

## PostgREST — ambiguous FK: multiple foreign keys to the same target

**Symptom:** `Could not embed because more than one relationship was found for 'X' and 'Y'` → HTTP 500.

**Cause:** the table has two or more FKs pointing to the same target table (e.g. `user_id` and `invited_by` both referencing `users`). PostgREST cannot infer which FK to use.

**Solution:** use an explicit hint with the constraint name:

```typescript
// ❌ Ambiguous → PGRST201
.select('*, users(full_name, email)')

// ✅ Correct — explicit FK constraint name
.select('*, users!my_table_user_id_fkey(full_name, email)')
```

**`!inner` does not resolve ambiguity** — it only changes cardinality. FK disambiguation requires the constraint name hint.

```sql
-- Finding constraint names:
SELECT constraint_name FROM information_schema.table_constraints
WHERE table_name = 'my_table' AND constraint_type = 'FOREIGN KEY';
```

---

## PostgREST — join alias with `:` is not valid syntax

`select('role, user_type: users(user_type)')` — the `:` alias form for joins does not exist in PostgREST. It silently returns no data or throws a parse error.

```typescript
// ❌ Invalid
.select('role, user_type: users(user_type)')

// ✅ Correct — embed the relation, destructure in code
.select('role, users(user_type)')
// then: const userType = row.users?.user_type
```

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

---

## timestamptz — Supabase returns `+00:00`, not `.000Z` — never compare as string

When inserting `"2026-06-22T08:00:00.000Z"` into a `timestamptz` column, Supabase/PostgREST returns `"2026-06-22T08:00:00+00:00"`. String comparison **always fails silently**.

```typescript
// ❌ Never — string comparison of timestamps fails silently
bookings.find(b => b.scheduled_time === scheduledTime)
// "2026-06-22T08:00:00+00:00" !== "2026-06-22T08:00:00.000Z" → always false

// ✅ Always — compare numeric epoch
const scheduledMs = new Date(scheduledTime).getTime();
bookings.find(b => new Date(b.scheduled_time).getTime() === scheduledMs)
```

---

## JWT access token expiry — refresh with mutex for concurrent requests

When 10 queries fail with 401 simultaneously, a mutex ensures only 1 refresh call is made:

```typescript
let refreshPromise: Promise<string | null> | null = null;

async function attemptRefresh(): Promise<string | null> {
  if (refreshPromise) return refreshPromise; // wait for the in-progress refresh
  refreshPromise = (async () => {
    try {
      // Use tokenService (SecureStore) — never AsyncStorage directly.
      // AsyncStorage maps to localStorage on web; tokenService uses SecureStore (safer on native).
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
```

---

## Seed timestamps — local time to UTC

When seeding historical data with timestamps at specific local times, **never** use `NOW() + TIME 'HH:MM'` — this *adds* hours to the current timestamp, it does not *set* a specific time.

```sql
-- ❌ Wrong
NOW() - INTERVAL '1 day' + TIME '19:00'  -- adds 19h to NOW(), does NOT set it to 19:00

-- ✅ Correct: UTC interval = local_hour - UTC_offset (UTC-3 → add 3h)
-- UTC-3: 07:00 local → INTERVAL '10h' | 19:00 → '22h'
-- "3 days ago at 19:00 local (UTC-3)":
(CURRENT_DATE - 3)::timestamp + INTERVAL '22h'
```

**Verify after seeding:**
```sql
SELECT created_at AT TIME ZONE '<target_tz>' FROM my_table LIMIT 5;
```
