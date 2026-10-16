# Outbox on Supabase/Postgres — NestJS implementation
> Sub-file of the `dev-patterns:domain-events` skill. Read when implementing durable event
> delivery in a NestJS + Supabase backend. The concepts (when to use an Outbox vs the in-memory
> bus, same-transaction write, atomic claim, relay, retries, dead letter, dedupe, Sagas) are in
> `dev-core:domain-events` → `advanced-delivery.md`.

---

### Migration — outbox table with atomic claim support

```sql
-- supabase/migrations/XXXX_create_domain_events_outbox.sql
CREATE TABLE domain_events_outbox (
  id                 uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  event_name         text        NOT NULL,
  payload            jsonb       NOT NULL,
  published          boolean     NOT NULL DEFAULT false,
  processing_since   timestamptz,           -- set when a worker claims this entry; cleared on done/fail
  retry_count        int         NOT NULL DEFAULT 0,
  created_at         timestamptz NOT NULL DEFAULT now(),
  dead_letter_reason text,                  -- set when moved to dead letter
  dead_lettered_at   timestamptz            -- set when moved to dead letter
);

-- Index covers claim query: unpublished + not claimed (or stale claim)
CREATE INDEX ON domain_events_outbox (published, processing_since, created_at)
  WHERE published = false;
```

### Migration — failure and dead letter functions

```sql
-- supabase/migrations/XXXX_fn_outbox_helpers.sql
-- Must run after XXXX_create_domain_events_outbox.sql

-- Atomically clears the worker lock and increments retry_count in a single UPDATE.
-- A SELECT + UPDATE pair would be a race condition: two workers recovering a stale
-- lock could both read the same retry_count and both write N+1, losing one increment.
CREATE OR REPLACE FUNCTION mark_outbox_failed(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE domain_events_outbox
  SET processing_since = null,
      retry_count      = retry_count + 1   -- atomic: no read-modify-write race
  WHERE id = p_id;
END;
$$;

CREATE OR REPLACE FUNCTION move_outbox_to_dead_letter(p_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE domain_events_outbox
  SET published          = true,           -- remove from the active relay queue
      processing_since   = null,           -- release the worker lock
      dead_letter_reason = p_reason,
      dead_lettered_at   = now()
  WHERE id = p_id;
END;
$$;
```

Dead-lettered entries keep `published = true` so the relay never picks them up again.
Query them with `WHERE dead_lettered_at IS NOT NULL` for manual inspection and replay.

---

### PostgreSQL function — atomic claim with `FOR UPDATE SKIP LOCKED`

`supabase-js` goes through PostgREST and cannot issue `FOR UPDATE` directly.
The only safe way to claim entries across multiple instances is a PostgreSQL function.

`FOR UPDATE SKIP LOCKED` guarantees that two concurrent workers never claim the same row:
Instance A locks rows 1–10; Instance B sees the locks and skips to rows 11–20 atomically.

```sql
-- supabase/migrations/XXXX_fn_claim_outbox_entries.sql
CREATE OR REPLACE FUNCTION claim_outbox_entries(
  p_batch_size   int DEFAULT 10,
  p_lock_ttl_sec int DEFAULT 30    -- entry returns to the queue if not confirmed within N seconds
)
RETURNS SETOF domain_events_outbox
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  UPDATE domain_events_outbox
  SET processing_since = now()
  WHERE id IN (
    SELECT id
    FROM domain_events_outbox
    WHERE published = false
      AND (
        processing_since IS NULL                                                          -- never claimed
        OR processing_since < now() - (p_lock_ttl_sec || ' seconds')::interval  -- stale lock
      )
    ORDER BY created_at
    LIMIT p_batch_size
    FOR UPDATE SKIP LOCKED   -- other instances skip locked rows; no double-processing
  )
  RETURNING *;
END;
$$;
```

**Stale lock recovery:** if a worker crashes while holding entries, `processing_since` stays set
but `published` stays `false`. After `p_lock_ttl_sec` seconds the next `claim()` call picks them up
automatically — no manual intervention needed.

### OutboxRepository implementation

`IOutboxRepository` / `OutboxEntry` are the dev-core port (`advanced-delivery.md`); in this
stack the port file also exports its DI token:

```typescript
// domain/events/i-outbox.repository.ts
export const OUTBOX_REPOSITORY = Symbol('OUTBOX_REPOSITORY');
```

```typescript
// infrastructure/events/supabase-outbox.repository.ts
@Injectable()
export class SupabaseOutboxRepository implements IOutboxRepository {
  constructor(private readonly supabase: SupabaseService) {}

  async save(event: DomainEvent): Promise<void> {
    const { error } = await this.supabase.client
      .from('domain_events_outbox')
      .insert({ event_name: event.eventName, payload: event });
    if (error) throw new OutboxPersistenceException(event.eventName, error.message);
  }

  async claim(batchSize = 10): Promise<OutboxEntry[]> {
    const { data, error } = await this.supabase.client
      .rpc('claim_outbox_entries', { p_batch_size: batchSize, p_lock_ttl_sec: 30 });
    if (error) throw new OutboxClaimException(error.message);
    return (data ?? []).map(this.mapRow);
  }

  async markPublished(id: string): Promise<void> {
    await this.supabase.client
      .from('domain_events_outbox')
      .update({ published: true, processing_since: null })
      .eq('id', id);
  }

  async markFailed(id: string): Promise<void> {
    // Uses an RPC instead of SELECT + UPDATE to guarantee the increment is atomic.
    // Two workers recovering a stale lock at the same time would each read the same
    // retry_count and both compute N+1 — the second write would silently overwrite the
    // first, resulting in one lost increment. The RPC issues a single UPDATE with
    // retry_count = retry_count + 1 which is evaluated atomically by PostgreSQL.
    await this.supabase.client.rpc('mark_outbox_failed', { p_id: id });
  }

  async markDeadLetter(id: string, reason: string): Promise<void> {
    await this.supabase.client.rpc('move_outbox_to_dead_letter', { p_id: id, p_reason: reason });
  }

  private mapRow(row: OutboxRow): OutboxEntry {
    return {
      id:         row.id,
      eventName:  row.event_name,
      payload:    row.payload,
      retryCount: row.retry_count,
      createdAt:  new Date(row.created_at),
    };
  }
}
```

### Use Case — persist entity and outbox in the same RPC

The atomicity guarantee comes from a single PostgreSQL transaction that writes both:

```typescript
// domain/repositories/i-order.repository.ts
export interface IOrderRepository {
  saveWithEvent(order: Order, event: DomainEvent): Promise<Order>;
}
```

```sql
-- supabase/migrations/XXXX_fn_save_order_with_event.sql
CREATE OR REPLACE FUNCTION save_order_with_event(
  p_order_id    uuid,
  p_status      text,
  p_event_name  text,
  p_payload     jsonb
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  UPDATE orders SET status = p_status WHERE id = p_order_id;

  INSERT INTO domain_events_outbox (event_name, payload)
  VALUES (p_event_name, p_payload);
END;
$$;
```

> **`[OL]` entities — extend this function with Optimistic Lock semantics.**
> The example above uses a plain `UPDATE ... WHERE id = p_order_id` which bypasses Optimistic
> Locking. For `[OL]` entities (those using Optimistic Locking — a `version` column checked on
> save), add the version check and
> increment to the SQL function so the OL constraint is enforced atomically alongside the
> outbox write:
>
> ```sql
> CREATE OR REPLACE FUNCTION save_order_with_event(
>   p_order_id      uuid,
>   p_status        text,
>   p_version       int,   -- ← current version from the loaded entity
>   p_event_name    text,
>   p_payload       jsonb
> ) RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
> DECLARE
>   updated_rows int;
> BEGIN
>   UPDATE orders
>   SET    status  = p_status,
>          version = p_version + 1
>   WHERE  id      = p_order_id
>     AND  version = p_version;   -- ← OL guard: fails silently if another writer won
>
>   GET DIAGNOSTICS updated_rows = ROW_COUNT;
>   IF updated_rows = 0 THEN
>     RAISE EXCEPTION 'OPTIMISTIC_LOCK_CONFLICT' USING ERRCODE = 'P0001';
>   END IF;
>
>   INSERT INTO domain_events_outbox (event_name, payload)
>   VALUES (p_event_name, p_payload);
> END;
> $$;
> ```
>
> The repository must catch `ERRCODE = 'P0001'` (or check `error.code`) and rethrow as
> `OptimisticLockException` (concept: `dev-core:error-handling`; NestJS class with
> `statusCode: 409`: `dev-patterns:error-handling`).

```typescript
// infrastructure/repositories/supabase-order.repository.ts
async saveWithEvent(order: Order, event: DomainEvent): Promise<Order> {
  const { error } = await this.supabase.client.rpc('save_order_with_event', {
    p_order_id:   order.id,
    p_status:     order.status,
    p_event_name: event.eventName,
    // Serialize the COMPLETE event — all public fields + occurredAt as ISO string.
    // Date objects do not serialize in jsonb; explicitly convert to string.
    // A truncated payload (e.g. only { orderId, occurredAt }) causes the outbox
    // worker to publish an event with undefined fields — subscribers fail silently.
    p_payload:    { ...(event as unknown as Record<string, unknown>),
                    occurredAt: event.occurredAt.toISOString() },
  });
  if (error) throw new OrderPersistenceException(order.id, error.message);
  return order;
}
```

The use case calls `saveWithEvent` instead of `eventBus.publish()` — see `dev-core:domain-events`
→ `advanced-delivery.md`.

### Outbox worker — atomic claim, retry, dead letter

**Rule:** the worker NEVER queries `WHERE published = false` directly.
Always uses `claim()` — the only mechanism that is safe across multiple instances.

```typescript
// infrastructure/jobs/outbox-relay.processor.ts
@Injectable()
export class OutboxRelayProcessor {
  // Total delivery attempts before dead-lettering.
  // retryCount starts at 0 and is incremented by markFailed() after each failure.
  // Dead-letter fires when retryCount >= MAX_ATTEMPTS − 1, giving exactly MAX_ATTEMPTS total.
  private readonly MAX_ATTEMPTS = 3;

  private readonly logger = new Logger(OutboxRelayProcessor.name);

  constructor(
    @Inject(OUTBOX_REPOSITORY) private readonly outbox: IOutboxRepository,
    // Strict path — never EVENT_BUS, whose publish() swallows subscriber failures
    @Inject(EVENT_DISPATCHER)  private readonly dispatcher: IEventDispatcher,
  ) {}

  // Requires: pnpm add @nestjs/schedule && ScheduleModule.forRoot() in AppModule.
  // → Setup: see skill `notifications-cron` — section "Scheduled jobs".
  // '*/30 * * * * *' is a 6-field cron (with seconds) — only @nestjs/schedule supports it;
  // standard cron tools treat the first field as minutes and would fire every 30 minutes.
  // Default interval: every 30 seconds — tune based on event volume.
  // At 5s intervals (*/5) that is 17,280 DB queries/day per process instance; prefer a
  // longer interval and reduce only when p95 delivery latency exceeds your SLA.
  // For high-throughput systems (>100 events/min), switch to a BullMQ repeatable job
  // instead of @Cron so the relay runs inside the existing queue infrastructure.
  @Cron('*/30 * * * * *')
  async relay(): Promise<void> {
    // claim() is atomic: SELECT FOR UPDATE SKIP LOCKED via RPC
    // Two instances running simultaneously will never process the same entry
    const entries = await this.outbox.claim(10);
    if (entries.length === 0) return;

    await Promise.allSettled(entries.map(e => this.processEntry(e)));
  }

  private async processEntry(entry: OutboxEntry): Promise<void> {
    try {
      // payload.occurredAt is a JSON string (ISO 8601) — PostgreSQL jsonb serializes Date as text.
      // Reconstruct as Date before publishing so subscribers receive the correct type.
      const event: DomainEvent = {
        ...entry.payload,
        eventName:  entry.eventName,
        occurredAt: new Date(entry.payload['occurredAt'] as string),
      };
      const failures = (await this.dispatcher.dispatch(event)).filter(r => !r.ok);
      if (failures.length > 0) {
        // Surface subscriber failures so the catch below retries or dead-letters the entry
        throw new Error(`subscribers failed: ${failures.map(f => `${f.subscriber}: ${String(f.error)}`).join('; ')}`);
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

> For writes that span two repositories: `dev-core:clean-architecture` → `transactions.md`
> "Decision tree"; the Supabase RPC / `pg` implementation is in
> `dev-patterns:clean-architecture` → `transactions-supabase.md`. When a Saga step needs
> atomicity on the same database, use a dedicated RPC (Layer 1) there.
