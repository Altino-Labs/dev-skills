# Transactions on Supabase — RPC (Layer 1) and `pg` unit of work (Layer 2)
> Sub-file of the `dev-patterns:clean-architecture` skill (NestJS + Supabase implementation of
> `dev-core:clean-architecture`). Read when a use case must write atomically to more than one
> table/aggregate in a Supabase project.

The decision tree (Layer 0 aggregate redesign → Layer 1 consolidated method → Layer 2 unit of
work → Layer 3 saga) is in `dev-core:clean-architecture` → transactions.md. In this stack:

| Situation | Pattern |
|---|---|
| Aggregate root + children | `repo.save(root)` via Supabase RPC — Layer 1 |
| Two separate aggregates, atomic required | Dedicated RPC per operation — Layer 1 |
| Two separate aggregates, eventual OK | Saga + Outbox — Layer 3 (`dev-core:domain-events`; Supabase outbox: `dev-patterns:domain-events`) |
| Many cross-aggregate combinations | `IUnitOfWork` with `pg` client — Layer 2 |

---

## Layer 1 — Consolidated repository method via Supabase RPC

`supabase-js` goes through PostgREST and does not expose `BEGIN/COMMIT`.
The only way to guarantee atomicity is a PostgreSQL function.

```typescript
// infrastructure/repositories/supabase-order.repository.ts
async save(order: Order): Promise<Order> {
  const { error } = await this.supabase.client.rpc('save_order_with_items', {
    p_order_id:    order.id,
    p_customer_id: order.customerId,
    p_status:      order.status,
    p_items: order.items.map(i => ({
      id: i.id, product_id: i.productId, quantity: i.quantity.value,
      unit_price_amount: i.unitPrice.amount, unit_price_currency: i.unitPrice.currency,
    })),
  });

  if (error) throw new OrderPersistenceException(order.id, error.message);
  return order;
}
```

```sql
-- supabase/migrations/XXXX_fn_save_order_with_items.sql
CREATE OR REPLACE FUNCTION save_order_with_items(
  p_order_id uuid, p_customer_id uuid, p_status text, p_items jsonb
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO orders (id, customer_id, status)
  VALUES (p_order_id, p_customer_id, p_status)
  ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status;

  DELETE FROM order_items WHERE order_id = p_order_id;

  INSERT INTO order_items (id, order_id, product_id, quantity, unit_price_amount, unit_price_currency)
  SELECT (item->>'id')::uuid, p_order_id, (item->>'product_id')::uuid,
         (item->>'quantity')::int, (item->>'unit_price_amount')::numeric, item->>'unit_price_currency'
  FROM jsonb_array_elements(p_items) AS item;
END;
$$;
```

**Name RPCs after the business operation, not the tables they touch:**

```typescript
// ✅ Describes the business operation
await this.supabase.client.rpc('close_order_and_archive_line_items', { p_order_id, p_closed_at });

// ❌ Describes the tables — implementation detail, not business intent
await this.supabase.client.rpc('update_orders_and_items', { ... });
```

## Layer 2 — IUnitOfWork interface (escape hatch for pg client)

> ⚠️ **INCOMPATIBILITY WITH SUPABASE/POSTGREST — READ BEFORE USING**
>
> `PgUnitOfWork` opens a transaction on a `node-postgres` `Pool` connection (`BEGIN/COMMIT`).
> Repository implementations that use `supabase-js` operate on a **completely separate
> connection pool** — their `save()` calls are **not inside the pg transaction**.
>
> What happens when you write:
> ```typescript
> await this.unitOfWork.execute(async () => {
>   await this.accounts.save(updatedSource);  // supabase-js — auto-commits on its own connection
>   await this.accounts.save(updatedTarget);  // supabase-js — auto-commits on its own connection
> });
> // pg BEGIN/COMMIT runs on an empty transaction — no atomicity provided
> ```
> If `save(updatedSource)` succeeds and `save(updatedTarget)` throws, `updatedSource` is
> permanently committed — exactly the inconsistency `IUnitOfWork` was supposed to prevent.
>
> **For Supabase/PostgREST projects: Layer 1 (dedicated RPC) is the ONLY reliable
> atomicity mechanism.** Layer 2 is viable only when repository implementations are
> rewritten to accept and use the `pg.Client` injected by the unit of work — which
> requires a parallel set of pg-based repository implementations alongside the supabase-js ones.

Use only when dedicated RPCs are impractical (too many cross-aggregate permutations)
**and** all repository implementations involved use the `pg.Client` directly.

```typescript
// domain/i-unit-of-work.ts
export const UNIT_OF_WORK = Symbol('UNIT_OF_WORK');

export interface IUnitOfWork {
  execute<T>(work: () => Promise<T>): Promise<T>;
}

// infrastructure/database/pg-unit-of-work.ts
@Injectable()
export class PgUnitOfWork implements IUnitOfWork {
  constructor(private readonly pool: Pool) {}  // node-postgres Pool, not supabase-js

  async execute<T>(work: () => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    await client.query('BEGIN');
    try {
      const result = await work();
      await client.query('COMMIT');
      return result;
    } catch (e) {
      await client.query('ROLLBACK');
      throw e;
    } finally {
      client.release();
    }
  }
}
```

> Prefer a dedicated RPC (Layer 1) before introducing a `pg` client.
> A second connection pool alongside `supabase-js` creates a second authentication path.

**Supabase connection string for `Pool`** — use the Transaction Mode pooler (port 6543),
not the direct connection. Prepared statements are disabled in Transaction Mode; use
parameterized queries only (`$1`, `$2` placeholders).

```bash
# .env.example — required only when Layer 2 is used
DATABASE_POOL_URL=postgresql://postgres.[project-ref]:[db-password]@[region].pooler.supabase.com:6543/postgres?pgbouncer=true
```

```typescript
// infrastructure/database/pg-pool.factory.ts
import { Pool } from 'pg';

export function createPgPool(): Pool {
  return new Pool({
    connectionString: process.env.DATABASE_POOL_URL,
    max: 5,   // keep low — each instance holds connections from the pooler limit
    ssl: { rejectUnauthorized: false },  // required for Supabase cloud
  });
}
```

Register in `AppModule` and inject via `@Inject('PG_POOL')` into `PgUnitOfWork`.

---

## Funds transfer across two aggregates — which variant in this stack

`dev-core:clean-architecture` → domain-services.md shows `TransferFundsUseCase` in two
variants. With Supabase:

**Variant A — Supabase/PostgREST (Layer 1, mandatory):** `supabase-js` repositories use
separate connection pools; `IUnitOfWork` does not provide atomicity over them. The only safe
option is a dedicated PostgreSQL RPC. Add `saveTransfer(source, target)` to
`IAccountRepository` — the implementation calls the RPC (same shape as `save_order_with_items`
above, named after the operation).

**Variant B — `pg` client directly (Layer 2, non-Supabase repositories only):** only when all
repository implementations use `pg.Client` directly — never with `supabase-js`. Inject
`@Inject(UNIT_OF_WORK) private readonly unitOfWork: IUnitOfWork` and publish the event after
`unitOfWork.execute()` returns.
