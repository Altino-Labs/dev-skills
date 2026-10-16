# Advanced Delivery — Outbox Pattern and Saga
> Sub-file of the `dev-core:domain-events` skill. Read when implementing durable event delivery
> (events must survive process restarts) or eventual consistency across aggregates.
> Framework-free TypeScript — read it as pseudo-code. The database tables, SQL functions,
> repository code and relay scheduler for a given stack live in stack plugins, e.g.
> `dev-patterns:domain-events` → `outbox-supabase.md` (NestJS + Supabase/Postgres).

---

## When to use Outbox vs in-memory Event Bus

| Loss of event | Pattern |
|---|---|
| Creates data inconsistency visible to the user | Outbox — mandatory |
| Causes a missed external call (email, push) | Outbox — recommended |
| Is a recoverable inconvenience (cache miss, audit lag) | In-memory Event Bus — sufficient |

The in-memory Event Bus loses events when the process restarts between `persist` and `publish`.
For side effects where that loss is unacceptable, use the Outbox Pattern: write the event to
a database table **in the same transaction** as the entity, then deliver it asynchronously from a worker.

---

## Outbox Pattern — durable event delivery across process restarts

### The outbox table

One row per event, written in the same transaction as the entity change:

| Field | Purpose |
|---|---|
| `id` | entry identity |
| `event_name` | the event-name constant |
| `payload` | the **complete** serialized event (all public fields + `occurredAt` as ISO 8601) |
| `published` | `false` until delivered (or dead-lettered) — the relay only reads unpublished rows |
| `processing_since` | set when a worker claims the entry; cleared on done/fail |
| `retry_count` | incremented on each failed delivery |
| `created_at` | delivery order |
| `dead_letter_reason`, `dead_lettered_at` | set when moved to dead letter |

Index the claim query: unpublished + not claimed (or stale claim), ordered by `created_at`.

Dead-lettered entries keep `published = true` so the relay never picks them up again.
Query them with `dead_lettered_at IS NOT NULL` for manual inspection and replay.

### Atomic claim — safe across multiple instances

Two relay instances must never claim the same entry. Claim with a single atomic statement that
locks the selected rows and **skips rows already locked** by another instance (e.g.
`SELECT ... FOR UPDATE SKIP LOCKED` in PostgreSQL): instance A locks rows 1–10; instance B
skips to rows 11–20.

Increment `retry_count` with a single `UPDATE ... SET retry_count = retry_count + 1` — never a
read-then-write pair, which loses an increment when two workers recover the same stale lock.

**Stale lock recovery:** if a worker crashes while holding entries, `processing_since` stays set
but `published` stays `false`. Once the lock is older than a TTL (e.g. 30 seconds) the next
claim picks them up automatically — no manual intervention needed.

### OutboxRepository interface

```typescript
// shared/events/i-outbox.repository.ts
export interface IOutboxRepository {
  save(event: DomainEvent): Promise<void>;
  claim(batchSize?: number): Promise<OutboxEntry[]>;   // atomic — safe for multiple instances
  markPublished(id: string): Promise<void>;
  markFailed(id: string): Promise<void>;               // releases lock, increments retry_count
  markDeadLetter(id: string, reason: string): Promise<void>;
}

export interface OutboxEntry {
  id:         string;
  eventName:  string;
  payload:    Record<string, unknown>;
  retryCount: number;
  createdAt:  Date;
}
```

### Use Case — persist entity and outbox entry in the same transaction

The atomicity guarantee comes from a single database transaction that writes both. The
repository exposes it as one method:

```typescript
// orders/domain/repositories/i-order.repository.ts
export interface IOrderRepository {
  saveWithEvent(order: Order, event: DomainEvent): Promise<Order>;
}
```

The implementation (one transaction, or one stored procedure) updates the entity and inserts
the outbox row. It serializes the **complete** event — all public fields plus `occurredAt` as
an ISO string; a truncated payload makes the relay publish an event with undefined fields and
subscribers fail silently.

> **Optimistic-lock entities — enforce the version check in the same transaction.** For
> entities that use Optimistic Locking (a `version` column checked on save —
> `dev-core:clean-architecture` → `entities.md`, "Optimistic Locking"), the entity update in
> `saveWithEvent` must be conditional (`WHERE id = ? AND version = ?`, setting
> `version = version + 1`). When it matches zero rows the transaction aborts — no outbox row
> is written — and the repository throws `OptimisticLockException` (defined in
> `dev-core:error-handling`).

```typescript
// orders/use-cases/ship-order.use-case.ts
async execute(input: ShipOrderInput): Promise<ShipOrderOutput> {
  const order = await this.orders.findById(input.orderId);
  if (!order) throw new OrderNotFoundException(input.orderId);

  const shipped = order.markAsShipped(input.trackingCode);
  const event   = new OrderShippedEvent(shipped.id, shipped.customerId, input.trackingCode);

  // Entity + outbox entry written atomically — event survives process restart
  const saved = await this.orders.saveWithEvent(shipped, event);

  return this.toOutput(saved);
  // ← does NOT call eventBus.publish() here; the relay reads the outbox
}
```

### Strict delivery for the relay

The in-process bus (`IEventBus.publish`, SKILL.md "Graceful degradation") isolates subscriber
failures and never rethrows. That is right for the in-process path — the use case already
committed — but fatal for the relay: a failing subscriber would look like a success, the entry
would be marked published, and retries and dead letter would never fire.

The relay therefore delivers through a separate **strict** port that reports every
subscriber's outcome. Only the relay uses it:

```typescript
// shared/events/i-event-dispatcher.ts
export type DeliveryResult =
  | { subscriber: string; ok: true }
  | { subscriber: string; ok: false; error: unknown };

export interface IEventDispatcher {
  // Runs every subscriber registered for event.eventName; never swallows a failure —
  // returns one result per subscriber so the caller decides what to do.
  dispatch(event: DomainEvent): Promise<DeliveryResult[]>;
}
```

One registry can serve both paths — the in-process `publish` is `dispatch` plus logging:

```typescript
// shared/infrastructure/events/in-memory-event-bus.ts (strict core + isolating wrapper)
async dispatch(event: DomainEvent): Promise<DeliveryResult[]> {
  const subscribers = this.registry.get(event.eventName) ?? [];
  const settled = await Promise.allSettled(subscribers.map(s => s.handle(event)));
  return settled.map((r, i) => {
    const subscriber = subscribers[i].constructor.name;
    return r.status === 'fulfilled'
      ? { subscriber, ok: true }
      : { subscriber, ok: false, error: r.reason };
  });
}

async publish(event: DomainEvent): Promise<void> {
  for (const r of await this.dispatch(event)) {
    if (!r.ok) this.logger.warn(`Subscriber failed: event=${event.eventName} subscriber=${r.subscriber} error=${String(r.error)}`);
  }   // never rethrows — in-process path only
}
```

A retry redelivers the event to **all** its subscribers, including those that already
succeeded — which is why subscribers must be idempotent ([subscribers.md](subscribers.md)).

### Outbox relay — atomic claim, retry, dead letter

**Rule:** the relay NEVER queries unpublished rows directly.
Always uses `claim()` — the only mechanism that is safe across multiple instances.

```typescript
// shared/infrastructure/events/outbox-relay.ts
export class OutboxRelay {
  // Total delivery attempts before dead-lettering.
  // retryCount starts at 0 and is incremented by markFailed() after each failure.
  // Dead-letter fires when retryCount >= MAX_ATTEMPTS − 1, giving exactly MAX_ATTEMPTS total.
  private readonly MAX_ATTEMPTS = 3;

  constructor(
    private readonly outbox:     IOutboxRepository,
    private readonly dispatcher: IEventDispatcher,   // strict path — never IEventBus.publish
    private readonly logger:     { warn(m: string): void; error(m: string): void },
  ) {}

  // Called by the project's scheduler at a fixed interval (default: every 30 seconds — tune
  // to event volume; a very short interval multiplies DB queries per instance, so shorten it
  // only when p95 delivery latency exceeds your SLA).
  async relay(): Promise<void> {
    // claim() is atomic — two instances running simultaneously never process the same entry
    const entries = await this.outbox.claim(10);
    if (entries.length === 0) return;

    await Promise.allSettled(entries.map(e => this.processEntry(e)));
  }

  private async processEntry(entry: OutboxEntry): Promise<void> {
    try {
      // payload.occurredAt was serialized as an ISO 8601 string.
      // Reconstruct it as a Date before publishing so subscribers receive the correct type.
      const event: DomainEvent = {
        ...entry.payload,
        eventName:  entry.eventName,
        occurredAt: new Date(entry.payload['occurredAt'] as string),
      };
      const failures = (await this.dispatcher.dispatch(event)).filter(r => !r.ok);
      if (failures.length > 0) {
        // Surface subscriber failures so the catch below retries or dead-letters the entry
        throw new Error(
          `subscribers failed: ${failures.map(f => `${f.subscriber}: ${String(f.error)}`).join('; ')}`,
        );
      }
      await this.outbox.markPublished(entry.id);
    } catch (error) {
      this.logger.warn(
        `failed to process entry: entryId=${entry.id} eventName=${entry.eventName} retryCount=${entry.retryCount} error=${error instanceof Error ? error.message : String(error)}`,
      );

      if (entry.retryCount >= this.MAX_ATTEMPTS - 1) {
        await this.outbox.markDeadLetter(entry.id, String(error));
        this.logger.error(`entry moved to dead letter: entryId=${entry.id} eventName=${entry.eventName}`);
      } else {
        await this.outbox.markFailed(entry.id);
      }
    }
  }
}
```

Delivery is **at-least-once**: an entry can be delivered again after a crash between
`dispatch` and `markPublished`, or after a retry. Subscribers dedupe — see
[subscribers.md](subscribers.md), "Idempotency in subscribers".

### Anti-patterns

```typescript
// ❌ WRONG — plain SELECT: two instances process the same entry simultaneously
const entries = await this.outbox.findUnpublished();

// ❌ WRONG — entity saved, then event published in two separate operations
await this.orderRepo.save(order);
await this.eventBus.publish(new OrderShippedEvent(...));   // may never run if process crashes

// ✅ CORRECT (Outbox) — both written atomically; the relay delivers when ready
await this.orderRepo.saveWithEvent(order, new OrderShippedEvent(...));

// ✅ ALSO CORRECT (in-memory) — when loss is an acceptable inconvenience
await this.orderRepo.save(order);
await this.eventBus.publish(new OrderShippedEvent(...));   // loss = cache miss, not data gap
```

> For writes that span two repositories, see `dev-core:clean-architecture` skill →
> `transactions.md` "Decision tree".

---

## Saga Pattern — eventual consistency across aggregates

Use a Saga when two separate aggregates need to stay consistent but **cannot** share a
database transaction (different services, or eventual consistency is acceptable).

A Saga is a sequence of local transactions. If one step fails, **compensating transactions**
undo the previous steps. The Outbox Pattern makes each step durable.

### When to use Saga vs. atomic transaction

| Scenario | Pattern |
|---|---|
| Same DB, atomicity required | One transaction / consolidated repository method (Layer 1 — `dev-core:clean-architecture`, `transactions.md`) |
| Inconsistency is a financial or irreversible risk | One transaction — mandatory |
| Inconsistency is a recoverable inconvenience | Saga (Layer 3) |
| Different services / microservices | Saga — only option |

### Choreography Saga (event-driven — preferred for simple flows)

Each aggregate reacts to an event and publishes the next one.
No central coordinator — modules stay decoupled.

```
PlaceOrderUseCase
  └── publishes: OrderPlacedEvent
        └── PaymentSubscriber
              ├── success → charges payment → publishes: PaymentProcessedEvent
              │     └── ShipmentSubscriber
              │           ├── success → creates shipment → publishes: ShipmentCreatedEvent
              │           └── failure → publishes: ShipmentFailedEvent
              │                 └── PaymentCompensationSubscriber
              │                       └── refunds payment → publishes: PaymentRefundedEvent
              └── failure → publishes: PaymentFailedEvent
                    └── OrderCancellationSubscriber
                          └── cancels order → publishes: OrderCancelledEvent
```

```typescript
// shared/events/catalog/order-placed.event.ts — carries what the payment step reads
export class OrderPlacedEvent implements DomainEvent {
  readonly eventName = EventNames.ORDER_PLACED;
  readonly occurredAt = new Date();
  constructor(
    public readonly orderId:     string,
    public readonly customerId:  string,
    public readonly currency:    string,
    public readonly totalAmount: string,   // decimal string (Money.amount) — never a float
  ) {}
}

// shared/events/catalog/payment-processed.event.ts — eventName MUST use EventNames constant
export class PaymentProcessedEvent implements DomainEvent {
  readonly eventName = EventNames.PAYMENT_PROCESSED;
  readonly occurredAt = new Date();
  constructor(
    public readonly orderId:   string,
    public readonly paymentId: string,
    public readonly amount:    number,
    public readonly currency:  string,
  ) {}
}

// shared/events/catalog/payment-failed.event.ts
export class PaymentFailedEvent implements DomainEvent {
  readonly eventName = EventNames.PAYMENT_FAILED;
  readonly occurredAt = new Date();
  constructor(public readonly orderId: string, public readonly reason: string) {}
}

// shared/events/catalog/shipment-created.event.ts
export class ShipmentCreatedEvent implements DomainEvent {
  readonly eventName = EventNames.SHIPMENT_CREATED;
  readonly occurredAt = new Date();
  constructor(public readonly orderId: string, public readonly shipmentId: string) {}
}

// shared/events/catalog/order-cancelled.event.ts
export class OrderCancelledEvent implements DomainEvent {
  readonly eventName = EventNames.ORDER_CANCELLED;
  readonly occurredAt = new Date();
  constructor(public readonly orderId: string, public readonly reason: string) {}
}
```

```typescript
// payments/infrastructure/subscribers/charge-payment.subscriber.ts
// Registered with the bus for EventNames.ORDER_PLACED
// A saga forward step: it charges the payment directly instead of enqueuing a job — allowed
// because OrderPlacedEvent is delivered by the Outbox relay's strict dispatch, so a failure is
// retried and dead-lettered (subscribers.md, "Exception — saga steps delivered by the Outbox
// relay"). Saga steps write their outcome event to the Outbox (not the in-process bus), so the
// next step — including a compensation — gets the same guarantee. (Where the step has its own
// write, use saveWithEvent to store both in one transaction.)
export class ChargePaymentSubscriber implements IEventSubscriber<OrderPlacedEvent> {
  constructor(
    private readonly payments: IPaymentRepository,
    private readonly outbox:   IOutboxRepository,
  ) {}

  async handle(event: OrderPlacedEvent): Promise<void> {
    // Idempotency guard — Outbox retries can redeliver the same OrderPlacedEvent.
    // Check whether a payment already exists for this order before acting.
    // Every saga forward step needs this guard, not just compensation subscribers.
    const existing = await this.payments.findByOrderId(event.orderId);
    if (existing) {
      // Re-publish the outcome so downstream subscribers receive it on retry too.
      await this.outbox.save(
        new PaymentProcessedEvent(event.orderId, existing.id, existing.amount, existing.currency),
      );
      return;
    }

    try {
      const payment = await this.payments.charge(event.orderId, event.totalAmount, event.currency);
      await this.outbox.save(
        new PaymentProcessedEvent(event.orderId, payment.id, payment.amount, payment.currency),
      );
    } catch (error) {
      await this.outbox.save(
        new PaymentFailedEvent(event.orderId, (error as Error).message),
      );
    }
  }
}

// orders/infrastructure/subscribers/cancel-order-on-payment-failure.subscriber.ts
// Registered with the bus for EventNames.PAYMENT_FAILED
// Delivered by the relay's strict dispatch — if it throws, the PaymentFailedEvent entry is
// retried and then dead-lettered.
export class CancelOrderOnPaymentFailureSubscriber implements IEventSubscriber<PaymentFailedEvent> {
  constructor(private readonly orders: IOrderRepository) {}

  async handle(event: PaymentFailedEvent): Promise<void> {
    const order = await this.orders.findById(event.orderId);
    if (!order || order.status === OrderStatus.CANCELLED) return;  // idempotency guard — compensating step
    const cancelled = order.cancel();
    // Entity + next event in one transaction
    await this.orders.saveWithEvent(cancelled, new OrderCancelledEvent(cancelled.id, 'PAYMENT_FAILED'));
  }
}
```

### Key rules for Sagas

- **Idempotency guard in every subscriber — both forward steps and compensations** — the same event may be delivered more than once (Outbox retry). Always check current state (or existence of a derived record) before acting. Forward steps: check if the derived record already exists. Compensating steps: check entity state (`if (order.status === OrderStatus.CANCELLED) return;`).
- **Re-publish the outcome on idempotent path** — if the idempotency guard detects the step already ran, re-publish the success/failure event so downstream subscribers receive it on the retry.
- **Compensating transactions must be idempotent** — cancelling an already-cancelled order must be a no-op.
- **Never share state between saga steps via mutable objects** — pass IDs in events, load fresh state in each subscriber.
- **Use Outbox** for any step that calls an external service — prevents losing saga progress on process restart.
- **Compensating transaction failures go to dead letter** — the event that triggers a compensation is delivered through the Outbox, so when the compensating subscriber throws, the relay's strict `dispatch` reports it, the entry is retried a bounded number of times and then moved to dead letter (`outbox.markDeadLetter()`). A failed compensation represents a real state inconsistency; it must never be silently dropped or retried indefinitely — alert on dead-lettered compensation events.

### Anti-patterns

```typescript
// ❌ WRONG — Orchestration Saga with direct use case calls (tight coupling)
export class PlaceOrderSaga {
  async run(orderId: string): Promise<void> {
    await this.inventoryUseCase.reserve(orderId);   // direct call — couples modules
    await this.paymentUseCase.charge(orderId);
  }
}

// ✅ CORRECT — Choreography: each module reacts to events independently
// OrderModule publishes → InventoryModule reacts → PaymentModule reacts
// No module knows about the others
```
