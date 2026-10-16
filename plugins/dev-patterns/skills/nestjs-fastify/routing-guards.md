---
# Guards, PATCH endpoints, empty-body POST, compiled build restart, and CORS configuration for NestJS + Fastify.
# Referenced by SKILL.md — do not duplicate content there.
---

## Guards — extract resource ID from multiple param name conventions

NestJS apps commonly mix two URL patterns for the same resource:

| Route pattern | `request.params` keys |
|---|---|
| `GET /resource/:id` | `{ id }` — owner route (summary, update, delete) |
| `GET /resource/:resourceId/children` | `{ resourceId }` — sub-resource routes |

A guard that only reads `request.params.resourceId` silently fails on `GET /resource/:id`
— the param key is `id`, not `resourceId`, so the guard gets `undefined` and throws 403
even for authorized users.

**Pattern — read both param name conventions:**

```typescript
// ❌ Misses owner routes (/resource/:id)
resourceId = request.params?.resourceId ?? request.body?.resource_id;

// ✅ Handles both /resource/:id and /resource/:resourceId/children
resourceId = request.params?.resourceId
          ?? request.params?.id
          ?? request.body?.resource_id;
```

**When to apply:** any guard that resolves a parent resource ID from the URL. Check both
the owner routes (`@Get(':id')`) and sub-resource routes (`@Get(':resourceId/children')`)
when writing or reviewing a guard.

---

## PATCH endpoint required for every entity with an edit form

Every entity that has an edit form in the frontend needs a `PATCH /<entity>/:id` endpoint.
Missing this causes `Cannot PATCH /api/v1/...` (404) in the frontend.

**Required artifacts per module:**

| File | Minimum content |
|---|---|
| `dto/update-<entity>.dto.ts` | `PartialType(OmitType(CreateDto, ['owner_id', ...] as const))` |
| `use-cases/update-<entity>.use-case.ts` | loads entity via repository interface → calls entity method → persists → returns output |
| `<entity>.controller.ts` | `@Patch('<entity>/:id')` with `@Param('id')` + typed body |
| `<entity>.module.ts` | use case registered in `providers` |

**DTO pattern:**

```typescript
import { OmitType, PartialType } from '@nestjs/swagger';
import { CreateEntityDto } from './create-entity.dto';

export class UpdateEntityDto extends PartialType(
  OmitType(CreateEntityDto, ['owner_id', 'created_at'] as const),
) {}
```

**Use case pattern — follows Clean Architecture (read `dev-core:clean-architecture` → `use-cases.md`; NestJS wiring in `dev-patterns:clean-architecture`):**

```typescript
// application/use-cases/entity/update-entity.use-case.ts
import { EntityResponse } from '@your-app/shared-types';   // output defined in shared-types first

export interface UpdateEntityInput { id: string; name?: string; /* dto fields */ }

@Injectable()
export class UpdateEntityUseCase {
  constructor(
    @Inject(ENTITY_REPOSITORY) private readonly entities: IEntityRepository,
  ) {}

  async execute(input: UpdateEntityInput): Promise<EntityResponse> {
    const entity = await this.entities.findById(input.id);
    if (!entity) throw new EntityNotFoundException('Entity', input.id);   // domain exception — never @nestjs/common

    const updated = entity.update(input);                        // invariant enforced by entity method
    const saved   = await this.entities.save(updated);           // persisted via repository interface
    return this.toOutput(saved);
  }

  private toOutput(entity: EntityName): EntityResponse {
    return { id: entity.id, /* snake_case fields — must match @your-app/shared-types */ };
  }
}
```

> **Never** inject `SupabaseService` or any infrastructure class into a Use Case.
> **Never** throw `NotFoundException` or `InternalServerErrorException` from `@nestjs/common` in a Use Case.
> Both violate DIP (the domain/application layer must not depend on infrastructure or the HTTP framework) — review should reject them.
> Use `IEntityRepository` (interface) and domain exceptions (`EntityNotFoundException`, and `DatabaseException` for persistence failures — `dev-patterns:error-handling`).

**Controller pattern:**

```typescript
@Patch(':id')
@ApiOperation({ summary: 'Update entity' })
update(@Param('id') id: string, @Body() dto: UpdateEntityDto) {
  return this.updateEntityUseCase.execute({ id, name: dto.name, /* map dto fields */ });
}
```

**Rule:** When generating any backend module, check whether there is a corresponding edit screen
in the frontend. If yes, PATCH is required. Verify that all HTTP verbs are present in the
controller: POST (create), GET (list/find), PATCH (update), DELETE/archive when applicable.

---

## POST requests with empty body require `JSON.stringify({})`

When the client sets `Content-Type: application/json` (the default for most API clients),
Fastify rejects POST requests with no body with error 500:
`"Body cannot be empty when content-type is set to 'application/json'"`.

This commonly affects action endpoints like `/deactivate`, `/archive`, `/cancel`, `/activate`.

**Solution — client side:** send `body: JSON.stringify({})` for POST endpoints without a payload:

```typescript
export function deactivateItem(id: string): Promise<void> {
  return apiRequest<void>(`/items/${id}/deactivate`, {
    method: 'POST',
    body: JSON.stringify({}),  // required — Fastify rejects empty body when Content-Type is JSON
  });
}
```

**When to apply:** any POST endpoint that takes no request body: `/deactivate`, `/archive`,
`/cancel`, `/activate`, `/resolve`, `/confirm`.

---

## Compiled build — new endpoints require rebuild and restart

When the API runs as `node dist/main.js`, adding new endpoints to a controller does NOT
hot-reload. The new routes return 404 until a full rebuild and process restart.

**Diagnosis:**

```bash
ps aux | grep node   # "node dist/main.js" → compiled build, no hot reload
```

**Solution:**

```bash
cd apps/api
pnpm build                                              # recompile TypeScript → dist/
pkill -f "dist/main"                                    # kill old process (matches with or without --enable-source-maps)
node --enable-source-maps dist/main.js &                # start with new dist
```

> ⚠️ `pkill -f "node dist/main.js"` does NOT match processes started with
> `node --enable-source-maps dist/main` (no extension). Always use `pkill -f "dist/main"`.

> ⚠️ The API must be restarted from `apps/api/` — `dotenv/config` resolves `.env`
> relative to `process.cwd()`. Restarting from the monorepo root causes the process
> to not find the correct `.env` and run with undefined variables.

**Verification:** in the NestJS boot log, confirm the new route appears:

```
[RouterExplorer] Mapped {/api/v1/items/:id/deactivate, POST} route
```

**For development:** prefer `nest start --watch` to avoid this issue entirely.

> ⚠️ **`nest start --watch` and `node dist/main.js` are independent processes** — both can
> run simultaneously on different ports or even the same port (if one took it). Verifying
> that `--watch` is running does NOT confirm that the compiled build was updated.
> Always check `ps aux | grep node` to identify WHICH process is actually serving the port.
> `lsof -i :3000 | grep LISTEN` shows the PID; match it against `ps` output to confirm.
> If the serving PID is `node dist/main.js`, a `nest build` + restart is required even if
> a `--watch` process is also running.

---

## CORS — list all frontend origins explicitly

With Fastify, `app.enableCors()` must include every frontend origin (port) explicitly.
Unlisted origins receive a silent CORS error in the browser — with no indication of which
origin is missing. Always use the `CORS_ORIGINS` env var to avoid hardcoding.

```typescript
app.enableCors({
  origin: process.env.CORS_ORIGINS?.split(',') ?? ['http://localhost:3001'],
  credentials: true,
});
```

**`apps/api/.env` — dev local origins:**

```
# Replace port numbers with your project's actual Expo / frontend ports.
# Include the local network IP (192.168.x.x) when testing on a physical device
# on the same network. Restart the API after changing CORS_ORIGINS — the value
# is read only at startup.
CORS_ORIGINS=http://localhost:3001,http://localhost:3002
```

After changing `CORS_ORIGINS`, a full API restart is required — the value is read only at startup.
