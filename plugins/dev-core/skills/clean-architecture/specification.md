# Specification Pattern
> Sub-file of the `dev-core:clean-architecture` skill. Read when implementing boolean eligibility rules
> that must be composed (AND/OR/NOT) or must filter a list in the database.

---

Use the Specification pattern when a business rule needs to be:
- **Composed** from smaller rules (`and`, `or`, `not`)
- **Reused** across multiple use cases or repositories
- **Tested** in isolation from the use case that applies it

> "A Specification states a constraint on the state of an object."
> — Eric Evans, *Domain-Driven Design*

**Strategy (OCP) handles behavioral variation per type. Specification handles boolean eligibility logic.**

## Interfaces — two tiers

```typescript
// domain/specifications/i-specification.ts

// Tier 1 — in-memory validation: every Specification implements this
export interface ISpecification<T> {
  isSatisfiedBy(entity: T): boolean;
  and(other: ISpecification<T>): ISpecification<T>;
  or(other: ISpecification<T>): ISpecification<T>;
  not(): ISpecification<T>;
}

// SqlFilter — a closed set of filter shapes that a repository translates into its query
// language (SQL WHERE clause, query-builder calls, ORM criteria). In TS: a discriminated
// union; in Java/C#: a sealed interface/records; in Python: dataclasses + a Union; in Go: an
// interface with one struct per op.
export type SqlFilter =
  | { op: 'eq' | 'neq' | 'gte' | 'lte'; column: string; value: unknown }
  | { op: 'in' | 'not_in';               column: string; values: unknown[] }
  | { op: 'and';                          filters: SqlFilter[] }
  | { op: 'or';                           filters: SqlFilter[] };

// Tier 2 — DB-translatable: specs that can also filter in the database
export interface IQueryableSpecification<T> extends ISpecification<T> {
  toQuery(): SqlFilter;
}
```

**When to implement `IQueryableSpecification` vs plain `ISpecification`:**

| Signal | Interface |
|---|---|
| Used only to validate a single loaded entity | `ISpecification<T>` |
| Used in a list endpoint that must filter in the DB | `IQueryableSpecification<T>` |
| Rule involves joining another table in SQL | `ISpecification<T>` + dedicated repository method |

## Base classes

Uses dedicated composite classes (Evans, *Domain-Driven Design*).
Anonymous object closures captured `this` of the original spec, causing chains of 3+ specs
to silently drop intermediate conditions — `specA.and(specB).and(specC)` would evaluate as
`specA AND specC`, losing `specB`. Dedicated classes fix this by holding both operands explicitly.

```typescript
// domain/specifications/specification.base.ts

// ── Tier 1 — in-memory base ──────────────────────────────────────────────────

export abstract class Specification<T> implements ISpecification<T> {
  abstract isSatisfiedBy(entity: T): boolean;

  and(other: ISpecification<T>): ISpecification<T> { return new AndSpecification(this, other); }
  or(other:  ISpecification<T>): ISpecification<T> { return new OrSpecification(this, other); }
  not(): ISpecification<T>                          { return new NotSpecification(this); }
}

class AndSpecification<T> extends Specification<T> {
  constructor(
    private readonly left:  ISpecification<T>,
    private readonly right: ISpecification<T>,
  ) { super(); }

  isSatisfiedBy(entity: T): boolean {
    return this.left.isSatisfiedBy(entity) && this.right.isSatisfiedBy(entity);
  }
}

class OrSpecification<T> extends Specification<T> {
  constructor(
    private readonly left:  ISpecification<T>,
    private readonly right: ISpecification<T>,
  ) { super(); }

  isSatisfiedBy(entity: T): boolean {
    return this.left.isSatisfiedBy(entity) || this.right.isSatisfiedBy(entity);
  }
}

class NotSpecification<T> extends Specification<T> {
  constructor(private readonly inner: ISpecification<T>) { super(); }

  isSatisfiedBy(entity: T): boolean { return !this.inner.isSatisfiedBy(entity); }
}

// ── Tier 2 — DB-translatable base ────────────────────────────────────────────

export abstract class QueryableSpecification<T>
  extends Specification<T>
  implements IQueryableSpecification<T>
{
  abstract toQuery(): SqlFilter;

  // Overrides produce IQueryableSpecification so toQuery() survives the composition
  and(other: IQueryableSpecification<T>): IQueryableSpecification<T> {
    return new AndQueryableSpecification(this, other);
  }
  or(other: IQueryableSpecification<T>): IQueryableSpecification<T> {
    return new OrQueryableSpecification(this, other);
  }

  // not() is intentionally NOT overridden here.
  // General negation is not part of SqlFilter — many query layers cannot express it as a
  // composable filter. Calling .not() on a QueryableSpecification returns ISpecification<T>
  // (in-memory only). In statically typed languages (TS, Java, C#, Go) the type system
  // enforces this: passing the result to findBySpec() produces a compile error. In Python or
  // other dynamic languages, a type checker (mypy/pyright) catches it if run in CI; otherwise
  // findBySpec() must check at runtime and raise.
  // For negation in DB queries, add a dedicated repository method that mirrors the rule.
}

class AndQueryableSpecification<T> extends QueryableSpecification<T> {
  constructor(
    private readonly left:  IQueryableSpecification<T>,
    private readonly right: IQueryableSpecification<T>,
  ) { super(); }

  isSatisfiedBy(entity: T): boolean {
    return this.left.isSatisfiedBy(entity) && this.right.isSatisfiedBy(entity);
  }
  toQuery(): SqlFilter {
    return { op: 'and', filters: [this.left.toQuery(), this.right.toQuery()] };
  }
}

class OrQueryableSpecification<T> extends QueryableSpecification<T> {
  constructor(
    private readonly left:  IQueryableSpecification<T>,
    private readonly right: IQueryableSpecification<T>,
  ) { super(); }

  isSatisfiedBy(entity: T): boolean {
    return this.left.isSatisfiedBy(entity) || this.right.isSatisfiedBy(entity);
  }
  toQuery(): SqlFilter {
    return { op: 'or', filters: [this.left.toQuery(), this.right.toQuery()] };
  }
}
```

## Concrete specifications

```typescript
// domain/specifications/order-status.specification.ts
// Implements IQueryableSpecification — used in list endpoints that filter by status
export class OrderStatusSpecification
  extends QueryableSpecification<Order>
{
  constructor(private readonly status: OrderStatus) { super(); }

  isSatisfiedBy(order: Order): boolean { return order.status === this.status; }
  toQuery(): SqlFilter { return { op: 'eq', column: 'status', value: this.status }; }
}

// domain/specifications/order-created-after.specification.ts
export class OrderCreatedAfterSpecification
  extends QueryableSpecification<Order>
{
  constructor(private readonly since: Date) { super(); }

  isSatisfiedBy(order: Order): boolean { return order.createdAt >= this.since; }
  toQuery(): SqlFilter { return { op: 'gte', column: 'created_at', value: this.since.toISOString() }; }
}

// Composite — AND of two queryable specs is itself queryable
// Usage: new OrderStatusSpecification(DRAFT).and(new OrderCreatedAfterSpecification(cutoff))
//   → isSatisfiedBy(): in-memory AND
//   → toQuery(): { op: 'and', filters: [{ op: 'eq', ... }, { op: 'gte', ... }] }
```

## Repository that accepts `IQueryableSpecification`

```typescript
// domain/repositories/i-order-query.repository.ts
export interface IOrderQueryRepository {
  findBySpec(spec: IQueryableSpecification<Order>, params: PageParams): Promise<Page<Order>>;
}
```

The repository implementation translates `spec.toQuery()` into its query language — a small
translator function (`applyFilter(query, filter)`) that walks the `SqlFilter` tree and emits
the WHERE clause or query-builder calls, then adds ordering and pagination as usual. The spec
drives the WHERE clause; the repository owns everything else. Translators for a specific query
layer, with that layer's composition limits, live in the stack plugin (e.g.
`dev-patterns:clean-architecture`).

## Use Case — DB filtering via spec

```typescript
// Use Case: passes the spec directly to the query repository — no N+1
export class ListActiveOrdersUseCase {
  constructor(private readonly query: IOrderQueryRepository) {}

  async execute(input: ListOrdersInput): Promise<ListOrdersOutput> {
    const spec = new OrderStatusSpecification(OrderStatus.ACTIVE)
      .and(new OrderCreatedAfterSpecification(input.since));

    const page = await this.query.findBySpec(spec, { page: input.page, per_page: input.per_page });
    return { data: page.data.map(this.toOutput), meta: page.meta };
  }
}
```

## Use Case — in-memory validation (single entity)

```typescript
export class CheckOrderEligibilityUseCase {
  constructor(private readonly orders: IOrderRepository) {}

  async execute(input: CheckEligibilityInput): Promise<CheckEligibilityOutput> {
    const order = await this.orders.findById(input.orderId);
    if (!order) throw new OrderNotFoundException(input.orderId);

    // isSatisfiedBy() — validates the already-loaded entity; no DB query needed
    const spec = new OrderStatusSpecification(OrderStatus.DRAFT);
    return { order_id: order.id, is_eligible: spec.isSatisfiedBy(order) };
  }
}
```

## Testing specifications in isolation (pure domain logic — no mocks)

```typescript
describe('OrderStatusSpecification', () => {
  const spec = new OrderStatusSpecification(OrderStatus.ACTIVE);

  it('should be satisfied when order is active', () => {
    expect(spec.isSatisfiedBy(OrderFactory.active())).toBe(true);
  });

  it('should not be satisfied when order is cancelled', () => {
    expect(spec.isSatisfiedBy(OrderFactory.cancelled())).toBe(false);
  });

  it('toQuery returns the correct SqlFilter', () => {
    expect(spec.toQuery()).toEqual({ op: 'eq', column: 'status', value: OrderStatus.ACTIVE });
  });

  it('and() composes isSatisfiedBy and toQuery correctly', () => {
    const cutoff = new Date('2024-01-01');
    const composed = spec.and(new OrderCreatedAfterSpecification(cutoff));

    expect(composed.isSatisfiedBy(OrderFactory.activeCreatedAt(new Date('2024-06-01')))).toBe(true);
    expect(composed.isSatisfiedBy(OrderFactory.activeCreatedAt(new Date('2023-01-01')))).toBe(false);
    expect(composed.toQuery()).toEqual({
      op: 'and',
      filters: [
        { op: 'eq',  column: 'status',     value: OrderStatus.ACTIVE },
        { op: 'gte', column: 'created_at', value: cutoff.toISOString() },
      ],
    });
  });
});
```

## Strategy vs Specification — when to use each

| Scenario | Pattern |
|---|---|
| Behavior varies by type — different *what to do* | Strategy (OCP) |
| Boolean rule — *whether* an entity qualifies | Specification |
| Rule is composed from smaller rules | Specification |
| Rule is reused across multiple use cases | Specification |
| Rule must filter a list in the database | `IQueryableSpecification<T>` + the repository's filter translator (`applyFilter()`) |
| Rule involves a SQL join (related table) | `ISpecification<T>` + dedicated repository method |

## When `toQuery()` is not enough — dedicated repository method

When the SQL rule requires joining another table, `toQuery()` cannot express it as a flat
`SqlFilter`. Use a dedicated repository method that documents which Specification it mirrors:

```typescript
// domain/repositories/i-order-query.repository.ts
export interface IOrderQueryRepository {
  findBySpec(spec: IQueryableSpecification<Order>, params: PageParams): Promise<Page<Order>>;

  /**
   * Returns orders with at least one item from a given product category.
   * Rule mirrors: OrderHasCategorySpecification (cannot be expressed as SqlFilter — requires JOIN).
   * Update this method when the spec changes.
   */
  findByCategorySpec(categoryId: string, params: PageParams): Promise<Page<Order>>;
}
```

The Specification remains the canonical reference for the business rule.
**When the rule changes: update the Specification first, then align the repository method.**

The same applies when the query layer's translator cannot express a composition (for example
an OR of AND groups, or negation): use a dedicated repository method that mirrors the
Specification instead of forcing it through `toQuery()`. Each stack's translator documents
which compositions are safe.
