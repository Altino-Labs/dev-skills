# Use Cases
> Sub-file of the `dev-core:clean-architecture` skill. Read when implementing use cases,
> their input/output types, the controller → use case boundary, or classifying a use case as
> Command or Query.

---

## Use Case pattern

**Input** types are application-layer types — not HTTP DTOs. They live in the same file as the Use Case.
The Controller converts the HTTP DTO → Input before calling `execute()`.

**Output** types follow **one source of truth for the wire contract** — never two
hand-maintained definitions of the same response shape:

- **TypeScript monorepo** — a shared contract-types package (e.g. `@your-app/shared-types`)
  declares the response; the use case imports and returns it, and the clients type from it.
- **Polyglot stacks** — the backend's response schema is the source of truth, published as
  OpenAPI; clients are generated from it (openapi-generator, Dart/Kotlin/Swift generators,
  etc.), never re-typed by hand.

A local `XxxOutput` type in the backend is fine when it **is** that source of truth (e.g. the
schema the OpenAPI document is generated from). What is wrong is a second definition of the
same shape maintained by hand next to the first.

```
Rule: Input (local) · Output (the single wire-contract definition)
  Input  → defined in the use-case file; the client never consumes it
  Output → defined once (shared types package, or the schema the OpenAPI is generated from);
           the use case returns it; clients use it or a client generated from it
```

```typescript
// TypeScript-monorepo variant
// 1. packages/shared-types/src/order.ts — define BEFORE the use case
export interface ProcessOrderResponse {
  shipment_id:  string;
  status:       string;
  processed_at: string;   // ISO 8601 — serializable over HTTP
}

// 2. <module>/use-cases/process-order.use-case.ts
import { ProcessOrderResponse } from '@your-app/shared-types';

// Input: local — defined in the use-case file; the frontend never consumes this
export interface ProcessOrderInput {
  order_id:     string;
  processed_by: string;   // comes from CurrentUser in the controller
  processed_at: Date;
}

export class ProcessOrderUseCase {
  constructor(
    private readonly orders: IOrderRepository,
    private readonly eventBus: IEventBus,
  ) {}

  async execute(input: ProcessOrderInput): Promise<ProcessOrderResponse> {
    // 1. Fetch required data
    // 2. Apply domain rules (via entity methods — never inline here)
    // 3. Persist via repository
    // 4. Publish domain events
    // 5. Return output (mapped here — never entity.toDto())
  }
}
```

**House convention (this plugin's default):** `execute()` always returns a response type
(`Promise<Response>` in TS) — never `Promise<void>` / `void` / `None`. A void return forces
the client to make a second round-trip to fetch the generated ID or timestamp. A project may
document a different convention (e.g. CQRS commands that return nothing); then apply it
consistently.

**Delete Use Cases** are the only case where there is no new state to return.
`IRepository.delete()` returns `Promise<string | null>` — the deleted id or null if not found.
The Use Case echoes that id, satisfying the no-void rule and surfacing not-found errors.
What reaches the wire is a per-project choice, applied to every delete endpoint: either
`204` with no body, or `200` with `{ deleted_id }` (wrapped in `{ data }` if the project wraps
success responses — `dev-core:error-handling`, "API success envelope"):

```typescript
// 1. packages/shared-types/src/order.ts
export interface DeleteOrderResponse { deleted_id: string; }

// 2. use case — strict variant (throws if not found)
async execute(input: { id: string }): Promise<DeleteOrderResponse> {
  const deletedId = await this.orders.delete(input.id);
  if (!deletedId) throw new OrderNotFoundException(input.id);
  return { deleted_id: deletedId };
}

// controller: HTTP 204 (no body) — or HTTP 200 { deleted_id } / { data: { deleted_id } },
// whichever form the project chose for all its delete endpoints.
```

**Idempotent variant** — when the business rule allows re-deleting a non-existent resource:

```typescript
// use case — idempotent variant (no-op if already gone)
async execute(input: { id: string }): Promise<DeleteOrderResponse> {
  await this.orders.delete(input.id);   // null return is intentionally ignored
  return { deleted_id: input.id };      // echo the input id — always succeeds
}
```

Choose the strict variant by default. Use the idempotent variant only when the business
rule explicitly allows it — document that decision with a comment in the Use Case.

### Anti-pattern — two hand-maintained definitions of the same output

```typescript
// ❌ WRONG — the response is declared in the shared contract (or the OpenAPI schema), and a
// second copy is maintained by hand in the use-case file. When one changes, the other
// silently diverges; structural typing never warns about the mismatch.
export interface ProcessOrderOutput {   // ← hand-written copy of ProcessOrderResponse
  shipment_id:  string;
  status:       string;
}

// ✅ CORRECT — one definition: import it (or, in a polyglot stack, make this local type the
// schema the OpenAPI is generated from, and generate the clients from it)
import { ProcessOrderResponse } from '@your-app/shared-types';
export class ProcessOrderUseCase {
  async execute(input: ProcessOrderInput): Promise<ProcessOrderResponse> { ... }
}
```

---

## Command vs Query Use Cases — CQRS at the use case level

Before wiring a Use Case constructor, classify it first:

| Type | Changes state? | Publishes events? | Inject `IEventBus`? |
|---|---|---|---|
| **Command** | Yes | Yes | ✅ Always |
| **Query** | No | No | ❌ Never |
| **Delete** | Yes | Only when deletion has domain consequences | ✅ When other modules must react (e.g. `order.cancelled`); ❌ when the deletion is a pure cleanup |

The absence of `IEventBus` in a Query Use Case is an **architectural health signal** — any reviewer sees immediately that the Use Case is read-only.

**Delete Use Cases and events:** deleting or archiving an entity is a state change. If other modules
depend on that change (cancel a shipment when an order is deleted, release reserved stock), inject
`IEventBus` and publish the domain event. If the deletion is a pure administrative cleanup with no
downstream reaction, omit `IEventBus`.

```typescript
import { OrderResponse, Page } from '@your-app/shared-types';   // the wire-contract source (TS monorepo)

// ✅ Query Use Case — no EventBus, no side effects
export class ListOrdersByCustomerUseCase {
  constructor(
    private readonly query: IOrderQueryRepository,
  ) {}

  async execute(input: ListOrdersInput): Promise<Page<OrderResponse>> {
    const page = await this.query.findByCustomer(input.customer_id, input.params);
    return { data: page.data.map(this.toOutput), meta: page.meta };
  }
}

// ✅ Command Use Case — EventBus required; changes state and notifies
export class PlaceOrderUseCase {
  constructor(
    private readonly orders: IOrderRepository,
    private readonly eventBus: IEventBus,
  ) {}

  async execute(input: PlaceOrderInput): Promise<OrderResponse> {
    const order = Order.create({ id: input.id, customerId: input.customer_id, currency: input.currency });
    const saved = await this.orders.save(order);   // use the persisted instance from here on
    await this.eventBus.publish(new OrderPlacedEvent(saved.id, saved.customerId, saved.currency, saved.total.amount));
    return this.toOutput(saved);
  }
}
```

**Detection rule:** if `execute()` contains no `save()` and no `eventBus.publish()` calls, it is a Query Use Case — remove `IEventBus` from the constructor.

---

## Idempotency in Command Use Cases

Read [idempotency.md](idempotency.md) for the full decision tree, Pattern A/B/C, the Idempotency-Key flow, and anti-patterns (the stack plugin holds the guard/interceptor code for its framework).

**Decision tree summary:**
- **Pattern A** — natural business key exists → find-or-create
- **Pattern B** — client-supplied UUID, low-risk → upsert
- **Pattern C** — financial or irreversible consequences → `Idempotency-Key` header

**Universal rule:** migration always has a `UNIQUE` constraint; Use Case always checks existence before inserting; repository uses `upsert`, never a plain `insert` — except for optimistic-lock entities, whose `save()` is the version-checked insert/update ([idempotency.md](idempotency.md), "Incompatibility with Optimistic Lock").

---

## Controller → Use Case boundary

The controller (or any interface adapter) is thin — zero business logic. It converts the
transport DTO into the Use Case's `Input` (adding values it owns, such as the authenticated
user's id from the request context) and **never passes the DTO directly to the Use Case**.
Its return type is the use case's Output type — the single wire-contract definition.

```typescript
// framework-free sketch — the stack plugin shows the real controller for your framework
async function processOrderHandler(req: { params: { id: string }; body: ProcessOrderDto; user: AuthUser }):
    Promise<ProcessOrderResponse> {
  return processOrderUseCase.execute({
    order_id:     req.params.id,
    processed_by: req.user.id,
    processed_at: new Date(req.body.processed_at),
  });
}
```
