---
name: test-patterns
description: >
  Test patterns for any stack: the fundamental rule, test pyramid, targets by layer, coverage
  threshold, mutation testing, test naming, factories, use case tests with fakes, domain
  service / specification / unit-of-work tests, optimistic-lock tests, what an API contract
  test must assert, event-bus fakes, and repository integration tests with safe test-data
  isolation. Invoke automatically when creating any test file or when reviewing existing test
  coverage, in any language or framework.
---

# Test Patterns

> **How to read the examples.** Every example in this skill is framework-free TypeScript in
> the `describe` / `it` / `expect` style most test runners share — plain classes and hand-written
> fakes, no mocking library, no framework testing module, no HTTP or database client. Read it
> as pseudo-code and translate it to the project's language and runner (`test_*` functions,
> `assert`, table tests, ...). Runner and framework specifics — commands, mock helpers,
> runner config, the mutation-testing tool, in-process HTTP clients, database test clients —
> live in stack plugins (e.g. `dev-patterns:test-patterns` for Jest/Vitest + NestJS +
> Supabase) and in the project's own delta skill (`.claude/skills/<project>-test-patterns/`),
> when they exist. Load them together with this skill.

## Fundamental rule

> **STOP.** If a test fails, report the failing test. Do not continue until it is resolved.
> Never skip, comment out, or mark tests as skipped/pending to make CI pass.

## Test pyramid

```
      ▲  E2E             (few — complete critical flows)
     ▲▲▲ Integration     (repositories, controllers with a real DB or a fake)
    ▲▲▲▲▲ Unit           (Use Cases, Entities, Value Objects — majority)
```

## Targets by layer

| Layer | Target |
|---|---|
| Domain (Entities, VOs, Events) | 100% branch coverage |
| Application (Use Cases) | 100% success scenarios + every named domain exception it can throw |
| Infrastructure | Integration tests against a real local/ephemeral database (or containers) |
| Controllers / handlers | Contract tests (input/output shape + status codes) |

Layer names follow `dev-core:clean-architecture`.

## Coverage threshold — required minimum

**≥ 80% coverage in business logic** (Use Cases, Entities, Value Objects).
Below that: report to the human before merging. Coverage is measured on business logic, not
on wiring, DTOs or generated code — a high project-wide number can hide an untested domain.

## Mutation testing — report-only first

Coverage says a line ran; a mutation score says a test would **notice** if the line were wrong.
A mutation tool changes the production code (flips a condition, removes a call, replaces a
constant) and re-runs the tests; a mutant that no test kills is a missing assertion.

**Scope it to business logic** — the domain layer (Entities/VOs) and Use Cases. Exclude
repository interfaces, DI/module wiring, barrel/index files and the tests themselves: there are
no real branches to mutate there.

**Targets by layer:** domain **≥ 80%**, use cases **≥ 60%**. Measure a baseline before treating
these as real — in practice they have turned out realistic, with the domain clearing its bar
and use cases comfortably above theirs.

**Where low scores cluster:** `create-*` use cases (40–60% is common) and large read/aggregate
use cases where whole blocks have *no covering test* at all ("no coverage" is worse than
"survived"). Typical missing cases:
- the "field omitted → default" side of `input.x ?? default` construction logic;
- untested enum branches (less common type/status values);
- weak error-path assertions — "throws" with no type/message check, missing non-standard
  error / fallback-message cases.

**How to fix efficiently:** use the run's own mutant list (location + mutator + replacement,
from the tool's machine-readable report) to know exactly which test cases are missing. This
typically needs no production change — the gap is coverage, not correctness. Leave genuine
**equivalent mutants** surviving (a branch where both arms produce the same result for any real
input) rather than writing contrived tests to force 100%.

**Not a merge gate at first.** Run it on a schedule (e.g. weekly + manual trigger) that
publishes the score and the report as a build artifact, with **no failing threshold** — so a
low score never fails CI or blocks a PR. Report-only lets real numbers settle (and the gaps get
fixed) before anyone considers gating merges on unmeasured targets. Keep the generated reports
out of version control.

**Unscored new code is expected lag, not a finding.** With a scheduled run, business logic
merged after the last run has no score until the next one. Before filing "X never ran mutation
testing", check whether a scheduled run has happened since it merged; if it has, read the score
from that run. Only a score actually **below** target is worth tracking.

**When it pays off:** domain and use-case code with real branching, once line coverage is
already high. It is slow (a full run over a mid-size backend takes minutes to tens of minutes)
— hence scheduled, scoped and incremental where the tool supports it. Extending it to a
UI/mobile codebase is a separate decision; tool support there is often weaker.

The concrete tool and its config are stack-specific (for TypeScript:
`dev-patterns:test-patterns` → `stryker-mutation.md`).

## Test naming rule

```
it('should [expected result] when [condition]', ...)
```

Never: `it('works')`, `it('test 1')`, `it('should work correctly')`. In languages that name
tests as functions, keep the same two parts (`test_[result]_when_[condition]`).

## Test factories — always use, never build test objects manually

One factory per entity, with a **named state** for each meaningful business condition
(`OrderFactory.draft()`, `.confirmed()`, `.cancelled()`). Factories build every named state
through the entity's own `reconstitute()` (the state a repository returns); `create()` is
called directly only in tests of the creation flow itself. Never
hand-assemble test objects or partial "mocks" of entities inline in a test. Details and
examples: [unit-test-patterns.md](unit-test-patterns.md).

## Use Case test pattern — with fakes

Inject hand-written in-memory fakes (or the stack's mock helper) for every port the use case
depends on; never the class under test. Assert on the **result**, the **fake's state** and the
**captured events** — Arrange / Act / Assert clearly separated.

```typescript
describe('ProcessOrderUseCase', () => {
  let orders: InMemoryOrderRepository;
  let eventBus: CapturingEventBus;
  let useCase: ProcessOrderUseCase;

  beforeEach(() => {
    orders   = new InMemoryOrderRepository();
    eventBus = new CapturingEventBus();
    useCase  = new ProcessOrderUseCase(orders, eventBus);
  });

  it('should process the order and publish order.processed when the order is confirmed', async () => {
    const order = OrderFactory.confirmed();
    await orders.save(order);                                   // Arrange

    const result = await useCase.execute({ orderId: order.id }); // Act

    expect(result.status).toBe('PROCESSED');                     // Assert
    expect((await orders.findById(order.id))!.status).toBe('PROCESSED');
    expect(eventBus.capturedOf(EventNames.ORDER_PROCESSED)).toHaveLength(1);
  });

  it('should throw OrderNotFoundException when the order does not exist', async () => {
    await expect(useCase.execute({ orderId: 'missing' })).rejects.toThrow(OrderNotFoundException);
    expect(eventBus.captured).toHaveLength(0);
  });
});
```

## API contract tests — what they must assert

Contract tests exercise the real interface adapter (in-process HTTP, no real network) and
verify the **wire format**, which the type system cannot see across the HTTP boundary. Every
endpoint gets at least:

1. **Happy path** — the status code and the **complete** response shape (envelope + every
   declared field, with types and formats such as ISO-8601 timestamps).
2. **Main error** — the status code and the project's **error envelope** (e.g.
   `{ error: { code, message } }`, no `data`), with the typed error code.
3. **Auth boundary** — **401 / unauthenticated** without credentials on every protected route.

And across the whole response tree: the project's **field naming convention** (e.g.
snake_case on the wire — `dev-core:api-contracts`) — a mismatch is the classic contract bug. Details:
[contract-event-tests.md](contract-event-tests.md).

## Security boundaries — assert them, not just the happy path

- **Mocks that ignore their arguments still assert the security filter.** A chainable
  query-builder mock (or any auto-mock returning canned rows regardless of input) proves error
  handling and mapping, **not** that the query was scoped — the test passes even if the
  `tenant_id` / `user_id` / owner filter is missing. For every repository method that scopes by
  tenant, owner or user, assert the filter call and its value (the recorded calls of the
  builder), or cover the method with an integration test against a real database.
- **Database privileges are tested against a real database in CI when migrations change.**
  Row-level policies, grants/revokes on tables and functions, and privileged
  (security-definer) functions can't be unit-tested. A dedicated suite starts a local
  database, applies every migration, and asserts as each role: an anonymous / authenticated
  client can't read or write what it shouldn't, can't execute privileged functions, and a
  privileged function rejects a caller who isn't a member. Run it on every PR that touches the
  migrations folder (path filter) and locally before pushing a migration. Details:
  [repository-integration-tests.md](repository-integration-tests.md) → "Database privilege
  tests".

## Detailed guides

Read the file that matches the task before writing the test:

- [unit-test-patterns.md](unit-test-patterns.md) — Use Case tests with fakes, test factories
  and their rules, the three layers of optimistic-lock tests.
- [mock-patterns.md](mock-patterns.md) — fakes and test doubles: in-memory fake for
  specification queries, pure vs injected domain service tests, unit-of-work fake.
- [contract-event-tests.md](contract-event-tests.md) — what an API contract test asserts
  (single, list, mutation, error, 401, naming convention) and the event-bus fakes
  (`StrictEventBus`, `CapturingEventBus`).
- [repository-integration-tests.md](repository-integration-tests.md) — when to write them,
  round-trip and LSP-contract tests, database privilege tests (policies, grants, privileged
  functions — per role, in CI when migrations change), and test-data isolation (track created
  IDs; never delete-all on a shared database).
