# Subscribers — NestJS + BullMQ
> Sub-file of the `dev-patterns:domain-events` skill. Read when writing a subscriber in a
> NestJS backend. The rules (thin side-effect trigger, idempotency, anti-patterns, Saga
> guards) are in `dev-core:domain-events` → `subscribers.md` and `advanced-delivery.md`.

---

## Registration

A subscriber is an `@Injectable()` provider decorated with `@EventSubscriber(EventNames.X)` and
listed in its feature module's `providers`. `InMemoryEventBus` finds it on module init through
`DiscoveryService` ([event-bus-impl.md](event-bus-impl.md)) — no manual registration.

## Subscriber that enqueues a BullMQ job

```typescript
// infrastructure/subscribers/enqueue-shipment-notification.subscriber.ts
@Injectable()
@EventSubscriber(EventNames.ORDER_SHIPPED)
export class EnqueueShipmentNotificationSubscriber
  implements IEventSubscriber<OrderShippedEvent>
{
  constructor(
    @InjectQueue('notifications') private readonly queue: Queue,
  ) {}

  async handle(event: OrderShippedEvent): Promise<void> {
    // Never calls the external service directly — enqueues a durable BullMQ job.
    // The worker (jobs-queues skill) sends the email with retry and deduplication.
    await this.queue.add(
      'send-shipment-notification',
      {
        order_id:     event.orderId,
        customer_id:  event.customerId,
        tracking_code: event.trackingCode,
        occurred_at:  event.occurredAt,
      },
      {
        // Deterministic jobId: same event redelivered while the job is still in the queue
        // (waiting or active) → BullMQ deduplicates automatically.
        // ⚠️ Scope: if removeOnComplete: true and the job already completed before the
        // re-delivery, BullMQ creates a second job — deduplication window is closed.
        // For critical operations (financial, irreversible) combine with a DB idempotency
        // check inside the processor, or use Pattern C (Idempotency-Key) at the HTTP layer.
        jobId:            `${EventNames.ORDER_SHIPPED}:${event.orderId}`,
        attempts:         3,
        backoff:          { type: 'exponential', delay: 1000 },
        removeOnComplete: true,
        removeOnFail:     false,
      },
    );
  }
}
```

Queue setup and the processor side: `dev-patterns:jobs-queues`.

## Saga subscribers — injecting repositories and the bus

Saga steps (`dev-core:domain-events` → `advanced-delivery.md`) are wired the same way; their
dependencies are injected by token:

```typescript
// infrastructure/subscribers/charge-payment.subscriber.ts
@Injectable()
@EventSubscriber(EventNames.ORDER_PLACED)
export class ChargePaymentSubscriber implements IEventSubscriber<OrderPlacedEvent> {
  constructor(
    @Inject(PAYMENT_REPOSITORY) private readonly payments: IPaymentRepository,
    @Inject(EVENT_BUS)          private readonly eventBus: IEventBus,
  ) {}

  async handle(event: OrderPlacedEvent): Promise<void> {
    // body as in dev-core:domain-events → advanced-delivery.md (idempotency guard first)
  }
}

// infrastructure/subscribers/cancel-order-on-payment-failure.subscriber.ts
@Injectable()
@EventSubscriber(EventNames.PAYMENT_FAILED)
export class CancelOrderOnPaymentFailureSubscriber implements IEventSubscriber<PaymentFailedEvent> {
  constructor(
    @Inject(ORDER_REPOSITORY) private readonly orders: IOrderRepository,
    @Inject(EVENT_BUS)        private readonly eventBus: IEventBus,
  ) {}

  async handle(event: PaymentFailedEvent): Promise<void> {
    // body as in dev-core:domain-events → advanced-delivery.md (idempotency guard first)
  }
}
```
