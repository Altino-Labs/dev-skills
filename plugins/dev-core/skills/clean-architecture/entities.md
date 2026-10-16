# Entities
> Sub-file of the `dev-core:clean-architecture` skill. Read when creating an entity, implementing
> state transition methods, immutability, boolean flags, output mapping, Law of Demeter,
> or Optimistic Locking.

---

## Entity pattern

An entity has **identity** (tracked by `id`) and **behavior** (methods that enforce invariants).
An entity that only holds data is an **Anemic Domain Model** — the most common DDD anti-pattern.

```typescript
// The canonical Order (fields and factories as in aggregates.md; items omitted here)
export class Order {
  private constructor(
    public readonly id: string,
    public readonly customerId: string,
    private readonly _items: OrderItem[],
    public readonly status: OrderStatus,
    public readonly currency: string,
  ) {}

  // Named-field factory — validation runs once, at creation
  static create(props: { id: string; customerId: string; currency: string }): Order {
    return new Order(props.id, props.customerId, [], OrderStatus.DRAFT, props.currency);
  }

  // For loading from DB — no validation; database constraints already ran
  static reconstitute(props: OrderProps): Order {
    return new Order(props.id, props.customerId, props.items, props.status, props.currency);
  }

  // Behavior enforces invariants — not the use case
  confirm(): Order {
    if (this.status !== OrderStatus.DRAFT)
      throw new OrderNotConfirmableException(this.id, this.status);
    return new Order(this.id, this.customerId, this._items, OrderStatus.CONFIRMED, this.currency);
  }

  cancel(): Order {
    if (this.status === OrderStatus.CANCELLED) throw new OrderAlreadyClosedException(this.id);
    return new Order(this.id, this.customerId, this._items, OrderStatus.CANCELLED, this.currency);
  }
}
```

```typescript
// ❌ ANTI-PATTERN — Anemic Domain Model
export class Order {
  constructor(public readonly id: string, public status: OrderStatus) {}  // mutable from outside
}

// Use case leaks domain logic:
export class ConfirmOrderUseCase {
  async execute(id: string): Promise<void> {
    const order = await this.orders.findById(id);
    if (order.status !== OrderStatus.DRAFT)  // ← invariant in the wrong place; will be duplicated
      throw new OrderNotConfirmableException(id, order.status);
    order.status = OrderStatus.CONFIRMED;    // ← mutation bypasses the entity
    await this.orders.save(order);
  }
}
```

**Detection rule:** if your entity has no methods besides the constructor, ask:
"Where is the invariant being enforced?" If the answer is "in the use case", extract it to the entity.

**Why `create()` must not be called from a repository:**
`create()` always sets initial state (e.g. `status = DRAFT`) — calling it from a repository would reset state for every loaded entity.

---

## State changes only through entity methods — copy-on-write is one way

**The invariant:** an entity's state changes **only through its own methods**, which enforce
the rules. Nothing outside the entity assigns its fields (no public setters, no
`order.status = …` in a use case).

How the method applies the change depends on the persistence style:

- **Copy-on-write (return a new instance)** — idiomatic in TypeScript and functional styles,
  and with immutable types (`dataclasses.replace` on a frozen dataclass, C# records with
  `with`, Java records). State transitions are explicit; the caller can compare before/after.
  The examples in this skill use this style.
- **Mutate inside the method, with private setters** — required for **ORM-tracked entities**
  (SQLAlchemy session, JPA/Hibernate, EF Core, Django models). The ORM tracks the instance it
  loaded (identity map / change tracking); a new instance is not tracked, so its changes are
  not flushed, or it collides with the tracked one. The method still validates first and is
  still the only way to change state.

```typescript
// ❌ WRONG — state changed from outside; the invariant lives in the caller
order.status = OrderStatus.CONFIRMED;

// ✅ Copy-on-write style — returns a new instance; caller replaces their reference explicitly
confirm(): Order {
  if (this.status !== OrderStatus.DRAFT)
    throw new OrderNotConfirmableException(this.id, this.status);
  return new Order(this.id, this.customerId, this._items, OrderStatus.CONFIRMED, this.currency);
}

// ✅ ORM-tracked style — same guard, mutates through a private setter
confirm(): void {
  if (this._status !== OrderStatus.DRAFT)
    throw new OrderNotConfirmableException(this.id, this._status);
  this._status = OrderStatus.CONFIRMED;
}
```

**Copy-on-write aggregates with child collections — spread, never push:**

In TS, `readonly` on an array protects the *reference*, not the *contents* (the same holds for
Java `final`, C# `readonly` and Python attribute conventions on a mutable list).
`this._items.push(x)` compiles without error and silently mutates the aggregate. Expose an
immutable view (`ReadonlyArray`, `List.copyOf`, `IReadOnlyList`, a tuple) and copy on change.
Spread creates a new array and forces a new root instance.

```typescript
// ❌ WRONG — push mutates the internal array; readonly does not prevent this
addItem(id: string, productId: string, quantity: number, unitPrice: Money): Order {
  this._items.push(OrderItem.create({ id, productId, quantity, unitPrice }));
  return this;  // same reference; caller cannot tell state changed
}

// ✅ CORRECT — spread creates a new array; root returns a new instance
addItem(id: string, productId: string, quantity: number, unitPrice: Money): Order {
  if (this.status !== OrderStatus.DRAFT)
    throw new OrderNotEditableException(this.id);
  const item = OrderItem.create({ id, productId, quantity, unitPrice });
  return new Order(this.id, this.customerId, [...this._items, item], this.status, this.currency);
}
```

**Enforcement checklist before committing any entity:**
- [ ] No field can be assigned from outside the entity (TS `readonly`, Java `final`, C#
      `init`/private setters, Python properties without setters, Go unexported fields)
- [ ] Every state change goes through an entity method that validates first
- [ ] Copy-on-write style: every state-changing method returns a new instance, and collection
      changes use spread (`[...arr, x]`), never `push`/`splice`
- [ ] ORM-tracked style: methods mutate the loaded instance (never replace it), and child
      collections are changed only through the aggregate root's methods

---

## Boolean state flags — always from the database, never computed from dates

```typescript
// ❌ WRONG — getter computed from dates; boundary ambiguity on the close day
get isActive(): boolean {
  return !this.endDate || this.endDate >= today;
}

// ✅ CORRECT — stored field from the DB column
export interface SubscriptionProps {
  // ...
  isActive: boolean;  // reads row.is_active ?? true
}
```

**Repository close method — must write BOTH the date and the flag:**

```sql
-- ❌ WRONG — only sets end_date; is_active stays true forever
UPDATE subscriptions SET end_date = $2 WHERE id = $1;

-- ✅ CORRECT
UPDATE subscriptions SET end_date = $2, is_active = false WHERE id = $1;
```

**Record → entity mapping in the repository — always pass the DB column, with a safe default:**

```typescript
return Subscription.reconstitute({
  id: row.id,
  // ...
  isActive: row.is_active ?? true,  // explicit default for rows created before the column existed
});
```

---

## Entity → Output mapping belongs to the Use Case, never the entity

`entity.toDto()` is a Dependency Rule violation: the domain layer would import a type from the interface layer.

```typescript
// ❌ WRONG — entity knows about output DTOs
export class Order {
  toDto(): OrderResponse { return { id: this.id, status: this.status }; }
}

// ✅ CORRECT — Use Case owns the mapping; entity stays pure
export class CloseOrderUseCase {
  private toOutput(order: Order): OrderResponse {
    return { id: order.id, customer_id: order.customerId, status: order.status };
  }
}
```

**Rule:** if you feel the urge to write `entity.toDto()`, write `useCase.toOutput(entity)` instead.

---

## Law of Demeter — one level of object graph

> "Talk to friends, not to strangers."
> — Ian Holland, *Demeter Project* (1987); popularized by Martin, *Clean Code*, ch. 6

A method should only call methods of objects it directly holds — never chain through
intermediate objects to reach a distant property.

### Detection rule

Any chain `a.b.c` where `a` is a domain entity is likely a violation.
Ask: *"Should this computation be a method on `a`?"* — if yes, move it there.

**Exception:** `entity.voField.value` — one hop into a Value Object — is acceptable.
Value Objects are value containers; accessing `.value` is their purpose.

### Canonical example — `Order` aggregate (Evans, *Domain-Driven Design*, ch. 6)

```typescript
// ❌ VIOLATION — Use Case traverses 3 levels of object graph
private toOutput(order: Order): OrderOutput {
  return {
    id:           order.id,
    total_amount: order.items                          // hop 1: Order → items[]
                    .reduce((sum, item) =>
                      sum + item.unitPrice.amount,     // hop 2: item → unitPrice (VO)
                      0),                             // hop 3: unitPrice → amount
  };
  // caller → order → items[i] → unitPrice → amount
  // Adding a discount rule now forces changes here and in every other caller
}

// ✅ CORRECT — Order exposes the aggregate computation; callers ask, not dig
// In the entity:
export class Order {
  get total(): Money {
    return this._items.reduce(
      (sum, item) => sum.add(item.subtotal),   // subtotal is OrderItem's own method
      Money.zero(this.currency),
    );
  }
}

// In the Use Case — one level, no traversal:
private toOutput(order: Order): OrderOutput {
  return {
    id:           order.id,
    total_amount: order.total.amount,   // order → total (Money VO) → amount
  };
}
```

```typescript
// ❌ VIOLATION — controller digs into nested result
const city = customer.address.city.value;   // 3 hops

// ✅ CORRECT — entity exposes what the caller needs
const city = customer.cityName;             // 1 hop; city derivation is the entity's concern
```

### Why the entity method is the right fix

Putting the computation in `Order.total` means:
- **Single change point:** adding a discount rule modifies only the entity.
- **Testable in isolation:** `order.total` can be unit-tested without a Use Case.
- **No duplicated logic:** every caller that needs the total uses the same method.

If the computation only ever appears in one Use Case, a private `toOutput()` helper
is acceptable. Extract to the entity when a second Use Case needs the same traversal.

---

## Optimistic Locking

Apply when an entity can be edited by more than one user simultaneously.
Without it: the second write silently overwrites the first — the "lost update" problem.

**With an ORM, use its native mechanism** — JPA `@Version`, EF Core concurrency token /
`RowVersion`, SQLAlchemy `version_id_col`, and equivalents. They add the `WHERE version = N`
and the increment for you and raise their own conflict exception (translate it to
`OptimisticLockException` in the repository). The hand-written repository protocol below is
for data access **without an ORM** (SQL client, query builder, PostgREST). The use-case check
of the client's version ("Use case" below) applies in both cases.

**When to apply:**

| Signal | Apply? |
|---|---|
| Multiple users can open and edit the same record simultaneously | ✅ Yes |
| Entity has an "edit" form accessible to more than one role | ✅ Yes |
| Records are append-only (each save creates a new row) | ❌ No |
| Entity is written only by automated processes | ❌ No |

### Entity — add `version: number` to the props

```typescript
export interface InvoiceProps {
  id: string;
  customerId: string;
  description: string;
  issuedAt: Date;
  version: number;        // optimistic lock field
}

export class Invoice {
  private constructor(
    public readonly id: string,
    public readonly customerId: string,
    public readonly description: string,
    public readonly issuedAt: Date,
    public readonly version: number,
  ) {}

  static create(props: { id: string; customerId: string; description: string }): Invoice {
    return new Invoice(props.id, props.customerId, props.description, new Date(), 0);  // version starts at 0
  }

  static reconstitute(props: InvoiceProps): Invoice {
    return new Invoice(props.id, props.customerId, props.description, props.issuedAt, props.version);
  }

  updateDescription(description: string): Invoice {
    return new Invoice(this.id, this.customerId, description, this.issuedAt, this.version);
    // version does not change inside the entity — the DB increments it on write
  }
}
```

### Use case — compare the client's version first

Two different races, two guards:

1. **Read-edit window** (minutes): the client loaded version N, the user edited the form, and
   someone else saved meanwhile. Only the client knows which version it edited, so the use case
   compares `input.version` with the loaded entity's version and throws **before** applying
   changes. Comparing only the loaded version against itself would never detect this.
2. **Load-save race** (milliseconds): another write lands between `findById` and `save`. The
   repository's `WHERE version = N` (or the ORM's version check) catches it.

```typescript
async execute(input: UpdateInvoiceInput): Promise<UpdateInvoiceOutput> {
  const invoice = await this.invoices.findById(input.id);
  if (!invoice) throw new InvoiceNotFoundException(input.id);

  // Guard 1 — the version the client edited must still be the current one
  if (input.version !== invoice.version)
    throw new OptimisticLockException('Invoice', invoice.id, input.version);

  const updated = invoice.updateDescription(input.description);
  const saved   = await this.invoices.save(updated);   // Guard 2 — WHERE version = N in save()
  return this.toOutput(saved);                          // includes the new version
}
```

### Domain exception

`OptimisticLockException` is a domain-level conflict exception, defined once in the project's
shared exception hierarchy — definition in `dev-core:error-handling` ("`OptimisticLockException`
— concurrent-edit conflict"); for NestJS also `dev-patterns:error-handling`.
Do not redefine it per module.
The interface layer maps it to the transport's conflict response (HTTP 409).

```typescript
// Usage — thrown by the use case (client version ≠ loaded version) and by the repository
// when the conditional UPDATE matches zero rows:
throw new OptimisticLockException('Invoice', invoice.id, invoice.version);
// → HTTP 409  { error: { code: 'OPTIMISTIC_LOCK_CONFLICT', message: '...' } }
```

### Repository — conditional UPDATE checks the version (no ORM)

Here `save()` is **not** an upsert: `version === 0` inserts, anything else is a conditional
update. The conditional `UPDATE ... WHERE id = $1 AND version = $2` matching **zero rows** is the
conflict signal. How the data-access layer reports "zero rows" varies (an affected-row count of
0, an empty result, a `null` record) — whatever it is, the repository must check it explicitly.

**Invariant:** `version === 0` signals a **new entity** — one created via `Entity.create()` and
not yet persisted. It must **never** be used with `reconstitute()` for an entity that already
exists in the database. Rows already in the database are by definition persisted; the migration
below must backfill them to `version = 1` in the same transaction as the column addition.

```typescript
// `this.db` stands for whatever data-access client the project uses
async save(invoice: Invoice): Promise<Invoice> {
  // version === 0 means the entity was just created via Invoice.create() and
  // has never been persisted. reconstitute() always sets version > 0 from the DB.
  if (invoice.version === 0) {
    const row = await this.db.insertReturning('invoices', {
      id: invoice.id, customer_id: invoice.customerId,
      description: invoice.description, version: 1,
    });
    return this.toEntity(row);
  }

  const row = await this.db.updateReturning(
    'invoices',
    { description: invoice.description, version: invoice.version + 1 },
    { id: invoice.id, version: invoice.version },   // ← the lock check: WHERE id = ? AND version = ?
  );

  if (!row) throw new OptimisticLockException('Invoice', invoice.id, invoice.version);
  // no row = WHERE matched 0 rows = another user saved a newer version

  return this.toEntity(row);
}
```

Infrastructure errors from the data-access client (connection, constraint violations) are
translated to a persistence exception (e.g. `InvoicePersistenceException`) — a different
failure from the lock conflict, and checked separately.

### Migration — version column

Two steps in the same migration — never split them:

```sql
-- Step 1: add the column; existing rows receive DEFAULT 0
ALTER TABLE invoices
  ADD COLUMN version integer NOT NULL DEFAULT 0;

-- Step 2: mandatory backfill — existing rows are already persisted and must never
-- be mistaken for new entities. version = 0 is reserved for Entity.create() output only.
-- Skipping this step causes save() to INSERT instead of UPDATE for every pre-existing row.
UPDATE invoices SET version = 1 WHERE version = 0;
```

**Why both steps are required:** `ADD COLUMN ... DEFAULT 0` sets every existing row to `version = 0`.
The `save()` method treats `version === 0` as "never persisted → INSERT path". Without the backfill,
the first PATCH on any pre-existing invoice silently creates a duplicate row instead of updating it.

### Frontend contract

- Every GET for a locked entity must include `version` in the payload.
- Every PATCH must send `version` back.
- On HTTP 409: show "This record was changed by another user. Reload and try again." — do not retry silently.

### Anti-patterns

```sql
-- ❌ WRONG — UPDATE without version check: second save silently overwrites first
UPDATE invoices SET description = $2 WHERE id = $1;
```

```typescript
// ❌ WRONG — handling the client error but not the zero-rows result
const result = await this.db.updateReturning('invoices', { ... }, { id, version });
if (result.error) throw ...;
// Missing: if no row was updated → throw new OptimisticLockException(...)

// ✅ CORRECT — always check both the error AND the zero-rows result after a conditional UPDATE
if (result.error) throw new InvoicePersistenceException(id, result.error.message);
if (!result.row)  throw new OptimisticLockException('Invoice', id, version);
```

A stack-specific implementation of this `save()` lives in the stack plugin (e.g. `dev-patterns:clean-architecture`).
