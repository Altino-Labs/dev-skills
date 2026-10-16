---
name: shared-kernel-boundaries
description: >
  Decision tree for placing code in packages/ vs inside an app.
  Read before creating any shared artifact. Prevents premature extraction
  and keeps packages/ as a stable contract boundary.
---

# Shared Kernel — Boundaries

> Sub-file of `shared-kernel` skill. Read when deciding whether an artifact
> belongs in `packages/`, in an app-level `common/` folder, or in a module.

---

## Decision tree

Run every question in order. Stop at the first YES.

```
1. Is this code consumed by more than one app (e.g. api + mobile)?
      YES → packages/ (see Package selection below)
      NO
      ↓
2. Is this code shared across multiple modules within the same app?
      YES → app/src/common/ (see Common folder below)
      NO
      ↓
3. Keep it inside the module that owns it.
```

**The threshold is actual consumption, not anticipated consumption.**
"It might be needed by both apps someday" is not sufficient — wait until the second consumer exists.
Premature extraction creates a package that only one app uses, with all the coordination cost and none of the benefit.

---

## Package selection — once you reach packages/

```
Does it contain type definitions only (interfaces, enums, DTOs)?
      YES → packages/shared-types
      NO
      ↓
Does it contain pure functions with zero framework dependencies?
      YES → packages/utils
      NO
      ↓
Does it contain design tokens (color, spacing, typography) with zero JSX?
      YES → packages/ui
      NO
      ↓
      ⚠️  Stop. Re-evaluate: this artifact likely has a framework
          dependency or framework-specific behaviour that prevents it
          from being a clean shared package. Keep it in the app.
```

---

## What belongs in each package

### `packages/shared-types` — the API contract boundary

✅ **Belongs here:**

| Artifact | Rule |
|---|---|
| API response interfaces | Also the return type of Use Case `execute()` — one definition, used by both sides |
| API request DTOs (plain interfaces) | Shape only — no `class-validator` decorators |
| Enums | Only when both backend and frontend reference the same values |
| `Page<T>`, `PageParams`, `PageMeta` | Canonical pagination types — never redefine per module |
| Error envelope types | `ApiError`, `ApiResponse<T>` |

❌ **Does NOT belong here:**

| Artifact | Why | Where it goes |
|---|---|---|
| Decorated DTO classes (`@IsString()`) | `class-validator` is backend-only | `apps/api/src/<module>/dtos/` |
| React / React Native components | Framework-specific | `apps/mobile/src/` |
| NestJS providers or decorators | Framework-specific | `apps/api/src/` |
| Domain entities or value objects | Never cross the HTTP boundary | `apps/api/src/<module>/domain/` |
| Backend-only interfaces (`IRepository`, `IEventBus`) | Not consumed by frontend | `apps/api/src/common/` or module domain folder |

### `packages/utils` — pure functions

✅ **Belongs here:**
- Date / time formatting and arithmetic
- Pure format validators (email regex, document number check)
- Stateless business calculations used on both sides (e.g. age from birth date)
- String, array, object helpers

❌ **Does NOT belong here:**
- Any `import` from React, React Native, NestJS, Next.js, or browser APIs
- Functions with side effects (network calls, file I/O, logging)
- Functions that depend on runtime environment variables

### `packages/ui` — design tokens

✅ **Belongs here:**
- Color palette, spacing scale, typography scale — as typed TypeScript constants
- Border radii, shadow definitions, z-index scale

❌ **Does NOT belong here:**
- React or React Native components (even "headless" ones)
- CSS stylesheets or `StyleSheet.create()` blocks
- Dynamic theme logic or context providers

---

## `app/src/common/` — intra-app shared code

Code shared across multiple modules **within the same app** does not need a package.
It belongs in the app's `common/` folder:

```
apps/api/src/common/
  guards/
    jwt-auth.guard.ts
    resource-member.guard.ts
  interceptors/
    idempotency-response.interceptor.ts
    logging.interceptor.ts
  filters/
    domain-exception.filter.ts
  decorators/
    current-user.decorator.ts
  pipes/
    parse-uuid.pipe.ts
```

```
apps/mobile/src/common/
  components/
    empty-state.tsx
    loading-spinner.tsx
  hooks/
    use-debounce.ts
  utils/
    format-relative-date.ts   ← mobile-only, not worth extracting to packages/utils
```

**Rule:** if the artifact is never imported by the other app, it stays in `common/`.
Only promote to `packages/` when the second app starts consuming it.

---

## Anti-patterns

### Premature extraction

```
// ❌ "It looks generic, let's put it in utils"
// packages/utils/src/retry.ts — only used by apps/api

// ✅ Wait for the second consumer
// apps/api/src/common/utils/retry.ts — used by 3 api modules
// → promote to packages/utils when apps/mobile needs it too
```

### Shared type that leaks backend concerns

```typescript
// ❌ WRONG — backend annotation leaked into shared-types
// packages/shared-types/src/order.ts
import { IsString, IsNotEmpty } from 'class-validator';  // backend-only dep

export class CreateOrderDto {
  @IsString() @IsNotEmpty()
  currency: string;
}

// ✅ CORRECT — plain interface in shared-types; decorated class in backend
// packages/shared-types/src/order.ts
export interface CreateOrderPayload { currency: string; }

// apps/api/src/orders/dtos/create-order.dto.ts
import { CreateOrderPayload } from '@your-app/shared-types';
export class CreateOrderDto implements CreateOrderPayload {
  @IsString() @IsNotEmpty() currency: string;
}
```

### Backend-only type extracted to shared-types

```typescript
// ❌ WRONG — IOrderRepository is never imported by the frontend
// packages/shared-types/src/i-order.repository.ts
export interface IOrderRepository { ... }

// ✅ CORRECT — stays in the backend domain layer
// apps/api/src/orders/domain/repositories/i-order.repository.ts
export interface IOrderRepository { ... }
```

### Over-generalising utils

```typescript
// ❌ WRONG — formatDeliverySlotDate is domain-specific, not general
// packages/utils/src/format-delivery-slot-date.ts

// ✅ CORRECT — domain-specific formatting stays in the app
// apps/mobile/src/features/orders/utils/format-slot-date.ts
```

---

## Checklist — before creating any artifact in packages/

- [ ] Is it actually imported by more than one app today (not "might be")?
- [ ] Does it have zero framework dependencies (React, NestJS, Next.js, Expo)?
- [ ] Is it the right package? (types → shared-types, pure fn → utils, tokens → ui)
- [ ] If it's a type: is it defined here and only here? (no local copy in the backend)
- [ ] If it's a function: does it have unit tests in `packages/utils/src/__tests__/`?
- [ ] Is `packages/<pkg>/src/index.ts` updated to export the new artifact?

Any NO → keep the artifact in the app until the condition is met.
