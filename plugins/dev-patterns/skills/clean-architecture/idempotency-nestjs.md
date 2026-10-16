# Idempotency in NestJS + Supabase
> Sub-file of the `dev-patterns:clean-architecture` skill (NestJS + Supabase implementation of
> `dev-core:clean-architecture`). Read when implementing Pattern B or Pattern C endpoints in
> NestJS on Supabase.

The decision tree, the universal rules, Patterns A/B/C, the request flow and the
Pattern C + Optimistic Lock interaction are in `dev-core:clean-architecture` →
idempotency.md. The Supabase upsert / OL `save()` is in
[supabase-repositories.md](supabase-repositories.md).

---

## Pattern B — DTO and controller

```typescript
// DTO: client may supply the ID; controller generates one if not provided
export class CreateOrderDto {
  @IsOptional() @IsUUID()
  id?: string;

  @IsString() @IsNotEmpty()
  currency: string;
}

// Controller generates the ID if absent
@Post()
async create(@Body() dto: CreateOrderDto, @CurrentUser() user: AuthUser) {
  return this.useCase.execute({ id: dto.id ?? randomUUID(), customer_id: user.id, currency: dto.currency });
}
```

The use case answers an existing ID owned by another customer as not found, and the upsert
never overwrites `customer_id` (IDOR) — `dev-core:clean-architecture` → idempotency.md,
Pattern B. supabase-js `.upsert()` cannot express the ownership `WHERE`, so `save()` calls an
owner-guarded RPC — [supabase-repositories.md](supabase-repositories.md), "Pattern B".

---

## Pattern C — `idempotency_keys` table on Supabase

```sql
CREATE TABLE idempotency_keys (
  user_id         uuid        NOT NULL,
  route           text        NOT NULL,     -- 'POST /orders/:order_id/process-payment'
  key             text        NOT NULL,
  request_hash    text        NOT NULL,
  status          text        NOT NULL CHECK (status IN ('in_progress', 'completed')),
  response_status int,
  response        jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, route, key)
);
CREATE INDEX ON idempotency_keys (created_at);  -- used by TTL cleanup below

ALTER TABLE idempotency_keys ENABLE ROW LEVEL SECURITY;

-- Only the admin client (service_role) accesses this table — no authenticated user access.
-- Without this policy, the service_role client cannot read, insert or delete rows
-- (supabase-js v2 requires an explicit service_role policy even for the admin client).
CREATE POLICY "idempotency_keys_service_role" ON public.idempotency_keys
  FOR ALL TO service_role USING (true);
```

### TTL cleanup job

The table must have a TTL cleanup job — without it it grows unbounded.
**Prefer Option B** (NestJS `@Cron`) — it works on every Supabase tier and requires no
extension. Use Option A (`pg_cron`) only when it is already enabled for other reasons.

**Option A — pg_cron (Supabase Pro / self-hosted with pg_cron enabled):**

Run in a **separate, optional migration** — never inline in the `CREATE TABLE` migration.
If pg_cron is not enabled, this migration fails and must be skipped.

```sql
-- supabase/migrations/XXXX_idempotency_keys_cleanup_cron.sql
-- OPTIONAL — only apply if pg_cron extension is enabled in the project.
-- Enable in Supabase: Dashboard → Database → Extensions → pg_cron

SELECT cron.schedule(
  'cleanup-idempotency-keys',
  '0 3 * * *',   -- daily at 03:00 UTC
  $$DELETE FROM idempotency_keys WHERE created_at < now() - interval '24 hours'$$
);
```

**Option B — NestJS @Cron (always available, no extension required):**

```typescript
// infrastructure/jobs/idempotency-cleanup.cron.ts
@Injectable()
export class IdempotencyCleanupCron {
  constructor(private readonly supabase: SupabaseService) {}

  @Cron('0 3 * * *')
  async cleanup(): Promise<void> {
    await this.supabase.client
      .from('idempotency_keys')
      .delete()
      .lt('created_at', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString());
  }
}
```

---

## Pattern C — guard, decorator, interceptor, controller

```typescript
// common/guards/idempotency.guard.ts
//
// Two modes controlled by @RequireIdempotencyKey():
//   Without decorator — key is optional; activates only when the client sends it.
//   With decorator    — key is REQUIRED; 400 if absent.
//                       Use on every Pattern C endpoint: missing key = no protection.
// Runs AFTER JwtAuthGuard (needs request.user). Reserves the key BEFORE the handler runs.
@Injectable()
export class IdempotencyGuard implements CanActivate {
  constructor(
    private readonly supabase:  SupabaseService,
    private readonly reflector: Reflector,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request    = context.switchToHttp().getRequest<FastifyRequest & { user: AuthUser }>();
    const reply      = context.switchToHttp().getResponse<FastifyReply>();
    const key        = request.headers['idempotency-key'] as string | undefined;
    const isRequired = this.reflector.get<boolean>('idempotency_required', context.getHandler());

    if (!key && isRequired)
      throw new InvalidValueException(
        'IDEMPOTENCY_KEY_REQUIRED',
        'Idempotency-Key header is required for this operation. Generate a unique UUID per request.',
      );

    if (!key) return true;  // optional for non-Pattern-C endpoints

    // Scope: (user, method + route template, key) — never a global key
    const scope = { user_id: request.user.id, route: `${request.method} ${request.routeOptions.url}`, key };
    const requestHash = createHash('sha256')   // node:crypto; canonical JSON in production
      .update(JSON.stringify({ params: request.params, body: request.body ?? null }))
      .digest('hex');
    const db = this.supabase.client.from('idempotency_keys');

    // 1. Reserve atomically — the primary key decides the winner of a race
    const { error } = await db.insert({ ...scope, request_hash: requestHash, status: 'in_progress' });
    if (!error) { (request as any).idempotency = scope; return true; }
    if (error.code !== '23505') throw new DatabaseException('DB_ERROR', error.message);

    // 2. Key already exists for this caller + route
    const { data: row } = await this.supabase.client.from('idempotency_keys')
      .select('request_hash, status, response_status, response').match(scope).single();

    if (row.request_hash !== requestHash)
      throw new IdempotencyKeyReusedException();
    if (row.status === 'completed') { reply.status(row.response_status).send(row.response); return false; }
    throw new IdempotencyRequestInProgressException();
  }
}
```

The two protocol errors are application exceptions with the `dev-patterns:error-handling`
shape (status fixed by the class, read only by `AppExceptionFilter`):

```typescript
export class IdempotencyKeyReusedException extends ApplicationException {
  constructor() {
    super('IDEMPOTENCY_KEY_REUSED', 'Idempotency-Key was already used with a different request.', 422);
  }
}
export class IdempotencyRequestInProgressException extends ApplicationException {
  constructor() {
    super('IDEMPOTENCY_REQUEST_IN_PROGRESS', 'A request with this Idempotency-Key is still in progress. Retry later.', 409);
  }
}
```

A crash between reserve and complete leaves a stale `in_progress` row; before throwing 409,
reclaim it when it is older than the lease (dev-core idempotency.md, "Request flow" step 3).

```typescript
// common/decorators/require-idempotency-key.decorator.ts
// Apply to any Pattern C endpoint. Without this decorator, IdempotencyGuard is lenient:
// a client that omits the header bypasses idempotency protection entirely.
export const RequireIdempotencyKey = (): MethodDecorator =>
  SetMetadata('idempotency_required', true);
```

```typescript
// common/interceptors/idempotency-response.interceptor.ts
//
// Registration: must be a GLOBAL interceptor registered BEFORE ResponseInterceptor.
//
// NestJS interceptor post-phase (response) order is the reverse of registration order:
// the FIRST registered interceptor executes LAST in the response phase.
// To see the already-wrapped { data: ... } body, IdempotencyResponseInterceptor
// must execute AFTER ResponseInterceptor in the response phase — which means it
// must be registered BEFORE ResponseInterceptor.
//
// ❌ DO NOT register with route-level @UseInterceptors() — route-level interceptors
//    run before global ones in the post-phase, so body would be the raw handler
//    output (pre-envelope) and the replayed response would arrive without the
//    { data: ... } wrapper, silently breaking every Pattern C retry.
//
// main.ts registration order:
//   app.useGlobalInterceptors(
//     app.get(IdempotencyResponseInterceptor), // outer — runs LAST in response phase, sees { data: ... }
//     app.get(ResponseInterceptor),            // inner — runs FIRST in response phase, wraps raw body
//   );
@Injectable()
export class IdempotencyResponseInterceptor implements NestInterceptor {
  private readonly logger = new Logger(IdempotencyResponseInterceptor.name);

  constructor(
    private readonly supabase:  SupabaseService,
    private readonly reflector: Reflector,
  ) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    // Only activate on routes decorated with @RequireIdempotencyKey().
    // All other routes pass through untouched — no performance cost.
    const isPatternC = this.reflector.get<boolean>('idempotency_required', context.getHandler());
    if (!isPatternC) return next.handle();

    const scope = context.switchToHttp().getRequest().idempotency;   // set by IdempotencyGuard
    if (!scope) return next.handle();
    // Nest's default status: @HttpCode() if present, else 201 for POST, 200 otherwise
    const status = this.reflector.get<number>(HTTP_CODE_METADATA, context.getHandler())
      ?? (context.switchToHttp().getRequest().method === 'POST' ? 201 : 200);

    return next.handle().pipe(
      // mergeMap awaits the DB update before the response is sent.
      // tap(async) is fire-and-forget: a retry arriving immediately would still see
      // 'in_progress' (409) instead of the stored response.
      mergeMap(async (body) => {
        // body is already { data: ... } — wrapped by the inner ResponseInterceptor.
        // Storing the wrapped body ensures the replayed response (sent by IdempotencyGuard)
        // has the same shape as the first successful response.
        const { error } = await this.supabase.client
          .from('idempotency_keys')
          .update({ status: 'completed', response_status: status, response: body })
          .match(scope);
        if (error) this.logger.error(`failed to complete idempotency key "${scope.key}": ${error.message}`);
        return body;
      }),
      // Handler failed: release the reservation so the client can retry
      catchError(async (err) => {
        await this.supabase.client.from('idempotency_keys')
          .delete().match({ ...scope, status: 'in_progress' });
        throw err;
      }),
    );
  }
}
```

```typescript
// Controller: @RequireIdempotencyKey() enforces the header for Pattern C endpoints.
// IdempotencyResponseInterceptor is registered globally — never add @UseInterceptors() here.
@Post(':order_id/process-payment')
@UseGuards(JwtAuthGuard, OrderMemberGuard, IdempotencyGuard)
@RequireIdempotencyKey()   // ← 400 if header is absent; also activates the global interceptor
async processPayment(
  @Param('order_id') orderId: string,
  @Body() dto: ProcessPaymentDto,
  @CurrentUser() user: AuthUser,
) {
  return this.useCase.execute({ order_id: orderId, amount: dto.amount, currency: dto.currency, processed_by: user.id });
}
```
