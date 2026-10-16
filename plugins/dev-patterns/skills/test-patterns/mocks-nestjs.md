# Mocks in NestJS tests — `createMock`, `jest.fn`, `vi.fn`
> Sub-file of `dev-patterns:test-patterns`. The concepts (which double to use, fakes honoring
> LSP, the three optimistic-lock layers, pure vs injected domain services, unit-of-work fake,
> `StrictEventBus` / `CapturingEventBus`) are in `dev-core:test-patterns` →
> `unit-test-patterns.md`, `mock-patterns.md` and `contract-event-tests.md`. This file shows the
> Jest/Vitest mock-helper versions. Under Vitest swap `jest.fn()` → `vi.fn()`,
> `jest.Mocked<T>` → `Mocked<T>` and import `createMock` from `@golevelup/ts-vitest`.

---

## Optimistic lock — simulating the conflict with a mock

`OptimisticLockException` (NestJS class in `dev-patterns:error-handling`) comes from two
guards: the use case throws when the client's `version` differs from the loaded one, and the
repository throws when `WHERE version = N` matches zero rows (supabase-js version in
`dev-patterns:clean-architecture` → `supabase-repositories.md`). Mock the repository conflict
with `mockRejectedValue` — never with `mockResolvedValue(null)`, because the interface contract
`Promise<Invoice>` guarantees the repository never resolves to null.

```typescript
describe('UpdateInvoiceUseCase — optimistic lock', () => {
  it('should throw OptimisticLockException when the client edited a stale version', async () => {
    // Entity loaded at version 2; client sends stale version 1 → rejected before saving.
    invoiceRepo.findById.mockResolvedValue(InvoiceFactory.withVersion(2));

    await expect(useCase.execute({ ...validInput, version: 1 }))
      .rejects.toThrow(OptimisticLockException);

    expect(invoiceRepo.save).not.toHaveBeenCalled();
    expect(eventBus.publish).not.toHaveBeenCalled();
  });

  it('should propagate the repository conflict when a write lands between load and save', async () => {
    invoiceRepo.findById.mockResolvedValue(InvoiceFactory.withVersion(1));
    invoiceRepo.save.mockRejectedValue(
      new OptimisticLockException('Invoice', validInput.id, 1),
    );

    await expect(useCase.execute({ ...validInput, version: 1 }))
      .rejects.toThrow(OptimisticLockException);

    // Event must NOT fire — conflict occurred before persistence completed
    expect(eventBus.publish).not.toHaveBeenCalled();
  });

  it('should succeed and return the incremented version on a clean save', async () => {
    invoiceRepo.findById.mockResolvedValue(InvoiceFactory.withVersion(1));
    invoiceRepo.save.mockResolvedValue(InvoiceFactory.withVersion(2));

    const result = await useCase.execute({ ...validInput, version: 1 });

    expect(result.version).toBe(2);
  });
});
```

The in-memory fake (layer 2) and the 409 contract test (layer 3) are still required — see
dev-core `unit-test-patterns.md` and [contract-tests-http.md](contract-tests-http.md).

---

## Injected Domain Service — mock only the external interface

```typescript
import { createMock } from '@golevelup/ts-jest';

describe('CurrencyConverter', () => {
  let rateProvider: jest.Mocked<IExchangeRateProvider>;
  let converter: CurrencyConverter;

  beforeEach(() => {
    rateProvider = createMock<IExchangeRateProvider>();
    converter    = new CurrencyConverter(rateProvider);
  });

  it('should convert amount using the rate returned by the provider', async () => {
    rateProvider.getRate.mockResolvedValue(0.9);

    const result = await converter.convert(Money.create(100, 'USD'), 'EUR');

    expect(result).toEqual(Money.create(90, 'EUR'));
    expect(rateProvider.getRate).toHaveBeenCalledWith('USD', 'EUR');
  });

  it('should return the original amount unchanged when currencies match', async () => {
    const amount = Money.create(100, 'USD');

    const result = await converter.convert(amount, 'USD');

    expect(result).toEqual(amount);
    expect(rateProvider.getRate).not.toHaveBeenCalled();  // no external call needed
  });

  it('should throw when the rate provider fails', async () => {
    rateProvider.getRate.mockRejectedValue(new ExternalServiceException('RATE_UNAVAILABLE', 'timeout'));

    await expect(converter.convert(Money.create(100, 'USD'), 'EUR'))
      .rejects.toThrow(ExternalServiceException);
  });
});
```

**Detection rule:** no constructor args → `new ServiceClass()`; constructor args →
`createMock<IDependency>()` per dependency.

---

## IUnitOfWork — `InMemoryUnitOfWork` with mocked repositories

`InMemoryUnitOfWork` is the dev-core fake (runs the callback directly). With `createMock`
repositories:

```typescript
import { createMock } from '@golevelup/ts-jest';

describe('TransferFundsUseCase', () => {
  let useCase:     TransferFundsUseCase;
  let accountRepo: jest.Mocked<IAccountRepository>;
  let unitOfWork:  InMemoryUnitOfWork;
  let eventBus:    jest.Mocked<IEventBus>;

  beforeEach(() => {
    accountRepo = createMock<IAccountRepository>();
    unitOfWork  = new InMemoryUnitOfWork();
    eventBus    = createMock<IEventBus>();
    // FundsTransferService is pure — see `dev-core:clean-architecture` → domain-services.md
    // ("new() vs inject"); if the Use Case injects it, add `new FundsTransferService()` as 4th arg.
    useCase = new TransferFundsUseCase(accountRepo, unitOfWork, eventBus);
  });

  it('should save both accounts and publish event on success', async () => {
    accountRepo.findById
      .mockResolvedValueOnce(AccountFactory.withBalance(100, 'USD'))
      .mockResolvedValueOnce(AccountFactory.withBalance(50,  'USD'));

    await useCase.execute({ sourceId: 'a', targetId: 'b', amount: 30, currency: 'USD' });

    expect(accountRepo.save).toHaveBeenCalledTimes(2);
    expect(eventBus.publish).toHaveBeenCalledWith(
      expect.objectContaining({ eventName: EventNames.FUNDS_TRANSFERRED }),
    );
  });

  it('should propagate the exception and not publish an event when save fails', async () => {
    accountRepo.findById
      .mockResolvedValueOnce(AccountFactory.withBalance(100, 'USD'))
      .mockResolvedValueOnce(AccountFactory.withBalance(50,  'USD'));
    accountRepo.save.mockRejectedValue(
      new DatabaseException('DB_ERROR', 'connection lost'),
    );

    await expect(
      useCase.execute({ sourceId: 'a', targetId: 'b', amount: 30, currency: 'USD' }),
    ).rejects.toThrow(DatabaseException);

    expect(eventBus.publish).not.toHaveBeenCalled();
  });
});
```

Atomicity against a real database: [supabase-integration-tests.md](supabase-integration-tests.md).

---

## Event bus in NestJS tests

`StrictEventBus` and `CapturingEventBus` are the dev-core fakes — copy them into
`apps/api/test/fakes/` (they implement the project's `IEventBus` from
`domain/events/i-event-bus`). The third option, for "was `publish()` called?", is
`createMock<IEventBus>()`:

```typescript
import { createMock } from '@golevelup/ts-jest';
import { EventNames } from '../../domain/events/event-names';

describe('PlaceOrderUseCase', () => {
  let eventBus: jest.Mocked<IEventBus>;

  beforeEach(() => {
    eventBus = createMock<IEventBus>();
    useCase  = new PlaceOrderUseCase(orderRepo, eventBus);
  });

  it('should publish OrderPlacedEvent', async () => {
    await useCase.execute(validInput);
    expect(eventBus.publish).toHaveBeenCalledWith(
      expect.objectContaining({ eventName: EventNames.ORDER_PLACED }),
    );
  });
});

// Integration: real subscriber, mocked outbound port, StrictEventBus wiring
describe('PlaceOrder → SendConfirmationEmail integration', () => {
  let eventBus: StrictEventBus;
  let emailService: jest.Mocked<IEmailService>;

  beforeEach(() => {
    emailService = createMock<IEmailService>();
    eventBus = new StrictEventBus()
      .register(EventNames.ORDER_PLACED, new SendOrderConfirmationEmailSubscriber(emailService));
    useCase = new PlaceOrderUseCase(orderRepo, eventBus);
  });

  it('should send confirmation email when order is placed', async () => {
    await useCase.execute(validInput);
    // Subscriber ran — if it threw, the test would fail (not silently pass)
    expect(emailService.send).toHaveBeenCalled();
  });
});
```

Subscribers are plain classes in tests: construct them with `new` and register them on the
`StrictEventBus` by hand — the `@EventSubscriber` decorator discovery is not involved.

### Anti-pattern — the NestJS `InMemoryEventBus` in unit tests

```typescript
// ❌ WRONG — the production InMemoryEventBus needs NestJS container services
//    (DiscoveryService plus Reflector/MetadataScanner — it scans all providers for
//    @EventSubscriber-decorated classes; the logger is instantiated internally,
//    never injected; see `dev-patterns:domain-events` → event-bus-impl.md); subscriber
//    errors are swallowed (logged via Logger.warn, never rethrown) — a test using
//    the real bus passes even if a subscriber has a bug
const eventBus = new InMemoryEventBus(discovery, reflector);

// ✅ CORRECT — choose the fake that matches what the test verifies
const eventBus = createMock<IEventBus>();      // unit: was publish() called?
const eventBus = new CapturingEventBus();      // unit: what was the event payload?
const eventBus = new StrictEventBus();         // integration: did the subscriber run correctly?
```
