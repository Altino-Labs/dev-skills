# InMemoryEventBus — Complete Implementation
> Sub-file of the `dev-patterns:domain-events` skill. Read when implementing the EventBus or its
> NestJS module. The bus contract (isolate subscriber failures, never rethrow) is in
> `dev-core:domain-events` — "Graceful degradation".
> For test fakes (StrictEventBus, CapturingEventBus), read `dev-core:test-patterns` →
> `contract-event-tests.md`; NestJS wiring and `createMock<IEventBus>()`:
> `dev-patterns:test-patterns` → `mocks-nestjs.md`.

---

Uses NestJS `DiscoveryService` to auto-register all providers decorated with `@EventSubscriber`.
No manual `register()` calls needed — NestJS wires everything on module init.

```typescript
// infrastructure/events/in-memory-event-bus.ts
import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { DiscoveryService, Reflector } from '@nestjs/core';
import { DomainEvent, EVENT_BUS, IEventBus } from '../../domain/events/i-event-bus';
import { DeliveryResult, IEventDispatcher } from '../../domain/events/i-event-dispatcher';
import { EVENT_SUBSCRIBER_KEY, IEventSubscriber } from '../../domain/events/i-event-subscriber';

@Injectable()
export class InMemoryEventBus implements IEventBus, IEventDispatcher, OnModuleInit {
  private readonly registry = new Map<string, IEventSubscriber[]>();
  // Infrastructure component: NestJS Logger used directly (no DIP binding needed here)
  private readonly logger = new Logger(InMemoryEventBus.name);

  constructor(
    private readonly discovery: DiscoveryService,
    private readonly reflector:  Reflector,
  ) {}

  // Called automatically by NestJS after all providers are instantiated.
  onModuleInit(): void {
    for (const wrapper of this.discovery.getProviders()) {
      const { instance } = wrapper;
      if (!instance?.constructor) continue;

      const eventName = this.reflector.get<string>(EVENT_SUBSCRIBER_KEY, instance.constructor);
      if (!eventName) continue;

      const existing = this.registry.get(eventName) ?? [];
      this.registry.set(eventName, [...existing, instance as IEventSubscriber]);
    }
  }

  // Strict path — used ONLY by the outbox relay: one result per subscriber, nothing swallowed.
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

  // In-process path — isolates failures, logs, never rethrows.
  async publish(event: DomainEvent): Promise<void> {
    for (const r of await this.dispatch(event)) {
      if (r.ok) continue;
      // Logs but never propagates — the use case already completed successfully
      this.logger.warn(
        `EventBus: subscriber "${r.subscriber}" failed for event "${event.eventName}": ` +
        `${r.error instanceof Error ? r.error.message : String(r.error)}`,
      );
    }
  }

  async publishAll(events: DomainEvent[]): Promise<void> {
    await Promise.all(events.map(e => this.publish(e)));
  }
}
```

> **Never use `InMemoryEventBus` in unit or integration tests.**
> It requires `DiscoveryService` and `Reflector` from the NestJS container,
> and swallows subscriber errors — a failing subscriber silently passes.
> Use `StrictEventBus`, `CapturingEventBus`, or `createMock<IEventBus>()` instead.
> See `dev-core:test-patterns` → `contract-event-tests.md` — "Event Bus test fakes" section,
> and `dev-patterns:test-patterns` → `mocks-nestjs.md` — "Event bus in NestJS tests".

## EventBusModule — register once, import everywhere

```typescript
// infrastructure/events/event-bus.module.ts
import { Global, Module } from '@nestjs/common';
import { DiscoveryModule } from '@nestjs/core';
import { EVENT_BUS } from '../../domain/events/i-event-bus';
import { EVENT_DISPATCHER } from '../../domain/events/i-event-dispatcher';
import { InMemoryEventBus } from './in-memory-event-bus';

@Global()   // ← global: every feature module receives EVENT_BUS without importing this module
@Module({
  imports:   [DiscoveryModule],   // required by DiscoveryService
  providers: [
    InMemoryEventBus,
    { provide: EVENT_BUS, useExisting: InMemoryEventBus },
    { provide: EVENT_DISPATCHER, useExisting: InMemoryEventBus },   // strict — relay only
  ],
  exports: [EVENT_BUS, EVENT_DISPATCHER],
})
export class EventBusModule {}
```

Register `EventBusModule` in `AppModule`. Feature modules inject `EVENT_BUS` with no extra imports.

> **`@Global()` and test isolation:** `EventBusModule` is `@Global()`. Any `createTestingModule` that
> imports a module depending on `EVENT_BUS` will share the event bus instance within the same Jest worker.
> **Never import `EventBusModule` in unit or integration tests.** Always override `EVENT_BUS` explicitly:
>
> ```typescript
> const module = await Test.createTestingModule({
>   providers: [
>     MyUseCase,
>     { provide: EVENT_BUS, useValue: createMock<IEventBus>() },  // ← explicit override
>     { provide: MY_REPOSITORY, useValue: createMock<IMyRepository>() },
>   ],
> }).compile();
> ```

## Graceful degradation — subscriber failure never brings down the use case

The `Promise.allSettled` in `dispatch` + the logging loop in `publish` ensure that if subscriber A throws,
subscriber B still runs and the Use Case receives no exception from `publish()`.
The failure is logged with the event name and subscriber class name for observability.
The rule behind it (and why the use case never wraps `publish()` in try/catch):
`dev-core:domain-events` and `dev-core:error-handling`.

`dispatch()` (token `EVENT_DISPATCHER`, port `IEventDispatcher` from `dev-core:domain-events` →
`advanced-delivery.md`) is the strict path: inject it only in the outbox relay, never in a use
case.
