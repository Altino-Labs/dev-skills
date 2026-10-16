# Logging & Observability — Sentry, Health Check, Metrics, and Environment

> Sub-file of `dev-patterns:logging-observability`. Implementation details for Sentry
> integration, the health check endpoint, Prometheus instrumentation, the metric source of each
> alert threshold, and required environment variables. Rules: `dev-core:logging-observability`.

## Sentry — uncaught errors and performance

```typescript
// infrastructure/observability/sentry.filter.ts
@Catch()
export class SentryExceptionFilter implements ExceptionFilter {
  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const req = ctx.getRequest();

    // Do not report expected domain errors (4xx)
    const isExpectedError = exception instanceof AppException && exception.statusCode < 500;

    if (!isExpectedError) {
      Sentry.withScope((scope) => {
        scope.setTag('correlationId', req.correlationId);
        scope.setUser({ id: req.user?.id });
        scope.setExtra('url', req.url);
        Sentry.captureException(exception);
      });
    }

    // Delegate response to the main exception filter
    throw exception;
  }
}
```

**Rule:** Sentry captures only 5xx errors and unexpected errors.
Domain errors (4xx) are expected behavior — they do not pollute Sentry.

**Registration order in `main.ts` — mandatory:** `SentryExceptionFilter` intercepts, rethrows,
and then the main `HttpExceptionFilter` produces the HTTP response. Reversing the order means
Sentry never sees the exception.

```typescript
// main.ts — order matters
app.useGlobalFilters(
  new SentryExceptionFilter(),   // 1st: captures and rethrows
  new HttpExceptionFilter(),     // 2nd: maps exception → HTTP response envelope
);
```

---

## Health check endpoint

```typescript
// interfaces/http/health/health.controller.ts
@Controller('health')
@Public()
export class HealthController {
  constructor(
    private readonly db: DatabaseHealthIndicator,
    private readonly redis: RedisHealthIndicator,
  ) {}

  @Get()
  async check() {
    return {
      status: 'ok',
      timestamp: new Date().toISOString(),
      checks: {
        database: await this.db.ping(),
        cache:    await this.redis.ping(),
      },
    };
  }
}
```

Railway and Cloudflare use `GET /health` for health checks. A common, valid starting point
is a minimal `/health/live` + `/health/ready` returning `{ status: 'ok' }` with no DB/cache
ping. If the app uses a global prefix (e.g. `/api/v1`), make sure the path configured in
the platform's health check matches the route that actually exists (prefixed via a
`HealthController`, or unprefixed via routes registered directly on the Fastify instance in
`main.ts`) — and don't keep both without recording which one the platform probes.
See also `dev-patterns:railway-nestjs` (live vs ready) and `dev-core:resilience-patterns`
(degraded vs critical dependencies).

---

## Application metrics — instrumentation

Logs and metrics are different things. The `LoggingInterceptor` logs individual events.
Metrics are aggregated values (counters, histograms) that tools like Prometheus can scrape.
Without instrumentation, the alert thresholds below are decorative — there is no data to trigger them.

### Setup — `@willsoto/nestjs-prometheus`

```bash
pnpm add @willsoto/nestjs-prometheus prom-client
```

```typescript
// app.module.ts
import { PrometheusModule } from '@willsoto/nestjs-prometheus';

@Module({
  imports: [
    PrometheusModule.register({
      defaultMetrics: { enabled: true },   // CPU, memory, event loop lag
      path: '/metrics',                    // scraped by Railway / Prometheus
    }),
    // ... other modules
  ],
})
export class AppModule {}
```

`GET /metrics` must be decorated with `@Public()` and excluded from the global auth guard.

Also exclude `/metrics` from the `LoggingInterceptor` — every Prometheus scrape would
otherwise generate a structured log entry, flooding logs with noise. Add an early return
at the top of `intercept()`:

```typescript
intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
  const req = context.switchToHttp().getRequest();
  if (req.url === '/metrics') return next.handle();  // skip logging for scrapes
  // ... existing logging logic
}
```

> **Production access control:** Prometheus metrics reveal internal error codes, route
> latency and throughput — they should not be publicly reachable. Restrict access via
> load balancer IP allowlist, internal VPC rules, or bind the endpoint to a separate
> internal port (e.g. 9090) using a second Fastify instance isolated from the public port.

---

### Mandatory metrics

#### 1. HTTP request latency histogram

Add to the existing `LoggingInterceptor` — alongside the log, record the duration:

```typescript
import { Histogram } from 'prom-client';

@Injectable()
export class LoggingInterceptor implements NestInterceptor {
  private readonly httpLatency = new Histogram({
    name: 'http_request_duration_ms',
    help: 'HTTP request latency in milliseconds',
    labelNames: ['method', 'route', 'status'],
    buckets: [50, 100, 200, 500, 1000, 2000, 5000],
  });

  intercept(context: ExecutionContext, next: CallHandler): Observable<unknown> {
    const req = context.switchToHttp().getRequest();
    const startedAt = Date.now();

    return next.handle().pipe(
      tap(() => {
        const status = context.switchToHttp().getResponse().statusCode;
        this.httpLatency.observe(
          { method: req.method, route: req.route?.path ?? req.url, status },
          Date.now() - startedAt,
        );
        // existing log call remains here
      }),
    );
  }
}
```

#### 2. HTTP error counter

Add to the existing `SentryExceptionFilter` — alongside Sentry capture, increment the counter:

```typescript
import { Counter } from 'prom-client';

@Catch()
export class SentryExceptionFilter implements ExceptionFilter {
  private readonly errorCounter = new Counter({
    name: 'http_errors_total',
    help: 'Total number of HTTP errors',
    labelNames: ['status_code', 'error_code'],
  });

  catch(exception: unknown, host: ArgumentsHost) {
    const isExpectedError = exception instanceof AppException && exception.statusCode < 500;

    if (!isExpectedError) {
      this.errorCounter.inc({
        status_code: exception instanceof AppException ? exception.statusCode : 500,
        error_code:  exception instanceof AppException ? exception.code : 'UNKNOWN',
      });
      // existing Sentry capture call remains here
    }

    throw exception;
  }
}
```

---

### Optional metrics (add per use case when relevant)

```typescript
// Counter — track business events
const ordersProcessed = new Counter({
  name: 'domain_events_published_total',
  help: 'Total domain events published',
  labelNames: ['event_name'],
});

// Gauge — track current state
const activeConnections = new Gauge({
  name: 'db_pool_active_connections',
  help: 'Active database connections',
});
```

---

## Metric source for each alert threshold

Thresholds and rationale: `dev-core:logging-observability` → "What to monitor and alert on".

| Metric | Source | Alert if |
|---|---|---|
| 5xx error rate | `http_errors_total` counter | > 1% of requests |
| P95 latency | `http_request_duration_ms` histogram | > 2000ms |
| Cron job failure | Sentry + log | Any failure |
| Failing event subscriber | Log (warn) | > 3 consecutive failures |
| Memory usage | `process_resident_memory_bytes` (default) | > 80% |
| Open database connections | `db_pool_active_connections` gauge | > 80% of pool |

---

## Required environment variables

```bash
# Add to .env.example
SENTRY_DSN=
LOG_LEVEL=info          # info | debug | verbose
NODE_ENV=               # production | staging | development
```
