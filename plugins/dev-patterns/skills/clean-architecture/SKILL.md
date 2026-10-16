---
name: clean-architecture
description: >
  NestJS + Supabase implementation layer of dev-core:clean-architecture — thin NestJS
  controllers, class-validator DTOs, module/provider wiring with repository-port tokens, the
  global authorization module for membership guards, Supabase repository implementations,
  PostgREST query limits, specification filters, Supabase RPC / pg transactions and the
  idempotency guard/interceptor. Invoke automatically (together with dev-core:clean-architecture)
  when creating an entity, use case, repository, controller, value object, or any domain
  artifact in a NestJS + Supabase backend.
---

# Clean Architecture — NestJS + Supabase implementation

**Load `dev-core:clean-architecture` first.** It holds the concepts and rules (creation order,
layers, entities, value objects, aggregates, domain services, use cases, repository ports,
specifications, idempotency, transactions, ACL, domain exceptions). This skill only shows how
to implement them with NestJS + Supabase (supabase-js / PostgREST); it does not restate the
rules.

## Folder structure for each new module (NestJS)

The dev-core layout, with NestJS + Supabase file names:

```
<module>/
  domain/
    entities/<module>.entity.ts
    repositories/i-<module>.repository.ts

  use-cases/
    <verb>-<noun>.use-case.ts
    <verb>-<noun>.use-case.spec.ts

  infrastructure/database/repositories/
    supabase-<module>.repository.ts

  <module>.module.ts
  <module>.controller.ts   ← DTO classes declared inline at the top of this
                              file (see below), not in a separate dtos/ folder
```

Shared domain exceptions live in `shared/exceptions/domain.exceptions.ts`; domain events in
`shared/events/catalog/`.

**Declare DTOs inline in the controller, not in a `dtos/` subfolder.** Put the request DTO
classes directly above the `@Controller` class in the same `<module>.controller.ts` file — see
"NestJS DTOs pattern" below for the actual shape. Don't create a separate `dtos/` folder.

## Use Case pattern (NestJS DI)

```typescript
@Injectable()
export class VerbNounUseCase {
  constructor(
    @Inject(ENTITY_REPOSITORY) private readonly repository: IEntityRepository,
    @Inject(EVENT_BUS) private readonly eventBus: IEventBus,
  ) {}

  async execute(input: VerbNounInput): Promise<VerbNounOutput> {
    // 1. Fetch required data
    // 2. Apply domain rules
    // 3. Persist via repository
    // 4. Publish domain events
    // 5. Map the entity to the output (toOutput) and return it
  }
}
```

## Entity built from a Supabase row

The repository always instantiates and returns the entity — never a `*Row` (raw table shape)
past the repository boundary. With supabase-js the record is the snake_case row, so the
entity's loading factory is a static `fromRow` that reads named fields off the row (never a
positional constructor call scattered across the repository):

```typescript
export class EntityName {
  private constructor(
    public readonly id: string,
    public readonly customerId: string,
    public readonly field: string,
    // ...
  ) {}

  static fromRow(row: EntityNameRow): EntityName {
    return new EntityName(
      row.id,
      row.customer_id,
      row.field,
      // ...
    );
  }

  /** Only if the entity has derived/computed state — see dev-core. */
  // get isActive(): boolean { ... }
}
```

No `toDto()` on the entity: the use case maps the entity back to the snake_case wire shape
the API/mobile app expects (the shared-types DTOs), in a private `toOutput()` — see
`dev-core:clean-architecture` → entities.md, "Entity → Output mapping belongs to the Use Case".

When an entity's data doesn't come entirely from one row, use `fromRow(row, extra)` — a second
argument for a value computed by a separate query the repository joins in after the fact.

## Repository port with a NestJS injection token

```typescript
export const ENTITY_REPOSITORY = Symbol('ENTITY_REPOSITORY');

export interface IEntityRepository {
  findById(id: string): Promise<EntityName | null>;
  create(data: CreateEntityData): Promise<EntityName>;
  update(id: string, data: UpdateEntityData): Promise<EntityName>;
}
```

## Controller pattern (thin — zero business logic)

```typescript
@ApiTags('orders')
@ApiBearerAuth()
@Controller('orders')
export class OrderController {
  constructor(private readonly useCase: ProcessOrderUseCase) {}

  @Post(':id/process')
  async process(
    @Param('id') orderId: string,
    @Body() dto: ProcessOrderDto,
    @CurrentUser() user: AuthUser,
  ): Promise<ProcessOrderResponse> {   // ← import from @your-app/shared-types, never a local type
    // Controller wires HTTP DTO → Input; never passes the DTO directly to the Use Case
    return this.useCase.execute({
      order_id:     orderId,
      processed_by: user.id,
      processed_at: new Date(dto.processed_at),
    });
  }
}
```

## NestJS DTOs pattern

```typescript
import { IsString, IsNotEmpty, IsOptional } from 'class-validator';

export class CreateOrderDto {
  @IsString()
  @IsNotEmpty()
  currency: string;      // no initializer — class-transformer populates via transform

  @IsOptional()
  @IsString()
  notes?: string;
}

// Update DTO: PartialType from the Create DTO
export class UpdateOrderDto extends PartialType(CreateOrderDto) {}
```

**`tsconfig.json` in `apps/api` must have `"strictPropertyInitialization": false`**
so DTOs without initializers compile without TS2564 errors.

## NestJS Module — provider pattern

```typescript
@Module({
  imports: [SupabaseModule],
  controllers: [OrderController],
  providers: [
    { provide: ORDER_REPOSITORY, useClass: SupabaseOrderRepository },
    // EVENT_BUS is provided globally by EventBusModule registered once in AppModule.
    // Never declare InMemoryEventBus per-module — each instance maintains an isolated
    // subscriber registry; events from this module would never reach subscribers
    // registered in other modules. See `dev-patterns:domain-events` → event-bus-impl.md.
    ProcessOrderUseCase,
    PlaceOrderUseCase,
    ListOrdersUseCase,
  ],
  exports: [ORDER_REPOSITORY],
})
export class OrderModule {}
```

More wiring (the three-part DIP binding, strategy factories with `useFactory`, domain services
with dependencies): [nestjs-wiring.md](nestjs-wiring.md).

## TenantMemberGuard / ResourceMemberGuard — inject via a global AuthorizationModule

A membership guard (`TenantMemberGuard`, or a resource-level `ResourceMemberGuard` such as
`CustomerMemberGuard`) requires its member repository (`TENANT_MEMBER_REPOSITORY`,
`CUSTOMER_MEMBER_REPOSITORY`). Do NOT duplicate the provider in each module — declare it once
in a `@Global()` AuthorizationModule:

```typescript
// infrastructure/auth/authorization.module.ts
@Global()
@Module({
  imports: [SupabaseModule],
  providers: [
    { provide: TENANT_MEMBER_REPOSITORY, useClass: SupabaseTenantMemberRepository },
    TenantMemberGuard,
    { provide: CUSTOMER_MEMBER_REPOSITORY, useClass: SupabaseCustomerMemberRepository },
    CustomerMemberGuard,
  ],
  exports: [TENANT_MEMBER_REPOSITORY, TenantMemberGuard,
            CUSTOMER_MEMBER_REPOSITORY, CustomerMemberGuard],
})
export class AuthorizationModule {}
```

Register in `AppModule`. Child modules receive the guards automatically via globals.
Keep the guards' own queries simple — see [supabase-repositories.md](supabase-repositories.md),
"Guards — simple queries in PostgREST".

## Domain exceptions → HTTP

Use cases throw the domain exceptions described in `dev-core:clean-architecture`; never
`HttpException`:

```typescript
// ✅ Correct
throw new EntityNotFoundException('Order', id);   // domain exception — dev-patterns:error-handling

// ❌ Wrong
throw new HttpException('Not found', 404);
```

In this stack the exception classes (with their `code` and `statusCode`) and the global
exception filter that maps them to HTTP live in `dev-patterns:error-handling`.

## Naming (NestJS + Supabase)

| Artifact | Convention | Example |
|---|---|---|
| Repository Impl | `SupabaseEntityRepository` | `SupabaseOrderRepository` |
| Injection token | `ENTITY_REPOSITORY` (`Symbol`) | `ORDER_REPOSITORY` |
| File | `kebab-case` with suffix | `process-order.use-case.ts`, `supabase-order.repository.ts` |

The other names (entity, use case, repository interface, DTO, exception) follow
`dev-core:clean-architecture`.

## Detailed guides

- [nestjs-wiring.md](nestjs-wiring.md) — wiring ports to adapters in NestJS modules: the
  three-part DIP binding (`Symbol` + `@Inject` + `useClass`), strategy factories with
  `useFactory`/`inject`, domain services with dependencies.
- [supabase-repositories.md](supabase-repositories.md) — writing a Supabase repository:
  mapping rows, error handling, close methods, optimistic-lock `save()`, upsert, N+1 with
  nested selects, LSP-safe `maybeSingle()`, guard queries, column-to-column comparison,
  Supabase Auth behind an ACL adapter.
- [specification-postgrest.md](specification-postgrest.md) — translating `SqlFilter`
  (`toQuery()`) to PostgREST with `applyFilter`, a spec-driven query repository, and
  PostgREST's composition limits.
- [transactions-supabase.md](transactions-supabase.md) — atomic writes: Layer 1 via a
  Supabase RPC (PostgreSQL function), Layer 2 unit of work with the `pg` client and its
  incompatibility with supabase-js, the `.env.example` entry.
- [idempotency-nestjs.md](idempotency-nestjs.md) — Pattern B DTO/controller, the
  `idempotency_keys` RLS policy and cleanup job, and the Pattern C guard, decorator and
  response interceptor.
