# Error Handling — Filters, Envelopes, and Degradation

NestJS/Fastify implementation of `dev-core:error-handling`: the global exception filter, the success envelope interceptor, DTO validation formatting, and graceful degradation via the NestJS Event Bus. The envelope shapes and the rules themselves are in `dev-core:error-handling`.

## ResponseInterceptor — success envelope (only if the project wraps successes)

Whether successes are wrapped is a per-project choice (`dev-core:error-handling` → "API success
envelope"). For projects that wrap, this interceptor wraps every successful response in `{ data: ... }`. `Page<T>` responses (which already carry
`{ data: T[], meta: PageMeta }`) pass through untouched. Register **before** the exception filters.

```typescript
// infrastructure/http/interceptors/response.interceptor.ts
import { Injectable, NestInterceptor, ExecutionContext, CallHandler } from '@nestjs/common';
import { Observable } from 'rxjs';
import { map } from 'rxjs/operators';

@Injectable()
export class ResponseInterceptor implements NestInterceptor {
  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    return next.handle().pipe(
      map(data => {
        // Page<T> detection: total_pages is unique to PageMeta (shared-types) — prevents
        // accidental pass-through of non-paginated responses that happen to carry a meta field.
        if (data && Array.isArray((data as any).data) && typeof (data as any).meta?.total_pages === 'number')
          return data;
        // Single item, cursor page ({ items, next_cursor }) or delete response — wrap in { data }
        return { data };
      }),
    );
  }
}
```

**Registration in `main.ts`:**

```typescript
import { ResponseInterceptor } from './infrastructure/http/interceptors/response.interceptor';

// Inside bootstrap():
app.useGlobalInterceptors(new ResponseInterceptor());   // wraps success in { data }
// SentryExceptionFilter implementation: see dev-patterns:logging-observability → observability.md
app.useGlobalFilters(
  new SentryExceptionFilter(),                          // 1st — capture and rethrow
  new AppExceptionFilter(),                             // 2nd — map AppException → { error }
);
```

**Why the order matters:** `ResponseInterceptor` wraps only successful responses; exceptions bypass
it entirely and reach `AppExceptionFilter` directly. Reversing filters and interceptors has no effect
on this flow, but `SentryExceptionFilter` must always precede `AppExceptionFilter`.

**Controller return types are unchanged:** `execute()` returns `OrderResponse` (the flat type from
`@your-app/shared-types`). The interceptor adds the `{ data }` wrapper invisibly. Never change a
Use Case or controller to return `{ data: result }` manually — that would double-wrap.

---

## AppExceptionFilter — global exception filter (required in every project)

This filter converts any `AppException` (and unhandled errors) into the standard envelope.
Register it in `main.ts` alongside `SentryExceptionFilter` — order matters.

```typescript
// infrastructure/http/filters/app-exception.filter.ts
import { ExceptionFilter, Catch, ArgumentsHost } from '@nestjs/common';
import { AppException } from '../../domain/exceptions/app.exception';

@Catch()
export class AppExceptionFilter implements ExceptionFilter {
  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx    = host.switchToHttp();
    const res    = ctx.getResponse();
    const status = exception instanceof AppException ? exception.statusCode : 500;
    const code   = exception instanceof AppException ? exception.code    : 'INTERNAL_ERROR';
    const msg    = exception instanceof AppException ? exception.message  : 'An unexpected error occurred.';
    const detail = exception instanceof AppException ? (exception.details ?? []) : [];

    res.status(status).send({
      error: { code, message: msg, details: detail },
    });
  }
}
```

**Registration in `main.ts` — order is mandatory:**

```typescript
// SentryExceptionFilter must come FIRST: it intercepts, captures to Sentry, then rethrows.
// AppExceptionFilter comes SECOND: it maps the rethrown exception to the HTTP response.
// Reversing the order means Sentry never sees the exception.
app.useGlobalFilters(
  new SentryExceptionFilter(),   // 1st — capture and rethrow (see dev-patterns:logging-observability)
  new AppExceptionFilter(),      // 2nd — map AppException → { error: { code, message, details } }
);
```

**DTO validation errors** — `ValidationPipe` throws `BadRequestException` (not an `AppException`).
To keep the response shape consistent and produce `{ field, message }` detail items, configure
`ValidationPipe` with `exceptionFactory` in `main.ts` **before** registering the filter:

```typescript
// main.ts — configure BEFORE useGlobalFilters
app.useGlobalPipes(new ValidationPipe({
  whitelist:              true,
  transform:              true,
  enableImplicitConversion: true,
  exceptionFactory: (errors) => new BadRequestException(
    errors.map(e => ({
      field:   e.property,
      message: Object.values(e.constraints ?? {})[0] ?? 'Invalid value',
    }))
  ),
}));
```

The filter then reads the structured array directly — `exception.getResponse()` returns
`Array<{ field: string; message: string }>` when `exceptionFactory` is in place:

```typescript
import { BadRequestException } from '@nestjs/common';

@Catch()
export class AppExceptionFilter implements ExceptionFilter {
  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const res = ctx.getResponse();

    if (exception instanceof BadRequestException) {
      const raw     = exception.getResponse();
      // exceptionFactory produces Array<{ field, message }> directly as the response body.
      // Fall back to a generic detail if the pipe is misconfigured (missing exceptionFactory).
      const details = Array.isArray(raw)
        ? raw
        : [{ field: 'unknown', message: typeof raw === 'string' ? raw : 'Validation failed' }];

      return res.status(400).send({
        error: { code: 'VALIDATION_ERROR', message: 'Invalid request payload', details },
      });
    }

    const status = exception instanceof AppException ? exception.statusCode : 500;
    const code   = exception instanceof AppException ? exception.code    : 'INTERNAL_ERROR';
    const msg    = exception instanceof AppException ? exception.message  : 'An unexpected error occurred.';
    const detail = exception instanceof AppException ? (exception.details ?? []) : [];

    res.status(status).send({
      error: { code, message: msg, details: detail },
    });
  }
}
```

---

## Envelope shapes

The error envelope (`{ error: { code, message, details } }`) and the `VALIDATION_ERROR` shape
with `{ field, message }` details are defined in `dev-core:error-handling` — the filter above
produces exactly those.

---

## Graceful degradation in non-critical services

Notifications, emails, and push notifications must never bring down the main operation.
The correct mechanism is the **Event Bus** — not a try/catch around a direct service call (the
wrong pattern and the rule are in `dev-core:error-handling`).

```typescript
// ✅ CORRECT — Use Case publishes an event; the bus absorbs subscriber failures internally
async execute(input: ProcessOrderInput): Promise<ProcessOrderOutput> {
  const order = await this.orders.findById(input.order_id);
  if (!order) throw new OrderNotFoundException(input.order_id);

  const confirmed = await this.orders.save(order.confirm());

  // InMemoryEventBus.publish() uses Promise.allSettled internally.
  // Subscriber failures are logged by the bus and never propagate to the Use Case.
  // Do NOT wrap in try/catch — it masks DI configuration errors (missing EVENT_BUS provider).
  await this.eventBus.publish(
    new OrderConfirmedEvent(confirmed.id, confirmed.customerId)
  );

  return { order_id: confirmed.id, status: confirmed.status };
}
```

For durable side effects (email, push, external API), the subscriber that receives
the event must enqueue a BullMQ job — not execute the call directly.
See `dev-core:domain-events` — "Graceful degradation — subscriber failure never brings down
the use case" and its `subscribers.md`; for NestJS + Supabase also `dev-patterns:domain-events`
([event-bus-impl.md](../domain-events/event-bus-impl.md),
[subscribers-nestjs.md](../domain-events/subscribers-nestjs.md)).
