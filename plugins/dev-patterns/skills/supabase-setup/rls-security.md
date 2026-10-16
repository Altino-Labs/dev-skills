# RLS, Security and Auth Patterns
> Sub-file of `supabase-setup` skill. Read when writing RLS policies, configuring
> the admin client, encrypting sensitive data, or implementing auth triggers.

---

## bytea columns — never insert raw text

PostgreSQL silently accepts a `text` value cast to `bytea`: `'hello'::bytea` = `\x68656c6c6f`. No error is raised. The consequence is data corruption that is invisible at write time and only discovered at read time.

**Rule:** never pass a plain TypeScript `string` to a column declared as `bytea`. Always encrypt first via the appropriate RPC function (or application-level encryption), and always decrypt on read before returning to the client.

```typescript
// ❌ Wrong — supabase-js accepts this, PostgreSQL casts silently, data is corrupted
await supabase.from('users').update({ secret_value: 'raw-plain-text' });

// ✅ Correct — encrypt first, then store the bytea result
const { data: encrypted } = await supabase.rpc('encrypt_text', {
  plain_value: 'raw-plain-text',
  enc_key: process.env.DATA_ENCRYPTION_KEY,
});
await supabase.from('users').update({ secret_value: encrypted });
```

**On read:** PostgREST returns `bytea` values as hex strings prefixed with `\x` (e.g. `\x3132...`). Always decrypt on the backend before returning the response:

```typescript
const { data: decrypted } = await supabase.rpc('decrypt_text', {
  encrypted_value: record.secret_value,
  enc_key: process.env.DATA_ENCRYPTION_KEY,
});
```

**Graceful fallback:** `pgp_sym_decrypt` throws if the data was not PGP-encrypted. Wrap in `try/catch` and return `null` — the user will re-enter the value.

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

**Lock down grants on every new SECURITY DEFINER function** — Supabase's default privileges make
every new function executable by `anon`. Full checklist and audit query in `SKILL.md` →
"Lock down grants on SECURITY DEFINER functions that take raw parameters".

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

## Supabase CLI v2 — JWT keys and ES256

The Supabase CLI v2 exposes keys in the `sb_publishable_*` / `sb_secret_*` format in `supabase status`, but `supabase-js` needs the classic JWT keys (`eyJ...`):

```bash
# ✅ Correct — use the -o env flag to get JWT keys in classic format
supabase status -o env | grep -E "ANON_KEY|SERVICE_ROLE_KEY|JWT_SECRET"
```

**Note:** CLI v2 uses ES256 (ECDSA) to sign tokens. Verify tokens with `supabase.auth.getUser(token)` — never with `jwt.verify(token, jwtSecret)`.

### NestJS integration — JwtAuthGuard for ES256

`passport-jwt` defaults to HS256 and **fails silently** with ES256 tokens (returns 401 with no useful error):

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

## on_auth_user_created trigger — always use upsert in user repository

If the schema defines a trigger that syncs `auth.users → public.users` on INSERT, calling `admin.auth.admin.createUser()` fires the trigger **synchronously**. By the time application code calls `users.create`, the row already exists. A plain `INSERT` fails with duplicate key.

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

---

## Supabase singleton client in NestJS — always disable persistSession

The `supabase.client` (anon key) is a NestJS singleton. With `persistSession` enabled (default), `signInWithPassword()` stores the authenticated session in memory. A subsequent `signIn()` call from a **different request** reuses the stale in-memory session — returning the **wrong `userId`**.

**Fix:** always disable `persistSession` on the anon client in server-side code:

```typescript
// ✅ Correct — stateless: every signIn returns a fresh response
this.client = createClient(url, anon, {
  auth: { autoRefreshToken: false, persistSession: false },
});
```

**Also:** never use `client.auth.signUp()` in a server-side singleton. Use `admin.auth.admin.createUser()` for user creation and `signInWithPassword()` (on the stateless client) for token generation.
