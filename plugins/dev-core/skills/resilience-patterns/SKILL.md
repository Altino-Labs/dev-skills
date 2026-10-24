---
name: resilience-patterns
description: >
  Reusable resilience patterns: circuit breaker, retry with backoff,
  timeouts, graceful degradation, policy by external service type, and scheduled jobs
  (in-process cron vs an OIDC-authenticated external tick with leases and dead-man alerts).
  Invoke automatically when integrating external services (email, push, third-party APIs),
  when implementing calls that can fail temporarily, when configuring timeouts, or when
  scheduling recurring jobs.
---

# Resilience Patterns

## Core principle

Non-critical services (notifications, email, cache) must **never** bring down
the main operation. The user cannot lose a critical action (e.g. order confirmation)
because the push service was down.

The patterns are language-neutral. **Code examples below are TypeScript/Node** (e.g. `opossum`
for the circuit breaker); on another stack use its equivalent library (e.g. resilience4j for
Java/Kotlin, Polly for .NET, tenacity for Python) — the thresholds and the policy table still apply.

---

## Circuit Breaker

Prevents failure cascades when an external service is degraded.

```typescript
// infrastructure/resilience/circuit-breaker.ts
import CircuitBreaker from 'opossum';

export function createCircuitBreaker<T>(
  fn: (...args: any[]) => Promise<T>,
  options?: Partial<CircuitBreakerOptions>,
) {
  const breaker = new CircuitBreaker(fn, {
    timeout: 3000,                   // fails if it takes more than 3s
    errorThresholdPercentage: 50,    // opens if 50% of calls fail
    resetTimeout: 30000,             // tries to close after 30s
    ...options,
  });

  breaker.on('open',     () => logger.warn('Circuit breaker OPEN',     { fn: fn.name }));
  breaker.on('halfOpen', () => logger.info('Circuit breaker HALF-OPEN', { fn: fn.name }));
  breaker.on('close',    () => logger.info('Circuit breaker CLOSED',    { fn: fn.name }));

  return breaker;
}

// Usage
const sendPushBreaker = createCircuitBreaker(pushService.send.bind(pushService));
await sendPushBreaker.fire(payload);
```

---

## Retry with exponential backoff

For calls to external services that can fail temporarily.

**Retry only idempotent operations — or send an idempotency key.** A timeout does not mean the
call failed: the provider may have sent the email or written the row before the response was
lost, and a retry then duplicates it. Retry a non-idempotent call only when the provider
deduplicates by an idempotency key you send (the same key on every attempt). Never retry
non-idempotent database writes blindly, and don't retry database writes in the request path at
all — fail fast and let the client (or a background job) retry the whole operation. Retry only
errors that can succeed on a second try (timeouts, connection resets, 429, 5xx) — never
validation errors, 4xx or business-rule violations: that is what `isRetryable` is for.

```typescript
// infrastructure/resilience/retry.ts
export async function withRetry<T>(
  fn: () => Promise<T>,
  options: {
    maxAttempts: number;
    baseDelayMs: number;
    label?: string;
    isRetryable?: (error: unknown) => boolean;   // default: retry every error
  },
): Promise<T> {
  let lastError: Error;

  for (let attempt = 1; attempt <= options.maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;
      if (attempt === options.maxAttempts) break;
      if (options.isRetryable && !options.isRetryable(error)) break;   // permanent error — stop now

      const delay = options.baseDelayMs * Math.pow(2, attempt - 1);
      const jitter = Math.random() * 200;  // avoids thundering herd

      logger.warn(`Retry ${attempt}/${options.maxAttempts}`, {
        label: options.label,
        error: lastError.message,
        nextRetryMs: delay + jitter,
      });

      await sleep(delay + jitter);
    }
  }

  throw lastError!;
}

// Usage — the same idempotency key on every attempt, so the provider sends the email once
const idempotencyKey = `order-confirmed:${orderId}`;
const result = await withRetry(
  () => emailService.send(payload, { idempotencyKey }),
  {
    maxAttempts: 3,
    baseDelayMs: 500,
    label: 'email.send',
    isRetryable: (e) => isTimeout(e) || isNetworkError(e) || [429, 500, 502, 503, 504].includes(statusOf(e)),
  },
);
```

**Request-path budget.** The total time of every attempt plus backoff must fit inside the
request's own timeout (and the client's). `3 attempts × 5s timeout + 5s/10s backoff` is ~30s —
far past any reasonable request budget. In the request path use one or two short attempts (or
none); longer retry schedules belong in background jobs.

---

## Graceful degradation

When a non-critical service fails, the main operation continues.

```typescript
// Pattern for non-critical services in Use Cases
async execute(input: ConfirmOrderInput) {
  // 1. Main operation — must always work
  const confirmation = await this.confirmationRepo.save(...);
  await this.orderRepo.update(...);

  // 2. Non-critical services — publish a domain event; the bus isolates and logs failures
  //    per subscriber (in TS: Promise.allSettled). Do NOT wrap publish in try/catch — it
  //    masks wiring/configuration errors (e.g. no event bus bound). See dev-core:error-handling.
  await this.eventBus.publish(new OrderConfirmedEvent(...));

  return confirmation;
}
```

---

## Timeouts by operation type

```typescript
export const TIMEOUTS_MS = {
  database:          5_000,   // 5s  — database queries
  externalApi:       10_000,  // 10s — third-party APIs
  fileUpload:        30_000,  // 30s — file uploads
  pdfGeneration:     60_000,  // 60s — PDF generation
  pushNotification:  5_000,   // 5s  — push notifications
  email:             10_000,  // 10s — email sending
  cache:             1_000,   // 1s  — cache operations
} as const;   // TS: a read-only constants object — elsewhere a config class, enum or constants block
```

---

## Resilience policy by service type

| Service | Circuit Breaker | Retry | Timeout | Fallback |
|---|---|---|---|---|
| Primary database | No (managed) | Reads / idempotent ops only (2x, 100ms base, within the request budget); never blind retries of writes in the request path | 5s | 503 error |
| Cache (Redis) | Yes | Yes (2x, 200ms base) | 1s | Operate without cache |
| Email | Yes | Yes (3x, 2s base) — with an idempotency key, outside the request path (a retry after a timeout can send twice) | 10s | Log + retry job |
| Push notification | Yes | Yes (3x, 1s base) | 5s | Log + retry job |
| Storage (upload) | No | Yes (2x, 1s base) | 30s | Error to user |
| Error tracking (e.g. Sentry) | No | No | 2s | Silent failure |
| PDF (generation) | No | Yes (2x, 5s base) | 60s | FAILED status on job |

**This table is the reference policy to build toward, not a claim that every row is
already live in a given project.** Record the project's real, audited status per row in
the project's own delta skill (e.g. `<project>-resilience-patterns`) and keep it dated —
stale "not implemented yet" notes are a recurring source of wrong decisions.

Lessons that commonly justify deviating from the table (document the deviation, don't
leave it implicit):
- **Circuit breaker is not worth it at low volume.** Its value (avoiding cascading
  overload from repeated retries against a degraded dependency) only shows up with real
  traffic. Retry + timeout first; add the breaker when volume/failure rate justifies it.
- **"Log + retry job" may honestly be just "Log"** if the project decided not to run a
  persistent queue (for TypeScript projects: `dev-patterns:jobs-queues`). Say so explicitly instead of implying a retry
  queue exists.
- **A cron can replace immediate retry.** For a scheduled sender (e.g. reminders) that
  only marks an item as sent *after* a successful send, a failed send is naturally
  picked up again on the next tick — self-healing at the cron's cadence. That reasoning
  is specific to that pipeline; don't assume it extends to event-driven sends (e.g. an
  "invite accepted" push) without checking.
- **A timeout longer than the table's target** (e.g. 20s instead of 5s for push) is
  acceptable as a deliberate decision — mark it as such so nobody "fixes" it as a typo.

---

## Scheduled jobs — in-process cron vs an external tick

An in-process scheduler (a cron library inside the API) only fires while an instance is
running, and fires once **per instance**. On a host that scales to zero (Cloud Run, serverless
functions, Fly machines that stop) jobs silently stop; with several replicas they run N times.
There, drive the jobs from an **external tick** instead:

- **One tick endpoint** (e.g. `POST /internal/cron/tick`), called every minute by the platform
  scheduler (Cloud Scheduler, EventBridge Scheduler, a platform cron). It asks "which jobs are
  due this minute?" and runs them, isolated per job (one failing job doesn't stop the others).
  Not one public endpoint per job.
- **Authenticate the caller with the platform's OIDC identity token**, not a shared secret:
  verify signature, `aud` (the service URL) and the caller's service-account identity (a
  dedicated account with no other roles). Nothing to rotate or leak. Exempt only this exact
  route from other edge checks, since it has its own authentication.
- **One schedule registry** — a single table in code of job → cron expression, time zone
  (when a daily job must run at a local hour) and stale-lease threshold. The in-process
  decorators (if kept) and the tick both read it, so they can't drift; a typed map makes the
  compiler reject a job without an entry.
- **A run log with leases:** each run inserts a `RUNNING` row (the lease) and closes it with
  `SUCCESS`/`ERROR` and a result. A second start while a fresh lease exists is skipped (an
  expected overlap, not an alert); a lease older than the job's threshold (scaled to its
  cadence — minutes for an every-minute job, not a fixed half hour) is **taken over as
  orphaned** (the instance died mid-run). Prune old rows with a job of its own.
- **Alert on both failure modes:** a job failed (a distinctive log line or metric → alert,
  rate-limited), **and** no tick arrived for N minutes (a dead-man switch on the tick's own
  log/metric) — a scheduler that stopped calling produces no errors at all. After each deploy,
  wait for the new revision to log a tick before calling the deploy healthy.
- **Never both firing at once.** One mode switch (e.g. `CRON_MODE=in-process | external`)
  turns the in-process scheduler off when the external tick is on. The rollback runbook flips
  the switch **and** pauses the external scheduler job in the same step; otherwise a rollback
  double-runs every job (the leases reduce, but don't remove, the damage for non-idempotent
  jobs).
- Validate the mode's config at startup (`external` without the expected audience/caller →
  refuse to start), and keep a manual "run now" path that records its own run.


---

## Isolate failures per task in parallel operations

When notifying N recipients (or running any N independent tasks) — failure on one must not
cancel or hide the others. Run them all, collect each outcome, log the failures.

| Language | Isolating form | ❌ Fail-fast form (the anti-pattern here) |
|---|---|---|
| TypeScript/JS | `Promise.allSettled` | `Promise.all` |
| Python | `asyncio.gather(..., return_exceptions=True)` | `asyncio.gather(...)` without `return_exceptions=True`; a `TaskGroup` (cancels siblings on first error) |
| Go | `sync.WaitGroup` with per-goroutine error capture (each goroutine records its own error) | `errgroup.Group` / `errgroup.WithContext` (returns the first error; with a context it cancels the rest) |
| Java | `CompletableFuture.allOf` over futures that each `.handle(...)` their own failure | `allOf(...).join()` over futures that throw (fails on the first exception; a fail-on-first structured-concurrency scope cancels the rest) |
| C# | `Task.WhenAll` over tasks that each catch and return a result | `await Task.WhenAll(...)` on tasks that throw (only the first exception surfaces) |

```typescript
// ✅ Correct — all try, failures are collected
const results = await Promise.allSettled(
  members.map(m => pushService.send({ token: m.pushToken, ...payload }))
);

// Log failures without propagating
results
  .filter(r => r.status === 'rejected')
  .forEach(r => logger.warn('Push failed', { reason: (r as PromiseRejectedResult).reason }));

// ❌ Wrong — the first failure rejects the whole call; the other outcomes are lost
await Promise.all(
  members.map(m => pushService.send({ token: m.pushToken, ...payload }))
);
```

---

## Health check with dependency verification

Liveness vs readiness and what a health check must not do: `dev-core:logging-observability`.

Framework-free example — a handler that returns a status code and a body; wire it to the
framework's route for `/health/ready`. The rule (ready = critical dependencies OK; degraded
optional ones don't fail readiness) applies to any framework.

```typescript
async function ready(): Promise<{ status: number; body: unknown }> {
  // Check every dependency, isolated per task, each with a short timeout
  const [dbOk, cacheOk] = await Promise.allSettled([
    this.db.ping(),
    this.redis.ping(),
  ]);

  const status = {
    database: dbOk.status === 'fulfilled' ? 'ok' : 'degraded',
    cache:    cacheOk.status === 'fulfilled' ? 'ok' : 'degraded',
  };

  // API is 'ready' even with degraded cache — only database is critical
  const httpStatus = status.database === 'ok' ? 200 : 503;

  return { status: httpStatus, body: { status, timestamp: new Date().toISOString() } };
}
```
