---
name: domain-events
description: >
  Domain events for any stack: the core principle (writes and side effects across modules go
  through events; cross-module reads go through the other module's public query API),
  event structure and naming, the event bus port and subscriber interface, publishing from a
  use case after persisting, idempotent subscribers, graceful degradation (the bus isolates
  subscriber failures), the project event catalog (names as constants, additive payload
  evolution), anti-patterns, testing with fakes, and durable delivery — when to use an Outbox
  vs an in-memory bus, the Outbox pattern and the Saga pattern with compensation. Invoke
  automatically when creating domain events, subscribers, publishing events in use cases, or
  implementing any inter-module communication via events (without direct coupling between use
  cases), in any language or framework.
---

# Domain Events

> **How to read the examples.** Every example in this skill is framework-free TypeScript —
> plain classes, interfaces and functions, no decorators, no framework, no database, queue or
> logging library. Read it as pseudo-code and translate it to the project's language and
> idioms. Stack-specific implementations (the production event bus and how it discovers
> subscribers, DI wiring, the outbox tables/SQL and the relay scheduler, the job-queue client)
> live in stack plugins — e.g. `dev-patterns:domain-events` for NestJS + Supabase — and in the
> project's own delta skill (`.claude/skills/<project>-domain-events/`), when they exist. Load
> them together with this skill.

## Core principle

Modules never reach into each other's internals. Two channels cross a module boundary:

- **Writes and side effects across modules go through domain events** published on the Event
  Bus. Module A never calls a command/use case of module B to change B's state.
- **Reads across modules go through the other module's public query API** — a facade / query
  service the module exposes on purpose (read-only, returns plain DTOs, no entities). Never
  through its repositories, its tables or its internal use cases. (This is the Spring
  Modulith-style split: events for state changes, a published API for queries.)

```
OrderModule  →  publishes: OrderShippedEvent
             ←  subscribes: NotificationModule (SendOrderConfirmationEmailSubscriber)
             ←  subscribes: AlertModule (CreateShippingAlertSubscriber)

InvoiceModule → reads:     ICustomerQueries.getBillingProfile(customerId)  // CustomerModule's public query API
```

```typescript
// customers/public/i-customer-queries.ts — the only thing other modules may import from CustomerModule
export interface ICustomerQueries {
  getBillingProfile(customerId: string): Promise<CustomerBillingProfile | null>;   // plain DTO
}
```

A query API that starts accumulating commands, or a caller that needs a synchronous answer
from another module to *change* that module's state, is a sign the boundary is wrong — raise
it with the architect.

Events decouple **different modules**. Use cases inside the same module call each other
directly — see [subscribers.md](subscribers.md), "Events for intra-module communication".

### Orchestrator / composition modules

Some modules exist only to compose others — e.g. an assistant that proposes actions and, once
the user confirms, executes them across many modules; a back-office command layer; a BFF. Such
a module is the one deliberate exception to "never call another module's use case", with
fixed limits:

- **Allowed:** calling the target modules' **published** use cases (a command API each module
  exports on purpose, next to its public query API) and their public query APIs.
- **Never:** their repositories, tables, entities or internal (unexported) use cases — the
  target module's own use case still enforces its invariants and authorization and publishes
  its own events.
- **One-way:** the orchestrator owns none of the target modules' state or business rules, and
  no target module depends back on it.
- Record each orchestrator module and the use cases it is allowed to call in the project's
  architecture doc, so it doesn't become a back door into every module.

---

## Domain event structure

```typescript
// shared/events/domain-event.ts
export interface DomainEvent {
  readonly eventName: string;
  readonly occurredAt: Date;
}

// shared/events/catalog/order-shipped.event.ts
export class OrderShippedEvent implements DomainEvent {
  readonly eventName = EventNames.ORDER_SHIPPED;   // 'order.shipped' — see event-catalog.md
  readonly occurredAt = new Date();                // also the shipping time

  constructor(
    public readonly orderId: string,
    public readonly customerId: string,
    public readonly trackingCode: string,
  ) {}
}
```

**Where events live:** the ports (`DomainEvent`, `IEventBus`, `IEventSubscriber`) in
`shared/events/`, the event classes and the event-name constants in `shared/events/catalog/` —
the folder layout of `dev-core:clean-architecture` ("Folder structure for each new module").

**Naming rules:**
- Class: `PastTenseEvent` → `OrderShippedEvent`
- `eventName`: `'module.past_tense'` → `'order.shipped'`, defined once as a constant
  ([event-catalog.md](event-catalog.md))
- Always include `occurredAt` for auditing
- Complete and immutable payload — never a reference to a mutable entity

---

## Event Bus interface (port)

```typescript
// shared/events/i-event-bus.ts
export interface IEventBus {
  publish(event: DomainEvent): Promise<void>;
  publishAll(events: DomainEvent[]): Promise<void>;
}
```

The domain and the use cases depend only on this interface — never on the concrete
implementation (dependency rule: `dev-core:clean-architecture`).

---

## Subscriber interface

```typescript
// shared/events/i-event-subscriber.ts
export interface IEventSubscriber<T extends DomainEvent = DomainEvent> {
  handle(event: T): Promise<void>;
}
```

Each subscriber is registered with the bus for one event name — by the composition root, or by
the framework's discovery mechanism (stack plugin). Always register with the event-name
constant, never a string literal ([event-catalog.md](event-catalog.md)).

---

## Publishing events in a Use Case

```typescript
// orders/use-cases/ship-order.use-case.ts
export class ShipOrderUseCase {
  constructor(
    private readonly orders: IOrderRepository,
    private readonly eventBus: IEventBus,
  ) {}

  async execute(input: ShipOrderInput): Promise<ShipOrderOutput> {
    const order = await this.orders.findById(input.orderId);
    if (!order) throw new OrderNotFoundException(input.orderId);

    // State changes only through the entity method, which returns the new state
    const shipped = order.markAsShipped(input.trackingCode);
    const saved   = await this.orders.save(shipped);

    // Publish AFTER persistence — never before
    await this.eventBus.publish(
      new OrderShippedEvent(saved.id, saved.customerId, input.trackingCode),
    );

    return { order_id: saved.id, status: saved.status };
  }
}
```

**Rule:** Always publish events **after** persisting. Never before. When losing the event on a
process restart between `persist` and `publish` is unacceptable, write it to an Outbox in the
same transaction instead — see [advanced-delivery.md](advanced-delivery.md).

---

## Subscriber implementation

A subscriber is a thin side-effect trigger: it reacts to the event and, for durable side
effects (email, push, external API), **enqueues a background job** instead of calling the
external service directly (the one exception: saga steps delivered by the Outbox relay —
[subscribers.md](subscribers.md)). Subscribers must be **idempotent** — the same event can be
delivered more than once (Outbox retry, reconnection).

The full pattern, the idempotency rules and the anti-patterns are in
[subscribers.md](subscribers.md).

---

## Graceful degradation — subscriber failure never brings down the use case

The in-process bus runs every subscriber of the event, **isolates their failures**
(allSettled-style: one failing subscriber does not stop the others) and logs each failure with
the event name and the subscriber name. It never rethrows — the use case already completed.

```typescript
// shared/infrastructure/events/in-memory-event-bus.ts
export class InMemoryEventBus implements IEventBus {
  private readonly registry = new Map<string, IEventSubscriber[]>();

  constructor(private readonly logger: { warn(message: string): void }) {}

  register(eventName: string, subscriber: IEventSubscriber): this {
    const existing = this.registry.get(eventName) ?? [];
    this.registry.set(eventName, [...existing, subscriber]);
    return this;
  }

  async publish(event: DomainEvent): Promise<void> {
    const subscribers = this.registry.get(event.eventName) ?? [];

    await Promise.allSettled(
      subscribers.map(async (subscriber) => {
        try {
          await subscriber.handle(event);
        } catch (error) {
          // Logs but never propagates — the use case already completed
          this.logger.warn(
            `Subscriber failed: event=${event.eventName} subscriber=${subscriber.constructor.name} error=${error instanceof Error ? error.message : String(error)}`,
          );
        }
      })
    );
  }

  async publishAll(events: DomainEvent[]): Promise<void> {
    await Promise.all(events.map(e => this.publish(e)));
  }
}
```

Consequently the use case **does not wrap `eventBus.publish` in try/catch** — it would mask
configuration errors (e.g. a missing event-bus binding). Same rule as
`dev-core:error-handling` → "Graceful degradation in non-critical services".

> **This isolating `publish` is for the in-process path only.** The Outbox relay must never
> deliver through it — the relay could not see a failure, so retries and dead letter would
> never fire. The relay uses a **strict** delivery port, `IEventDispatcher.dispatch(event)`,
> which returns one result per subscriber; see [advanced-delivery.md](advanced-delivery.md),
> "Strict delivery for the relay".

---

## Project event catalog

Define your project's event catalog in the project spec (e.g. a section of `PROJECT.md`, or
equivalent). Event names follow `domain.past_tense_verb` (`order.placed`, `payment.failed`,
`user.registered`), live as constants in one file, and payloads evolve additively only — see
[event-catalog.md](event-catalog.md).

---

## Anti-patterns

Business logic inside a subscriber, calling a use case from a subscriber, publishing before
persisting, events between use cases of the same module, and mutable references in the
payload — each with the correct alternative in [subscribers.md](subscribers.md), "Anti-patterns".

---

## Testing events

Use the event-bus fakes from `dev-core:test-patterns` → `contract-event-tests.md` ("Event Bus
test fakes"): `CapturingEventBus` in use case unit tests (was it published, with what
payload?), `StrictEventBus` in integration tests (the subscriber must run and its errors must
fail the test). Never use the production bus in tests — it swallows subscriber errors.

What every use case that publishes must cover:

```typescript
it('should publish OrderPlacedEvent after persisting the order', async () => {
  await useCase.execute(ValidPlaceOrderInput);

  const [event] = eventBus.capturedOf<OrderPlacedEvent>(EventNames.ORDER_PLACED);
  expect(event.orderId).toBe(ValidPlaceOrderInput.id);
});

it('should NOT publish event when the order is not found', async () => {
  await expect(useCase.execute(UnknownOrderInput)).rejects.toThrow(OrderNotFoundException);
  expect(eventBus.captured).toHaveLength(0);
});

it('should NOT publish event when persistence fails', async () => {
  // publish must never fire before save completes — this verifies the order guarantee
  // (a fake repository whose save() throws DatabaseException)
  useCase = new PlaceOrderUseCase(new FailingOrderRepository(), eventBus);
  await expect(useCase.execute(ValidPlaceOrderInput)).rejects.toThrow(DatabaseException);
  expect(eventBus.captured).toHaveLength(0);
});
```

---

## Durable delivery — Outbox and Saga

- **Outbox vs in-memory bus:** if losing an event creates a data inconsistency visible to the
  user, the Outbox is mandatory; if it causes a missed external call, recommended; if it is a
  recoverable inconvenience, the in-memory bus is enough.
- **Outbox pattern:** write the event in the **same transaction** as the entity; a relay
  claims entries atomically, delivers them through a **strict** dispatcher that reports each
  subscriber's failure (never the isolating `publish`), retries with a bounded attempt count
  and moves exhausted entries to a dead letter; subscribers dedupe redeliveries.
- **Saga pattern:** a sequence of local transactions across aggregates that cannot share a
  transaction, with **compensating transactions** that undo earlier steps on failure;
  choreography (each module reacts to events) is preferred.

Details: [advanced-delivery.md](advanced-delivery.md).

---

## Supporting files

- [subscribers.md](subscribers.md) — subscriber implementation (enqueue a durable job with a
  deterministic job ID), idempotency rules, anti-patterns.
- [event-catalog.md](event-catalog.md) — event naming, the event-name constants file, payload
  evolution rules (additive only).
- [advanced-delivery.md](advanced-delivery.md) — when to use an Outbox vs an in-memory bus,
  the Outbox pattern (same-transaction write, atomic claim, relay with strict delivery,
  retries, dead letter, dedupe), the Saga pattern with compensation and its key rules.
