# Repository Integration Tests — local Supabase
> Sub-file of `dev-patterns:test-patterns`. When to write them, round-trip and LSP-contract
> tests, the contract table and the test-data isolation rules are in `dev-core:test-patterns` →
> `repository-integration-tests.md`. This file is the Supabase (supabase-js) implementation.

---

Run against the local Supabase instance (`supabase start`) with the migrations applied — never
against the hosted staging/production project. These tests belong in the API app's
`test/integration/` (e.g. `apps/api/test/integration/`).

## Setup

```typescript
// test/setup/supabase-test-client.ts
import { createClient } from '@supabase/supabase-js';

export function createTestSupabaseClient() {
  return createClient(
    process.env.SUPABASE_URL          ?? 'http://localhost:54321',
    process.env.SUPABASE_SERVICE_ROLE_KEY ?? '',   // service_role bypasses RLS in tests
    { auth: { autoRefreshToken: false, persistSession: false } },
  );
}
```

`SUPABASE_URL` must point at the local instance. If the test env could ever inherit a hosted
URL, add a guard here that throws unless the URL is `localhost`/`127.0.0.1`.

Add to `jest.config.ts` for the integration suite:

```typescript
// jest.config.integration.ts
export default {
  testMatch: ['**/test/integration/**/*.spec.ts'],
  globalSetup:    './test/setup/supabase-start.ts',   // runs `supabase start`
  globalTeardown: './test/setup/supabase-stop.ts',    // optional: stop after suite
};
```

(Under Vitest: the same split with a `vitest.config.integration.ts` — `include` for the glob,
`globalSetup` for start/stop.)

---

## Round-trip test pattern

```typescript
// test/integration/orders.repository.integration.spec.ts
import { SupabaseService } from '../../src/supabase/supabase.service';
import { SupabaseOrderRepository } from '../../src/orders/infrastructure/database/repositories/supabase-order.repository';
import { OrderFactory } from '../factories/order.factory';
import { createTestSupabaseClient } from '../setup/supabase-test-client';

describe('SupabaseOrderRepository — integration', () => {
  let repo: SupabaseOrderRepository;
  let supabase: ReturnType<typeof createTestSupabaseClient>;
  const createdIds: string[] = [];   // ids of every order row this suite inserts

  // Save through the repository and remember the id for cleanup
  async function saveTracked(order: Order): Promise<Order> {
    const saved = await repo.save(order);
    createdIds.push(saved.id);
    return saved;
  }

  beforeAll(() => {
    supabase = createTestSupabaseClient();
    repo = new SupabaseOrderRepository({ client: supabase } as SupabaseService);
  });

  afterEach(async () => {
    // Delete exactly the rows this test inserted (tracked in createdIds) — nothing else.
    // service_role client, so RLS does not block the delete.
    if (createdIds.length > 0) {
      const { error } = await supabase.from('orders').delete().in('id', createdIds);
      if (error) throw error;
    }
    createdIds.length = 0;
  });

  // ── Round-trip ──────────────────────────────────────────────────────────────

  it('save() → findById() preserves all fields', async () => {
    const saved = await saveTracked(OrderFactory.draft());

    const found = await repo.findById(saved.id);

    expect(found).not.toBeNull();
    expect(found!.id).toBe(saved.id);
    expect(found!.customerId).toBe(saved.customerId);
    expect(found!.status).toBe(saved.status);
    expect(found!.currency).toBe(saved.currency);
    expect(found!.isActive).toBe(true);
  });

  it('findById() returns null when not found — never throws', async () => {
    const result = await repo.findById('00000000-0000-0000-0000-000000000000');
    expect(result).toBeNull();
  });

  it('save() is idempotent — upsert with same id does not create duplicates', async () => {
    const order = OrderFactory.draft();
    await saveTracked(order);
    await repo.save(order);  // second call with same id

    const { count } = await supabase
      .from('orders')
      .select('*', { count: 'exact', head: true })
      .eq('id', order.id);

    expect(count).toBe(1);
  });

  // ── LSP compliance ──────────────────────────────────────────────────────────
  // If a test below fails while the unit test (against the fake) passes,
  // the fake violates LSP — fix the fake to match production behavior.

  it('findActiveByCustomer() excludes inactive orders', async () => {
    const active    = OrderFactory.draft();
    const cancelled = OrderFactory.cancelled({ customerId: active.customerId });  // isActive = false

    await Promise.all([saveTracked(active), saveTracked(cancelled)]);

    const results = await repo.findActiveByCustomer(active.customerId);

    expect(results.map(o => o.id)).toContain(active.id);
    expect(results.map(o => o.id)).not.toContain(cancelled.id);
  });

  it('findActiveByCustomer() returns results ordered by created_at descending', async () => {
    const first  = OrderFactory.draft();
    const second = OrderFactory.draft({ customerId: first.customerId });

    await saveTracked(first);
    await new Promise(r => setTimeout(r, 20));   // ensure distinct created_at
    await saveTracked(second);

    const results = await repo.findActiveByCustomer(first.customerId);
    const ids = results.map(o => o.id);

    // Most recent first — same order the in-memory fake must produce
    expect(ids.indexOf(second.id)).toBeLessThan(ids.indexOf(first.id));
  });

  it('delete() returns the deleted id when found', async () => {
    const order = await saveTracked(OrderFactory.draft());

    const deletedId = await repo.delete(order.id);

    expect(deletedId).toBe(order.id);
    expect(await repo.findById(order.id)).toBeNull();
  });

  it('delete() returns null when not found — never throws', async () => {
    const result = await repo.delete('00000000-0000-0000-0000-000000000000');
    expect(result).toBeNull();
  });
});
```

The LSP self-check table that these tests implement is in dev-core
`repository-integration-tests.md`.

---

## Test data isolation (Supabase)

- Track the ids of every inserted row and clean up with
  `supabase.from('<table>').delete().in('id', createdIds)` in `afterEach`, then reset the
  array. Delete child tables first when the FK has no `ON DELETE CASCADE`.
- **Never** a filter that matches the whole table — e.g. `delete()` with a "not equal to a
  sentinel UUID" filter on `id` deletes **every** row, whatever the comment above it says.
  (PostgREST refuses a `delete()` with no filter, which is exactly why that sentinel trick
  shows up — don't use it.)
- Use the `service_role` client (from `createTestSupabaseClient`) for cleanup; the default
  `anon` key is blocked by RLS.
- Never rely on state left by a previous test — each `it()` must be self-contained.
- Do not use `supabase db reset` inside tests — it drops all data and re-seeds, which is too
  slow for per-test isolation.
