---
name: jobs-queues
description: >
  Async jobs and queue patterns with BullMQ + Upstash Redis, and scheduled jobs with
  @nestjs/schedule (schedule registry, in-process cron disabled when an external tick drives
  the jobs). Invoke automatically when implementing tasks that must not block the HTTP
  response: PDF generation, email sending, report processing, exports, or any
  long-running operation triggered by an event — or when adding a scheduled job.
---

# Jobs & Queues

## When to use queue vs cron vs direct call

| Situation | Mechanism |
|---|---|
| Periodic task (check overdue items at 00:00) | Cron — see "Scheduled jobs" below (`notifications-cron` for reminders) |
| Event-triggered task, takes >500ms (generate PDF) | **Job queue** |
| Fast event-triggered task (<500ms) | Direct Event Bus |
| Task that can fail and needs retry | **Job queue** |

---

## Implementation with BullMQ + Upstash Redis

```typescript
// infrastructure/jobs/queues.ts
export const QUEUES = {
  REPORTS:       'reports',
  EMAILS:        'emails',
  NOTIFICATIONS: 'notifications',
} as const;

export const JOBS = {
  GENERATE_REPORT:  'generate-report',
  SEND_EMAIL:       'send-email',
  SEND_PUSH:        'send-push-batch',
} as const;
```

---

## IJobQueue interface (domain depends only on this)

```typescript
// domain/services/i-job-queue.ts
export const JOB_QUEUE = Symbol('JOB_QUEUE');

export interface IJobQueue {
  add<T>(queueName: string, jobName: string, data: T, options?: JobOptions): Promise<void>;
}

export interface JobOptions {
  delay?: number;       // ms before executing
  attempts?: number;    // attempts on failure (default: 3)
  backoff?: number;     // ms between attempts (exponential)
  priority?: number;    // 1 = highest
}
```

---

## Enqueuing a job in a Use Case

```typescript
// application/use-cases/report/request-report.use-case.ts
export class RequestReportUseCase {
  constructor(
    private readonly reportRepo: IReportRepository,
    private readonly jobQueue: IJobQueue,
  ) {}

  async execute(input: RequestReportInput): Promise<RequestReportOutput> {
    // 1. Create report record with PENDING status
    const report = Report.create({
      requestedBy: input.requestedBy,
      type: input.type,
      status: 'PENDING',
    });
    await this.reportRepo.save(report);

    // 2. Enqueue generation — does not block the response
    await this.jobQueue.add(
      QUEUES.REPORTS,
      JOBS.GENERATE_REPORT,
      { reportId: report.id },
      { attempts: 3, backoff: 5000 },
    );

    return { reportId: report.id, status: 'PENDING' };
  }
}
```

---

## Implementing a processor (worker)

```typescript
// infrastructure/jobs/processors/generate-report.processor.ts
@Processor(QUEUES.REPORTS)
export class GenerateReportProcessor {
  private readonly logger = new Logger(GenerateReportProcessor.name);

  constructor(
    private readonly reportRepo: IReportRepository,
    private readonly pdfService: IPdfService,
    private readonly storageService: IStorageService,
    private readonly eventBus: IEventBus,
  ) {}

  @Process(JOBS.GENERATE_REPORT)
  async handle(job: Job<{ reportId: string }>): Promise<void> {
    const { reportId } = job.data;
    this.logger.log(`Generating report reportId=${reportId} attempt=${job.attemptsMade}`);

    const report = await this.reportRepo.findById(reportId);
    if (!report) throw new Error(`Report ${reportId} not found`);

    try {
      await this.reportRepo.updateStatus(reportId, 'PROCESSING');

      const pdf = await this.pdfService.generate(report);
      const url = await this.storageService.upload(`reports/${reportId}.pdf`, pdf);

      await this.reportRepo.markCompleted(reportId, url);
      await this.eventBus.publish(new ReportGeneratedEvent(reportId, url));

    } catch (error) {
      await this.reportRepo.updateStatus(reportId, 'FAILED');
      this.logger.error(`Report generation failed reportId=${reportId}: ${(error as Error).message}`);
      throw error; // BullMQ retries automatically
    }
  }
}
```

---

## Retry configuration per queue

```typescript
export const QUEUE_CONFIGS = {
  [QUEUES.REPORTS]: {
    attempts: 3,
    backoff: { type: 'exponential', delay: 5000 },
    removeOnComplete: 100,  // keep last 100 completed jobs
    removeOnFail: 500,      // keep last 500 failed jobs for debugging
  },
  [QUEUES.EMAILS]: {
    attempts: 5,
    backoff: { type: 'exponential', delay: 2000 },
    removeOnComplete: 50,
    removeOnFail: 200,
  },
  [QUEUES.NOTIFICATIONS]: {
    attempts: 3,
    backoff: { type: 'fixed', delay: 3000 },
    removeOnComplete: 50,
    removeOnFail: 100,
  },
};
```

---

## Scheduled jobs — `@nestjs/schedule` and the external tick

The concept (why an external tick on scale-to-zero hosts, OIDC instead of a shared secret,
run-log leases, missing-tick alert, never both modes at once): `dev-core:resilience-patterns`
→ "Scheduled jobs". The NestJS side:

```typescript
// shared/scheduling/cron-schedules.ts — the ONLY place a schedule is written
export type CronJobName = 'send-reminders' | 'expire-reports' | 'prune-cron-runs';

export interface CronSchedule {
  readonly expression: string;        // 5-field cron
  readonly timeZone?: string;         // IANA; absent = server zone (UTC on most hosts)
  readonly staleAfterMinutes: number; // a RUNNING lease older than this is taken over
}

export const CRON_SCHEDULES: Readonly<Record<CronJobName, CronSchedule>> = {
  'send-reminders':  { expression: '*/5 * * * *', staleAfterMinutes: 10 },
  'expire-reports':  { expression: '0 3 * * *', timeZone: 'Europe/Lisbon', staleAfterMinutes: 30 },
  'prune-cron-runs': { expression: '0 4 * * *', timeZone: 'Europe/Lisbon', staleAfterMinutes: 30 },
};

// scheduler/cron-config.ts — read before DI exists, so the module definition can use it
export const inProcessCronEnabled = (env = process.env) => env.CRON_MODE?.trim() !== 'external';

// scheduler/scheduler.module.ts — in 'external' mode no @Cron fires in this process
@Module({
  imports: [ScheduleModule.forRoot({ cronJobs: inProcessCronEnabled() })],
  controllers: [CronTickController],
  providers: [/* jobs, RunDueCronJobsUseCase, CronOidcGuard, ... */],
})
export class SchedulerModule {}

// each job keeps its decorator, fed by the registry (fires only in 'in-process' mode)
@Cron(CRON_SCHEDULES['send-reminders'].expression, { name: 'send-reminders' })
async onCron(): Promise<void> { await this.run(); }   // run() takes the lease, never throws
```

- `ScheduleModule.forRoot({ cronJobs: false })` keeps the `@Cron` decorators from starting
  (check the option exists in your `@nestjs/schedule` version); the tick then calls the same
  `run()` methods for the jobs due that minute (evaluate each expression in its `timeZone`
  against the tick's time).
- The tick controller is `@Public()` for the user `JwtAuthGuard` and protected by its own guard
  that verifies the scheduler's OIDC token — for Google Cloud Scheduler, `google-auth-library`
  `verifyIdToken({ idToken, audience })`, then require `email` = the invoker service account
  and `email_verified`.
- Validate the env at startup: `CRON_MODE` other than `in-process`/`external`, or `external`
  without the audience and invoker account → throw, so a misconfigured revision never serves.
- Wrap each job's body in one shared helper (take lease → run → record `SUCCESS`/`ERROR` →
  return `ran | skipped_locked | failed`) instead of copying the try/catch into every job.

---

## Project job catalog

Define the job catalog in the project spec (e.g. `PROJECT.md`). Example structure:

| Job | Queue | Triggered by | Timeout | Attempts |
|---|---|---|---|---|
| `generate-report` | `reports` | `ReportRequestedEvent` | 60s | 3 |
| `send-email` | `emails` | `UserInvitedEvent`, `ReportGeneratedEvent` | 10s | 5 |
| `send-push-batch` | `notifications` | `AlertTriggeredEvent` | 15s | 3 |

---

## Job states

```
waiting → active → completed
                 ↘ failed → (retry) → waiting
                           → (no more attempts) → definitively failed
```

Always save the job state on the corresponding entity (`report.status`, etc.)
so the frontend can poll or receive a push when it completes.

---

## Environment variables

```bash
# Shared with cache — Upstash Redis
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=
```
