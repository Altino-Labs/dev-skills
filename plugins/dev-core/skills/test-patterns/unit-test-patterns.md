# Unit Test Patterns
> Sub-file of the `dev-core:test-patterns` skill. Read when writing unit tests for Use Cases,
> test factories, or entities with optimistic locking. Examples are framework-free TypeScript
> (see the note at the top of SKILL.md); the stack's mock helpers live in the stack plugin
> (e.g. `dev-patterns:test-patterns`).

---

## Use Case test pattern

A Use Case test wires the use case to **fakes** of its ports — in-memory repositories, a
capturing event bus, stub gateways — and asserts on the result, the fakes' state and the
captured events. The stack's mocking helper (an auto-mock of an interface) is an acceptable
substitute when the test only needs "was it called with X"; a fake is preferable whenever the
test depends on state (find after save, version checks, filters).

```typescript
// test/fakes/in-memory-order.repository.ts
export class InMemoryOrderRepository implements IOrderRepository {
  private readonly items = new Map<string, Order>();

  async findById(id: string): Promise<Order | null> {
    return this.items.get(id) ?? null;           // same contract as production: null, never throws
  }

  async save(order: Order): Promise<Order> {
    this.items.set(order.id, order);
    return order;
  }
}
```

```typescript
describe('ProcessOrderUseCase', () => {
  let orders:   InMemoryOrderRepository;
  let eventBus: CapturingEventBus;
  let useCase:  ProcessOrderUseCase;

  beforeEach(() => {
    orders   = new InMemoryOrderRepository();
    eventBus = new CapturingEventBus();
    useCase  = new ProcessOrderUseCase(orders, eventBus);
  });

  it('should process the order and publish order.processed when the order is confirmed', async () => {
    // Arrange
    const order = OrderFactory.confirmed();
    await orders.save(order);
    // Act
    const result = await useCase.execute({ orderId: order.id });
    // Assert
    expect(result.status).toBe('PROCESSED');
    expect((await orders.findById(order.id))!.status).toBe('PROCESSED');
    // Use the EventNames constant — never a string literal (see `dev-core:domain-events` → `event-catalog.md`)
    expect(eventBus.capturedOf(EventNames.ORDER_PROCESSED)).toHaveLength(1);
  });

  it('should throw OrderNotFoundException when the order does not exist', async () => {
    await expect(useCase.execute({ orderId: 'missing' })).rejects.toThrow(OrderNotFoundException);
    expect(eventBus.captured).toHaveLength(0);
  });

  it('should throw OrderNotConfirmedException when the order is still a draft', async () => {
    const order = OrderFactory.draft();
    await orders.save(order);
    await expect(useCase.execute({ orderId: order.id })).rejects.toThrow(OrderNotConfirmedException);
  });
});
```

## Test factories — always use, never build test objects manually

```typescript
// test/factories/order.factory.ts
export class OrderFactory {
  // Every named state is built with reconstitute() — the state a repository would return
  private static build(overrides?: Partial<OrderProps>): Order {
    return Order.reconstitute({
      id:         randomUUID(),
      customerId: randomUUID(),
      items:      [],
      status:     OrderStatus.DRAFT,
      currency:   'EUR',
      ...overrides,
    });
  }

  // Named state for each meaningful business condition
  static draft(overrides?: Partial<OrderProps>): Order {
    return OrderFactory.build({ ...overrides, status: OrderStatus.DRAFT });
  }

  static confirmed(overrides?: Partial<OrderProps>): Order {
    return OrderFactory.build({ ...overrides, status: OrderStatus.CONFIRMED });
  }

  static cancelled(overrides?: Partial<OrderProps>): Order {
    return OrderFactory.build({ ...overrides, status: OrderStatus.CANCELLED });
  }
}

// test/factories/customer.factory.ts
export class CustomerFactory {
  static valid(overrides?: Partial<{ id: string; email: string; fullName: string }>): Customer {
    return Customer.reconstitute({
      id:       overrides?.id ?? randomUUID(),
      email:    Email.reconstitute(overrides?.email ?? 'john.doe@example.com'),
      fullName: overrides?.fullName ?? 'John Doe',
      isActive: true,
    });
  }

  static archived(): Customer {
    return Customer.reconstitute({
      id: randomUUID(), email: Email.reconstitute('archived@example.com'),
      fullName: 'Archived Customer', isActive: false,
    });
  }
}
```

**Factory rules:**
- Factories build every named state with `reconstitute()` — the state a repository returns —
  never by chaining domain methods (a factory must not depend on transition rules it is not
  testing)
- `create()` is called directly in the tests of the creation flow itself, not in factories
- Named states (`draft()`, `confirmed()`, `cancelled()`) are cheaper than `overrides` — add a
  named state for each meaningful business condition
- Keep factories where the project keeps them (e.g. `test/factories/<entity>.factory.<ext>`)

(`create()` vs `reconstitute()`: see `dev-core:clean-architecture` → `entities.md` /
`value-objects.md`.)

---

## Optimistic Lock test patterns

Three layers are required for every entity that uses Optimistic Locking (marked `[OL]` here: a
`version` column checked by a conditional `UPDATE ... WHERE version = N` on save).
Missing any one of them leaves a gap: the use case may behave correctly but the
contract is untested, or tests pass with the fake while production silently overwrites.

### 1 — Use Case unit test: simulating the conflict

`OptimisticLockException` (defined in `dev-core:error-handling`) comes from two guards (see
`dev-core:clean-architecture` → `entities.md` — "Use case — compare the client's version
first"): the use case throws when `input.version` (what the client edited) differs from the
loaded entity's version, and the repository throws when `WHERE version = N` matches zero rows
(a write between load and save). A repository conflict is simulated by **throwing** from
`save()` — never by returning `null`, because the interface contract `Promise<Invoice>`
guarantees the repository never resolves to null.

```typescript
describe('UpdateInvoiceUseCase — optimistic lock', () => {
  let invoices: InMemoryInvoiceRepository;
  let eventBus: CapturingEventBus;
  let useCase:  UpdateInvoiceUseCase;

  beforeEach(() => {
    invoices = new InMemoryInvoiceRepository();
    eventBus = new CapturingEventBus();
    useCase  = new UpdateInvoiceUseCase(invoices, eventBus);
  });

  it('should throw OptimisticLockException when the client edited a stale version', async () => {
    // Stored at version 2; the client edited version 1 → the use case rejects before saving.
    const stored = InvoiceFactory.withVersion(2);
    invoices.seed(stored);

    await expect(useCase.execute({ id: stored.id, description: 'x', version: 1 }))
      .rejects.toThrow(OptimisticLockException);

    expect((await invoices.findById(stored.id))?.description).toBe(stored.description);
    // Event must NOT fire — nothing was persisted
    expect(eventBus.captured).toHaveLength(0);
  });

  it('should return the incremented version when the save is clean', async () => {
    const stored = InvoiceFactory.withVersion(1);
    invoices.seed(stored);

    const result = await useCase.execute({ id: stored.id, description: 'x', version: 1 });

    expect(result.version).toBe(2);
  });
});
```

Add a named state to the factory for each version scenario:

```typescript
// test/factories/invoice.factory.ts
export class InvoiceFactory {
  static withVersion(version: number, overrides?: Partial<InvoiceProps>): Invoice {
    return Invoice.reconstitute({
      id:          overrides?.id          ?? randomUUID(),
      customerId:  overrides?.customerId  ?? randomUUID(),
      description: overrides?.description ?? 'Service description',
      issuedAt:    new Date(),
      version,
    });
  }
}
```

### 2 — In-memory fake: LSP compliance for `[OL]` entities

The fake **must** enforce the same version check as production.
A fake that skips the check passes all unit tests while masking real concurrent-edit bugs.

```typescript
// test/fakes/in-memory-invoice.repository.ts
export class InMemoryInvoiceRepository implements IInvoiceRepository {
  private readonly items = new Map<string, Invoice>();

  seed(invoice: Invoice): void { this.items.set(invoice.id, invoice); }

  async findById(id: string): Promise<Invoice | null> {
    return this.items.get(id) ?? null;
  }

  async save(invoice: Invoice): Promise<Invoice> {
    if (invoice.version === 0) {
      // Insert path — no conflict check needed; assign version 1
      const inserted = Invoice.reconstitute({ ...invoice, version: 1 });
      this.items.set(invoice.id, inserted);
      return inserted;
    }

    const existing = this.items.get(invoice.id);

    // ✅ Same guard as production (WHERE version = N): the stored version must still be the loaded one
    if (!existing || existing.version !== invoice.version)
      throw new OptimisticLockException('Invoice', invoice.id, invoice.version);

    const updated = Invoice.reconstitute({ ...invoice, version: invoice.version + 1 });
    this.items.set(invoice.id, updated);
    return updated;
  }
}
```

The load-save race is tested against the fake itself — two saves from the same loaded version:

```typescript
it('should throw when another write lands between load and save', async () => {
  const loaded = InvoiceFactory.withVersion(1);
  invoices.seed(loaded);
  await invoices.save(loaded.updateDescription('other user'));   // stored version is now 2

  await expect(invoices.save(loaded.updateDescription('x')))       // still carries version 1
    .rejects.toThrow(OptimisticLockException);
});
```

### 3 — Contract test: 409 envelope shape

The contract test proves the conflict reaches the client as the project's conflict status and
error envelope, and that a successful update returns the new version. `api` stands for the
stack's in-process HTTP test client (see the stack plugin):

```typescript
describe('PATCH /api/v1/invoices/:id — optimistic lock', () => {
  it('should return 409 with a typed error code when the version is stale', async () => {
    const res = await api.patch(`/api/v1/invoices/${seededInvoiceId}`, {
      token: validToken,
      body:  { description: 'Concurrent update', version: 0 }, // stale version
    });

    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({
      error: { code: 'OPTIMISTIC_LOCK_CONFLICT', message: expect.any(String) },
    });
    expect(res.body).not.toHaveProperty('data');
    assertFieldNaming(res.body);   // the project's wire naming convention
  });

  it('should include the updated version in a successful PATCH response', async () => {
    const res = await api.patch(`/api/v1/invoices/${seededInvoiceId}`, {
      token: validToken,
      body:  { description: 'Valid update', version: 1 }, // correct version from prior GET
    });

    expect(res.status).toBe(200);
    expect(typeof res.body.data.version).toBe('number');
    assertFieldNaming(res.body);
  });
});
```

### Anti-pattern — missing the conflict path

```typescript
// ❌ WRONG — only the happy path is tested; the 409 contract is invisible
it('should update invoice', async () => {
  const res = await api.patch(`/api/v1/invoices/${id}`, { body: { description: 'x', version: 1 } });
  expect(res.status).toBe(200);
});

// ❌ WRONG — fake skips the version check; LSP violation
async save(invoice: Invoice): Promise<Invoice> {
  this.items.set(invoice.id, invoice); // no conflict check — tests always pass
  return invoice;
}
```

---

See [mock-patterns.md](mock-patterns.md) for specification-query fakes, domain service tests
(pure and injected) and the unit-of-work fake; [contract-event-tests.md](contract-event-tests.md)
for `CapturingEventBus` and `assertFieldNaming`.
