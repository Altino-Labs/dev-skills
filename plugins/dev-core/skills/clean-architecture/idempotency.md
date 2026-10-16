# Idempotency in Command Use Cases
> Sub-file of the `dev-core:clean-architecture` skill. Read before writing any Command Use Case
> that creates or mutates state — especially when duplication has financial or irreversible consequences.

---

Before writing any Command Use Case, run the decision tree. Do not write the Use Case without it.

Pattern A and B apply to **Create** operations. Pattern C applies to **any Command** — Create,
Update, Transfer, Process, Apply — whenever duplication has financial or irreversible consequences.

```
Is this a Create operation AND does the entity have a natural business key?
      │
      YES ──→ Pattern A: find-or-create
      NO
      │
      ▼
Does the operation have financial or irreversible consequences if duplicated?
  (applies to ANY Command: Create, Transfer, Process, Apply, …)
      │
      YES ──→ Pattern C: Idempotency-Key header
      NO
      │
      ▼
Is this a Create operation with a client-supplied identifier?
      │
      YES ──→ Pattern B: client-supplied UUID + upsert
      NO  ──→ No idempotency mechanism required
```

**Universal rule — independent of which pattern:**
- Migration ALWAYS has the corresponding `UNIQUE` constraint.
- Use Case ALWAYS does `findById`/`findByKey` before creating when it receives an ID or key from the client.
- Repository uses `upsert` (never a plain `insert`) when the entity accepts a client-supplied ID —
  **except** for entities under optimistic locking, whose `save()` is the version-checked
  insert/update (see "Incompatibility with Optimistic Lock" below). With an ORM, its own
  save/merge plus the unique constraint plays this role.
- A client-supplied ID that already exists must **belong to the caller** — otherwise the
  request is answered as if the ID did not exist, and the upsert never changes the owner
  (Pattern B).

## Pattern A — Natural Business Key + find-or-create

Use when the entity has domain uniqueness (e.g., an invoice is unique by `customer_id + billing_period` — one invoice per customer per billing cycle).

```sql
-- migration: UNIQUE constraint is the last safety net
ALTER TABLE invoices
  ADD CONSTRAINT uq_invoices_customer_period
  UNIQUE (customer_id, billing_period);
```

```typescript
async execute(input: CreateInvoiceInput): Promise<CreateInvoiceOutput> {
  // find-or-create: second call with same key → return existing silently
  const existing = await this.invoices.findByKey(input.customer_id, input.billing_period);
  if (existing) return this.toOutput(existing);

  const invoice = Invoice.create({ id: generateId(), customerId: input.customer_id, billingPeriod: input.billing_period });
  const saved   = await this.invoices.save(invoice);
  await this.eventBus.publish(new InvoiceCreatedEvent(saved.id, input.customer_id));
  return this.toOutput(saved);
}
```

## Pattern B — Client-supplied UUID + upsert

Use when the entity has no natural business key and the operation is low-risk.
The client generates the UUID before the request — second call with same ID is a no-op.

```typescript
// Request DTO: client may supply the ID (validated as a UUID when present)
export interface CreateOrderDto {
  id?: string;        // optional, UUID
  currency: string;   // required, non-empty
}

// Controller generates the ID if absent
async function createOrderHandler(dto: CreateOrderDto, user: AuthUser) {
  return placeOrderUseCase.execute({ id: dto.id ?? randomUUID(), customer_id: user.id, currency: dto.currency });
}

// Use Case: explicit idempotency check before creating
async execute(input: PlaceOrderInput): Promise<PlaceOrderOutput> {
  const existing = await this.orders.findById(input.id);
  if (existing) {
    // The ID is client-controlled: never return or touch another user's order (IDOR).
    // Answer as if it did not exist — no data from the foreign row leaks.
    if (existing.customerId !== input.customer_id) throw new OrderNotFoundException(input.id);
    return this.toOutput(existing);
  }

  const order = Order.create({ id: input.id, customerId: input.customer_id, currency: input.currency });
  const saved = await this.orders.save(order);
  await this.eventBus.publish(new OrderPlacedEvent(saved.id, saved.customerId, saved.currency, saved.total.amount));
  return this.toOutput(saved);
}
```

```sql
-- Repository save(): upsert — never a plain insert.
-- The owner is never in the SET list, and the update only applies to the caller's own row.
INSERT INTO orders (id, customer_id, currency, status)
VALUES ($1, $2, $3, $4)
ON CONFLICT (id) DO UPDATE
  SET currency = EXCLUDED.currency, status = EXCLUDED.status
  WHERE orders.customer_id = EXCLUDED.customer_id
RETURNING *;
-- Zero rows returned → the ID belongs to another customer (a race the use-case check missed):
-- the repository throws OrderNotFoundException. Otherwise it maps the row via reconstitute().
```

> **Incompatibility with Optimistic Lock:** Pattern B defines `save()` as an unconditional upsert.
> Upsert never evaluates `WHERE version = N`, so the OL concurrency check is silently bypassed on
> every UPDATE — exactly the lost-update the lock was meant to prevent. Code compiles, unit tests
> pass (save() is mocked), but two concurrent PATCHes overwrite each other in production.
>
> **Rule:** Pattern B and `[OL]` cannot share the same `save()` implementation.
>
> When an entity needs **both** (client-supplied UUID AND multiple concurrent editors):
> - The repository `save()` uses **only** the OL logic from `entities.md`
>   (`version === 0` → INSERT; `version > 0` → UPDATE WHERE version = N).
> - What remains from Pattern B is only the existence check in the Use Case
>   (`findById` before creating) — which still guarantees creation idempotency.
>
> ```typescript
> // ✅ CORRECT — Pattern B existence check in Use Case + OL save() in repository
> async execute(input: PlaceOrderInput): Promise<PlaceOrderOutput> {
>   const existing = await this.orders.findById(input.id);
>   if (existing) {                                   // ← Pattern B: creation idempotency
>     if (existing.customerId !== input.customer_id) throw new OrderNotFoundException(input.id);
>     return this.toOutput(existing);
>   }
>
>   const order = Order.create({ id: input.id, customerId: input.customer_id, currency: input.currency });
>   const saved = await this.orders.save(order);   // ← OL save(): version === 0 → INSERT with version = 1
>   return this.toOutput(saved);
> }
>
> // Repository uses OL save() — NOT Pattern B's upsert
> async save(order: Order): Promise<Order> {
>   if (order.version === 0) {
>     return this.toEntity(await this.db.insertReturning('orders', { id: order.id, ..., version: 1 }));
>   }
>   const row = await this.db.updateReturning('orders',
>     { ..., version: order.version + 1 }, { id: order.id, version: order.version });
>   if (!row) throw new OptimisticLockException('Order', order.id, order.version);
>   return this.toEntity(row);
> }
> ```
>
> If the module has a design plan, record this combination explicitly in it, and check that no
> entity is both marked `[OL]` (uses Optimistic Locking) AND assigned Pattern B's upsert `save()`.

## Pattern C — Idempotency-Key header

Use when duplication has financial or irreversible consequences (charging a payment twice, issuing a duplicate shipment).

```sql
CREATE TABLE idempotency_keys (
  user_id         uuid        NOT NULL,     -- the authenticated caller
  route           text        NOT NULL,     -- method + route template, e.g. 'POST /orders/:id/payments'
  key             text        NOT NULL,     -- the Idempotency-Key header
  request_hash    text        NOT NULL,     -- hash of the canonical request (path params + body)
  status          text        NOT NULL CHECK (status IN ('in_progress', 'completed')),
  response_status int,                      -- NULL while in_progress
  response        jsonb,                    -- NULL while in_progress
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, route, key)         -- the key is scoped: never shared across users/routes
);
CREATE INDEX ON idempotency_keys (created_at);  -- used by TTL cleanup below
```

The key is **scoped** to `(user_id, method + route, key)`: a key is only meaningful for the
caller and endpoint that sent it. A global key lets one user receive another user's stored
response by guessing or reusing their key.

Only the backend's own service identity reads and writes this table — no end-user access.
Apply the database's access-control mechanism accordingly (the stack plugin shows how).

The table must have a TTL cleanup job — without it it grows unbounded. Two options:

- **Database-side scheduler** (a scheduling extension, when the database has one enabled) —
  put it in a **separate, optional migration**, never inline in the `CREATE TABLE` migration:
  if the extension is not enabled, that migration fails and must be skipped.
- **Application-level scheduled job** (the app's cron/scheduler) — always available, no
  database extension required. **Prefer this one** unless the database scheduler is already
  enabled for other reasons.

Both run, daily, the equivalent of:

```sql
DELETE FROM idempotency_keys WHERE created_at < now() - interval '24 hours';
```

The retention window (24h) matches the typical idempotency window — adjust if your use
case requires longer replay protection.

### Request flow — reserve first, execute, then complete

A read-then-execute check is not enough: two concurrent requests with the same key both see
"not stored" and both execute. The key is **reserved atomically before** the use case runs; the
unique constraint decides which request wins.

1. **Pre-handler: reserve (guard / middleware)** — reads the `Idempotency-Key` header.
   - Endpoints are marked as Pattern C explicitly (a route annotation/flag). On a Pattern C
     endpoint the key is **required**: reject with 400 (`IDEMPOTENCY_KEY_REQUIRED`) if absent —
     a missing key means no protection. On other endpoints the key is optional and the check
     activates only when the client sends it.
   - Insert the reservation in one atomic statement:
     `INSERT INTO idempotency_keys (user_id, route, key, request_hash, status)
      VALUES (…, 'in_progress') ON CONFLICT DO NOTHING RETURNING key`.
   - **Row inserted** → this request owns the key: continue to the handler.
   - **Conflict** → read the existing row for the same `(user_id, route, key)`:
     - `request_hash` differs → reject with 422 (`IDEMPOTENCY_KEY_REUSED`): the same key was
       sent with a different request. Never replay a response for a different body.
     - `completed` → reply with the stored status and body and **do not run the use case**.
     - `in_progress` → reply 409 (`IDEMPOTENCY_REQUEST_IN_PROGRESS`, with `Retry-After`) —
       or wait/poll briefly for completion. Never run the use case a second time.
2. **Post-handler: complete (interceptor / response middleware)** — only on Pattern C
   endpoints: after the handler succeeds, `UPDATE … SET status = 'completed',
   response_status = …, response = … WHERE (user_id, route, key) = (…)`.
   - Store the response **in its final wire shape** (after the standard response envelope is
     applied), so a replayed response is identical to the first one. If the envelope is applied
     by another post-processing step, order the two so the store sees the wrapped body.
   - **Await the update before the response is sent** — otherwise an immediate retry still
     sees `in_progress` instead of the stored response.
3. **On handler failure** — delete the reservation (same scope, `status = 'in_progress'`) so
   the client can retry the request. A crash between reserve and complete leaves an
   `in_progress` row: let a later request reclaim it only once it is older than a lease (e.g.
   60 s), with a conditional `UPDATE … SET created_at = now() WHERE status = 'in_progress' AND
   created_at < now() - lease` — exactly one request wins the reclaim.

The stack plugin holds the concrete guard/decorator/interceptor code for its framework (e.g.
`dev-patterns:clean-architecture`).

## Pattern C + Optimistic Lock — interaction warning

When an endpoint requires both `Idempotency-Key` (Pattern C) and Optimistic Lock (`version`
in the DTO), the idempotency check returns the cached response from the first successful
execution. That cached response contains the `version` value at the time of the first write.

A client that retries and receives the cached response will then attempt a subsequent PATCH
with that stale `version`, producing an `OptimisticLockException` (HTTP 409).

**Client contract for Pattern C + OL endpoints:**
- HTTP 409 from a retry must be treated as *"reload the resource, then resubmit"* — not as a
  permanent failure.
- Never auto-retry a 409 silently. Surface it to the user or refresh the local version first.

**Server side:** no code change needed. The idempotency check returning the cached response
is the correct behavior — the 409 on the next PATCH is the Optimistic Lock working as designed.

---

## Anti-patterns

```typescript
// ❌ WRONG — plain insert: double-click or retry creates two records
async save(order: Order): Promise<Order> {
  await this.db.insert('orders', { id: order.id, ... });
}

// ❌ WRONG — Use Case with no existence check: does not detect client-generated duplicate
async execute(input: PlaceOrderInput): Promise<PlaceOrderOutput> {
  const order = Order.create({ id: input.id, customerId: input.customer_id, currency: input.currency });
  await this.orders.save(order);  // second call: constraint violation or duplicate row
}
```
