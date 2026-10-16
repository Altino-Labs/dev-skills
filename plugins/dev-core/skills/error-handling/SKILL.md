---
name: error-handling
description: >
  Error handling for any stack: the fundamental rule (use cases throw domain exceptions, never
  transport errors), the exception hierarchy (domain / application / infrastructure) with a
  stable code, mapping to the transport (HTTP status, error envelope) only at the edge,
  domain-specific exceptions, the API error and success envelope contracts (or RFC 9457
  Problem Details), validation errors and overriding the framework's default validation response,
  and graceful degradation of non-critical side effects via domain events. Invoke automatically
  when implementing or reviewing try/catch, exceptions, error mapping or error responses, in any
  language or framework.
---

# Error Handling

> **How to read the examples.** Every example in this skill is framework-free TypeScript —
> plain classes and functions, no decorators, no framework, no HTTP or logging library. Read it
> as pseudo-code and translate it to the project's language and idioms. Stack-specific
> implementations (the global exception filter / error middleware, the success-envelope
> wrapper, the validation library's error mapping, error-tracker hooks) live in stack plugins —
> e.g. `dev-patterns:error-handling` for NestJS/Fastify — and in the project's own delta skill
> (`.claude/skills/<project>-error-handling/`), when they exist. Load them together with this
> skill.

## Fundamental rule

**Use cases throw domain exceptions. They NEVER throw transport errors** (HTTP exceptions,
status codes, gRPC codes). The mapping to the transport happens exclusively at the edge — in
the interface adapter's single global error handler (exception filter / error-handling
middleware). Layers and the dependency rule: `dev-core:clean-architecture`.

## Exception hierarchy

```
AppException (base)
├── DomainException
│   ├── EntityNotFoundException
│   ├── BusinessRuleViolationException
│   ├── OptimisticLockException
│   └── InvalidValueException
├── ApplicationException
│   ├── UnauthorizedException
│   └── ForbiddenOperationException
└── InfrastructureException
    ├── DatabaseException
    └── ExternalServiceException
```

Every exception carries a stable, machine-readable `code` (e.g. `'ENTITY_NOT_FOUND'`) — the
value clients branch on. Messages are for humans and may change; codes may not.

## Base structure — the canonical definitions

This is the **one** definition of the hierarchy. Every other skill and example uses these
classes, constructors and codes — never a local variant.

```typescript
export abstract class AppException extends Error {
  constructor(
    readonly code: string,        // e.g.: 'ENTITY_NOT_FOUND'
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

// The three layers — same constructor as the base
export abstract class DomainException extends AppException {}
export abstract class ApplicationException extends AppException {}
export abstract class InfrastructureException extends AppException {}

// Domain — reused as-is or subclassed per entity
export class EntityNotFoundException extends DomainException {
  constructor(entity: string, id: string) {
    super('ENTITY_NOT_FOUND', `${entity} ${id} not found`, { entity, id });
  }
}
export class BusinessRuleViolationException extends DomainException {}  // (code, message, details?)
export class InvalidValueException extends DomainException {}           // (code, message, details?)

// Application
export class UnauthorizedException extends ApplicationException {}
export class ForbiddenOperationException extends ApplicationException {}

// Infrastructure
export class DatabaseException extends InfrastructureException {}
export class ExternalServiceException extends InfrastructureException {}
```

There is **one not-found code**: `ENTITY_NOT_FOUND`. A per-entity subclass only fixes the
entity name — it never introduces its own code.

No transport concept (status code, header) in the base class: the domain and application layers
must not know which transport serves them. Some stacks attach the transport status to the class
as a pragmatic shortcut (e.g. `dev-patterns:error-handling`); when they do, it is read only by
the edge handler, never by domain or use case code.

## Domain-specific exceptions

Create them in the domain layer of the corresponding module (or in one shared domain-exceptions
file — see `dev-core:clean-architecture`):

```typescript
// Example patterns — adapt names to your domain
export class OrderNotFoundException extends EntityNotFoundException {
  constructor(id: string) {
    super('Order', id);   // code stays ENTITY_NOT_FOUND
  }
}

export class ResourceExpiredException extends BusinessRuleViolationException {
  constructor() {
    super('RESOURCE_EXPIRED', 'Resource has expired. Renewal required.');
  }
}

export class InsufficientQuantityException extends BusinessRuleViolationException {
  constructor() {
    super('INSUFFICIENT_QUANTITY', 'Quantity cannot go below zero');
  }
}
```

### `OptimisticLockException` — concurrent-edit conflict

The one domain exception every project with Optimistic Locking shares (entity `version`
checked on save — `dev-core:clean-architecture` → `entities.md`, "Optimistic Locking").
Define it **once** in the shared domain exceptions, never per module. The repository throws it
when the conditional update (`WHERE id = ? AND version = ?`) matches zero rows:

```typescript
export class OptimisticLockException extends DomainException {
  constructor(entity: string, id: string, expectedVersion: number) {
    super(
      'OPTIMISTIC_LOCK_CONFLICT',
      `${entity} ${id} was modified by another request (expected version ${expectedVersion}). Reload and retry.`,
    );
  }
}

// Usage (repository): throw new OptimisticLockException('Invoice', invoice.id, invoice.version);
```

## Mapping to the transport — only at the edge

One global error handler in the interface adapter converts any exception into the transport's
error response. For HTTP:

| Exception | HTTP status |
|---|---|
| `EntityNotFoundException` | 404 |
| `BusinessRuleViolationException` | 422 |
| `InvalidValueException` | 400 |
| `UnauthorizedException` | 401 |
| `ForbiddenOperationException` | 403 |
| `OptimisticLockException` | 409 |
| `DatabaseException` | 500 |
| `ExternalServiceException` | 502 |
| validation error (see below) | 400 |
| anything else (unhandled) | 500 |

```typescript
// The edge handler — the only place that knows about status codes
function toErrorResponse(exception: unknown): { status: number; body: ErrorEnvelope } {
  if (exception instanceof AppException) {
    return {
      status: httpStatusFor(exception),      // the table above
      body: { error: { code: exception.code, message: exception.message, details: exception.details ?? [] } },
    };
  }
  // Unknown error: never leak internals to the client
  return {
    status: 500,
    body: { error: { code: 'INTERNAL_ERROR', message: 'An unexpected error occurred.', details: [] } },
  };
}
```

Error tracking (capturing the exception to the error tracker) also happens at the edge, before
the mapping — see `dev-core:logging-observability` (for NestJS also
`dev-patterns:logging-observability`).

## Languages without exceptions (Go, Rust)

The same rule applies with **typed error values** instead of exceptions: the use case
**returns** a domain error that carries the same stable `code`; it never panics for a domain
error (panic is for programmer bugs only). Each layer wraps the error with context without
losing its type, and the edge maps it with the same code → status table as above.

```go
// domain
type DomainError struct{ Code, Message string }
func (e *DomainError) Error() string { return e.Message }
var ErrOrderNotFound = &DomainError{Code: "ENTITY_NOT_FOUND", Message: "order not found"}

// use case — return, wrap with context (%w keeps the chain)
if order == nil { return nil, fmt.Errorf("ship order %s: %w", id, ErrOrderNotFound) }

// edge — unwrap and map by code (errors.Is(err, ErrOrderNotFound) to test one sentinel)
var de *DomainError
if errors.As(err, &de) { writeError(w, httpStatusFor(de.Code), de.Code, de.Message); return }
writeError(w, 500, "INTERNAL_ERROR", "An unexpected error occurred.")   // never leak err
```

In Rust, define the domain errors as an enum (with `thiserror`), propagate with `?` (adding
context via `map_err` or an `#[error(transparent)]`/`#[from]` variant), and map at the edge
with `match` on the variant → the same code and status.

## API error envelope

Every error response has the same shape, whatever the transport framework:

```json
{
  "error": {
    "code": "ENTITY_NOT_FOUND",
    "message": "Order 3f2a… not found",
    "details": []
  }
}
```

An error response never carries `data`.

### Alternative: RFC 9457 Problem Details

If the project prefers a standard format, **RFC 9457 Problem Details**
(`Content-Type: application/problem+json`) is an equally valid error format. Keep the stable
`code` as an extension member, and per-field errors as an extension too:

```json
{
  "type": "https://api.example.com/problems/entity-not-found",
  "title": "Entity not found",
  "status": 404,
  "detail": "Order 3f2a… not found",
  "code": "ENTITY_NOT_FOUND",
  "errors": []
}
```

**Pick one format per API** — the `{ error: { code, message, details } }` envelope or Problem
Details — and use it for every error, validation errors included. Some frameworks emit Problem
Details natively (Spring 6 `ProblemDetail`, ASP.NET Core `AddProblemDetails()`), which makes it
the cheaper choice there. The rest of this skill uses the envelope; the rules (stable `code`,
mapping only at the edge, no internals leaked) apply identically to both.

## API success envelope — a per-project choice

The error envelope above is mandatory. The success envelope is a **project decision**: either
every successful response is wrapped in `{ data: ... }`, or none is and the result is returned
as-is. Both are valid; mixing them is not. Record the choice once (project spec or delta skill)
and apply it to every endpoint, including paginated ones.

If the project wraps:

```json
{ "data": { "id": "...", "status": "confirmed" } }
```

The wrapping happens once, at the edge (a response wrapper / interceptor) — use cases and
controllers return the flat result type and never build `{ data: result }` themselves, which
would double-wrap.

If the project does not wrap: success responses are the result type itself, and clients tell
success from failure by the HTTP status, never by sniffing for an `error` key.

How each response kind appears in each mode (page shapes: `dev-core:api-contracts`):

| Response | Wrapping | Not wrapping |
|---|---|---|
| Single resource | `{ "data": { ... } }` | `{ ... }` |
| Offset page | `{ "data": [ ... ], "meta": { ... } }` — already in envelope shape, passes through untouched | `{ "data": [ ... ], "meta": { ... } }` as-is |
| Cursor page | `{ "data": { "items": [ ... ], "next_cursor": "..." } }` | `{ "items": [ ... ], "next_cursor": "..." }` as-is |
| Delete | `204` with no body, or `200` with `{ "data": { "deleted_id": "..." } }` | `204` with no body, or `200` with `{ "deleted_id": "..." }` |

Never a raw array at the top level, in either mode. For deletes, pick one of the two forms per
project and use it on every delete endpoint.

## Validation errors

Input validation happens at the system boundary (the interface adapter, before the use case
runs) — never in the domain. Its errors are not domain exceptions; the edge maps them to the
same envelope with the code `VALIDATION_ERROR` and one `{ field, message }` item per invalid
field:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Invalid request payload",
    "details": [
      { "field": "email", "message": "must be a valid email" },
      { "field": "name",  "message": "must not be empty" }
    ]
  }
}
```

If the validator's output cannot be read as field errors (misconfiguration), fall back to a
generic detail (`{ field: 'unknown', message: 'Validation failed' }`) rather than a different
shape.

**Override the framework's default validation response.** Most frameworks answer invalid input
with their own built-in shape before your edge handler ever runs, so the API ends up with two
error formats. Replace the default so validation errors come out in the project's format:

- FastAPI — `RequestValidationError` returns `422 { "detail": [...] }` by default; register an
  exception handler for it.
- Spring — `MethodArgumentNotValidException` (and `ConstraintViolationException`); handle them
  in the `@ControllerAdvice`.
- ASP.NET Core — `[ApiController]` returns an automatic ModelState `400`; replace it via
  `ConfigureApiBehaviorOptions(o => o.InvalidModelStateResponseFactory = ...)`.
- Others (Django REST Framework `EXCEPTION_HANDLER`, Go validators, the NestJS
  `ValidationPipe`'s `exceptionFactory`) — same idea: one hook, the project's format.

Cover it with a contract test that sends an invalid payload and asserts the error shape.

## Graceful degradation in non-critical services

Notifications, emails, and push notifications must never bring down the main operation.
The correct mechanism is the **event bus** — not a try/catch around a direct service call.

```typescript
// ✅ CORRECT — use case publishes an event; the bus absorbs subscriber failures internally
async execute(input: ProcessOrderInput): Promise<ProcessOrderOutput> {
  const order = await this.orders.findById(input.orderId);
  if (!order) throw new OrderNotFoundException(input.orderId);

  const confirmed = await this.orders.save(order.confirm());

  // The in-process bus's publish() isolates failures per subscriber internally
  // (in TS: Promise.allSettled). Subscriber failures are logged by the bus and never
  // propagate to the use case.
  // Do NOT wrap in try/catch — it masks wiring/configuration errors (e.g. no event bus bound).
  await this.eventBus.publish(
    new OrderConfirmedEvent(confirmed.id, confirmed.customerId)
  );

  return { orderId: confirmed.id, status: confirmed.status };
}

// ❌ WRONG — direct service call in a use case; bypasses the event bus entirely
async execute(input: ProcessOrderInput) {
  const result = await this.repo.save(...);
  try {
    await this.notificationService.notify(...);  // couples use case to infra service
  } catch (error) {
    logger.warn('Notification failed', { error });
  }
  return result;
}
```

For durable side effects (email, push, external API), the subscriber that receives the event
must enqueue a background job — not execute the call directly. See
`dev-core:domain-events` for the bus and its subscribers (for NestJS + Supabase also
`dev-patterns:domain-events`), and
`dev-core:resilience-patterns` for retries and timeouts.
