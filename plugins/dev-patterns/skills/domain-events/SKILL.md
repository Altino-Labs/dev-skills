---
name: domain-events
description: >
  NestJS + Supabase implementation layer of dev-core:domain-events — the EVENT_BUS token and
  @EventSubscriber decorator, InMemoryEventBus with DiscoveryService/Reflector auto-registration,
  the global EventBusModule (register once, import everywhere), Nest subscriber registration
  and BullMQ-enqueueing subscribers, and the Outbox on Supabase/Postgres (outbox table, claim /
  fail / dead-letter SQL functions, saveWithEvent RPC, @Cron relay). Invoke automatically
  (together with dev-core:domain-events) when creating domain events, subscribers, publishing
  events in use cases, or implementing inter-module communication via events in a NestJS +
  Supabase backend.
---

# Domain Events — NestJS + Supabase implementation

**Load `dev-core:domain-events` first.** It holds the concepts and rules (cross-module writes
and side effects through events, reads through the module's query API, event structure and naming, the event bus port and subscriber interface,
publish after persisting, idempotent subscribers, graceful degradation, the event catalog and
payload evolution, anti-patterns, testing with fakes, Outbox vs in-memory bus, the Outbox and
Saga patterns). This skill only shows how to implement them with NestJS (Fastify) and
Supabase/Postgres; it does not restate the rules.

## Event bus token and subscriber decorator

```typescript
// domain/events/i-event-bus.ts
export const EVENT_BUS = Symbol('EVENT_BUS');   // DI token for IEventBus (dev-core port)

// domain/events/i-event-dispatcher.ts
export const EVENT_DISPATCHER = Symbol('EVENT_DISPATCHER');   // strict IEventDispatcher — outbox relay only

// domain/events/i-event-subscriber.ts
export const EVENT_SUBSCRIBER_KEY = 'EVENT_SUBSCRIBER';

export const EventSubscriber = (eventName: string) =>
  SetMetadata(EVENT_SUBSCRIBER_KEY, eventName);
```

Use cases receive the bus with `@Inject(EVENT_BUS) private readonly eventBus: IEventBus`.
Subscribers are `@Injectable()` providers decorated with `@EventSubscriber(EventNames.X)`;
`InMemoryEventBus` discovers them on module init — no manual `register()` calls. Implementation,
`EventBusModule` and test isolation: [event-bus-impl.md](event-bus-impl.md).

## Graceful degradation in this stack

`InMemoryEventBus.publish()` is the bus that isolates subscriber failures
(`Promise.allSettled` + try/catch, logged with event and subscriber name) — see
[event-bus-impl.md](event-bus-impl.md). It logs with NestJS's built-in `Logger` used directly
(`new Logger(ClassName.name)`), never an injected `ILogger` interface — see
`dev-patterns:logging-observability`.

## Subscribers in this stack

Durable side effects are enqueued as BullMQ jobs (`@InjectQueue`) with a deterministic `jobId`;
Saga subscribers inject repositories and the bus by token — see
[subscribers-nestjs.md](subscribers-nestjs.md). Worker side: `dev-patterns:jobs-queues`.

## Outbox on Supabase/Postgres

The outbox table, the `claim_outbox_entries` / `mark_outbox_failed` /
`move_outbox_to_dead_letter` functions, `SupabaseOutboxRepository`, the `saveWithEvent`
dedicated RPC (with the optimistic-lock variant) and the `@Cron` relay processor:
[outbox-supabase.md](outbox-supabase.md).

## Testing events in this stack

The fakes (`CapturingEventBus`, `StrictEventBus`) are in `dev-core:test-patterns`; with a
`createMock<IEventBus>()` auto-mock (`dev-patterns:test-patterns` → `mocks-nestjs.md`, "Event
bus in NestJS tests"):

```typescript
it('should publish OrderProcessedEvent after processing', async () => {
  orderRepo.findById.mockResolvedValue(OrderFactory.active());
  shipmentRepo.save.mockResolvedValue(ShipmentFactory.valid());

  await useCase.execute(ValidProcessInput);

  expect(eventBus.publish).toHaveBeenCalledWith(
    expect.objectContaining({
      eventName: EventNames.ORDER_PROCESSED,
      orderId: ValidProcessInput.orderId,
    })
  );
});

it('should NOT publish event when order is not found', async () => {
  orderRepo.findById.mockResolvedValue(null);
  await expect(useCase.execute(ValidProcessInput)).rejects.toThrow(OrderNotFoundException);
  expect(eventBus.publish).not.toHaveBeenCalled();
});

it('should NOT publish event when persistence fails', async () => {
  // publish must never fire before save completes — this verifies the order guarantee
  orderRepo.findById.mockResolvedValue(OrderFactory.active());
  shipmentRepo.save.mockRejectedValue(new DatabaseException('DB_ERROR', 'connection lost'));
  await expect(useCase.execute(ValidProcessInput)).rejects.toThrow(DatabaseException);
  expect(eventBus.publish).not.toHaveBeenCalled();
});
```

## Supporting files

- [event-bus-impl.md](event-bus-impl.md) — `InMemoryEventBus` (DiscoveryService + Reflector
  auto-registration of `@EventSubscriber` providers), `EventBusModule` (`@Global()`, register
  once in `AppModule`), and why tests never import it.
- [subscribers-nestjs.md](subscribers-nestjs.md) — Nest subscriber registration, the
  BullMQ-enqueueing subscriber (`@InjectQueue`, deterministic `jobId`, `removeOnComplete`
  dedup window), Saga subscribers wired with `@Inject` tokens.
- [outbox-supabase.md](outbox-supabase.md) — outbox migration and SQL functions
  (`FOR UPDATE SKIP LOCKED` claim, atomic retry increment, dead letter),
  `SupabaseOutboxRepository`, the `save_order_with_event` RPC (plus optimistic-lock variant),
  and the `@Cron` `OutboxRelayProcessor`.
