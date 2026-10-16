# Specifications on PostgREST
> Sub-file of the `dev-patterns:clean-architecture` skill (NestJS + Supabase implementation of
> `dev-core:clean-architecture`). Read when a `QueryableSpecification` must filter a list in
> Supabase, or when composing specifications that will reach PostgREST.

The Specification pattern itself (`ISpecification`, `IQueryableSpecification`, `SqlFilter`,
base classes, concrete specs, testing) is in `dev-core:clean-architecture` → specification.md.
Here: translating `SqlFilter` into PostgREST calls and what PostgREST can and cannot compose.

In this stack, `not()` is not composable as a `SqlFilter` because PostgREST does not support
general negation as a composable filter — `.not()` on a `QueryableSpecification` stays
in-memory only; for negation in DB queries, add a dedicated repository method.

---

## Translator — `applyFilter`

```typescript
// infrastructure/repositories/spec-filter.helper.ts
// Translates SqlFilter to PostgREST chained calls
export function applyFilter<T>(
  query: PostgrestFilterBuilder<any, any, T>,
  filter: SqlFilter,
): PostgrestFilterBuilder<any, any, T> {
  switch (filter.op) {
    case 'eq':     return query.eq(filter.column, filter.value);
    case 'neq':    return query.neq(filter.column, filter.value);
    case 'gte':    return query.gte(filter.column, filter.value);
    case 'lte':    return query.lte(filter.column, filter.value);
    case 'in':     return query.in(filter.column, filter.values.map(String));
    case 'not_in': return query.not(filter.column, 'in', `(${filter.values.map(String).join(',')})`);
    case 'and':    return filter.filters.reduce((q, f) => applyFilter(q, f), query);
    case 'or': {
      // PostgREST or() takes a comma-separated filter string: 'col.op.val,col.op.val'
      // Supported primitives inside or(): eq, neq, gte, lte ONLY.
      // in, not_in, and nested and/or all require a dedicated repository method.
      const orParts = filter.filters.map(f => {
        if (f.op === 'and' || f.op === 'or' || f.op === 'in' || f.op === 'not_in')
          throw new Error(
            `'${f.op}' inside or() is not supported by PostgREST — use a dedicated repository method instead.`
          );
        return `${f.column}.${f.op}.${(f as any).value}`;
      });
      return query.or(orParts.join(','));
    }
  }
}
```

## Query repository that accepts `IQueryableSpecification`

```typescript
// infrastructure/repositories/supabase-order-query.repository.ts
@Injectable()
export class SupabaseOrderQueryRepository implements IOrderQueryRepository {
  constructor(private readonly supabase: SupabaseService) {}

  async findBySpec(spec: IQueryableSpecification<Order>, params: PageParams): Promise<Page<Order>> {
    const from = (params.page - 1) * params.per_page;
    const to   = from + params.per_page - 1;

    let query = this.supabase.client
      .from('orders')
      .select('*', { count: 'exact' });

    query = applyFilter(query, spec.toQuery());  // ← spec drives the WHERE clause

    const { data, count, error } = await query
      .order('created_at', { ascending: false })
      .range(from, to);

    if (error) throw new OrderQueryException(error.message);

    return {
      data: (data ?? []).map(row => this.toEntity(row)),   // named props → Order.reconstitute({ ... })
      meta: { page: params.page, per_page: params.per_page,
              total: count ?? 0, total_pages: Math.ceil((count ?? 0) / params.per_page) },
    };
  }
}
```

---

## PostgREST composition limits — safe vs unsafe combinations

`applyFilter` supports these compositions correctly:

| Composition | Safe? | Why |
|---|---|---|
| `specA.and(specB)` | ✅ | `and` reduces each primitive filter sequentially |
| `specA.and(specB).and(specC)` | ✅ | chains correctly via `AndQueryableSpecification` |
| `specA.or(specB)` | ✅ | only when both are primitive specs (`eq`/`neq`/`gte`/`lte`) |
| `specA.or(specB.and(specC))` | ❌ | `and` inside `or()` → throws in `applyFilter` |
| `specA.and(specB.or(specC))` | ❌ | `or` inside `and()` loses PostgREST compatibility |
| spec with `in`/`not_in` inside `or()` | ❌ | throws in `applyFilter` — use a dedicated repository method |

**Rule:** only use `.or()` between two **primitive** specs (no further composition on either side).
For any complex disjunction (OR of AND groups), use a dedicated repository method instead.

```typescript
// ✅ SAFE — OR between two primitive specs
const spec = new ActiveSpec().or(new DraftSpec());

// ❌ UNSAFE at runtime — AND group inside OR
const spec = new ActiveSpec().or(new DraftSpec().and(new NewSpec()));
// → use a dedicated repo method: findActiveOrNewDraft(params)
```
