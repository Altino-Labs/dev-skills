# Cross-Aggregate Writes and Transactions
> Sub-file of the `dev-core:clean-architecture` skill. Read when a Use Case needs to write to two or more
> repositories and you need to decide the right atomicity strategy.

---

## Decision tree

Run this tree before reaching for transactions. Most cases are resolved by correcting the aggregate boundary.

> **Start here — Layer 0:** before applying any layer, ask: *"Are these objects always written together?"*
> If YES → they form a single aggregate. Collapse the repositories (see Layer 0 below). This resolves ~80% of cases.
> Only continue to the tree below when the aggregates are genuinely separate.

```
Use Case writes to 2+ repositories
           │
           ▼
Same aggregate (root + children)?      ─── YES ──→ Layer 1: repo.save(root) in one DB transaction
           │
          NO
           │
           ▼
Must both writes be atomic?
           │
          YES
           │
           ▼
Number of cross-aggregate combinations is small and stable?
           │                                          │
          YES                                        NO (many permutations — dedicated
           │                                              methods become impractical)
           ▼                                          │
Layer 1: dedicated consolidated                      ▼
repository method per operation          Layer 2: IUnitOfWork port
                                         (escape hatch — read Layer 2 warning below)
           │
          NO (eventual consistency acceptable)
           │
           ▼
           └──→ Layer 3: Saga + Outbox (see `dev-core:domain-events`)
```

## Layer 0 — Redesign the aggregate boundary (resolves ~80% of cases)

If two repositories are always written together, they likely form a single aggregate.

```typescript
// ❌ SYMPTOM — use case writes to two separate repositories
await this.orderRepo.save(order);
await this.orderItemRepo.save(orderItem);  // item cannot exist without its parent order

// ✅ DIAGNOSIS — OrderItem is a child of Order; collapse into one aggregate
// OrderRepository.save(order) persists root + children atomically in one DB transaction
```

## Layer 1 — Consolidated repository method backed by one DB transaction

One repository method performs every write of the operation inside a single database
transaction. How the transaction is opened depends on the data-access layer:

- the repository opens `BEGIN … COMMIT` itself on one connection, or
- when the data-access client cannot run multi-statement transactions from the application
  (each call auto-commits on its own connection), the repository calls a **stored procedure /
  database function** that does all the writes — the database runs it as one transaction.
  The stack plugin shows the concrete version (e.g. `dev-patterns:clean-architecture`).

```typescript
// infrastructure/repositories/sql-order.repository.ts — `this.db` = the project's data-access client
async save(order: Order): Promise<Order> {
  await this.db.transaction(async (tx) => {
    await tx.query(
      `INSERT INTO orders (id, customer_id, status) VALUES ($1, $2, $3)
       ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status`,
      [order.id, order.customerId, order.status],
    );
    await tx.query('DELETE FROM order_items WHERE order_id = $1', [order.id]);
    for (const i of order.items) {
      await tx.query(
        `INSERT INTO order_items (id, order_id, product_id, quantity, unit_price_amount, unit_price_currency)
         VALUES ($1, $2, $3, $4, $5, $6)`,
        [i.id, order.id, i.productId, i.quantity, i.unitPrice.amount, i.unitPrice.currency],
      );
    }
  });   // any failure → ROLLBACK; the repository translates it to OrderPersistenceException
  return order;
}
```

**Name consolidated methods (and stored procedures) after the business operation, not the
tables they touch:**

```typescript
// ✅ Describes the business operation
await this.orders.closeAndArchiveLineItems(orderId, closedAt);   // procedure: close_order_and_archive_line_items

// ❌ Describes the tables — implementation detail, not business intent
await this.orders.updateOrdersAndItems(...);                      // procedure: update_orders_and_items
```

## Layer 2 — IUnitOfWork port (escape hatch)

> ⚠️ **A UNIT OF WORK ONLY WORKS IF EVERY REPOSITORY RUNS INSIDE IT — READ BEFORE USING**
>
> The unit of work opens a transaction on **one connection**. Repository implementations that
> use a **different client or connection pool** (e.g. an HTTP-based data API, or a second pool)
> are **not inside that transaction** — each of their writes auto-commits on its own connection.
>
> What happens when you write:
> ```typescript
> await this.unitOfWork.execute(async () => {
>   await this.accounts.save(updatedSource);  // separate client — auto-commits on its own connection
>   await this.accounts.save(updatedTarget);  // separate client — auto-commits on its own connection
> });
> // BEGIN/COMMIT runs on an empty transaction — no atomicity provided
> ```
> If `save(updatedSource)` succeeds and `save(updatedTarget)` throws, `updatedSource` is
> permanently committed — exactly the inconsistency `IUnitOfWork` was supposed to prevent.
>
> **If the repositories cannot join the unit of work's transaction, Layer 1 (consolidated
> method / stored procedure) is the ONLY reliable atomicity mechanism.** Layer 2 is viable
> only when the repository implementations involved accept and use the transaction/connection
> the unit of work opened — which may require a parallel set of repository implementations.

Use only when dedicated consolidated methods are impractical (too many cross-aggregate
permutations) **and** all repository implementations involved run on the unit of work's
transaction.

```typescript
// domain/i-unit-of-work.ts — the port
export interface IUnitOfWork {
  execute<T>(work: () => Promise<T>): Promise<T>;
}

// infrastructure/database/sql-unit-of-work.ts — the adapter
export class SqlUnitOfWork implements IUnitOfWork {
  constructor(private readonly pool: ConnectionPool) {}

  async execute<T>(work: () => Promise<T>): Promise<T> {
    const conn = await this.pool.connect();
    await conn.query('BEGIN');
    try {
      const result = await work();   // repositories must use `conn` (e.g. via a transaction context)
      await conn.query('COMMIT');
      return result;
    } catch (e) {
      await conn.query('ROLLBACK');
      throw e;
    } finally {
      conn.release();
    }
  }
}
```

> Prefer a consolidated method (Layer 1) before introducing a second database client or pool
> just for the unit of work — a second pool alongside the main client also creates a second
> authentication/connection path to secure and size.

Publish domain events **after** the unit of work commits — never inside `execute()` (see
[domain-services.md](domain-services.md), "Why the event is published outside
`unitOfWork.execute()`").

## Layer 3 — Saga with compensation (eventual consistency)

When two aggregates can tolerate a brief inconsistency window, a Saga is preferable: each
step commits on its own, and a failure triggers **compensating actions** that undo the
already-committed steps. The Outbox Pattern in `dev-core:domain-events` (`advanced-delivery.md`;
for NestJS + Supabase also `dev-patterns:domain-events`) makes Sagas durable across process restarts.

**Decision rule — choose atomicity vs eventual consistency:**
- Inconsistency creates a financial or irreversible consequence (payment charged without matching order) → atomicity required → use Layer 1.
- Inconsistency is a recoverable inconvenience (push notification delayed by seconds) → Saga is acceptable → use Layer 3.

## Quick reference

| Situation | Pattern |
|---|---|
| Aggregate root + children | `repo.save(root)` in one DB transaction — Layer 1 |
| Two separate aggregates, atomic required | Dedicated consolidated method per operation — Layer 1 |
| Two separate aggregates, eventual OK | Saga + Outbox — Layer 3 |
| Many cross-aggregate combinations | `IUnitOfWork` — Layer 2 (only if all repositories join its transaction) |
