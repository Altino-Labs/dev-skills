# Repositories — DIP, ISP, N+1, Tenant Scoping, LSP
> Sub-file of the `dev-core:clean-architecture` skill. Read when creating repository interfaces
> or implementations, injecting dependencies, or reviewing query methods.

---

## Repository Interface pattern

```typescript
export const ORDER_REPOSITORY = Symbol('ORDER_REPOSITORY');   // TS DI token — only if the container resolves by token (Java/C#/Python containers resolve by the interface type)

export interface IOrderRepository {
  /**
   * Returns null if not found — never throws NotFoundException.
   * The caller is responsible for the null check and must throw a domain exception if needed.
   */
  findById(id: string): Promise<Order | null>;

  /**
   * Persists a new order (insert) or updates an existing one (upsert by id — or, for an
   * optimistic-lock entity, insert when version = 0 else UPDATE … WHERE version = N).
   * Returns the persisted state — callers must use the returned instance, not the input.
   */
  save(order: Order): Promise<Order>;

  /**
   * Permanently removes the order.
   * Returns the deleted id if found and removed.
   * Returns null if the order does not exist — never throws NotFoundException.
   * The Use Case decides whether to throw OrderNotFoundException on a null result.
   */
  delete(id: string): Promise<string | null>;
}
```

---

## ISP + CQRS — split write model from read model at the repository boundary

> **Absolute criterion:** a repository interface must not exceed **5 methods** — beyond that, the split is mandatory.
> The primary signal below is the practical diagnostic that frequently anticipates this threshold —
> evaluate it before reaching 5, but the mandatory review trigger remains at > 5.

Never add methods indefinitely to the same interface. Evaluate a split when **either**:
- The interface mixes write methods (`save`, `delete`) with list or projection reads (`findByOwner`, `countByStatus`) — this is the primary diagnostic signal. Note: `findById` is **not** a projection read; it belongs on the write side because Command Use Cases need it to load before mutating.
- The total exceeds **5 methods** — the enforceable threshold (a project may set its own in its rules, e.g. `.claude/constitution.md`, if it has one); any result from the tech-lead checklist uses this number.

```typescript
// PageParams, PageMeta and Page<T> are defined once in the wire-contract source (here a TS
// shared-types package) — never redefine locally. Canonical shapes: `dev-core:api-contracts`
// → "Mandatory pagination for list endpoints".
import { PageParams, Page } from '@your-app/shared-types';

// ✅ Write side — state mutations; always present.
// Use Cases that change state inject this.
export interface IOrderRepository {
  /**
   * Returns null if not found — never throws NotFoundException.
   * Used as the fetch-before-mutate step in Command Use Cases.
   */
  findById(id: string): Promise<Order | null>;

  /**
   * Persists a new order (insert) or updates an existing one (upsert by id — or, for an
   * optimistic-lock entity, insert when version = 0 else UPDATE … WHERE version = N).
   * Returns the persisted state — callers must use the returned instance, not the input.
   */
  save(order: Order): Promise<Order>;

  /**
   * Permanently removes the order.
   * Returns the deleted id if found and removed.
   * Returns null if the order does not exist — never throws NotFoundException.
   * The Use Case decides whether to throw OrderNotFoundException on a null result.
   */
  delete(id: string): Promise<string | null>;
}

// ✅ Read side — projections and complex reads; created when they appear.
// Use Cases that only query inject this — no accidental mutation surface.
export interface IOrderQueryRepository {
  /**
   * Returns a paginated list of orders scoped to the given customer.
   * Results are ordered by created_at descending. Returns an empty page when none exist.
   */
  findByCustomer(customerId: string, params: PageParams): Promise<Page<Order>>;

  /**
   * Returns the order with all related entities eager-loaded.
   * Returns null if not found — never throws NotFoundException.
   */
  findWithRelated(id: string): Promise<OrderWithRelated | null>;

  /**
   * Returns a count per status value for the given customer.
   * Keys are OrderStatus enum values; missing statuses are omitted (not zero).
   */
  countByStatus(customerId: string): Promise<Record<string, number>>;
}
```

Each interface gets its own binding (token + provider, if the DI container uses tokens) in the
composition root:

```typescript
// ✅ Query use case — can only read; cannot accidentally mutate
export class ListOrdersByCustomerUseCase {
  constructor(
    private readonly query: IOrderQueryRepository,
  ) {}
}

// ✅ Command use case — injects write side; no complex read methods available
export class PlaceOrderUseCase {
  constructor(
    private readonly orders: IOrderRepository,
    private readonly eventBus: IEventBus,
  ) {}
}
```

---

## N+1 — mandatory anti-pattern check before committing any repository list method

An N+1 is **one extra query per parent row**: a list fetches N rows, then each row triggers
its own query for related data. Two sources:

- **A loop that does I/O per row** — `for`/`map` calling the database (with or without
  `await`; `Promise.all(rows.map(query))` is still N queries).
- **Lazy loading triggered after the query** — an ORM relation accessed per row (`order.items`
  in SQLAlchemy, JPA/Hibernate, EF Core with lazy proxies, Django), often far from the
  repository: in a mapper, a serializer or a template. No loop with `await` is visible.

**Fix:** load the relation in the same query or one batched query — a `JOIN`, or the ORM's
eager loading (SQLAlchemy `selectinload`/`joinedload`, JPA `JOIN FETCH`/`@EntityGraph`, EF
Core `Include`, Django `select_related`/`prefetch_related`).
**Verify** with a test that counts queries for a list of several rows (e.g. Django
`assertNumQueries`, a SQLAlchemy event listener, Hibernate statistics, a counting wrapper
around the data-access client) — the count must not grow with N.

```typescript
// `this.db` stands for whatever data-access client the project uses
// ❌ N+1 — fetches 100 orders then makes 100 queries for items
async findByCustomer(customerId: string): Promise<Order[]> {
  const orders = await this.db.query('SELECT * FROM orders WHERE customer_id = $1', [customerId]);
  for (const row of orders) {
    row.items = await this.db.query('SELECT * FROM order_items WHERE order_id = $1', [row.id]);
    //          ^^^^ 1 query per row — catastrophic at scale
  }
}

// ✅ Single round-trip — JOIN (or the data-access layer's eager/nested load), paginated
async findByCustomer(customerId: string, params: PageParams): Promise<Page<Order>> {
  const offset = (params.page - 1) * params.per_page;

  const rows = await this.db.query(
    `SELECT o.*, i.* FROM orders o
       LEFT JOIN order_items i ON i.order_id = o.id
      WHERE o.id IN (SELECT id FROM orders WHERE customer_id = $1
                      ORDER BY created_at DESC LIMIT $2 OFFSET $3)
      ORDER BY o.created_at DESC`,
    [customerId, params.per_page, offset],
  );
  const [{ count }] = await this.db.query(
    'SELECT count(*) FROM orders WHERE customer_id = $1', [customerId],
  );

  return {
    data: groupRowsByOrder(rows).map(r => this.toEntity(r)),
    meta: {
      page:        params.page,
      per_page:    params.per_page,
      total:       count,
      total_pages: Math.ceil(count / params.per_page),
    },
  };
}
```

---

## DIP — Dependency Inversion Principle

**Rule:** Use Cases must depend on abstractions (interfaces), never on concretions (infrastructure classes).
The flow of control goes down; the flow of source-code dependencies goes up.

```
Use Case ──depends on──→ IRepository        (abstraction — stable)
                              ↑
                         implements
                              │
                   SqlOrderRepository       (concretion — volatile)
```

### The three-part binding

DIP needs three pieces — all present, all connected:

**1. Port (+ token if the DI container needs one) — in `domain/`**
```typescript
// domain/repositories/i-order.repository.ts
export const ORDER_REPOSITORY = Symbol('ORDER_REPOSITORY');   // TS-specific — only if the container resolves by token

export interface IOrderRepository {
  findById(id: string): Promise<Order | null>;
  save(order: Order): Promise<Order>;
}
```

**2. The consumer declares the dependency on the abstraction — in the Use Case**
```typescript
export class ProcessOrderUseCase {
  constructor(
    private readonly orders: IOrderRepository,   // ← abstraction
    private readonly eventBus: IEventBus,        // ← abstraction
  ) {}
  // This file has ZERO imports from infrastructure/ — DIP is satisfied
}
```

**3. The binding — wires abstraction to concretion in the composition root (module / DI registration)**
```typescript
// composition root — framework-free version
const processOrder = new ProcessOrderUseCase(
  new SqlOrderRepository(db),   // ← concretion
  new InMemoryEventBus(),       // ← concretion
);
```

The composition root (module/DI registration) is the only place that knows about both sides.
The stack plugin shows the framework's version of steps 1–3 (e.g. `dev-patterns:clean-architecture`).

### DIP applies to every volatile dependency

| Dependency type | Interface | Symbol | Concrete |
|---|---|---|---|
| Persistence | `IOrderRepository` | `ORDER_REPOSITORY` | `SqlOrderRepository` |
| Event publishing | `IEventBus` | `EVENT_BUS` | `InMemoryEventBus` |
| Email sending | `IEmailService` | `EMAIL_SERVICE` | `<Vendor>EmailService` |
| PDF generation | `IPdfService` | `PDF_SERVICE` | `HeadlessBrowserPdfService` |
| Push notifications | `IPushService` | `PUSH_SERVICE` | `<Vendor>PushService` |
| Cache | `ICacheRepository` | `CACHE_REPOSITORY` | `RedisCacheRepository` |

**Never import the concrete class directly into a Use Case.**

### Anti-patterns

```typescript
// ❌ WRONG — Use Case imports the concrete class directly (DIP violation)
import { SqlOrderRepository } from '../../infrastructure/repositories/sql-order.repository';
export class ProcessOrderUseCase {
  constructor(private readonly orders: SqlOrderRepository) {}
  // Replacing the database technology now requires editing this Use Case
}

// ❌ WRONG — in a token-based DI container, depending on the interface without its token:
// TypeScript interfaces do not exist at runtime, so the container cannot resolve the binding
// (or resolves it by class name — non-deterministic if two classes implement the same interface)

// ✅ CORRECT — three-part DIP binding: port + consumer depends on the port + composition-root binding
export class ProcessOrderUseCase {
  constructor(private readonly orders: IOrderRepository) {}   // bound to SqlOrderRepository in the composition root
}
```

---

## Tenant scoping in repositories

In multi-tenant systems, every method that returns a list **must** include the owner/tenant id.
This enforces isolation at the application layer independently of database-level policies.

```typescript
// ✅ Name declares the scope — reviewer can verify at a glance
findByCustomer(customerId: string): Promise<Order[]>
findActiveByCustomer(customerId: string): Promise<Order[]>
findByCustomerAndStatus(customerId: string, status: OrderStatus): Promise<Order[]>

// findById is justified without tenant — it operates on a global unique key
findById(id: string): Promise<Order | null>        // ✅ global unique key — justified
findAll(): Promise<Order[]>                         // ❌ requires explicit justification + comment
```

```typescript
// ❌ WRONG — list without tenant scope; relies entirely on DB policies
export interface IOrderRepository {
  findActive(): Promise<Order[]>;
}

// ✅ CORRECT — tenant id is part of the method contract
export interface IOrderRepository {
  findActiveByCustomer(customerId: string): Promise<Order[]>;
  findByCustomerAndStatus(customerId: string, status: OrderStatus): Promise<Order[]>;
  findById(id: string): Promise<Order | null>;   // global key — no tenant needed
}
```

**When a tenant parameter is NOT required:**

| Case | Reason |
|---|---|
| `findById(id: string)` | Global unique key already identifies the record |
| `findByToken(token: string)` | Token is already scoped to a single owner |
| Admin use case with explicit comment | Intentional cross-tenant read; must be documented |

> **Security note:** `findById` without a tenant parameter is safe only when resource ownership
> is verified by an authorization check — at the edge (e.g. a resource-membership guard) before
> the Use Case runs, or as a resource-based policy check on the loaded record before the Use Case
> returns or mutates it (`dev-core:auth-security`). Without that check, any caller who knows a UUID can resolve any
> record regardless of ownership — a classic IDOR (Insecure Direct Object Reference) vulnerability.
> Confirm with `appsec` before exposing any unguarded `findById` on a public-facing endpoint.

---

## LSP — Liskov Substitution Principle

Every implementation of a repository interface must honor the same implicit contract.
An in-memory test repository that behaves differently from the production repository is an LSP violation
— the Use Case will pass tests but fail in production.

### Contract violations to avoid

**1. Return value divergence — null vs exception**

```typescript
export interface IOrderRepository {
  // Contract: returns null when not found — never throws
  findById(id: string): Promise<Order | null>;
}

// ✅ CORRECT — production implementation honors the contract
async findById(id: string): Promise<Order | null> {
  const row = await this.db.queryOne('SELECT * FROM orders WHERE id = $1', [id]);
  return row ? this.toEntity(row) : null;
}

// ❌ WRONG — throws when the interface promises null (LSP violation)
async findById(id: string): Promise<Order | null> {
  const row = await this.db.queryOne('SELECT * FROM orders WHERE id = $1', [id]);
  if (!row) throw new OrderNotFoundException(id);  // Use Case's null guard never runs
  return this.toEntity(row);
}
```

**2. Filter divergence — in-memory vs production**

```typescript
// ❌ WRONG — different results from the same method call
// Production: filters active
async findActiveByCustomer(customerId: string): Promise<Order[]> {
  return this.db({ customerId, isActive: true });
}
// In-memory: returns ALL — LSP violation; tests pass, production filters correctly
async findActiveByCustomer(customerId: string): Promise<Order[]> {
  return this.items.filter(o => o.customerId === customerId);  // missing isActive check
}

// ✅ CORRECT — both implementations apply the same filter
async findActiveByCustomer(customerId: string): Promise<Order[]> {
  return this.items.filter(o => o.customerId === customerId && o.isActive);
}
```

### Contract documentation rule

Every repository interface method must document its behavioral contract:

```typescript
export interface IOrderRepository {
  /**
   * Returns only active orders (isActive = true) for the customer.
   * Cancelled and completed orders are excluded. Use findAllByCustomer for the full list.
   */
  findActiveByCustomer(customerId: string): Promise<Order[]>;

  /**
   * Returns null if not found — never throws NotFoundException.
   * The caller is responsible for handling the null case.
   */
  findById(id: string): Promise<Order | null>;
}
```

### LSP self-check — verify before committing any repository

| Check | Pass criterion |
|---|---|
| Return type when not found | All return `null` OR all throw — never mixed across implementations |
| Filter applied | All implementations apply identical filters |
| Sort order | If the interface implies an order, all implementations sort identically |
| Side effects | None — repository methods never publish events or mutate unrelated state |
