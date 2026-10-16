# Contract and Event Bus Test Patterns
> Sub-file of the `dev-core:test-patterns` skill. Read when writing API contract tests or
> event-bus fakes. Examples are framework-free TypeScript; `api` stands for the stack's
> in-process HTTP test client and `assertFieldNaming` for the project's naming-convention
> helper — the concrete versions live in the stack plugin (e.g. `dev-patterns:test-patterns`).

---

## API contract test pattern

Contract tests verify the **actual wire format** — not just status codes. They catch field
naming mismatches (snake_case vs camelCase), broken envelopes and missing fields that the type
system cannot detect across the HTTP boundary. They run against the real interface adapter
(routing, validation, auth, error mapping, serialization) in-process, with no real network.

Every endpoint must have a contract test covering:
1. **Happy path** — the status code and the complete response shape
2. **Main error** — the status code and the error envelope shape, with the typed error code
3. **Auth boundary** — 401 / unauthenticated without credentials (for protected routes)

…and every response tree must follow the project's **field naming convention**.

| Assert | Why |
|---|---|
| Status code for each case | The client branches on it (200/201/204, 401, 403, 404, 409, 422) — a delete returns the project's chosen form (`204` no body, or `200` with `deleted_id`) |
| Envelope: the project's success-envelope choice (wrapped `{ data }` or unwrapped — `dev-core:error-handling`) and `{ error: { code, message } }`, never both `data` and `error` | Clients parse the envelope generically |
| Every declared field, with type and format (ISO-8601 timestamps, numbers not strings) | A field silently dropped or renamed breaks the client |
| Typed error code (`ENTITY_NOT_FOUND`), not just the status | Clients map codes to messages |
| No field violates the naming convention, anywhere in the tree | The most common contract bug |
| 401 without credentials on every protected route; no `data` leaked | Proves the auth guard is actually wired |

### Helper — assert the field naming convention

Write one recursive helper and call it on every response body. For a snake_case wire
convention:

```typescript
// test/helpers/assert-field-naming.ts
export function assertFieldNaming(obj: unknown, path = 'response'): void {
  if (obj === null || typeof obj !== 'object') return;
  for (const key of Object.keys(obj as Record<string, unknown>)) {
    if (/[a-z][A-Z]/.test(key)) {
      throw new Error(
        `camelCase field detected: "${path}.${key}". The API returns snake_case — ` +
        `check the Use Case output mapping and the shared contract types.`,
      );
    }
    assertFieldNaming((obj as Record<string, unknown>)[key], `${path}.${key}`);
  }
}
```

(Invert the regex for a camelCase convention. The stack plugin may ship this helper under a
convention-specific name, e.g. `assertSnakeCase`.)

### Single-item endpoint (GET / POST / PATCH)

The examples assume a project that wraps success responses in `{ data }`; in a project that
does not wrap, assert the same shape on `res.body` directly.

```typescript
describe('GET /api/v1/orders/:id — contract', () => {
  it('should return the complete order shape with snake_case fields when the order exists', async () => {
    const res = await api.get(`/api/v1/orders/${seededOrderId}`, { token: validToken });

    expect(res.status).toBe(200);

    // 1. Envelope structure
    expect(res.body).toHaveProperty('data');
    expect(res.body).not.toHaveProperty('error');

    // 2. Complete data shape — every field declared in the shared contract types
    expect(res.body.data).toMatchObject({
      id:         expect.any(String),
      name:       expect.any(String),
      quantity:   expect.any(Number),
      order_type: expect.any(String),
      is_active:  expect.any(Boolean),
      created_at: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T/), // ISO 8601
    });

    // 3. Naming convention across the whole response tree
    assertFieldNaming(res.body);
  });

  it('should return the standard error envelope when the order does not exist', async () => {
    const res = await api.get('/api/v1/orders/00000000-0000-0000-0000-000000000000', { token: validToken });

    expect(res.status).toBe(404);
    expect(res.body).toMatchObject({
      error: { code: expect.any(String), message: expect.any(String) },
    });
    expect(res.body).not.toHaveProperty('data');
    expect(res.body.error.code).toBe('ENTITY_NOT_FOUND');
  });

  it('should return 401 when no credentials are sent', async () => {
    const res = await api.get(`/api/v1/orders/${seededOrderId}`);
    expect(res.status).toBe(401);
    expect(res.body).not.toHaveProperty('data');
  });
});
```

### List endpoint (GET with pagination)

```typescript
describe('GET /api/v1/orders — contract', () => {
  it('should return a paginated list with meta when orders exist', async () => {
    const res = await api.get('/api/v1/orders?page=1&per_page=5', { token: validToken });

    expect(res.status).toBe(200);

    // 1. Envelope: data array + meta object
    expect(res.body).toMatchObject({
      data: expect.any(Array),
      meta: {
        page:        expect.any(Number),
        per_page:    expect.any(Number),
        total:       expect.any(Number),
        total_pages: expect.any(Number),
      },
    });

    // 2. Shape of the first item — seed at least one so this always runs
    expect(res.body.data.length).toBeGreaterThan(0);
    expect(res.body.data[0]).toMatchObject({
      id:         expect.any(String),
      name:       expect.any(String),
      is_active:  expect.any(Boolean),
      created_at: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T/),
    });

    // 3. Naming convention across the whole response
    assertFieldNaming(res.body);
  });
});
```

### Mutation endpoint (POST / PATCH creating or changing state)

```typescript
describe('POST /api/v1/orders/:id/process — contract', () => {
  it('should return the processed order shape when the order is confirmed', async () => {
    const res = await api.post(`/api/v1/orders/${seededOrderId}/process`, {
      token: validToken,
      body:  { processed_at: new Date().toISOString() }, // input follows the same convention
    });

    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({
      id:           expect.any(String),
      status:       'PROCESSED',
      processed_at: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T/),
    });
    assertFieldNaming(res.body);
  });

  it('should return 422 with a typed error code when the order is still a draft', async () => {
    const res = await api.post(`/api/v1/orders/${draftOrderId}/process`, {
      token: validToken,
      body:  { processed_at: new Date().toISOString() },
    });

    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('ORDER_NOT_CONFIRMED');
    assertFieldNaming(res.body);
  });
});
```

### Where contract tests live

One contract test file per controller/handler (e.g. `test/contracts/orders.contract.<ext>`),
plus the shared naming helper under `test/helpers/`. Alternatively keep contract assertions in
the controller's colocated test file and only share the helper — fine as long as every endpoint
still gets the three cases above.

Contract tests run with the normal test command. They need seeded data: seed in a
before-all/before-each hook and remove **only what you seeded** afterwards (see
[repository-integration-tests.md](repository-integration-tests.md) — "Test data isolation").

---

## Event Bus test fakes

A production in-process event bus usually isolates subscribers — it catches and logs subscriber
errors so a Use Case does not fail because a notification could not be sent. **In tests this
behaviour hides bugs:** a subscriber that throws silently passes.

Use the double that matches what the test verifies:

| Double | When to use |
|---|---|
| Auto-mock of `IEventBus` (stack helper) | Unit test of a Use Case — verify `publish()` was called with the right event. Subscriber code does not run. |
| `CapturingEventBus` | Unit test where the event payload must be inspected but subscribers should not run. Also works framework-free in place of an auto-mock. |
| `StrictEventBus` | Integration test — the subscriber must actually execute; its errors must propagate and fail the test. |

### `StrictEventBus` — propagates subscriber errors

```typescript
// test/fakes/strict-event-bus.ts
export class StrictEventBus implements IEventBus {
  private readonly registry = new Map<string, IEventSubscriber[]>();

  register(eventName: string, subscriber: IEventSubscriber): this {
    const existing = this.registry.get(eventName) ?? [];
    this.registry.set(eventName, [...existing, subscriber]);
    return this;
  }

  async publish(event: DomainEvent): Promise<void> {
    const subscribers = this.registry.get(event.eventName) ?? [];
    // Promise.all — does NOT swallow errors; a failing subscriber fails the test.
    await Promise.all(subscribers.map(s => s.handle(event)));
  }

  async publishAll(events: DomainEvent[]): Promise<void> {
    await Promise.all(events.map(e => this.publish(e)));
  }
}
```

### `CapturingEventBus` — records events without running subscribers

```typescript
// test/fakes/capturing-event-bus.ts
export class CapturingEventBus implements IEventBus {
  readonly captured: DomainEvent[] = [];

  async publish(event: DomainEvent): Promise<void> {
    this.captured.push(event);
  }

  async publishAll(events: DomainEvent[]): Promise<void> {
    await Promise.all(events.map(e => this.publish(e)));
  }

  // Convenience helpers
  capturedOf<T extends DomainEvent>(eventName: string): T[] {
    return this.captured.filter(e => e.eventName === eventName) as T[];
  }

  reset(): void { this.captured.length = 0; }
}
```

### Usage examples

```typescript
// ── Unit test with CapturingEventBus (was it published? with what payload?) ──
describe('PlaceOrderUseCase — events', () => {
  let eventBus: CapturingEventBus;
  let useCase:  PlaceOrderUseCase;

  beforeEach(() => {
    eventBus = new CapturingEventBus();
    useCase  = new PlaceOrderUseCase(new InMemoryOrderRepository(), eventBus);
  });

  it('should publish OrderPlacedEvent with the currency when the order is placed', async () => {
    await useCase.execute({ ...validInput, currency: 'EUR' });
    // Use the EventNames constant — same source of truth as the event class itself.
    // A typo in EventNames (e.g. 'order.plaed') would make this test fail, catching
    // the mistake before it silently breaks a subscriber in production.
    const [event] = eventBus.capturedOf<OrderPlacedEvent>(EventNames.ORDER_PLACED);
    expect(event.currency).toBe('EUR');
  });
});

// ── Integration test with StrictEventBus (subscriber must execute) ───────────
describe('PlaceOrder → EnqueueOrderConfirmationEmail integration', () => {
  let queue:   CapturingJobQueue;   // fake IJobQueue that records enqueued jobs
  let useCase: PlaceOrderUseCase;

  beforeEach(() => {
    queue = new CapturingJobQueue();
    // The subscriber enqueues a durable job — it never sends the email itself
    // (dev-core:domain-events → subscribers.md)
    const eventBus = new StrictEventBus()
      .register(EventNames.ORDER_PLACED, new EnqueueOrderConfirmationEmailSubscriber(queue));
    useCase = new PlaceOrderUseCase(new InMemoryOrderRepository(), eventBus);
  });

  it('should enqueue a confirmation-email job when the order is placed', async () => {
    await useCase.execute(validInput);
    // Subscriber ran — if it threw, the test would fail (not silently pass)
    expect(queue.jobs).toHaveLength(1);
    expect(queue.jobs[0].name).toBe('send-order-confirmation');
  });
});
```

### Anti-pattern — production bus in unit tests

```typescript
// ❌ WRONG — the production bus usually needs the framework container to discover
//    subscribers, and it swallows subscriber errors (logs them, never rethrows) — a test
//    using it passes even if a subscriber has a bug
const eventBus = createProductionEventBus(container);

// ✅ CORRECT — choose the double that matches what the test verifies
const eventBus = new CapturingEventBus();      // unit: was it published, with what payload?
const eventBus = new StrictEventBus();         // integration: did the subscriber run correctly?
```

The stack-specific version of this anti-pattern (which container services the real bus needs,
the auto-mock helper) is in the stack plugin.
