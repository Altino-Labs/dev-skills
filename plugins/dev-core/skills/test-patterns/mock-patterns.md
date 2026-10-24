# Fakes and Test Doubles
> Sub-file of the `dev-core:test-patterns` skill. Read when writing in-memory fakes,
> specification-query fakes, domain service tests, or unit-of-work test doubles. Covers fake LSP
> compliance, in-memory filtering, and cross-aggregate write testing. Examples are
> framework-free TypeScript with hand-written fakes and stubs; the stack's auto-mock helpers
> live in the stack plugin (e.g. `dev-patterns:test-patterns`).

---

## Which double to use

| Double | What it is | Use when |
|---|---|---|
| **Fake** | Working in-memory implementation of a port (`InMemoryOrderRepository`) | The test depends on state: save then find, filters, version checks |
| **Stub** | Returns canned answers and records calls (`StubExchangeRateProvider`) | An external dependency must answer a fixed value or fail |
| **Auto-mock** | The runner's/mock library's generated interface double | Only "was it called with X" matters; the stack plugin shows the helper |

An auto-mock or chainable query-builder mock that returns canned rows **whatever the
arguments** can't tell a scoped query from an unscoped one. Wherever the code under test scopes
by tenant, owner or user, assert the recorded call that applies that filter and its value
(`expect(builder.eq).toHaveBeenCalledWith('tenant_id', tenantId)`) — otherwise a missing
filter, a data leak across tenants, passes every test.

Never double the class under test. Every fake honors the **same contract** as the production
implementation (LSP) — null vs throw, filters, ordering, version checks — otherwise the unit
tests pass against behavior production does not have.

---

## Specification pattern test

**Specification unit tests** (testing `isSatisfiedBy`, `toQuery`, composition) are documented
in the `dev-core:clean-architecture` skill's `specification.md` — "Testing specifications in
isolation" section. Read that section before writing any Specification test.

The gap not covered there: **how to test a Use Case that calls `findBySpec()`** — i.e.,
the in-memory fake for `IQueryableSpecification`.

### In-memory fake for `IQueryableSpecification`

The fake applies `isSatisfiedBy()` in memory. It never calls `toQuery()` — that is the
production repository's concern. Unit tests verify the Use Case logic; `toQuery()` correctness
is verified by the Specification's own unit test.

```typescript
// test/fakes/in-memory-order-query.repository.ts
export class InMemoryOrderQueryRepository implements IOrderQueryRepository {
  constructor(private readonly items: Order[] = []) {}

  async findBySpec(
    spec: IQueryableSpecification<Order>,
    params: PageParams,
  ): Promise<Page<Order>> {
    // isSatisfiedBy() — in-memory filter; never toQuery() in a fake
    const filtered = this.items.filter(item => spec.isSatisfiedBy(item));
    const from     = (params.page - 1) * params.per_page;

    return {
      data: filtered.slice(from, from + params.per_page),
      meta: {
        page:        params.page,
        per_page:    params.per_page,
        total:       filtered.length,
        total_pages: Math.ceil(filtered.length / params.per_page),
      },
    };
  }
}
```

### Use Case test using the fake

```typescript
describe('ListActiveOrdersUseCase', () => {
  it('should return only orders matching the composed specification', async () => {
    const cutoff = new Date('2024-01-01');
    const queryRepo = new InMemoryOrderQueryRepository([
      OrderFactory.activeCreatedAt(new Date('2024-06-01')),     // ✓ active + after cutoff
      OrderFactory.activeCreatedAt(new Date('2023-06-01')),     // ✗ active but before cutoff
      OrderFactory.cancelledCreatedAt(new Date('2024-06-01')), // ✗ after cutoff but cancelled
    ]);
    const useCase = new ListActiveOrdersUseCase(queryRepo);

    const result = await useCase.execute({ since: cutoff, page: 1, per_page: 10 });

    expect(result.data).toHaveLength(1);
    expect(result.meta.total).toBe(1);
  });

  it('should return an empty page when no orders match', async () => {
    const queryRepo = new InMemoryOrderQueryRepository([
      OrderFactory.cancelledCreatedAt(new Date('2024-06-01')),
    ]);
    const useCase = new ListActiveOrdersUseCase(queryRepo);

    const result = await useCase.execute({ since: new Date('2024-01-01'), page: 1, per_page: 10 });

    expect(result.data).toHaveLength(0);
    expect(result.meta.total).toBe(0);
  });
});
```

### Anti-pattern — fake calls toQuery()

```typescript
// ❌ WRONG — the fake reimplements DB filtering in code; any divergence hides real bugs
async findBySpec(spec: IQueryableSpecification<Order>, params: PageParams) {
  const filter = spec.toQuery();          // ← toQuery() output is for the DB, not in-memory code
  const filtered = applyFilterInMemory(this.items, filter);  // ← custom reimplementation
}

// ✅ CORRECT — delegate to the specification's own isSatisfiedBy()
const filtered = this.items.filter(item => spec.isSatisfiedBy(item));
```

---

## Domain Service test pattern

Domain Services divide into two kinds — each requires a different test approach.

### Pure Domain Service — no doubles, no async

Pure services have no constructor arguments and no I/O. Instantiate with `new` and assert
the return value directly. No `beforeEach`, no double setup.

The example below uses three factories. Add the named states your domain actually needs —
these are illustrative; the pattern is the same for any pure Domain Service.

```typescript
// test/factories/order.factory.ts — add states relevant to the service under test
export class OrderFactory {
  static standard(): Order {
    return Order.reconstitute({
      id: randomUUID(), customerId: randomUUID(), items: [], status: OrderStatus.DRAFT, currency: 'USD',
    });
  }
  static heavy(): Order {
    // Returns an order whose total weight exceeds 30 kg — the surcharge threshold.
    // Pass the items (or the weight field) your domain uses to compute the weight.
    return Order.reconstitute({
      id: randomUUID(), customerId: randomUUID(), items: heavyItems(), status: OrderStatus.DRAFT, currency: 'USD',
    });
  }
}

// test/factories/address.factory.ts
export class AddressFactory {
  static domestic(): Address {
    return Address.reconstitute({ street: '123 Main St', city: 'New York', region: 'NY', country: 'US' });
  }
  static remote(): Address {
    // A region the domestic carrier does not serve
    return Address.reconstitute({ street: '1 Arctic Rd', city: 'Barrow', region: 'AK', country: 'US' });
  }
}

// test/factories/carrier.factory.ts
export class CarrierFactory {
  static standard(): Carrier {
    return Carrier.reconstitute({ id: 'standard-carrier', regions: ['NY', 'CA', 'TX', 'AK'] });
  }
  static domestic(): Carrier {
    // Does not serve the remote region used in AddressFactory.remote()
    return Carrier.reconstitute({ id: 'domestic-carrier', regions: ['NY', 'CA', 'TX'] });
  }
}
```

```typescript
describe('ShippingCostCalculator', () => {
  const calc = new ShippingCostCalculator();

  it('should return the base rate when the order has standard weight', () => {
    const cost = calc.calculate(
      OrderFactory.standard(),
      AddressFactory.domestic(),
      CarrierFactory.standard(),
    );
    expect(cost.amount).toBe(10);
    expect(cost.currency).toBe('USD');
  });

  it('should add the weight surcharge when the order exceeds 30 kg', () => {
    const cost = calc.calculate(
      OrderFactory.heavy(),      // > 30 kg
      AddressFactory.domestic(),
      CarrierFactory.standard(),
    );
    expect(cost.amount).toBe(25);  // base 10 + surcharge 15
  });

  it('should throw CarrierNotAvailableException when the carrier does not serve the region', () => {
    expect(() =>
      calc.calculate(
        OrderFactory.standard(),
        AddressFactory.remote(),
        CarrierFactory.domestic(),  // does not serve remote region
      )
    ).toThrow(CarrierNotAvailableException);
  });
});
```

### Injected Domain Service — double only the external interface

When a Domain Service has constructor dependencies, double only those interfaces.
Test that the service coordinates correctly — not the double's internals.

```typescript
// test/fakes/stub-exchange-rate.provider.ts
export class StubExchangeRateProvider implements IExchangeRateProvider {
  readonly calls: Array<[string, string]> = [];
  constructor(private readonly answer: number | Error) {}

  async getRate(from: string, to: string): Promise<number> {
    this.calls.push([from, to]);
    if (this.answer instanceof Error) throw this.answer;
    return this.answer;
  }
}
```

```typescript
describe('CurrencyConverter', () => {
  it('should convert the amount using the rate returned by the provider', async () => {
    const rates     = new StubExchangeRateProvider(0.9);
    const converter = new CurrencyConverter(rates);

    const result = await converter.convert(Money.create(100, 'USD'), 'EUR');

    expect(result).toEqual(Money.create(90, 'EUR'));
    expect(rates.calls).toEqual([['USD', 'EUR']]);
  });

  it('should return the original amount unchanged when the currencies match', async () => {
    const rates     = new StubExchangeRateProvider(0.9);
    const converter = new CurrencyConverter(rates);
    const amount    = Money.create(100, 'USD');

    const result = await converter.convert(amount, 'USD');

    expect(result).toEqual(amount);
    expect(rates.calls).toHaveLength(0);  // no external call needed
  });

  it('should throw when the rate provider fails', async () => {
    const rates     = new StubExchangeRateProvider(new ExternalServiceException('RATE_UNAVAILABLE', 'timeout'));
    const converter = new CurrencyConverter(rates);

    await expect(converter.convert(Money.create(100, 'USD'), 'EUR'))
      .rejects.toThrow(ExternalServiceException);
  });
});
```

**Detection rule:**
- No constructor args → `new ServiceClass()`, pure synchronous assertions.
- Constructor args → a stub/fake (or the stack's auto-mock) per dependency; test coordination
  and error propagation.

(When to create a domain service and `new()` vs inject: `dev-core:clean-architecture` →
`domain-services.md`.)

---

## IUnitOfWork test pattern

`IUnitOfWork` is an escape hatch for cross-aggregate writes when a dedicated transactional
method is impractical (see `dev-core:clean-architecture` → `transactions.md`). The in-memory
fake runs the callback directly — no transaction, no rollback.

```typescript
// test/fakes/in-memory-unit-of-work.ts
export class InMemoryUnitOfWork implements IUnitOfWork {
  async execute<T>(work: () => Promise<T>): Promise<T> {
    return work();  // no BEGIN/COMMIT — just run the callback
  }
}
```

### Use Case test using the fake

```typescript
describe('TransferFundsUseCase', () => {
  let accounts:   InMemoryAccountRepository;
  let unitOfWork: InMemoryUnitOfWork;
  let eventBus:   CapturingEventBus;
  let useCase:    TransferFundsUseCase;

  beforeEach(() => {
    accounts   = new InMemoryAccountRepository();
    unitOfWork = new InMemoryUnitOfWork();
    eventBus   = new CapturingEventBus();
    // FundsTransferService is pure (no constructor args) — this example assumes the
    // Use Case instantiates it with `new FundsTransferService()` inside execute().
    // If the Use Case injects it instead, pass `new FundsTransferService()` as well.
    useCase = new TransferFundsUseCase(accounts, unitOfWork, eventBus);
  });

  it('should save both accounts and publish the event when the transfer succeeds', async () => {
    accounts.seed(AccountFactory.withBalance('a', 100, 'USD'));
    accounts.seed(AccountFactory.withBalance('b', 50,  'USD'));

    await useCase.execute({ sourceId: 'a', targetId: 'b', amount: 30, currency: 'USD' });

    expect((await accounts.findById('a'))!.balance.amount).toBe(70);
    expect((await accounts.findById('b'))!.balance.amount).toBe(80);
    expect(eventBus.capturedOf(EventNames.FUNDS_TRANSFERRED)).toHaveLength(1);
  });

  it('should propagate the exception and not publish an event when save fails', async () => {
    accounts.seed(AccountFactory.withBalance('a', 100, 'USD'));
    accounts.seed(AccountFactory.withBalance('b', 50,  'USD'));
    accounts.failNextSave(new DatabaseException('DB_ERROR', 'connection lost'));  // fake hook

    await expect(
      useCase.execute({ sourceId: 'a', targetId: 'b', amount: 30, currency: 'USD' }),
    ).rejects.toThrow(DatabaseException);

    expect(eventBus.captured).toHaveLength(0);
  });
});
```

**Scope of the in-memory fake:** it verifies Use Case orchestration (correct calls, correct
order, event not published after failure). It does NOT verify transaction atomicity — that
requires an integration test against a real database
(see [repository-integration-tests.md](repository-integration-tests.md)).
