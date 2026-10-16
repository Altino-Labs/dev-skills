# NestJS wiring — ports, adapters, strategies, domain services
> Sub-file of the `dev-patterns:clean-architecture` skill (NestJS + Supabase implementation of
> `dev-core:clean-architecture`). Read when wiring a repository port, a strategy factory or a
> domain service with dependencies into a NestJS module.

---

## DIP — the three-part binding in NestJS

The concept (port in the domain, consumer depends on the abstraction, the composition root
binds it) is in `dev-core:clean-architecture` → repositories.md, "DIP". In NestJS:

**1. Symbol — injection token (in `domain/`)**
```typescript
// domain/repositories/i-order.repository.ts
export const ORDER_REPOSITORY = Symbol('ORDER_REPOSITORY');

export interface IOrderRepository {
  findById(id: string): Promise<Order | null>;
  save(order: Order): Promise<Order>;
}
```

**2. `@Inject(Symbol)` — declares the dependency on the abstraction (in Use Case)**
```typescript
@Injectable()
export class ProcessOrderUseCase {
  constructor(
    @Inject(ORDER_REPOSITORY)  private readonly orders: IOrderRepository,   // ← abstraction
    @Inject(EVENT_BUS)         private readonly eventBus: IEventBus,         // ← abstraction
  ) {}
  // This file has ZERO imports from infrastructure/ — DIP is satisfied
}
```

**3. `useClass` binding — wires abstraction to concretion (in `interfaces/`)**
```typescript
@Module({
  providers: [
    { provide: ORDER_REPOSITORY, useClass: SupabaseOrderRepository },  // ← concretion
    { provide: EVENT_BUS,        useClass: InMemoryEventBus },          // ← concretion
    ProcessOrderUseCase,
  ],
})
export class OrderModule {}
```

The module is the only place that knows about both sides.

### Concrete adapters in this stack

| Dependency type | Interface | Symbol | Concrete |
|---|---|---|---|
| Persistence | `IOrderRepository` | `ORDER_REPOSITORY` | `SupabaseOrderRepository` |
| Event publishing | `IEventBus` | `EVENT_BUS` | `InMemoryEventBus` |
| Email sending | `IEmailService` | `EMAIL_SERVICE` | `ResendEmailService` |
| PDF generation | `IPdfService` | `PDF_SERVICE` | `PuppeteerPdfService` |
| Push notifications | `IPushService` | `PUSH_SERVICE` | `ExpoPushService` |
| Cache | `ICacheRepository` | `CACHE_REPOSITORY` | `RedisRepository` |

### Anti-patterns (NestJS)

```typescript
// ❌ WRONG — Use Case imports the concrete class directly (DIP violation)
import { SupabaseOrderRepository } from '../../infrastructure/repositories/supabase-order.repository';
export class ProcessOrderUseCase {
  constructor(private readonly orders: SupabaseOrderRepository) {}
  // Replacing Supabase now requires editing this Use Case
}

// ❌ WRONG — no Symbol; injection is by class name (non-deterministic if two classes implement the same interface)
export class ProcessOrderUseCase {
  constructor(private readonly orders: IOrderRepository) {}  // missing @Inject(ORDER_REPOSITORY)
}

// ✅ CORRECT — three-part DIP binding
export class ProcessOrderUseCase {
  constructor(@Inject(ORDER_REPOSITORY) private readonly orders: IOrderRepository) {}
}
```

Read/write split (ISP + CQRS): `IOrderRepository` and `IOrderQueryRepository` each get their
own `Symbol` (`ORDER_REPOSITORY`, `ORDER_QUERY_REPOSITORY`) and their own provider in the module.

---

## Strategies with injected dependencies — NestJS DI factory

The static factory (`dev-core:clean-architecture` → aggregates.md) works only when Strategies are **pure classes with no constructor arguments**.
When a Strategy needs an injected dependency, switch to DI registration.

**Detection rule:** if any Strategy class has a constructor with parameters, use DI.

```typescript
// domain/discount-policy.factory.ts — token + interface only
export const DISCOUNT_POLICY_FACTORY = Symbol('DISCOUNT_POLICY_FACTORY');

export interface IDiscountPolicyFactory {
  for(type: OrderType): DiscountPolicy;
}
```

```typescript
// order/order.module.ts
@Module({
  providers: [
    { provide: LOYALTY_REPOSITORY, useClass: SupabaseLoyaltyRepository },
    StandardDiscountPolicy,         // no constructor args — pure
    PremiumDiscountPolicy,          // NestJS injects ILoyaltyRepository automatically
    VipDiscountPolicy,              // pure
    {
      provide: DISCOUNT_POLICY_FACTORY,
      useFactory: (std: StandardDiscountPolicy, prem: PremiumDiscountPolicy,
                   vip: VipDiscountPolicy): IDiscountPolicyFactory => ({
        for: (type: OrderType): DiscountPolicy =>
          ({ [OrderType.STANDARD]: std, [OrderType.PREMIUM]: prem, [OrderType.VIP]: vip }[type] ?? std),
      }),
      inject: [StandardDiscountPolicy, PremiumDiscountPolicy, VipDiscountPolicy],
    },
    CalculateDiscountUseCase,
  ],
})
export class OrderModule {}
```

```typescript
// Use Case: identical to static factory version
@Injectable()
export class CalculateDiscountUseCase {
  constructor(
    @Inject(DISCOUNT_POLICY_FACTORY) private readonly factory: IDiscountPolicyFactory,
    @Inject(ORDER_REPOSITORY)        private readonly orders: IOrderRepository,
  ) {}

  async execute(input: CalculateDiscountInput): Promise<Money> {
    const order = await this.orders.findById(input.orderId);
    if (!order) throw new OrderNotFoundException(input.orderId);
    return this.factory.for(order.type).calculate(order);
  }
}
```

| Strategies have | Pattern |
|---|---|
| No constructor args (pure) | Static factory — `DiscountPolicyFactory.for()`; no module wiring needed |
| Constructor args (injected deps) | DI factory via `useFactory` + `inject` |

---

## Domain Service with a dependency — register it in the module

```typescript
// ✅ CORRECT — Domain Service WITH dependency: inject it
@Injectable()
export class PlaceOrderUseCase {
  constructor(
    @Inject(ORDER_REPOSITORY) private readonly orders: IOrderRepository,
    @Inject(EVENT_BUS)        private readonly eventBus: IEventBus,
    private readonly currencyConverter: CurrencyConverter,  // ← injected, not new()
  ) {}
}

// Module registers it — NestJS injects IExchangeRateProvider automatically
@Module({
  providers: [
    { provide: EXCHANGE_RATE_PROVIDER, useClass: OpenExchangeRatesProvider },
    CurrencyConverter,    // ← registered; constructor dep injected by NestJS
    PlaceOrderUseCase,
  ],
})
export class OrderModule {}
```
