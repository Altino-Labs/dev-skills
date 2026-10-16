# Repository Integration Tests
> Sub-file of the `dev-core:test-patterns` skill. Read when writing integration tests for
> repository implementations — verifying that production repositories honor the same contract
> as their in-memory fakes (LSP compliance). Examples are framework-free TypeScript; `db` stands
> for the stack's database test client — the concrete setup (client, runner config, local
> database) lives in the stack plugin (e.g. `dev-patterns:test-patterns`).

---

## When to write

After unit tests pass against the in-memory fake, write one integration test suite per
repository implementation to verify:

1. **Round-trip correctness** — `save()` persists exactly what `findById()` reads back.
2. **LSP compliance** — every filter, sort order, and null semantic matches the fake's behavior
   (see `dev-core:clean-architecture` → `repositories.md` — LSP).
3. **Atomicity** of transactional methods / unit of work — the in-memory fake cannot prove it.

**Run them only against a local or ephemeral database** (a local dev instance, a container
started for the run, a per-run schema) with the real schema applied — never against a shared
staging or production database. Keep them in their own folder (e.g. `test/integration/`) and,
when they are slow, behind their own command so unit tests stay fast.

---

## Round-trip test pattern

```typescript
// test/integration/order.repository.integration.<ext>
describe('OrderRepository (real database) — integration', () => {
  let db:   TestDatabaseClient;          // stack-specific; privileged enough to clean up
  let repo: IOrderRepository;
  const createdIds: string[] = [];       // every row this suite creates

  // Save through the repository AND remember the id for cleanup
  async function saveTracked(order: Order): Promise<Order> {
    const saved = await repo.save(order);
    createdIds.push(saved.id);
    return saved;
  }

  beforeAll(() => {
    db   = createTestDatabaseClient();
    repo = new SqlOrderRepository(db);
  });

  afterEach(async () => {
    // Delete ONLY the rows this test created — never every row in the table
    await db.deleteWhereIdIn('orders', createdIds);
    createdIds.length = 0;
  });

  // ── Round-trip ──────────────────────────────────────────────────────────────

  it('should preserve all fields when save() is followed by findById()', async () => {
    const saved = await saveTracked(OrderFactory.draft());

    const found = await repo.findById(saved.id);

    expect(found).not.toBeNull();
    expect(found!.id).toBe(saved.id);
    expect(found!.customerId).toBe(saved.customerId);
    expect(found!.status).toBe(saved.status);
    expect(found!.currency).toBe(saved.currency);
    expect(found!.isActive).toBe(true);
  });

  it('should return null when findById() finds nothing — never throw', async () => {
    const result = await repo.findById('00000000-0000-0000-0000-000000000000');
    expect(result).toBeNull();
  });

  // Not for optimistic-lock entities: their save() is the version-checked insert/update —
  // test the stale-version conflict instead (unit-test-patterns.md — Optimistic Lock).
  it('should not create duplicates when save() is called twice with the same id (upsert)', async () => {
    const order = OrderFactory.draft();
    await saveTracked(order);
    await repo.save(order);  // second call with same id

    expect(await db.countWhere('orders', { id: order.id })).toBe(1);
  });

  // ── LSP compliance ──────────────────────────────────────────────────────────
  // If a test below fails while the unit test (against the fake) passes,
  // the fake violates LSP — fix the fake to match production behavior.

  it('should exclude inactive orders when listing active orders by customer', async () => {
    const active    = OrderFactory.draft();
    const cancelled = OrderFactory.cancelled({ customerId: active.customerId });  // isActive = false

    await Promise.all([saveTracked(active), saveTracked(cancelled)]);

    const results = await repo.findActiveByCustomer(active.customerId);

    expect(results.map(o => o.id)).toContain(active.id);
    expect(results.map(o => o.id)).not.toContain(cancelled.id);
  });

  it('should order active orders by created_at descending', async () => {
    const first  = OrderFactory.draft();
    const second = OrderFactory.draft({ customerId: first.customerId });

    await saveTracked(first);
    await new Promise(r => setTimeout(r, 20));   // ensure distinct created_at
    await saveTracked(second);

    const ids = (await repo.findActiveByCustomer(first.customerId)).map(o => o.id);

    // Most recent first — same order the in-memory fake must produce
    expect(ids.indexOf(second.id)).toBeLessThan(ids.indexOf(first.id));
  });

  it('should return the deleted id when delete() finds the row', async () => {
    const order = await saveTracked(OrderFactory.draft());

    const deletedId = await repo.delete(order.id);

    expect(deletedId).toBe(order.id);
    expect(await repo.findById(order.id)).toBeNull();
  });

  it('should return null when delete() finds nothing — never throw', async () => {
    const result = await repo.delete('00000000-0000-0000-0000-000000000000');
    expect(result).toBeNull();
  });
});
```

---

## LSP self-check — contract table

Before committing any repository implementation, verify:

| Contract declared in the interface docs | Verified by test |
|---|---|
| `findById` returns `null`, never throws | "return null when findById() finds nothing" |
| List methods apply the same filter as the fake | "exclude inactive orders" |
| List methods sort identically to the fake | "order ... by created_at descending" |
| `save()` is an upsert, not a plain insert (except `[OL]` entities) | "not create duplicates ... (upsert)" |
| `delete()` returns `null`, never throws | "return null when delete() finds nothing" |
| `save()` on an `[OL]` entity throws on a stale version | see `unit-test-patterns.md` — Optimistic Lock |

**Rule:** if a test here fails while the unit test against the fake passes → the fake is wrong.
Fix the fake first (it violates LSP), then re-run the integration test.

---

## Test data isolation

- **Delete only what the test created.** Record the id of every row a test inserts (wrap
  `save()` as above, or collect ids from the seed helpers) and delete exactly those ids in
  the after-each hook, then reset the list. Child rows first if there is no cascading delete.
- Where the stack supports it, prefer the cheaper and safer alternatives: **run each test
  inside a transaction and roll it back**, or tag every row with a **per-run marker** (a unique
  run id in a column or in the generated ids) and delete by that marker.
- **Never truncate or delete-all** in test cleanup — not `DELETE FROM orders`, not "delete
  where id is not some sentinel value". Against anything other than a throwaway database it
  wipes real data, and even locally it destroys seed data other tests and developers rely on.
  A comment that says "only rows from this run" must be literally true of the query.
- **Integration tests target a local/ephemeral database only.** Fail fast in the setup if the
  connection points anywhere else (e.g. refuse to start when the URL is not localhost or the
  container started for the run).
- Never rely on state left by a previous test — each `it()` must be self-contained; generate
  fresh ids (and fresh parent ids, e.g. a new `customerId`) per test so parallel or leftover
  rows cannot match your filters.
- Cleanup needs a client privileged enough to delete regardless of row-level access rules —
  use it only in the test setup, never in application code.
- Don't reset/re-seed the whole database inside tests — too slow for per-test isolation; do
  it once per run if at all.
