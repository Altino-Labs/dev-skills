# API Contract Tests — supertest / Fastify `inject()`
> Sub-file of `dev-patterns:test-patterns`. What a contract test must assert (happy-path shape,
> error envelope, 401, field naming, status codes) is in `dev-core:test-patterns` →
> `contract-event-tests.md`. This file is the NestJS + Fastify implementation: the
> `assertSnakeCase` helper (the wire convention is snake_case — see `dev-core:api-contracts`;
> for this stack also `dev-patterns:api-contracts`) and the HTTP calls.

---

## HTTP client — supertest or Fastify `inject()`

The examples use supertest (`request(app.getHttpServer())`, shown as `request(app)`). With the
Fastify adapter you can instead call `app.inject()` — no port, no supertest dependency — after
`await app.init()` and `await app.getHttpAdapter().getInstance().ready()`:

```typescript
const res = await app.inject({
  method: 'GET',
  url: `/api/v1/orders/${seededOrderId}`,
  headers: { authorization: `Bearer ${validToken}` },
});
expect(res.statusCode).toBe(200);
const body = res.json();
```

Build `app` from the real `AppModule` with `Test.createTestingModule({ imports: [AppModule] })`
and `moduleRef.createNestApplication<NestFastifyApplication>(new FastifyAdapter())`, applying
the same global prefix, pipes and filters as `main.ts` — otherwise the contract under test is
not the one clients see.

## Helper — assert no camelCase fields in response

```typescript
// test/helpers/assert-snake-case.ts
export function assertSnakeCase(obj: unknown, path = 'response'): void {
  if (obj === null || typeof obj !== 'object') return;
  for (const key of Object.keys(obj as Record<string, unknown>)) {
    if (/[a-z][A-Z]/.test(key)) {
      throw new Error(
        `camelCase field detected: "${path}.${key}". ` +
        `Backend must return snake_case. Check the Use Case output and ` +
        `compare against @your-app/shared-types interface.`
      );
    }
    assertSnakeCase((obj as Record<string, unknown>)[key], `${path}.${key}`);
  }
}
```

## Single-item endpoint (GET / POST / PATCH)

```typescript
// test/contracts/orders.contract.spec.ts
import { assertSnakeCase } from '../helpers/assert-snake-case';

describe('GET /api/v1/orders/:id — contract', () => {
  it('should return complete OrderResponse shape with snake_case fields', async () => {
    const res = await request(app)
      .get(`/api/v1/orders/${seededOrderId}`)
      .set('Authorization', `Bearer ${validToken}`);

    expect(res.status).toBe(200);

    // 1. Envelope structure
    expect(res.body).toHaveProperty('data');
    expect(res.body).not.toHaveProperty('error');

    // 2. Complete data shape — every field declared in shared-types
    expect(res.body.data).toMatchObject({
      id:         expect.any(String),
      name:       expect.any(String),
      quantity:   expect.any(Number),
      order_type: expect.any(String),       // snake_case
      is_active:  expect.any(Boolean),      // snake_case
      created_at: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T/), // ISO 8601
    });

    // 3. No camelCase anywhere in the response tree
    assertSnakeCase(res.body);
  });

  it('should return standard error envelope on 404', async () => {
    const res = await request(app)
      .get('/api/v1/orders/00000000-0000-0000-0000-000000000000')
      .set('Authorization', `Bearer ${validToken}`);

    expect(res.status).toBe(404);
    expect(res.body).toMatchObject({
      error: {
        code:    expect.any(String),
        message: expect.any(String),
      },
    });
    expect(res.body).not.toHaveProperty('data');
    expect(res.body.error.code).toBe('ENTITY_NOT_FOUND');
  });

  it('should return 401 without token', async () => {
    const res = await request(app).get(`/api/v1/orders/${seededOrderId}`);
    expect(res.status).toBe(401);
    expect(res.body).not.toHaveProperty('data');
  });
});
```

## List endpoint (GET with pagination)

```typescript
describe('GET /api/v1/orders — contract', () => {
  it('should return paginated list with meta and snake_case fields', async () => {
    const res = await request(app)
      .get('/api/v1/orders?page=1&per_page=5')
      .set('Authorization', `Bearer ${validToken}`);

    expect(res.status).toBe(200);

    // 1. Envelope: data array + meta object
    expect(res.body).toMatchObject({
      data: expect.any(Array),
      meta: {
        page:        expect.any(Number),
        per_page:    expect.any(Number),   // snake_case
        total:       expect.any(Number),
        total_pages: expect.any(Number),   // snake_case
      },
    });

    // 2. Shape of first item (seed at least one so this always runs)
    expect(res.body.data.length).toBeGreaterThan(0);
    expect(res.body.data[0]).toMatchObject({
      id:         expect.any(String),
      name:       expect.any(String),
      is_active:  expect.any(Boolean),
      created_at: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T/),
    });

    // 3. No camelCase in the entire response
    assertSnakeCase(res.body);
  });
});
```

## Mutation endpoint (POST / PATCH creating or changing state)

```typescript
describe('POST /api/v1/orders/:id/process — contract', () => {
  it('should return complete ProcessedOrderResponse shape', async () => {
    const res = await request(app)
      .post(`/api/v1/orders/${seededOrderId}/process`)
      .set('Authorization', `Bearer ${validToken}`)
      .send({ processed_at: new Date().toISOString() }); // snake_case input

    expect(res.status).toBe(200);
    expect(res.body.data).toMatchObject({
      id:           expect.any(String),
      status:       'PROCESSED',
      processed_at: expect.stringMatching(/^\d{4}-\d{2}-\d{2}T/),
    });
    assertSnakeCase(res.body);
  });

  it('should return 422 with typed error code when order is expired', async () => {
    const res = await request(app)
      .post(`/api/v1/orders/${expiredOrderId}/process`)
      .set('Authorization', `Bearer ${validToken}`)
      .send({ processed_at: new Date().toISOString() });

    expect(res.status).toBe(422);
    expect(res.body.error.code).toBe('ORDER_EXPIRED');
    assertSnakeCase(res.body);
  });
});
```

## Optimistic lock — 409 envelope

```typescript
describe('PATCH /api/v1/invoices/:id — optimistic lock', () => {
  it('should return 409 with typed error code on stale version', async () => {
    const res = await request(app)
      .patch(`/api/v1/invoices/${seededInvoiceId}`)
      .set('Authorization', `Bearer ${validToken}`)
      .send({ description: 'Concurrent update', version: 0 }); // stale version

    expect(res.status).toBe(409);
    expect(res.body).toMatchObject({
      error: {
        code:    'OPTIMISTIC_LOCK_CONFLICT',
        message: expect.any(String),
      },
    });
    expect(res.body).not.toHaveProperty('data');
    assertSnakeCase(res.body);
  });

  it('should include the updated version in a successful PATCH response', async () => {
    const res = await request(app)
      .patch(`/api/v1/invoices/${seededInvoiceId}`)
      .set('Authorization', `Bearer ${validToken}`)
      .send({ description: 'Valid update', version: 1 }); // correct version from prior GET

    expect(res.status).toBe(200);
    expect(res.body.data).toHaveProperty('version');
    expect(typeof res.body.data.version).toBe('number');
    assertSnakeCase(res.body);
  });
});
```

## Where contract tests live

```
apps/api/test/
├── contracts/          ← one file per controller
│   ├── orders.contract.spec.ts
│   ├── customers.contract.spec.ts
│   └── ...
└── helpers/
    └── assert-snake-case.ts
```

Alternative layout: keep contract assertions inside the colocated `*.controller.spec.ts`
files and only share `test/helpers/assert-snake-case.ts` — fine as long as every endpoint
still gets the three cases (happy path, main error, 401).

Contract tests run alongside unit tests in `pnpm test`.
They require a seeded test database — use `beforeAll` to seed and `afterAll` to remove **only
the rows you seeded** (track their ids — see
[supabase-integration-tests.md](supabase-integration-tests.md) → "Test data isolation").
