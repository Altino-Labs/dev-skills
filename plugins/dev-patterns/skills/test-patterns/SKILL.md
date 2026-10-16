---
name: test-patterns
description: >
  Jest/Vitest + NestJS + Supabase implementation layer of dev-core:test-patterns — test
  commands, runner by stack (Jest 30 + CommonJS vs Vitest + ESM), createMock / jest.fn / vi.fn,
  the NestJS testing module and DI guard test, API contract tests with supertest / Fastify
  inject and assertSnakeCase, NestJS event-bus fakes, Supabase repository integration tests
  (service_role client, safe cleanup), and Stryker mutation testing (report-only).
  Invoke automatically (together with dev-core:test-patterns) when creating any test file or
  when reviewing existing test coverage in a NestJS + Supabase + Expo TypeScript project.
---

# Test Patterns — Jest/Vitest + NestJS + Supabase implementation

**Load `dev-core:test-patterns` first.** It holds the concepts and rules (fundamental rule, test
pyramid, targets by layer, coverage threshold, mutation-testing policy, naming, factories, use
case tests with fakes, domain service / specification / unit-of-work / optimistic-lock tests,
what a contract test asserts, event-bus fakes, repository integration tests and test-data
isolation). This skill only shows how to implement them with Jest or Vitest, NestJS (Fastify)
and Supabase; it does not restate the rules.

## Commands

```bash
pnpm test              # all tests (unit + integration)
pnpm test:unit         # unit tests only (jest)
pnpm test:e2e          # E2E tests only (playwright or supertest)
pnpm test --coverage   # with coverage report
```

## Runner by stack — check before writing a test

| Workspace | Runner | Mocks |
|---|---|---|
| NestJS 11 / CommonJS packages | Jest + ts-jest | `createMock` from `@golevelup/ts-jest`, `jest.Mocked<T>` |
| NestJS 12 / ESM packages (`"type": "module"`) | **Vitest** (`vitest run`) | `createMock` from `@golevelup/ts-vitest` (exists on npm, not yet exercised in a project), `Mocked<T>` from `vitest` |
| Expo app | `jest-expo` (version picked by `npx expo install jest`) | `@testing-library/react-native` |

**How to check:** look at the workspace's `package.json` — `"type": "module"` and a `vitest`
devDependency / `"test": "vitest run"` mean Vitest; `jest` + `ts-jest` (or a `jest` key /
`jest.config.*`) mean Jest. Follow the existing `*.spec.ts` files in that workspace.

The examples in this skill and its supporting files use Jest syntax; under Vitest the shape is
identical — swap `jest.fn()` → `vi.fn()`, `jest.Mocked<T>` → `Mocked<T>`, `jest.spyOn` →
`vi.spyOn`.

### Vitest specifics (ESM workspaces)

- **Import the test API explicitly** — `import { describe, it, expect, vi } from 'vitest'` —
  instead of enabling `globals`; no `types` entry needed, and the file is self-describing.
- **No config file needed** for plain packages: Vitest's defaults find `*.spec.ts` and skip
  `node_modules`/`dist`. Add a `vitest.config.ts` only for real needs (path aliases, setup files).
- **Vitest 5 engines:** Node `^22.12 || ^24 || >=26` (odd majors like 23 are outside the range)
  and `vite` is a peer — declare it next to `vitest`.
- **NestJS DI guard test** — Nest resolves constructor dependencies from
  `emitDecoratorMetadata`; Vitest transpiles with its own transformer, not `tsc`. Keep one test
  that proves metadata is emitted:

```typescript
import 'reflect-metadata';
import { Injectable } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { describe, expect, it } from 'vitest';

@Injectable() class Clock { now() { return 'tick'; } }
@Injectable() class UsesClock { constructor(readonly clock: Clock) {} }

describe('decorator metadata under Vitest', () => {
  it('injects a class dependency without an explicit @Inject token', async () => {
    const moduleRef = await Test.createTestingModule({ providers: [Clock, UsesClock] }).compile();
    expect(moduleRef.get(UsesClock).clock.now()).toBe('tick');
  });
});
```

- **Smoke-boot the Fastify app in-process** (no port) with `app.inject()` after
  `await app.getHttpAdapter().getInstance().ready()` — covers routing, global prefix and Swagger.

## Use Case test — `createMock` (NestJS DI)

Use cases are plain classes: instantiate them with `new` and pass `createMock<T>()` doubles —
no `Test.createTestingModule` needed for a unit test. Use the dev-core in-memory fakes when the
test depends on state; `createMock` when it only checks calls.

```typescript
import { createMock } from '@golevelup/ts-jest';

describe('ProcessOrderUseCase', () => {
  let useCase: ProcessOrderUseCase;
  let orderRepo: jest.Mocked<IOrderRepository>;
  let auditRepo: jest.Mocked<IOrderAuditRepository>;
  let eventBus: jest.Mocked<IEventBus>;

  beforeEach(() => {
    orderRepo  = createMock<IOrderRepository>();
    auditRepo  = createMock<IOrderAuditRepository>();
    eventBus   = createMock<IEventBus>();
    useCase = new ProcessOrderUseCase(orderRepo, auditRepo, eventBus);
  });

  it('should process order and decrement available quantity', async () => {
    // Arrange
    orderRepo.findById.mockResolvedValue(OrderFactory.pending());
    // Act
    const result = await useCase.execute(ValidProcessInput);
    // Assert
    expect(result.status).toBe('PROCESSED');
    expect(auditRepo.save).toHaveBeenCalled();
    // Use EventNames constant — never a string literal (see `dev-core:domain-events` → `event-catalog.md`)
    expect(eventBus.publish).toHaveBeenCalledWith(
      expect.objectContaining({ eventName: EventNames.ORDER_PROCESSED })
    );
  });

  it('should throw OrderNotFoundException when order does not exist', async () => {
    orderRepo.findById.mockResolvedValue(null);
    await expect(useCase.execute(ValidProcessInput)).rejects.toThrow(OrderNotFoundException);
    expect(eventBus.publish).not.toHaveBeenCalled();
  });

  it('should throw OrderExpiredException when order is expired', async () => {
    orderRepo.findById.mockResolvedValue(OrderFactory.withExpiredValidity());
    await expect(useCase.execute(ValidProcessInput)).rejects.toThrow(OrderExpiredException);
  });
});
```

## Supporting files

- [mocks-nestjs.md](mocks-nestjs.md) — `createMock` / `jest.fn` / `vi.fn` versions of the
  dev-core doubles: optimistic-lock conflict with `mockRejectedValue`, injected domain service,
  unit of work, `createMock<IEventBus>()`, and why the NestJS `InMemoryEventBus` never goes into
  a test.
- [contract-tests-http.md](contract-tests-http.md) — API contract tests with supertest /
  Fastify `inject()`: the `assertSnakeCase` helper, single/list/mutation/409/401 examples, where
  the files live.
- [supabase-integration-tests.md](supabase-integration-tests.md) — repository integration tests
  against local Supabase: `createTestSupabaseClient` (service_role), the integration Jest
  config, round-trip/LSP suite and the **ID-tracked cleanup** (never delete-all).
- [stryker-mutation.md](stryker-mutation.md) — Stryker config, report-only scheduled workflow,
  the mutation-report gitignore, pnpm plugin-discovery pitfall, checking per-file scores.
