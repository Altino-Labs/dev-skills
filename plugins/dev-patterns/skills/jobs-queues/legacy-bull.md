# Legacy — @nestjs/bull (Bull v3/v4)

> **Read this file only if `package.json` shows `@nestjs/bull` instead of `@nestjs/bullmq`.**
> The two packages are NOT interchangeable. Check `package.json` before copying any pattern.
> For new projects, always use `@nestjs/bullmq` (BullMQ v5+) — the patterns in `SKILL.md` apply.

---

## Processor — legacy `@Process` decorator

With `@nestjs/bull`, the processor does NOT extend `WorkerHost` and does NOT implement `process()`.
Each job type gets its own `@Process(JOBS.X)` decorated method:

```typescript
// infrastructure/jobs/processors/generate-invoice-pdf.processor.ts
import { Process, Processor } from '@nestjs/bull';
import { Job } from 'bull';

@Processor(QUEUES.INVOICES)
export class GenerateInvoicePdfProcessor {
  private readonly logger = new Logger(GenerateInvoicePdfProcessor.name);

  constructor(
    private readonly invoiceRepo: IInvoiceRepository,
    private readonly pdfService: IPdfService,
  ) {}

  @Process(JOBS.GENERATE_INVOICE_PDF)
  async handleGenerate(job: Job<{ invoice_id: string }>): Promise<void> {
    const { invoice_id } = job.data;
    this.logger.log(`Generating invoice PDF invoice_id=${invoice_id} attempt=${job.attemptsMade}`);

    try {
      const invoice = await this.invoiceRepo.findById(invoice_id);
      if (!invoice) throw new Error(`Invoice ${invoice_id} not found`);

      const pdf = await this.pdfService.generate(invoice);
      await this.invoiceRepo.markPdfCompleted(invoice_id, pdf.url);
    } catch (error) {
      await this.invoiceRepo.updatePdfStatus(invoice_id, 'FAILED');
      this.logger.warn(`Invoice PDF generation attempt failed invoice_id=${invoice_id}`);
      throw error; // Bull retries automatically
    }
  }
}
```

**Key difference from BullMQ:**
- `@nestjs/bullmq`: one `process()` method; dispatch by `job.name` if handling multiple jobs.
- `@nestjs/bull`: one `@Process(JOBS.X)` method per job name; adding a second `@Process` handler
  for the same job name silently uses the last one defined.

---

## GlobalFailureListener — legacy `queue.on('failed')`

With `@nestjs/bull`, `Queue` emits `'failed'` directly — no `QueueEvents` class needed:

```typescript
// infrastructure/jobs/global-failure.listener.ts
@Injectable()
export class GlobalFailureListener implements OnModuleInit {
  private readonly logger = new Logger(GlobalFailureListener.name);

  constructor(
    @InjectQueue(QUEUES.INVOICES)      private invoicesQueue: Queue,
    @InjectQueue(QUEUES.EMAILS)        private emailsQueue: Queue,
    @InjectQueue(QUEUES.NOTIFICATIONS) private notificationsQueue: Queue,
  ) {}

  onModuleInit(): void {
    const entries = [
      { name: QUEUES.INVOICES,      queue: this.invoicesQueue },
      { name: QUEUES.EMAILS,        queue: this.emailsQueue },
      { name: QUEUES.NOTIFICATIONS, queue: this.notificationsQueue },
    ];

    for (const { name, queue } of entries) {
      // @nestjs/bull: Queue emits 'failed' directly; no QueueEvents needed
      queue.on('failed', (job, error) => {
        const maxAttempts = job.opts.attempts ?? 1;
        if (job.attemptsMade >= maxAttempts) {
          this.logger.error(
            `Job permanently failed: queue=${name} jobId=${job.id} attempts=${job.attemptsMade}: ${error.message}`,
          );
        }
      });
    }
  }
}
```

**Key difference from BullMQ:**
- `@nestjs/bullmq`: `Queue` does NOT emit `'failed'`; use `QueueEvents` (requires its own Redis connection).
- `@nestjs/bull`: `queue.on('failed', ...)` works directly on the `Queue` instance.
