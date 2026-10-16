---
name: shared-types-lifecycle
description: >
  Breaking change classification, expand/contract protocol, consumer audit,
  enum lifecycle and emergency path for packages/shared-types.
  Read before renaming, removing, or restructuring any shared type.
---

# shared-types Lifecycle — Breaking Changes

> Sub-file of `shared-kernel` skill. Read when modifying an existing interface,
> renaming a field, removing a field, or changing an enum in `packages/shared-types`.

---

## The HTTP boundary problem

TypeScript's structural typing catches shape mismatches **within the same process**.
It does NOT protect you across the HTTP boundary.

```
Backend process          Wire (JSON)          Frontend process
──────────────           ──────────           ────────────────
OrderResponse.ts         { "order_status" }   OrderResponse.ts
  status: string   →          ↑          →      status: string
                         field name
                         mismatch here
                         TypeScript is silent on both sides
```

**Consequence:** renaming `status` to `order_status` in the interface compiles cleanly on
both sides. At runtime, the frontend receives `{ order_status: 'SHIPPED' }` but reads
`response.status` — which is `undefined`. No TypeScript error, no runtime exception.
The bug manifests as silent UI breakage.

This is why every field rename requires the expand/contract protocol, not just a refactor.

---

## Breaking change classification

Run this table for every field change before committing to `shared-types`.

| Change | Classification | Safe to ship? |
|---|---|---|
| Add a new optional field | Non-breaking | ✅ Yes — consumers receive `undefined` and ignore it |
| Add a new required field | **Breaking** | ❌ Frontend build fails if it references the field; runtime crash if it reads it |
| Add a new interface | Non-breaking | ✅ Yes — consumers import what they need |
| Remove a field | **Breaking** | ❌ Frontend code referencing it compiles but reads `undefined` at runtime |
| Rename a field | **Breaking** | ❌ HTTP boundary is silent; old name disappears from wire |
| Change optional → required | **Breaking** | ❌ Frontend code that omits the field in a request now fails validation |
| Change required → optional | Non-breaking | ✅ Frontend code that always sends the field continues to work |
| Widen a type (`string` → `string \| null`) | Non-breaking | ✅ Yes — existing code handles the non-null case |
| Narrow a type (`string \| null` → `string`) | **Breaking** | ❌ Frontend null checks now over-guard a field that can never be null |
| Add a new enum value | **Breaking** | ❌ `switch` statements with no `default` crash; UI renderers show blank |
| Remove an enum value | **Breaking** | ❌ Any stored or in-flight value becomes unrecognised |
| Rename an enum value | **Breaking** | ❌ Same as remove + add simultaneously |
| Change field type (`string` → `number`) | **Breaking** | ❌ Runtime coercion errors; comparisons silently wrong |
| Change date format (`Date` → `string`) | **Breaking** | ❌ Consumer code calling `.toISOString()` crashes |

**Rule of thumb:** if the wire payload shape changes in any way that a consumer
already in production would not understand, it is breaking.

---

## Consumer audit — run before every breaking change

Before starting the expand phase, find every consumer of the field you are about to change.
Missing even one means silent breakage in production.

```bash
# Find all files that reference the field by name
# Replace 'status' and 'OrderResponse' with the actual field and type names
grep -rn "\.status\b" apps/ packages/ --include="*.ts" --include="*.tsx"
grep -rn "OrderResponse" apps/ packages/ --include="*.ts" --include="*.tsx"

# Check contract tests — they verify the wire name
grep -rn '"status"' apps/api/test/ --include="*.ts"

# Check frontend display logic
grep -rn "order\.status\|item\.status" apps/mobile/src/ --include="*.tsx"
```

Record the full list of consumer files before writing a single line of code.
Each file in the list is a migration task in Sprint N+1.

---

## Expand / Contract — full protocol

### When to use

Any change classified as **Breaking** in the table above requires the 3-sprint protocol.
Non-breaking changes skip directly to shipping.

### Sprint N — Expand (add without removing)

**Goal:** the wire carries both the old field and the new field simultaneously.
Both the old and new consumers work correctly.

```typescript
// packages/shared-types/src/order.ts
export interface OrderResponse {
  id:           string;
  status:       string;   // ← original field: kept; do NOT remove yet
  order_status: string;   // ← new canonical name: added alongside
  created_at:   string;
}
```

```typescript
// apps/api — Use Case maps both fields
private toOutput(order: Order): OrderResponse {
  return {
    id:           order.id,
    status:       order.status,        // kept: old consumers still read this
    order_status: order.status,        // new: same value, new name
    created_at:   order.createdAt.toISOString(),
  };
}
```

**Contract test** — both field names must appear in the response during the expand phase:

```typescript
it('should return both status and order_status during migration', async () => {
  const res = await request(app).get(`/orders/${id}`).set('Authorization', `Bearer ${token}`);
  expect(res.body.data).toHaveProperty('status');       // old — still present
  expect(res.body.data).toHaveProperty('order_status'); // new — now present
});
```

### Sprint N+1 — Migrate all consumers

**Goal:** every consumer switches from the old field to the new one.
The old field is still on the wire (backend still sends it), but no code reads it.

```typescript
// apps/mobile — every reference to .status is migrated to .order_status
// Before:
<Text>{order.status}</Text>
// After:
<Text>{order.order_status}</Text>
```

Migration checklist (from the consumer audit above):
- [ ] Every screen that renders the field
- [ ] Every hook that maps or filters by the field
- [ ] Every contract test that asserts the field name
- [ ] Every Zustand store that caches the field

**Do not remove the old field from the interface yet.**
The backend is still sending it; removing the type definition before the frontend is
fully migrated causes TypeScript to flag every reference, which is noise, not safety.

### Sprint N+2 — Contract (remove the old field)

**Goal:** the old field is gone from the interface, the wire, and all consumers.
Run the consumer audit again before this step — confirms zero references remain.

```typescript
// packages/shared-types/src/order.ts
export interface OrderResponse {
  id:           string;
  order_status: string;   // canonical name only
  created_at:   string;
  // status removed — no consumer references it
}
```

```typescript
// apps/api — Use Case stops sending the old field
private toOutput(order: Order): OrderResponse {
  return {
    id:           order.id,
    order_status: order.status,
    created_at:   order.createdAt.toISOString(),
    // status removed from wire
  };
}
```

**Contract test** — old field must be absent:

```typescript
it('should not return the deprecated status field after contract', async () => {
  const res = await request(app).get(`/orders/${id}`).set('Authorization', `Bearer ${token}`);
  expect(res.body.data).not.toHaveProperty('status');   // removed
  expect(res.body.data).toHaveProperty('order_status'); // canonical
});
```

---

## Enum lifecycle

Adding or removing enum values is a breaking change — treat it with the same
expand/contract discipline, but the migration surface is different.

### Adding a new value — consumer-side impact

```typescript
// packages/shared-types/src/order.ts
export enum OrderStatus {
  DRAFT     = 'DRAFT',
  CONFIRMED = 'CONFIRMED',
  SHIPPED   = 'SHIPPED',
  DELIVERED = 'DELIVERED',   // ← new value added in Sprint N
}
```

**Audit target:** every `switch`, `if`, or `.map` that handles `OrderStatus` values.

```typescript
// ❌ WRONG — no default; new value produces blank UI silently
function statusLabel(status: OrderStatus): string {
  switch (status) {
    case OrderStatus.DRAFT:     return 'Draft';
    case OrderStatus.CONFIRMED: return 'Confirmed';
    case OrderStatus.SHIPPED:   return 'Shipped';
    // DELIVERED never handled — renders nothing
  }
}

// ✅ CORRECT — exhaustive with explicit default
function statusLabel(status: OrderStatus): string {
  switch (status) {
    case OrderStatus.DRAFT:     return 'Draft';
    case OrderStatus.CONFIRMED: return 'Confirmed';
    case OrderStatus.SHIPPED:   return 'Shipped';
    case OrderStatus.DELIVERED: return 'Delivered';
    default:
      // TypeScript's never check: if this branch is reachable, a new enum value was added
      // without updating this switch. The type error surfaces at compile time.
      const _exhaustive: never = status;
      return String(_exhaustive);
  }
}
```

**Sprint order for new enum value:**
1. Sprint N: add the value to the enum; update every `switch` in the same PR
2. Backend starts sending the new value
3. Frontend already handles it (migration happened in Step 1)

### Removing a value — requires data migration

Removing an enum value means stored rows in the database may still hold the old value.

```
Sprint N:   Mark value as deprecated in a comment — still in the enum
            Find all DB rows that hold the value
Sprint N+1: Migrate all stored rows to the replacement value (data migration)
Sprint N+2: Remove the value from the enum
```

```typescript
// Sprint N — deprecation marker (do NOT remove yet)
export enum OrderStatus {
  DRAFT     = 'DRAFT',
  /** @deprecated Use CONFIRMED. Will be removed in Sprint N+2. */
  PENDING   = 'PENDING',
  CONFIRMED = 'CONFIRMED',
}

// Sprint N+2 — removal (only after data migration confirms zero rows)
export enum OrderStatus {
  DRAFT     = 'DRAFT',
  CONFIRMED = 'CONFIRMED',
}
```

**Never remove an enum value before confirming zero rows hold it in every environment.**

---

## Emergency path — when you cannot wait 3 sprints

When a breaking change must ship immediately (security fix, critical bug, compliance),
use API versioning rather than forcing a coordinated deploy.

### Route versioning

```typescript
// apps/api — new version at /v2/; old version at /v1/ still works
@Controller('v2/orders')
export class OrderV2Controller {
  @Get(':id')
  findOne(@Param('id') id: string): OrderV2Response { ... }
}

@Controller('v1/orders')
export class OrderV1Controller {
  @Get(':id')
  findOne(@Param('id') id: string): OrderV1Response { ... }  // old shape, kept for compat
}
```

```typescript
// packages/shared-types/src/order.ts — both shapes coexist during transition
export interface OrderV1Response { id: string; status: string; }
export interface OrderV2Response { id: string; order_status: string; }
```

**Exit condition:** once every frontend consumer migrates to `/v2/`, remove `/v1/`
and `OrderV1Response` in the next sprint.

### When NOT to use API versioning

API versioning is an escape hatch for emergencies only. Using it routinely creates
a versioning debt that grows faster than it is paid down. The 3-sprint expand/contract
protocol is the default; versioning is the exception.

---

## Verification checklist

Before merging any `shared-types` change:

- [ ] Change classified as Breaking or Non-breaking (table above)
- [ ] If Breaking: consumer audit ran; full list of consumer files recorded
- [ ] If Breaking: expand phase adds new field alongside old (never removes on first PR)
- [ ] If Breaking: contract test covers both field names during expand phase
- [ ] If Breaking: migrate tasks created for Sprint N+1 (one per consumer file)
- [ ] If enum value added: every `switch`/`if` over that enum has a `default` or exhaustive check
- [ ] If enum value removed: data migration confirmed zero rows hold the old value
- [ ] `packages/shared-types/src/index.ts` exports the updated type
- [ ] `pnpm --filter "@your-app/shared-types" build` passes with zero errors
