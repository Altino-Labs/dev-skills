# Project event catalog — naming, constants, payload evolution
> Sub-file of the `dev-core:domain-events` skill. Read when defining a new event or changing
> an existing event's payload. Framework-free TypeScript — read it as pseudo-code.

---

## Project event catalog

Define your project's event catalog in the project spec (e.g. a section of `PROJECT.md`, or equivalent).

Convention for event names: `domain.past_tense_verb` — e.g.:
- `order.placed`, `order.shipped`, `order.cancelled`
- `payment.processed`, `payment.failed`
- `user.registered`, `user.deactivated`

### Event name constants — mandatory

Never use string literals for event names when registering a subscriber or in `eventBus.publish()`.
A typo (`'order.shiped'` instead of `'order.shipped'`) causes the subscriber to silently never fire — no error, no log.

Define the names once (here `shared/events/catalog/event-names.ts`) and import them everywhere.
The TS version below uses an object `as const`; the equivalent elsewhere is a Python
`StrEnum` (or `Enum` with string values), a Java or C# `enum` / class of `const string`s, or a
block of Go `const`s of a named `EventName` type:

```typescript
// shared/events/catalog/event-names.ts
export const EventNames = {
  // Order module
  ORDER_PLACED:             'order.placed',
  ORDER_SHIPPED:            'order.shipped',
  ORDER_CANCELLED:          'order.cancelled',
  ORDER_PROCESSED:          'order.processed',
  // Inventory module
  STOCK_RESERVED:           'stock.reserved',
  STOCK_UNAVAILABLE:        'stock.unavailable',
  // Payment module
  PAYMENT_PROCESSED:        'payment.processed',
  PAYMENT_FAILED:           'payment.failed',
  // Shipment module
  SHIPMENT_CREATED:         'shipment.created',
  // Account module
  FUNDS_TRANSFERRED:        'funds.transferred',
  // User module
  USER_REGISTERED:          'user.registered',
  // Add entries here when new events are defined in the project's event catalog
} as const;

export type EventName = typeof EventNames[keyof typeof EventNames];
```

```typescript
// In Use Case — publish with constant
await this.eventBus.publish(
  new OrderShippedEvent(order.id, order.customerId, input.trackingCode)
);
// OrderShippedEvent.eventName === EventNames.ORDER_SHIPPED — no literal in the Use Case

// In subscriber registration — use the constant
eventBus.register(EventNames.ORDER_SHIPPED, sendOrderConfirmationEmailSubscriber);
// ← not register('order.shipped', ...)
```

```typescript
// In the event class itself
export class OrderShippedEvent implements DomainEvent {
  readonly eventName = EventNames.ORDER_SHIPPED;  // ← single definition
  ...
}
```

**Rule:** the string `'order.shipped'` should appear in ONE place only — `EventNames.ORDER_SHIPPED`.
Everywhere else, import and use the constant. A misspelled constant then fails at compile time
(TS, Java, C#, Go) or at import / lint time (Python with an `Enum` and a type checker or
linter in CI) — instead of a subscriber that silently never fires.

### Event payload evolution — additive only

When the payload of an event needs to change, **always add fields as optional first**.
Removing or renaming a required field is a breaking change: the Outbox may hold events
in the old format that the subscriber will try to deserialize with the new schema.

```typescript
// ✅ Safe — new optional field; existing outbox entries deserialize without error
export class OrderShippedEvent implements DomainEvent {
  constructor(
    public readonly orderId:      string,
    public readonly customerId:   string,
    public readonly trackingCode: string,
    public readonly carrierId?:   string,  // ← added as optional; old entries have undefined
  ) {}
}

// ❌ Unsafe — renaming a required field breaks existing outbox entries
// Before: constructor(public readonly trackingCode: string)
// After:  constructor(public readonly tracking_code: string)  ← old entries: tracking_code = undefined
```

**Protocol before removing an old field:**
1. Deploy the version that adds the new field (optional).
2. Wait until the Outbox has no undelivered entries with the old field format
   (e.g. count the unpublished outbox rows — see [advanced-delivery.md](advanced-delivery.md)).
3. Deploy the version that removes the old field.
