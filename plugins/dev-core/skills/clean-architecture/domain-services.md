# Domain Services
> Sub-file of the `dev-core:clean-architecture` skill. Read when deciding whether logic belongs to
> an entity method, a use case, or a Domain Service — and how to implement either.

---

## Decision tree — where does this logic go?

Run this tree before creating any artifact. The most common mistake is putting orchestration
in a Domain Service, or putting cross-entity computation in a Use Case.

```
Does the logic enforce invariants on ONE entity's own data?
      │
      YES → Entity method
             Example: order.confirm(), order.cancel(), invoice.close()
      NO
      │
      ▼
Does the logic ORCHESTRATE? (load from repo → mutate → persist → publish events)
      │
      YES → Use Case
             Example: PlaceOrderUseCase, ProcessPaymentUseCase, CloseInvoiceUseCase
      NO (pure computation — no I/O, no side effects)
      │
      ▼
Does the logic span two or more entities/aggregates,
OR would it be duplicated across multiple Use Cases?
      │
      YES → Domain Service
             Example: DeliveryWindowCalculator, ShippingCostCalculator, TaxPolicy
      NO
      │
      ▼
      It belongs in the Use Case that needs it.
      Extract only if a second Use Case duplicates the same logic.
```

**The clearest diagnostic question:** does this logic *save* anything or *publish* an event?
- YES → Use Case (orchestrates; has side effects)
- NO  → Entity method or Domain Service (pure computation)

**Use Case calling another Use Case — when is it acceptable?**

Direct UC→UC injection is acceptable **only within the same module** when Use Case A needs to
trigger a complete operation that Use Case B already owns, and that operation is not shared
business logic.

> **Module boundary rule:** if B belongs to a different module, A must never inject B directly.
> Cross-module writes and side effects happen via Domain Events published on the Event Bus;
> cross-module reads go through the other module's public query API, never its repositories or
> use cases (`dev-core:domain-events` — "Core principle"). UC→UC across modules
> is the same violation as calling a Use Case from inside a subscriber. The one sanctioned
> relaxation is for explicitly named **aggregator modules** (read-only, lint-enforced). See
> "Exception — aggregator modules" in `dev-core:domain-events`.

```typescript
// ✅ Acceptable — A and B are in the SAME module; A delegates a complete operation to B
export class CloseAccountUseCase {
  constructor(
    private readonly cancelActiveOrders: CancelActiveOrdersUseCase,  // same AccountModule
    private readonly accounts: IAccountRepository,
    private readonly eventBus: IEventBus,
  ) {}
}

// ❌ Wrong — CancelActiveOrdersUseCase belongs to OrderModule (different module).
// Use AccountClosedEvent → OrderModule subscriber → cancel orders instead.
export class CloseAccountUseCase {
  constructor(
    private readonly cancelActiveOrders: CancelActiveOrdersUseCase,  // cross-module!
  ) {}
}

// ❌ Wrong — shared computation extracted to a Use Case instead of a Domain Service
export class PlaceOrderUseCase {
  constructor(private readonly calculateTax: CalculateTaxUseCase) {}
  // CalculateTax is pure computation — it belongs to a Domain Service, not a Use Case
}
```

**Rule:** if the shared code contains `IRepository`, `IEventBus`, or any I/O — it is a Use Case
and direct injection is acceptable **within the same module**. If it is pure computation with no I/O — it is a Domain
Service and must not be wrapped in a Use Case.

**Boundary with the aggregate rule:** by default a use case changes **one aggregate per
transaction** (`aggregates.md`, "Design principle"). UC→UC injection is safe only when A
*delegates the entire operation* to B and does not use B's return value to make decisions
about A's own aggregate — otherwise A is coordinating two aggregates. When two aggregates
really must change together, a domain service coordinates them and the use case persists both
either in one transaction ([transactions.md](transactions.md)) or via a saga
(`dev-core:domain-events` → `advanced-delivery.md`). `FundsTransferService` below is the
explicit example of the one-transaction case.

---

## When to create a Domain Service

| Signal | Example |
|---|---|
| The operation involves **two or more aggregates** | Calculate discount using `Order` + `CustomerLoyaltyTier` |
| The logic would be **duplicated across multiple use cases** | Tax calculation used by `PlaceOrder`, `QuoteOrder`, `RefundOrder` |
| The operation has **no natural owner** among existing entities | Validate that a shipment route is reachable given carrier constraints |
| The logic requires **external data** (injected via interface) | Exchange rate lookup to convert `Money` between currencies |

## What a Domain Service is NOT

- It is NOT a Use Case. Use Cases orchestrate; Domain Services compute.
- It is NOT a replacement for entity behavior. If logic belongs to one entity, put it there.
- It is NOT infrastructure. Domain Services have no database calls, no HTTP, no framework imports.

---

## Pattern — pure Domain Service (no constructor args)

```typescript
// domain/services/shipping-cost-calculator.ts
// Pure domain concept — no framework, no infrastructure imports
export class ShippingCostCalculator {
  calculate(order: Order, destination: Address, carrier: Carrier): Money {
    if (!carrier.servicesRegion(destination.region))
      throw new CarrierNotAvailableException(carrier.id, destination.region);

    const baseRate      = carrier.baseRateFor(destination.region);
    const weightSurcharge = order.totalWeight.exceedsKg(30)
      ? Money.create(15, order.currency)
      : Money.zero(order.currency);

    return baseRate.add(weightSurcharge);
  }
}
```

## Pattern — Domain Service with injected dependency

When a Domain Service needs external data, inject it via a domain interface:

```typescript
// domain/services/i-exchange-rate-provider.ts
export const EXCHANGE_RATE_PROVIDER = Symbol('EXCHANGE_RATE_PROVIDER');   // TS DI token — only if the container resolves by token

export interface IExchangeRateProvider {
  getRate(from: string, to: string): Promise<number>;
}

// domain/services/currency-converter.ts
export class CurrencyConverter {
  constructor(private readonly rateProvider: IExchangeRateProvider) {}

  async convert(amount: Money, targetCurrency: string): Promise<Money> {
    if (amount.currency === targetCurrency) return amount;
    const rate = await this.rateProvider.getRate(amount.currency, targetCurrency);
    return amount.convert(rate, targetCurrency);   // exact, rounded to the target's minor unit
  }
}

// infrastructure/services/open-exchange-rates.provider.ts
export class OpenExchangeRatesProvider implements IExchangeRateProvider { ... }
```

---

## Canonical example — FundsTransferService (Evans, *Domain-Driven Design*, ch. 5)

The textbook Domain Service: transfer money between two `Account` aggregates.
Neither account "owns" the transfer logic because it spans both.

Entity methods here return **new instances** (copy-on-write style — see `entities.md`, "State
changes only through entity methods"; ORM-tracked entities mutate inside the same methods
instead). The Domain Service returns the pair of updated accounts so the Use Case can persist
them without relying on mutable references.

```typescript
// domain/entities/account.entity.ts
// Each entity enforces only its own invariants
export class Account {
  private constructor(
    public readonly id: string,
    public readonly currency: string,   // plain string — no behavior, no arithmetic
    public readonly balance: Money,     // public readonly — no private mutable field needed
  ) {}

  static create(props: { id: string; currency: string; initialBalance: string }): Account {
    return new Account(props.id, props.currency, Money.create(props.initialBalance, props.currency));
  }

  static reconstitute(props: { id: string; currency: string; balance: string }): Account {   // NUMERIC as string
    return new Account(props.id, props.currency, Money.reconstitute(props.balance, props.currency));
  }

  // Returns a NEW Account — same immutable pattern as Order.confirm(), Invoice.close(), etc.
  debit(amount: Money): Account {
    if (this.balance.amount < amount.amount)
      throw new InsufficientFundsException(this.id, amount);
    return new Account(this.id, this.currency, this.balance.subtract(amount));
  }

  credit(amount: Money): Account {
    return new Account(this.id, this.currency, this.balance.add(amount));
  }
}
```

```typescript
// domain/services/funds-transfer-service.ts
// Spans two aggregates — belongs to neither — Evans' canonical Domain Service
export class FundsTransferService {
  transfer(
    source: Account,
    target: Account,
    amount: Money,
  ): { source: Account; target: Account } {
    if (source.currency !== target.currency)
      throw new CurrencyMismatchException(source.id, target.id);

    // Neither Account knows about the other — the Service coordinates them.
    // Callers must use the returned instances; the originals are unchanged.
    return {
      source: source.debit(amount),
      target: target.credit(amount),
    };
  }
}
```

Two variants — choose based on the persistence layer (see [transactions.md](transactions.md)).

**Variant A — consolidated repository method (Layer 1):**

When the repositories cannot share one database transaction from the application layer
(e.g. the data-access client has no `BEGIN/COMMIT` and each call auto-commits on its own
connection), a unit of work does not provide atomicity over them. The only safe option is a
single repository method backed by one database transaction (a stored procedure / database
function, or a transaction opened inside the repository).
Add `saveTransfer(source, target)` to `IAccountRepository` — the implementation writes both
accounts atomically.

```typescript
// use-cases/transfer-funds.use-case.ts
export class TransferFundsUseCase {
  constructor(
    private readonly accounts: IAccountRepository,
    private readonly eventBus: IEventBus,
    private readonly transferService: FundsTransferService,
  ) {}

  async execute(input: TransferFundsInput): Promise<TransferFundsOutput> {
    const [source, target] = await Promise.all([
      this.accounts.findById(input.sourceId),
      this.accounts.findById(input.targetId),
    ]);
    if (!source) throw new AccountNotFoundException(input.sourceId);
    if (!target) throw new AccountNotFoundException(input.targetId);

    const amount = Money.create(input.amount, input.currency);
    const { source: updatedSource, target: updatedTarget } =
      this.transferService.transfer(source, target, amount);

    // Layer 1: one repository method — both accounts written in one database transaction.
    // See transactions.md §Layer 1.
    await this.accounts.saveTransfer(updatedSource, updatedTarget);

    await this.eventBus.publish(
      new FundsTransferredEvent(updatedSource.id, updatedTarget.id, amount.amount),
    );
    return {
      source_balance: updatedSource.balance.amount,
      target_balance: updatedTarget.balance.amount,
    };
  }
}
```

**Variant B — unit of work (Layer 2):**

Only when every repository implementation involved runs on the connection/transaction the unit
of work opened — never with repositories that use a separate client or pool.
See `transactions.md §Layer 2` for the `IUnitOfWork` port and the compatibility warning.

```typescript
export class TransferFundsUseCase {
  constructor(
    private readonly accounts: IAccountRepository,
    private readonly unitOfWork: IUnitOfWork,
    private readonly eventBus: IEventBus,
    private readonly transferService: FundsTransferService,
  ) {}

  async execute(input: TransferFundsInput): Promise<TransferFundsOutput> {
    const [source, target] = await Promise.all([
      this.accounts.findById(input.sourceId),
      this.accounts.findById(input.targetId),
    ]);
    if (!source) throw new AccountNotFoundException(input.sourceId);
    if (!target) throw new AccountNotFoundException(input.targetId);

    const amount = Money.create(input.amount, input.currency);
    const { source: updatedSource, target: updatedTarget } =
      this.transferService.transfer(source, target, amount);

    await this.unitOfWork.execute(async () => {
      await this.accounts.save(updatedSource);
      await this.accounts.save(updatedTarget);
    });

    // Publish AFTER the transaction commits — never inside unitOfWork.execute()
    await this.eventBus.publish(
      new FundsTransferredEvent(updatedSource.id, updatedTarget.id, amount.amount),
    );
    return {
      source_balance: updatedSource.balance.amount,
      target_balance: updatedTarget.balance.amount,
    };
  }
}
```

**Why `FundsTransferService` is a Domain Service and not a Use Case:**
- It computes only — no repository calls, no event publishing.
- The same logic can be called by `TransferFundsUseCase`, `RefundUseCase`, and `BatchSettlementUseCase`.

**Why it is not an entity method:**
- `transfer()` involves two `Account` aggregates simultaneously; neither is a natural owner.
- `Account.transferTo(target)` would make `Account` depend on another `Account` — violates aggregate isolation.

**Why the event is published outside `unitOfWork.execute()`:**
- The in-memory Event Bus dispatches subscribers synchronously inside the same process.
- Publishing inside a transaction that later rolls back would fire subscribers for a write
  that never committed — a false notification. Always publish after the transaction commits.

---

## Use Case consumes the Domain Service — `new()` vs inject

**Rule:** does the Domain Service have a constructor with arguments?
- **YES (has dependencies) → always inject it** into the Use Case through the constructor (DI
  container or composition root). The Use Case cannot mock a `new X()` call.
- **NO (pure computation) → either is fine:** inject it (as `TransferFundsUseCase` does with
  `FundsTransferService`) or `new()` it inside `execute()` (as below). Pure services have no
  state and no I/O, so tests lose nothing either way; pick one per project and stay consistent.

```typescript
// ✅ CORRECT — Domain Service WITH dependency: inject it
export class PlaceOrderUseCase {
  constructor(
    private readonly orders: IOrderRepository,
    private readonly eventBus: IEventBus,
    private readonly currencyConverter: CurrencyConverter,  // ← injected, not new()
  ) {}
}

// Composition root (or DI container registration) builds it with its own dependency
const currencyConverter = new CurrencyConverter(new OpenExchangeRatesProvider(/* config */));
const placeOrder        = new PlaceOrderUseCase(orderRepository, eventBus, currencyConverter);
```

```typescript
// ✅ CORRECT — Pure Domain Service (no dependencies): new() inside execute() is fine (injecting it is too)
async execute(input: CalculateShippingInput): Promise<CalculateShippingOutput> {
  const order    = await this.orders.findById(input.orderId);
  const calc     = new ShippingCostCalculator();   // ← pure: no hidden state, no I/O
  const shipping = calc.calculate(order, input.destination, input.carrier);
  return { shipping_cost: shipping.amount, currency: shipping.currency };
}
```

```typescript
// ❌ WRONG — Domain Service WITH dependency instantiated inside execute()
async execute(input: PlaceOrderInput): Promise<PlaceOrderOutput> {
  const converter = new CurrencyConverter(this.rateProvider);  // ← not mockable as a unit
  // CurrencyConverter.convert() cannot be intercepted in tests
  // Adding caching/logging to CurrencyConverter forces changes here too
}
```

---

## Where Domain Services live

```
domain/
  services/
    shipping-cost-calculator.ts        ← pure computation, no interface needed
    currency-converter.ts              ← needs IExchangeRateProvider (injected)
    i-exchange-rate-provider.ts        ← interface for external data (DIP)

infrastructure/
  services/
    open-exchange-rates.provider.ts    ← implements IExchangeRateProvider
```

---

## Anti-patterns

```typescript
// ❌ WRONG — Domain Service with framework import (DIP violation)
import { HttpClient } from 'some-web-framework/http';
export class CurrencyConverter {
  constructor(private readonly http: HttpClient) {}  // framework in domain layer
}

// ❌ WRONG — logic that belongs to the entity extracted to a Domain Service
export class OrderTotalCalculator {
  calculate(items: OrderItem[]): Money {  // Order.total getter already handles this
    return items.reduce((sum, i) => sum.add(i.subtotal), Money.zero('USD'));
  }
}

// ❌ WRONG — Domain Service calling a Use Case (layer inversion)
export class ShippingCostCalculator {
  constructor(private readonly getCarrierUseCase: GetCarrierUseCase) {}
  // Domain layer must not depend on Application layer
}

// ❌ WRONG — Domain Service making a repository call (this is a Use Case)
export class OrderFulfillmentService {
  constructor(private readonly orders: IOrderRepository) {}  // I/O → should be a Use Case
  async fulfill(orderId: string): Promise<void> {
    const order = await this.orders.findById(orderId);  // orchestration = Use Case territory
  }
}
```
