---
name: clean-architecture
description: >
  Clean Architecture and tactical DDD guide for any stack: creation order, layers and the
  dependency rule, entities, value objects, aggregates, domain services, use cases,
  repository ports, specifications, idempotency, transactions, anti-corruption layers and
  domain exceptions. Invoke automatically when creating an entity, use case, repository,
  value object, domain service, or any other domain artifact, in any language or framework.
---

# Clean Architecture

> **How to read the examples.** Every example in this skill is framework-free TypeScript —
> plain classes, interfaces and functions, no decorators, no framework, no database client.
> Read it as pseudo-code and translate it to the project's language and idioms.
> Stack-specific implementations (DI wiring, ORM/query-builder code, HTTP adapters) live in
> stack plugins — e.g. `dev-patterns:clean-architecture` for NestJS + Supabase — and in the
> project's own delta skill (`.claude/skills/<project>-clean-architecture/`), when they exist.
> Load them together with this skill.

## Mandatory creation order per module

```
entity → repository interface → use case → controller → DTOs
```

Never skip steps. Never create a controller before the use case exists.
("Controller" = whatever interface adapter the stack uses: HTTP controller, handler, resolver,
message consumer, CLI command.)

## Layers and dependencies

```
Domain          ← zero external dependencies (no framework imports)
Application     ← depends only on Domain (interfaces, never concretes)
Infrastructure  ← implements Domain interfaces
Interfaces      ← thin controllers, only receive and delegate
```

The absolute rule: **dependencies always point inward**.

Interface adapters (controllers, handlers) contain zero business logic: they receive the
request, convert the transport DTO into the use case's input, call the use case, and return
its output.

## Folder structure for each new module

Use this layout consistently for every module — flatter than a textbook Clean Architecture
tree, but easier to navigate once there are more than a handful of modules. Names below are
generic; the stack plugin gives the concrete file names for your framework.

```
<module>/
  domain/
    entities/<module> entity
    value-objects/<name> value object
    repositories/<module> repository interface (port)
    services/        ← domain services, when needed
    specifications/  ← specifications, when needed

  use-cases/
    <verb>-<noun> use case
    <verb>-<noun> use case test

  infrastructure/
    repositories/<technology>-<module> repository (adapter implementing the port)

  <module> wiring      ← where the framework/DI container binds ports to adapters
  <module> controller  ← interface adapter + its request DTOs
```

Avoid `application/` or `interfaces/http/modules/` wrapper directories — keep `use-cases/`,
the module wiring and the controller directly under `<module>/`. Keep domain events centrally
in `shared/events/catalog/` rather than per-module (`shared/events/`, not
`<module>/domain/events/`); do the same for exceptions — centralize them in one shared
domain-exceptions file rather than a per-module `domain/exceptions/` folder, as long as the
exception hierarchy is generic (`EntityNotFoundException`, `ForbiddenOperationException`, ...)
rather than module-specific.

## Use Case pattern

```typescript
export class VerbNounUseCase {
  constructor(
    private readonly repository: IEntityRepository,   // port — never a concrete class
    private readonly eventBus: IEventBus,             // port
  ) {}

  async execute(input: VerbNounInput): Promise<VerbNounOutput> {
    // 1. Fetch required data
    // 2. Apply domain rules (via entity methods)
    // 3. Persist via repository
    // 4. Publish domain events
    // 5. Map the entity to the output here and return it
  }
}
```

## Entity pattern

**Mandatory:** the repository always instantiates and returns the entity — never the raw
persistence record (row, document, ORM model) past the repository boundary.
The constructor is **private**; entities are built via static factories that take **named
fields** (`create()` for a new entity, `reconstitute()` for one loaded from storage), not a
positional constructor call scattered across the repository. This prevents a real bug class:
adjacent same-typed fields silently swapped in a long positional constructor call, with no
compiler error.

```typescript
export interface OrderProps {
  id: string;
  customerId: string;
  items: OrderItem[];
  status: OrderStatus;
  currency: string;
}

export class Order {
  private constructor(
    public readonly id: string,
    public readonly customerId: string,
    private readonly _items: OrderItem[],
    public readonly status: OrderStatus,
    public readonly currency: string,
  ) {}

  /** A new entity — sets the initial state. */
  static create(props: { id: string; customerId: string; currency: string }): Order {
    return new Order(props.id, props.customerId, [], OrderStatus.DRAFT, props.currency);
  }

  /** Loading from storage — the repository maps its record to named props, then calls this. */
  static reconstitute(props: OrderProps): Order {
    return new Order(props.id, props.customerId, props.items, props.status, props.currency);
  }

  /** Only if the entity has derived/computed state — see below. */
  // get total(): Money { ... }
}
```

The full `Order` aggregate (items, `addItem`, `total`) is in [aggregates.md](aggregates.md);
every example in this skill uses that same shape.

**The entity never maps itself to an output/DTO** (no `toDto()`, no `toResponse()`): that
would make the domain depend on the interface layer's types. The use case (or a mapper it
owns) converts the entity into the output — including any wire-format conventions such as
snake_case field names:

```typescript
export class GetOrderUseCase {
  async execute(input: GetOrderInput): Promise<OrderResponse> {
    const order = await this.orders.findById(input.id);
    if (!order) throw new EntityNotFoundException('Order', input.id);
    return this.toOutput(order);
  }

  private toOutput(order: Order): OrderResponse {
    return { id: order.id, customer_id: order.customerId, status: order.status };
  }
}
```

See [entities.md](entities.md) — "Entity → Output mapping belongs to the Use Case".

**Getters/methods are not mandatory on every entity** — many entities need none, and that's
fine. Add one only when there's real derived state to centralize. When an entity's data
doesn't come entirely from one record, prefer a `reconstitute(props, extra)` shape — a second
argument for a value computed by a separate query the repository joins in after the fact —
over smuggling that kind of derived value into the record type itself.

**Watch for:** entities with public constructors built positionally by their repositories
(many positional args, several adjacent `string | null` fields) are a common source of
argument-order bugs. Prefer a named-parameters object or a private constructor + static
factory once an entity grows past 4-5 fields.

## Repository Interface pattern

```typescript
export interface IEntityRepository {
  findById(id: string): Promise<EntityName | null>;
  create(data: CreateEntityData): Promise<EntityName>;
  update(id: string, data: UpdateEntityData): Promise<EntityName>;
}
```

The interface (port) lives in the domain layer; the implementation (adapter) lives in
infrastructure. If the project's DI container resolves dependencies by token, the token is
declared next to the interface. See [repositories.md](repositories.md).

## Domain exceptions

Domain and application code throws **domain-level errors** — they describe what went wrong in
business terms and carry a stable machine-readable `code`. They never carry or throw transport
concepts.

The hierarchy (`AppException` → `DomainException` / `ApplicationException` /
`InfrastructureException`), its constructors and its codes (one not-found code,
`ENTITY_NOT_FOUND`) are defined once in `dev-core:error-handling` — use those classes; never
redefine a local base class.

```typescript
// Never throw transport errors (HTTP exceptions, status codes) in use cases
// ✅ Correct
throw new EntityNotFoundException('Order', id);

// ❌ Wrong
throw new HttpError('Not found', 404);
```

Mapping a domain exception to the transport (HTTP status, error envelope, gRPC code) happens
once, in the interface layer (an exception filter / error-handling middleware) — see the
project's error-handling conventions (`dev-core:error-handling`; for NestJS also
`dev-patterns:error-handling`).

## Mandatory naming conventions

Adapt casing and file suffixes to the language's conventions; keep the roles distinct.

| Artifact | Convention | Example |
|---|---|---|
| Entity | `PascalCase` | `TenantMember` |
| Use Case | `VerbNounUseCase` | `ProcessOrderUseCase` |
| Repository Interface | `IEntityRepository` | `IOrderRepository` |
| Repository Impl | `<Technology>EntityRepository` | `SqlOrderRepository` |
| Input DTO | `VerbEntityDto` | `CreateOrderDto` |
| Exception | `ConceptException` | `OrderNotFoundException` |
| File | `kebab-case` with role suffix | `process-order.use-case.ts` |

## Detailed guides

Read the file that matches the task before writing the artifact:

- [entities.md](entities.md) — creating an entity: behavior vs anemic model, state changes
  only through entity methods (copy-on-write, or in-place mutation for ORM-tracked entities),
  boolean state flags from the DB, entity → output mapping in the use case, Law of Demeter,
  optimistic locking (ORM-native first; client version checked in the use case).
- [value-objects.md](value-objects.md) — creating a value object, running the VO detection
  protocol, `create()` vs `reconstitute()`, canonical `Money`/`Email`/`DateRange`/`Quantity`.
- [aggregates.md](aggregates.md) — designing aggregate boundaries and child entities;
  replacing `if/switch` on type with Strategy (OCP).
- [domain-services.md](domain-services.md) — deciding between entity method, use case and
  domain service; domain service patterns and anti-patterns.
- [use-cases.md](use-cases.md) — use case input/output types, delete use cases, Command vs
  Query (CQRS) and when to inject the event bus.
- [repositories.md](repositories.md) — repository interfaces: contracts, ISP + CQRS
  read/write split, N+1 check, DIP, tenant scoping, LSP.
- [specification.md](specification.md) — composable boolean eligibility rules
  (in-memory and DB-translatable), testing them, Strategy vs Specification.
- [idempotency.md](idempotency.md) — before writing any Command use case that creates or
  mutates state: patterns A/B/C, interaction with optimistic locking, anti-patterns.
- [transactions.md](transactions.md) — a use case that writes to two or more repositories:
  aggregate redesign, consolidated transactional method, unit of work, saga.
- [acl.md](acl.md) — integrating an external system (auth provider, email API, payment
  gateway, storage) through an anti-corruption layer.
