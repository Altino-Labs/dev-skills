# Subscribers — implementation, idempotency, anti-patterns
> Sub-file of the `dev-core:domain-events` skill. Read when writing or reviewing a subscriber.
> Framework-free TypeScript — read it as pseudo-code. Stack wiring (how a subscriber is
> registered with the bus, the job-queue client): stack plugins, e.g.
> `dev-patterns:domain-events` → `subscribers-nestjs.md`.

---

## Subscriber implementation

```typescript
// notifications/infrastructure/subscribers/enqueue-shipment-notification.subscriber.ts
// Registered with the bus for EventNames.ORDER_SHIPPED
export class EnqueueShipmentNotificationSubscriber
  implements IEventSubscriber<OrderShippedEvent>
{
  constructor(private readonly queue: IJobQueue) {}   // port to the project's durable job queue

  async handle(event: OrderShippedEvent): Promise<void> {
    // Never calls the external service directly — enqueues a durable job.
    // The worker sends the email with retry and deduplication.
    await this.queue.add(
      'send-shipment-notification',
      {
        order_id:      event.orderId,
        customer_id:   event.customerId,
        tracking_code: event.trackingCode,
        occurred_at:   event.occurredAt,
      },
      {
        // Deterministic job ID: the same event redelivered while the job is still in the
        // queue (waiting or active) → the queue deduplicates it.
        // ⚠️ Scope: if the queue removes completed jobs and the job already completed before
        // the redelivery, a second job is created — the deduplication window is closed.
        // For critical operations (financial, irreversible) combine with a DB idempotency
        // check inside the worker, or use Pattern C (Idempotency-Key) at the HTTP layer
        // (`dev-core:clean-architecture` → `idempotency.md`).
        jobId:    `${EventNames.ORDER_SHIPPED}:${event.orderId}`,
        attempts: 3,
        backoff:  { type: 'exponential', delay: 1000 },
      },
    );
  }
}
```

> **Idempotency in subscribers:** if the same event can be redelivered (Outbox retry,
> reconnection), `handle()` must be idempotent.
> - **Job-enqueueing subscribers** (email, push, report): pass a deterministic job ID derived
>   from invariant event fields — `jobId: \`${event.eventName}:${event.orderId}\`` —
>   so a redelivered event enqueues the same job ID and the queue deduplicates it while the
>   job is still in the queue. If completed jobs are removed and the job has already
>   finished, deduplication no longer applies — add a DB idempotency check inside the
>   worker for operations where double-execution has irreversible consequences.
> - **DB-write subscribers**: check the entity's current state before mutating:
>   `if (order.status === OrderStatus.SHIPPED) return;`. See [advanced-delivery.md](advanced-delivery.md)
>   for the full idempotency rules in Saga subscribers.

---

## Anti-patterns

### Business logic inside a subscriber
```typescript
// ❌ WRONG — subscriber encodes domain rules: who receives, when to send
async handle(event: OrderShippedEvent): Promise<void> {
  if (event.customerId === SPECIAL_CUSTOMER) { ... }  // domain rule in wrong layer
  const customer = await this.customerRepo.findById(event.customerId);
  if (customer.hasOptedOut) return;                   // another domain rule here
  await this.emailService.send(...);
}

// ✅ CORRECT — subscriber is a thin side-effect trigger; rules stay in the Use Case
async handle(event: OrderShippedEvent): Promise<void> {
  await this.queue.add('send-confirmation', { orderId: event.orderId });
}
```

### Calling a Use Case from inside a subscriber
```typescript
// ❌ WRONG — direct coupling between modules via subscriber
async handle(event: OrderShippedEvent): Promise<void> {
  await this.notifyUseCase.execute({ orderId: event.orderId }); // Use Case inside subscriber
}

// ✅ CORRECT — subscriber enqueues a job; the worker executes the side effect
async handle(event: OrderShippedEvent): Promise<void> {
  await this.queue.add('notify-customer', { orderId: event.orderId });
}
```

> **Exception — saga steps delivered by the Outbox relay:** a subscriber that implements a
> saga step — a forward step (e.g. charging a payment) or a compensating transaction
> (`load → mutate → persist → publish`) — may do its work directly instead of enqueuing a job,
> **provided the event that triggers it is delivered by the Outbox relay** through the strict
> dispatcher. The relay then plays the job queue's role: a failure is retried a bounded number
> of times and dead-lettered. Each such subscriber needs an idempotency guard before acting
> (forward step: does the derived record already exist? compensation: e.g.
> `if (order.status === OrderStatus.CANCELLED) return;`) and writes its outcome event to the
> Outbox. A subscriber on the in-process bus never gets this exception — its failures are only
> logged. See [advanced-delivery.md](advanced-delivery.md) ("Key rules for Sagas").

### Publishing an event before persisting
```typescript
// ❌ WRONG — event published before save; if save fails, subscriber already ran
await this.eventBus.publish(new OrderShippedEvent(...));
await this.orderRepo.save(order);   // fails here → inconsistency

// ✅ CORRECT (in-memory) — persist first, then publish
await this.orderRepo.save(order);
await this.eventBus.publish(new OrderShippedEvent(...));

// ✅ CORRECT (durable) — persist + outbox atomically; the relay delivers
await this.orderRepo.saveWithEvent(order, new OrderShippedEvent(...));
// See advanced-delivery.md — "When to use Outbox vs in-memory Event Bus"
```

### Events for intra-module communication
```typescript
// ❌ WRONG — event between use cases of the same module is unnecessary overhead
// OrderModule → OrderLineItemRemovedEvent → OrderModule (subscriber in the same module)

// ✅ CORRECT — use cases in the same module call each other directly via injection
// Events exist to decouple DIFFERENT MODULES, not use cases within the same module
```

> **When is UC→UC injection within the same module acceptable?**
> Direct injection of Use Case B into Use Case A is valid only when A delegates an entire
> operation to B — and does not use B's return value to decide how to mutate A's own aggregate.
> If A reads data from B's aggregate to mutate its own, use a Domain Event instead.
> Across module boundaries, writes and side effects always go through the event bus — never
> inject another module's use cases or repositories. Cross-module reads use that module's public
> query API (`SKILL.md` — "Core principle").
> See `dev-core:clean-architecture` → `domain-services.md` — "Use Case calling another Use Case".

### Mutable reference in event payload
```typescript
// ❌ WRONG — the subscriber can mutate the received object
new OrderShippedEvent(order);   // passes the full entity

// ✅ CORRECT — immutable primitives only; the entity does not leak outside the module
new OrderShippedEvent(order.id, order.customerId, input.trackingCode);
```
