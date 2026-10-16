---
name: error-handling
description: >
  NestJS/Fastify implementation layer of dev-core:error-handling — the AppException classes
  with code + statusCode, the global AppExceptionFilter (and its order after the Sentry filter),
  the ResponseInterceptor success envelope, ValidationPipe / class-validator errors mapped to
  the envelope, and HttpException handling. Invoke automatically (together with
  dev-core:error-handling) when implementing or reviewing try/catch, exceptions, exception
  filters, or HTTP error mappings in a NestJS/Fastify backend.
---

# Error Handling — NestJS/Fastify implementation

**Load `dev-core:error-handling` first.** It holds the concepts and rules (fundamental rule,
exception hierarchy with a stable `code`, mapping to the transport only at the edge,
domain-specific exceptions, the error and success envelope contracts, validation errors,
graceful degradation via domain events). This skill only shows how to implement them with
NestJS (Fastify); it does not restate the rules.

## Fundamental rule in this stack

**Use Cases throw domain exceptions. They NEVER throw `HttpException`.**
The mapping to HTTP happens exclusively in the global exception filter (`AppExceptionFilter`,
see [filters.md](filters.md)).

## Exception hierarchy → HTTP status

```
AppException (base)
├── DomainException
│   ├── EntityNotFoundException      → 404
│   ├── BusinessRuleViolationException → 422
│   ├── OptimisticLockException      → 409
│   └── InvalidValueException        → 400
├── ApplicationException
│   ├── UnauthorizedException        → 401
│   └── ForbiddenOperationException  → 403
└── InfrastructureException
    ├── DatabaseException            → 500
    └── ExternalServiceException     → 502
```

## Base structure

Same classes, constructors and codes as `dev-core:error-handling` (one not-found code,
`ENTITY_NOT_FOUND`). The only addition in this stack: the classes carry the HTTP `statusCode`
next to the `code`, and `AppExceptionFilter` reads it. The status is fixed by the class in the
hierarchy, so code that throws uses exactly the dev-core constructors; only the filter reads
`statusCode` — use cases never do.

```typescript
// domain/exceptions/app.exception.ts — the whole hierarchy, defined once
export abstract class AppException extends Error {
  constructor(
    readonly code: string,        // e.g.: 'ENTITY_NOT_FOUND'
    message: string,
    readonly statusCode: number,  // read only by AppExceptionFilter
    readonly details?: unknown,
  ) {
    super(message);
  }
}

export abstract class DomainException extends AppException {}
export abstract class ApplicationException extends AppException {}
export abstract class InfrastructureException extends AppException {}

export class EntityNotFoundException extends DomainException {
  constructor(entity: string, id: string) {
    super('ENTITY_NOT_FOUND', `${entity} ${id} not found`, 404, { entity, id });
  }
}
export class BusinessRuleViolationException extends DomainException {
  constructor(code: string, message: string, details?: unknown) { super(code, message, 422, details); }
}
export class InvalidValueException extends DomainException {
  constructor(code: string, message: string, details?: unknown) { super(code, message, 400, details); }
}
export class UnauthorizedException extends ApplicationException {   // not @nestjs/common's
  constructor(code: string, message: string, details?: unknown) { super(code, message, 401, details); }
}
export class ForbiddenOperationException extends ApplicationException {
  constructor(code: string, message: string, details?: unknown) { super(code, message, 403, details); }
}
export class DatabaseException extends InfrastructureException {
  constructor(code: string, message: string, details?: unknown) { super(code, message, 500, details); }
}
export class ExternalServiceException extends InfrastructureException {
  constructor(code: string, message: string, details?: unknown) { super(code, message, 502, details); }
}
```

## Domain-specific exceptions

Create them in the shared domain-exceptions file (or the module's domain layer —
`dev-core:clean-architecture`):

```typescript
// Example patterns — adapt names to your domain
export class OrderNotFoundException extends EntityNotFoundException {
  constructor(id: string) {
    super('Order', id);   // code stays ENTITY_NOT_FOUND, status 404
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

`OptimisticLockException` (concept and when it is thrown: `dev-core:error-handling`) — defined
once in `domain/exceptions/app.exception.ts`, never per module:

```typescript
export class OptimisticLockException extends DomainException {
  constructor(entity: string, id: string, expectedVersion: number) {
    super(
      'OPTIMISTIC_LOCK_CONFLICT',
      `${entity} ${id} was modified by another request (expected version ${expectedVersion}). Reload and retry.`,
      409,
      { entity, id, expectedVersion },
    );
  }
}
```

## Graceful degradation in this stack

The rule (publish a domain event; never wrap `eventBus.publish` or a direct notification call
in a try/catch inside a use case) is in `dev-core:error-handling`. Here, `InMemoryEventBus.publish()`
is what absorbs subscriber failures — see [filters.md](filters.md) and `dev-patterns:domain-events`
(concept: `dev-core:domain-events`).

## Supporting files

- [filters.md](filters.md) — `ResponseInterceptor` (success envelope), `AppExceptionFilter`
  (global exception filter) and its registration order after `SentryExceptionFilter`,
  `ValidationPipe` `exceptionFactory` + `BadRequestException` mapping to `VALIDATION_ERROR`,
  and the NestJS event-bus version of graceful degradation.
