# Supabase repository implementations
> Sub-file of the `dev-patterns:clean-architecture` skill (NestJS + Supabase implementation of
> `dev-core:clean-architecture`). Read when writing or reviewing a repository (or guard, or
> ACL adapter) that talks to Supabase through supabase-js / PostgREST.

The rules (contracts, LSP, N+1, tenant scoping, optimistic locking, idempotent saves) are in
`dev-core:clean-architecture` → repositories.md, entities.md and idempotency.md. This file shows
their supabase-js form.

---

## Mapping rows — always pass the DB column, with a safe default

The repository maps each row with the entity's `fromRow` (see SKILL.md) or a private
`mapRow`; boolean state flags come from their column, never computed from dates:

```typescript
return new EntityName(
  row.id,
  // ...
  row.is_active ?? true,  // explicit default for rows created before the column existed
);
```

**Close method — must write BOTH the date and the flag:**

```typescript
// ❌ WRONG — only sets end_date; is_active stays true forever
.update({ end_date: endDate })

// ✅ CORRECT
.update({ end_date: endDate, is_active: false })
```

## Error handling

Every supabase-js call returns `{ data, error }` — it does not throw. Check `error` on every
call and translate it into a domain persistence exception (`OrderPersistenceException`,
`InvoicePersistenceException`, ...) carrying `error.message`; never let the raw error object
leave the repository. A `null` `data` is a separate signal (not found, or zero rows matched)
and is handled per the method's contract — see the optimistic-lock `save()` below.

---

## Optimistic Locking — conditional UPDATE with supabase-js

`supabase-js` returns `{ data: null, error: null }` when the `WHERE version = N` clause matches
zero rows — that null is the conflict signal. (Entity, invariant `version === 0` = new entity,
the version-column migration and the frontend contract: dev-core entities.md, "Optimistic
Locking". `OptimisticLockException` itself is defined in `dev-patterns:error-handling`,
`domain/exceptions/app.exception.ts` — concept in `dev-core:error-handling`.)

```typescript
async save(invoice: Invoice): Promise<Invoice> {
  // version === 0 means the entity was just created via Invoice.create() and
  // has never been persisted. reconstitute() always sets version > 0 from the DB.
  if (invoice.version === 0) {
    const { data, error } = await this.supabase
      .from('invoices')
      .insert({ id: invoice.id, customer_id: invoice.customerId,
                description: invoice.description, version: 1 })
      .select().single();

    if (error) throw new InvoicePersistenceException(invoice.id, error.message);
    return this.mapRow(data);
  }

  const { data, error } = await this.supabase
    .from('invoices')
    .update({ description: invoice.description, version: invoice.version + 1 })
    .eq('id', invoice.id)
    .eq('version', invoice.version)   // ← the lock check
    .select().single();

  if (error) throw new InvoicePersistenceException(invoice.id, error.message);
  if (!data)  throw new OptimisticLockException('Invoice', invoice.id, invoice.version);
  // null data = WHERE matched 0 rows = another user saved a newer version

  return this.mapRow(data);
}
```

### Anti-patterns

```typescript
// ❌ WRONG — UPDATE without version check: second save silently overwrites first
await this.supabase.from('invoices').update({ description }).eq('id', id);

// ❌ WRONG — checking null only after error check
const { data, error } = await supabase.update(...).select().single();
if (error) throw ...;
// Missing: if (!data) throw new OptimisticLockException(...)

// ✅ CORRECT — always check both error AND null data after conditional UPDATE
if (error) throw new InvoicePersistenceException(id, error.message);
if (!data)  throw new OptimisticLockException('Invoice', id, version);
```

---

## Pattern B — upsert (client-supplied id)

supabase-js `.upsert()` cannot add the ownership guard — on conflict it would overwrite
`customer_id` with the caller's (IDOR, dev-core idempotency.md Pattern B). Run the owner-guarded
upsert as an RPC:

```sql
CREATE FUNCTION save_order(p_id uuid, p_customer_id uuid, p_currency text, p_status text)
RETURNS SETOF orders LANGUAGE sql AS $$
  INSERT INTO orders (id, customer_id, currency, status)
  VALUES (p_id, p_customer_id, p_currency, p_status)
  ON CONFLICT (id) DO UPDATE
    SET currency = EXCLUDED.currency, status = EXCLUDED.status   -- never customer_id
    WHERE orders.customer_id = EXCLUDED.customer_id
  RETURNING *;
$$;
```

```typescript
// Repository: owner-guarded upsert — never a plain insert, never .upsert() on this table
async save(order: Order): Promise<Order> {
  const { data, error } = await this.supabase
    .rpc('save_order', { p_id: order.id, p_customer_id: order.customerId, p_currency: order.currency, p_status: order.status })
    .maybeSingle();

  if (error) throw new OrderPersistenceException(order.id, error.message);
  if (!data)  throw new OrderNotFoundException(order.id);   // id belongs to another customer
  return this.toEntity(data);
}

// Row → entity: named props into the canonical Order factory (dev-core clean-architecture)
private toEntity(row: OrderRow): Order {
  return Order.reconstitute({
    id:         row.id,
    customerId: row.customer_id,
    items:      (row.items ?? []).map(toOrderItem),   // when the select embeds order_items
    status:     row.status as OrderStatus,
    currency:   row.currency,
  });
}
```

When the entity also uses Optimistic Locking, `save()` must NOT be this upsert — use the OL
`save()` above (see dev-core idempotency.md, "Incompatibility with Optimistic Lock"):

```typescript
// Repository uses OL save() — NOT Pattern B's upsert
async save(order: Order): Promise<Order> {
  if (order.version === 0) {
    const { data, error } = await this.supabase
      .from('orders').insert({ id: order.id, ..., version: 1 }).select().single();
    if (error) throw new OrderPersistenceException(order.id, error.message);
    return this.mapRow(data);
  }
  const { data, error } = await this.supabase
    .from('orders').update({ ..., version: order.version + 1 })
    .eq('id', order.id).eq('version', order.version).select().single();
  if (error) throw new OrderPersistenceException(order.id, error.message);
  if (!data)  throw new OptimisticLockException('Order', order.id, order.version);
  return this.mapRow(data);
}
```

```typescript
// ❌ WRONG — plain insert: double-click or retry creates two records
async save(order: Order): Promise<Order> {
  await this.supabase.from('orders').insert({ id: order.id, ... });
}
```

---

## N+1 — use a PostgREST nested select

```typescript
// ❌ N+1 — fetches 100 orders then makes 100 queries for items
async findByCustomer(customerId: string): Promise<Order[]> {
  const orders = await this.supabase.from('orders').select('*').eq('customer_id', customerId);
  for (const row of orders.data) {
    row.items = await this.supabase.from('order_items').select('*').eq('order_id', row.id);
    //          ^^^^ 1 query per row — catastrophic at scale
  }
}

// ✅ JOIN in a single query — PostgREST nested select
async findByCustomer(customerId: string, params: PageParams): Promise<Page<Order>> {
  const from = (params.page - 1) * params.per_page;
  const to   = from + params.per_page - 1;

  const { data, count } = await this.supabase
    .from('orders')
    .select('*, items:order_items(*)', { count: 'exact' })
    .eq('customer_id', customerId)
    .order('created_at', { ascending: false })
    .range(from, to);

  return {
    data: (data ?? []).map(row => this.toEntity(row)),
    meta: {
      page:        params.page,
      per_page:    params.per_page,
      total:       count ?? 0,
      total_pages: Math.ceil((count ?? 0) / params.per_page),
    },
  };
}
```

---

## LSP — `maybeSingle()` honors the "null when not found" contract

```typescript
// ✅ CORRECT — production implementation honors the contract
async findById(id: string): Promise<Order | null> {
  const { data } = await this.supabase.from('orders').select('*').eq('id', id).maybeSingle();
  return data ? this.mapRow(data) : null;
}

// ❌ WRONG — throws when the interface promises null (LSP violation)
async findById(id: string): Promise<Order | null> {
  const { data } = await this.supabase.from('orders').select('*').eq('id', id).maybeSingle();
  if (!data) throw new OrderNotFoundException(id);  // Use Case's null guard never runs
  return this.mapRow(data);
}
```

---

## Guards — simple queries in PostgREST

```typescript
// ✅ Correct — direct columns only
.from('tenant_members').select('role').eq('tenant_id', id).eq('user_id', uid).single()

// ❌ Wrong — invalid join alias in PostgREST
.select('role, user_type: users(user_type)')
```

## Column-to-column comparison does not work in PostgREST

```typescript
// ❌ PostgREST compares with the literal string 'threshold_column', not the column value
.filter('count', 'lte', 'threshold_column')

// ✅ Filter in JS when the volume per record is low and bounded
const { data } = await client.from('items').select('*').eq('is_active', true);
return data.filter(r => r.stock_count <= r.stock_alert_threshold);
```

---

## ACL — Supabase Auth behind `IAuthProvider`

The ACL concept and the `IAuthProvider` port are in dev-core acl.md. The Supabase adapter:

```typescript
// infrastructure/auth/supabase-auth.provider.ts — ACL: translates Supabase → domain
@Injectable()
export class SupabaseAuthProvider implements IAuthProvider {
  constructor(private readonly supabase: SupabaseService) {}

  async register(email: string, password: string, fullName: string): Promise<AuthResult> {
    const { data, error } = await this.supabase.client.auth.admin.createUser({
      email, password, user_metadata: { full_name: fullName },
    });
    if (error || !data.user) throw new UserRegistrationException(email, error?.message);

    // Translation: Supabase model → domain model. External field names stay here.
    return {
      user_id:   data.user.id,
      email:     data.user.email!,
      full_name: data.user.user_metadata?.full_name ?? null,
    };
  }

  async verifyToken(token: string): Promise<AuthResult | null> {
    const { data, error } = await this.supabase.client.auth.getUser(token);
    if (error || !data.user) return null;
    return { user_id: data.user.id, email: data.user.email!, full_name: data.user.user_metadata?.full_name ?? null };
  }
}
```

Wire it with `{ provide: AUTH_PROVIDER, useClass: SupabaseAuthProvider }` (token
`AUTH_PROVIDER = Symbol('AUTH_PROVIDER')` declared next to `IAuthProvider`); the use case
injects `@Inject(AUTH_PROVIDER) private readonly auth: IAuthProvider` and has zero Supabase
imports. `SupabaseOrderRepository` is DIP; `SupabaseAuthProvider` is both DIP and ACL.

ACL violations to look for in this stack — inside a use case or entity:

```typescript
// ❌ External SDK import inside a Use Case
import { SupabaseClient } from '@supabase/supabase-js';
import Resend from 'resend';

// ❌ External field naming convention reaching the domain
data.user.user_metadata.full_name   // Supabase model inside Use Case
response.data[0].email_address      // Resend model inside Use Case
```

Adapters live in `infrastructure/auth/supabase-auth.provider.ts` and
`infrastructure/email/resend-email.provider.ts`.
