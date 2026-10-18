---
name: logging-observability
description: >
  NestJS/Fastify implementation layer of dev-core:logging-observability — NestJS's built-in
  Logger (no custom ILogger abstraction) and how to test it, log levels via NestFactory, the
  CorrelationIdMiddleware + LoggingInterceptor, Nest's default colorized text vs a JSON
  transport, the SentryExceptionFilter and its registration order, the health controller,
  Prometheus metrics with @willsoto/nestjs-prometheus, and the env vars. Invoke automatically
  (together with dev-core:logging-observability) when implementing logging at any layer,
  interceptors, request middlewares, uncaught error handling, or Sentry integration in a
  NestJS/Fastify backend — and, for the clients, Sentry in Next.js (`@sentry/nextjs`) and Expo
  (`@sentry/react-native`).
---

# Logging & Observability — NestJS/Fastify implementation

**Load `dev-core:logging-observability` first.** It holds the concepts and rules (what to log
at each layer and what never to log, log levels by environment, correlation ID and when it
pays off, structured format, error tracking only for 5xx/unexpected errors, liveness vs
readiness, metrics and alert thresholds, required configuration). This skill only shows how
to implement them with NestJS (Fastify); it does not restate the rules.

## Core principle — use NestJS's built-in `Logger`, not a custom abstraction

Do **not** introduce an injected `ILogger` domain interface by default. Every class that
needs to log instantiates NestJS's own `Logger` directly, scoped to the class name as context:

```typescript
import { Injectable, Logger } from '@nestjs/common';

@Injectable()
export class SomeUseCase {
  private readonly logger = new Logger(SomeUseCase.name);

  async execute(...) {
    try {
      // ...
    } catch (err) {
      this.logger.error(`operation failed: ${(err as Error).message}`);
      throw ...;
    }
  }
}
```

- `.log()` for normal operational events, `.warn()` for recoverable/degraded situations,
  `.error()` for failures that were caught and handled (or are about to be rethrown).
- One `private readonly logger` per class — never a shared/static instance across classes,
  and never a bare module-level `console.log`/`console.warn`/`console.error` call. The one
  exception is `main.ts`, which has no class to scope a logger to — use a single
  module-level `const logger = new Logger('Bootstrap')` there instead.

**Why not an `ILogger` interface + DI symbol, the "textbook" Clean Architecture approach?**
It rarely pays off — a typical app has one runtime
(NestJS/Fastify on Railway), no plan to swap logging backends, and the abstraction adds a
constructor param and a test double to every class for no behavioral gain over calling
`new Logger(ClassName.name)` directly. If a project genuinely needs to swap logging
implementations (multi-runtime, library code, etc.), reintroduce the interface then — don't
carry it as unused ceremony.

**Testing:** spy on `Logger.prototype` rather than mocking an injected dependency:

```typescript
import { Logger } from '@nestjs/common';

const errorSpy = jest.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
// ... exercise the code path that should log ...
expect(errorSpy).toHaveBeenCalled();
errorSpy.mockRestore();
```

A concrete case of an SDK that resolves with `{ error }` instead of throwing (so the catch
block never runs): the Resend SDK — see `dev-patterns:resend-email`.

---

## Log levels

```typescript
const LOG_LEVELS = {
  production:  ['log', 'warn', 'error'],
  staging:     ['log', 'warn', 'error', 'debug'],
  development: ['log', 'warn', 'error', 'debug', 'verbose'],
};
```

Pass this to `NestFactory.create(AppModule, { logger: LOG_LEVELS[env] })` to silence
`.debug()`/`.verbose()` output outside development — the built-in `Logger` respects
whichever levels the app was bootstrapped with.

---

## Correlation ID / logging interceptor

When the core skill's "evaluate before adding" says yes, prefer this over reintroducing an
`ILogger` interface — the interceptor wraps the built-in `Logger` directly:

```typescript
// infrastructure/http/middleware/correlation-id.middleware.ts
@Injectable()
export class CorrelationIdMiddleware implements NestMiddleware {
  use(req: Request, res: Response, next: NextFunction) {
    const correlationId = req.headers['x-correlation-id'] as string ?? randomUUID();
    req['correlationId'] = correlationId;
    res.setHeader('x-correlation-id', correlationId);
    next();
  }
}
```

```typescript
// infrastructure/http/interceptors/logging.interceptor.ts
@Injectable()
export class LoggingInterceptor implements NestInterceptor {
  private readonly logger = new Logger('HTTP');

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const req = context.switchToHttp().getRequest();
    const { method, url, correlationId } = req;
    const startedAt = Date.now();

    return next.handle().pipe(
      tap(() => {
        this.logger.log(
          `${method} ${url} ${context.switchToHttp().getResponse().statusCode} +${Date.now() - startedAt}ms [${correlationId}]`,
        );
      }),
      catchError((error) => {
        this.logger.error(
          `${method} ${url} failed +${Date.now() - startedAt}ms [${correlationId}]: ${error.message}`,
        );
        throw error;
      }),
    );
  }
}
```

The metrics histogram and the `/metrics` early return are added to this same interceptor —
see [observability.md](observability.md).

---

## Log format — NestJS's default is colorized text, not JSON

Out of the box, `new Logger(...)` writes NestJS's standard colorized console text
(`[Nest] 12345 - <timestamp> LOG [ClassName] message`), **not** structured JSON. That's
sufficient for `pnpm start:dev` and reading Railway's log viewer directly. The JSON shape in
`dev-core:logging-observability` only exists if a JSON-emitting transport is deliberately
configured as the Nest logger — it is not free just because messages are written through
`Logger`. If/when log volume justifies a log-aggregation tool (Datadog, Axiom, Railway's own
search), that's the point to add one.

---

## Sentry, health check, metrics, env vars

All in [observability.md](observability.md):

- `SentryExceptionFilter` (captures only 5xx/unexpected, tags correlation ID and user) and
  its **mandatory registration order** before the main exception filter (see also
  `dev-patterns:error-handling` → `filters.md`). Check that the project actually registered
  the filter and set `SENTRY_DSN` before assuming anything is captured.
- The `HealthController` (`@Public()`), the live/ready routes and the global-prefix caveat
  for Railway/Cloudflare probes (see also `dev-patterns:railway-nestjs`).
- Prometheus with `@willsoto/nestjs-prometheus` + `prom-client`: the latency histogram, the
  error counter, optional counters/gauges, and the metric source for each alert threshold.
- `SENTRY_DSN`, `LOG_LEVEL`, `NODE_ENV`.

## Sentry in the clients — Next.js and Expo

Applies `dev-core:logging-observability` → "Error tracking in client apps".

- **Public env vars are inlined only when spelled out.** Next replaces
  `process.env.NEXT_PUBLIC_X` and Expo replaces `process.env.EXPO_PUBLIC_X` at build time, *only*
  at that literal spelling. `const env = process.env; env.NEXT_PUBLIC_SENTRY_DSN` is `undefined`
  in the browser/app — Sentry ships switched off, while Jest (real `process.env`) and the Next
  middleware (real server env) both look fine. Read each variable literally; a small spec that
  reads the options file's source and asserts `process.env.<NAME>` appears for every public name
  it uses guards it. Confirm by building with a sample DSN and grepping the client chunks / the
  exported bundle for its host.
- **`@sentry/nextjs` 11 (core v11): `sendDefaultPii` is gone, replaced by `dataCollection`.**
  Unset, it collects user info (session envelopes carry `ip_address: "{{auto}}"`), cookies,
  headers, bodies and query strings. Set every category, same baseline as the backend:

  ```typescript
  dataCollection: {
    userInfo: false,
    cookies: false,
    httpHeaders: {
      request: { deny: ['forwarded', '-ip', 'remote-', 'via', '-user'] },
      response: { deny: ['forwarded', '-ip', 'remote-', 'via', '-user'] },
    },
    httpBodies: [],
    urlQueryParams: false,
    genAI: { inputs: false, outputs: false },
    databaseQueryData: false,
    queues: false,
    graphQL: { document: false, variables: false },
  },
  ```

  `@sentry/react-native` 7.x still sits on core v10, where `sendDefaultPii` exists (default
  `false`) — revisit on its v11 upgrade.
- **Type the options:** `type SentryInitOptions = NonNullable<Parameters<typeof Sentry.init>[0]>`
  and declare the object as that type, so a dropped option is a compile error.
- **Next.js wiring without the wizard:** `src/instrumentation-client.ts` (`Sentry.init`) and
  `src/instrumentation.ts` (`register()` + `export const onRequestError =
  Sentry.captureRequestError`). With a nonce CSP, add the DSN's ingest origin to `connect-src`
  (`new URL(dsn).origin` drops the key). Public-prefixed variables can't be "Secret" on Vercel —
  use the Config type.
- **Expo without the config plugin:** the native SDK autolinks; `@sentry/react-native/expo` (and
  `@sentry/cli`'s install script) only matter for source-map upload, and the plugin fails the
  EAS build without a Sentry auth token. Older builds that receive the JS over the air keep
  working without the native module (JS errors only).
- **Verifying from the browser:** a `429` with `x-sentry-rate-limits: …:organization:
  error_usage_exceeded` means the organization's error quota is spent — every project's errors
  are dropped, the SDK backs off ~60 s, and session envelopes still return 200, which looks like
  "it works". Check Stats & Usage before debugging the code. Custom per-key rate limits are a
  Business-plan feature.

