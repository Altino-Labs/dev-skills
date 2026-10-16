---
name: api-contracts
description: >
  NestJS/Fastify + Supabase implementation layer of dev-core:api-contracts — snake_case
  checked against the shared-types package, cursor pagination with Supabase/PostgREST
  (composite cursor via .or(), status filters, ascending variant, active vs history split),
  the React Query + React Native infinite-list recipe, NestJS DTO classes with class-validator
  and @Type, @fastify/helmet for the security headers, and @nestjs/throttler for rate limits.
  Invoke automatically (together with dev-core:api-contracts) when creating or reviewing
  endpoints, input/output DTOs, pagination, filters, or API versioning in a NestJS/Fastify +
  Supabase backend or the apps that consume it.
---

# API Contracts — NestJS/Fastify + Supabase implementation

**Load `dev-core:api-contracts` first.** It holds the concepts and rules (snake_case on the
wire, the standard envelope, prefix and versioning, offset vs cursor pagination and their
response shapes, server-side filters, DTOs as the contract, the required security headers,
rate limiting). This skill only shows how to implement them with NestJS (Fastify),
Supabase/PostgREST and the Expo/React Native client; it does not restate the rules.

## snake_case in this stack

The shared contract types live in the shared-types package (e.g. `@your-app/shared-types`,
see `dev-patterns:shared-kernel`). TypeScript does not type-check across the HTTP boundary:
before finishing a use case, confirm that every returned field name matches exactly the field
name declared in the corresponding `@your-app/shared-types` interface. The camelCase-key
detector for contract tests is in `dev-patterns:test-patterns` → `contract-tests-http.md`.

## Envelope in this stack

The error envelope (`AppExceptionFilter`, mandatory) and — only for projects that chose to wrap
successes — the `{ data }` success wrapper (`ResponseInterceptor`, which lets `Page<T>` — detected
by `meta.total_pages` — pass through untouched) are in `dev-patterns:error-handling` →
`filters.md`. Offset-paginated Supabase repositories:
`dev-patterns:clean-architecture` → `supabase-repositories.md`.

---

## Cursor pagination — backend recipe (NestJS + Supabase/Postgres)

**Response shape — `CursorPage<T>`, no `meta`, distinct from the offset pattern** (whether it
is wrapped in `{ data }` follows the project's success-envelope choice, i.e. whether it registers
`ResponseInterceptor` —
`dev-patterns:error-handling`; the client's `apiRequest` must read the same shape):

```typescript
export interface CursorPage<T> {
  items: T[];
  next_cursor: string | null;
}
```

Shared helper — one copy per service, reused by every cursor-paginated repository (the
framework-free version is in `dev-core:api-contracts`; this one uses Node's `Buffer`):

```typescript
// src/shared/pagination/cursor.ts
export interface CursorPage<T> { items: T[]; next_cursor: string | null; }

export function encodeCursor(sortValue: string, id: string): string {
  return Buffer.from(`${sortValue}|${id}`).toString('base64');
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// timestamptz as Supabase returns it, e.g. 2026-05-28T14:32:00.123456+00:00
const TIMESTAMP_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/;
// Letters, digits, space, '_' and '-' only — no PostgREST syntax: , . ( ) " \ :
const SAFE_TEXT_RE = /^[\p{L}\p{N} _-]{1,200}$/u;

export type CursorSortKind = 'timestamp' | 'text';

// The cursor is untrusted input: every field is validated here, before it reaches .or()
export function decodeCursor(
  cursor: string,
  sortKind: CursorSortKind = 'timestamp',
): { sortValue: string; id: string } | null {
  try {
    const decoded = Buffer.from(cursor, 'base64').toString('utf-8');
    const sep = decoded.lastIndexOf('|');
    if (sep <= 0) return null;
    const sortValue = decoded.slice(0, sep);
    const id = decoded.slice(sep + 1);
    if (!UUID_RE.test(id)) return null;
    const pattern = sortKind === 'timestamp' ? TIMESTAMP_RE : SAFE_TEXT_RE;
    return pattern.test(sortValue) ? { sortValue, id } : null;
  } catch { return null; }
}

// Fetches limit+1 rows to cheaply detect a next page without a COUNT query.
export function toCursorPage<T>(rows: T[], limit: number, cursorOf: (last: T) => string): CursorPage<T> {
  const hasMore = rows.length > limit;
  const items = hasMore ? rows.slice(0, limit) : rows;
  const last = items[items.length - 1];
  return { items, next_cursor: hasMore && last ? cursorOf(last) : null };
}

export const DEFAULT_PAGE_LIMIT = 20;
export const MAX_PAGE_LIMIT = 50;
export function parseLimit(raw: string | undefined): number {
  const n = raw ? parseInt(raw, 10) : DEFAULT_PAGE_LIMIT;
  return !Number.isFinite(n) || n < 1 ? DEFAULT_PAGE_LIMIT : Math.min(n, MAX_PAGE_LIMIT);
}
```

Repository — sort by `(timestamp_col, id)` so ties break deterministically, and use
PostgREST's `.or()` to express the composite `WHERE (col, id) < (cursor_col, cursor_id)`.

> **`.or()` takes a filter string, not bound parameters.** Interpolating a raw decoded cursor
> lets a crafted cursor inject PostgREST syntax (`,` `.` `(` `)`) — extra conditions that widen
> the result set. Only ever interpolate values that passed `decodeCursor`'s validation (UUID id,
> timestamp or safe-text sort value). If a text sort column can hold characters the safe-text
> pattern rejects, paginate it with an RPC that takes the cursor as typed parameters instead.

```typescript
async findByProject(projectId: string, options?: { cursor?: string; limit?: number }) {
  const limit = options?.limit ?? DEFAULT_PAGE_LIMIT;
  let query = this.supabase.admin
    .from('table')
    .select('*')
    .eq('project_id', projectId)
    .order('recorded_at', { ascending: false })
    .order('id', { ascending: false })   // tie-breaker — required, timestamps aren't unique
    .limit(limit + 1);

  if (options?.cursor) {
    const decoded = decodeCursor(options.cursor);
    if (decoded) {
      query = query.or(
        `recorded_at.lt.${decoded.sortValue},and(recorded_at.eq.${decoded.sortValue},id.lt.${decoded.id})`,
      );
    }
  }

  const { data, error } = await query;
  if (error) return { items: [], next_cursor: null };
  return toCursorPage(data ?? [], limit, (row) => encodeCursor(row.recorded_at, row.id));
}
```

Controller — plain `@Query()` params (no DTO class needed for two optional strings),
clamp `limit` server-side, never trust the client value directly:

```typescript
@Get('projects/:projectId/events')
async list(
  @Param('projectId') projectId: string,
  @Query('cursor') cursor?: string,
  @Query('limit') limit?: string,
) {
  return this.listEvents.execute(projectId, { cursor, limit: parseLimit(limit) });
}
```

## Cursor pagination — frontend recipe (React Query + React Native)

```typescript
// api function — cursor/limit in, CursorPage<T> out
export async function listItems(projectId: string, params?: { cursor?: string; limit?: number }) {
  const qs = new URLSearchParams();
  if (params?.cursor) qs.set('cursor', params.cursor);
  if (params?.limit) qs.set('limit', String(params.limit));
  return apiRequest<CursorPage<Item>>(`/projects/${projectId}/items${qs.toString() ? `?${qs}` : ''}`);
}

// hook — useInfiniteQuery, not useQuery
export function useItems(projectId: string) {
  return useInfiniteQuery({
    queryKey: ['projects', projectId, 'items'],
    queryFn: ({ pageParam }) => listItems(projectId, { cursor: pageParam, limit: 20 }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.next_cursor ?? undefined,
    enabled: !!projectId,
  });
}
```

Screen — flatten pages, trigger `fetchNextPage` near the bottom of a plain `ScrollView`
(no need to migrate to `FlatList` just for this — `FlatList`'s `onEndReached` is the
equivalent if the list isn't already grouped by date section headers):

```typescript
const { data, fetchNextPage, hasNextPage, isFetchingNextPage } = useItems(projectId);
const items = useMemo(() => data?.pages.flatMap((p) => p.items) ?? [], [data]);

<ScrollView
  onScroll={(e) => {
    const { contentOffset, layoutMeasurement, contentSize } = e.nativeEvent;
    const distanceFromBottom = contentSize.height - (contentOffset.y + layoutMeasurement.height);
    if (distanceFromBottom < 200 && hasNextPage && !isFetchingNextPage) fetchNextPage();
  }}
  scrollEventThrottle={200}
>
  {/* ...rows... */}
  {isFetchingNextPage && <ActivityIndicator color="#3B82F6" />}
</ScrollView>
```

Pull-to-refresh: call the existing `refetch()` — `useInfiniteQuery` refetches all
currently-loaded pages, which is the correct behavior (keeps the loaded window fresh
without resetting scroll position back to a single page).

**Reference implementation:** if the project has one, record its canonical
cursor-paginated module (repository, use case, controller, hook, screen) in the
project-specific complement to this skill.

### Status filter + cursor in one Supabase query

One endpoint, one `status` query param, one repository method that both filters and
paginates in the same Supabase query:

```typescript
export type StatusFilter = 'active' | 'resolved' | 'all'; // or 'active'|'archived'|'all'

async findByProject(
  projectId: string,
  options?: { cursor?: string; limit?: number; status?: StatusFilter },
) {
  let query = this.supabase.admin.from('table').select('*')
    .eq('project_id', projectId)
    .order('created_at', { ascending: false })
    .order('id', { ascending: false })
    .limit((options?.limit ?? DEFAULT_PAGE_LIMIT) + 1);

  if (options?.status === 'active') query = query.is('resolved_at', null);
  else if (options?.status === 'resolved') query = query.not('resolved_at', 'is', null);
  // 'all' (or undefined): no extra filter

  // ...cursor + toCursorPage as above
}
```

On the frontend, the `status` becomes part of the `useInfiniteQuery` key
(`['projects', id, 'items', status]`) so each tab has its own independently-paginated
cache — switching tabs is a normal query switch, not a client-side re-filter:

```typescript
export function useItems(projectId: string, status: StatusFilter = 'active') {
  return useInfiniteQuery({
    queryKey: ['projects', projectId, 'items', status],
    queryFn: ({ pageParam }) => listItems(projectId, { cursor: pageParam, limit: 20, status }),
    initialPageParam: undefined as string | undefined,
    getNextPageParam: (lastPage) => lastPage.next_cursor ?? undefined,
  });
}
```

Mutations still invalidate the bare `['projects', projectId, 'items']` prefix — React
Query's default partial-match invalidation covers every status variant at once, no need
to enumerate them.

### Ascending-sort variant in PostgREST

Same helpers, `ascending: true` on both `.order()` calls and `.gt` instead of `.lt` in the
`.or()` filter:

```typescript
let query = this.supabase.admin.from('projects').select('*')
  .order('name', { ascending: true })
  .order('id', { ascending: true })
  .limit(limit + 1);

if (options?.cursor) {
  const decoded = decodeCursor(options.cursor, 'text');   // safe-text validation for a name column
  if (decoded) {
    query = query.or(
      `name.gt.${decoded.sortValue},and(name.eq.${decoded.sortValue},id.gt.${decoded.id})`,
    );
  }
}
```

Everything else — `toCursorPage`, the frontend hook, `onScroll` near-bottom trigger — is
identical.

### Active vs history split in this stack

Typical repository shape: `findActiveByProject` (open statuses, no pagination — the endpoint
returns `{ items: [...] }`, no `next_cursor`, never a bare array) +
`findHistoryByProject` (terminal statuses, cursor-paginated); on the frontend a
`useItems` + `useItemHistory` pair, combined in the screen. Infinite-scroll wiring
(`onScroll`, back-to-top) is gated on `filter === 'history-tab' || filter === 'all'`.

Mutation invalidation: invalidating the bare `['projects', projectId, '<resource>']` prefix
still covers the `[..., 'history']` key too (React Query prefix match) — don't add a
redundant explicit invalidation of the `history` sub-key in every mutation hook.

---

## DTOs — class-validator

With `ValidationPipe({ whitelist: true, transform: true, transformOptions: { enableImplicitConversion: true } })`
(standard NestJS setup; its error mapping to the envelope is in `dev-patterns:error-handling`).

### Array fields require `@Type(() => String)`

Array fields in DTOs **must** have `@Type(() => String)` (or the appropriate element type).
Without it, `enableImplicitConversion` may discard or misinterpret the array.

```typescript
// ❌ Wrong — array silently discarded with enableImplicitConversion
@IsArray() @IsOptional()
tags?: string[];

// ✅ Correct — explicit element type
@IsArray() @IsOptional() @Type(() => String)
tags?: string[];
```

This applies to any `T[]` field: `string[]`, `number[]`, enum arrays. Always add `@Type(() => ElementClass)`.

```typescript
// Input DTO — class with validation decorators, snake_case fields
export class CreateOrderDto {
  @IsString() @IsNotEmpty()
  name: string;

  @IsNumber() @Min(0)
  quantity: number;

  @IsEnum(OrderType)
  order_type: OrderType;            // snake_case — matches the HTTP body key

  @IsObject()
  order_details: Record<string, unknown>;
}

// Output — plain interface, no decorators, snake_case fields
export interface OrderResponse {
  id: string;
  name: string;
  quantity: number;
  unit: string;
  order_type: OrderType;            // snake_case — matches @your-app/shared-types exactly
  is_active: boolean;
  item_count: number;
  created_at: string;               // ISO 8601 string, not Date (serialized over HTTP)
}
```

---

## Security headers — `@fastify/helmet`

Register `@fastify/helmet` once in `main.ts` (`await app.register(helmet, { ... })`) — never
the Express `helmet` package, which crashes on Fastify. Plugin versions per Fastify major:
`dev-patterns:nestjs-fastify`.

## Rate limiting — `@nestjs/throttler`

Global `ThrottlerModule` default + `ThrottlerGuard` as `APP_GUARD`, per-route `@Throttle()`
overrides, `trustProxy: true` on the `FastifyAdapter`, named profiles in one shared file, and
the in-memory storage limitation: `dev-patterns:auth-security` → `backend-auth.md` ("Rate
limiting").
