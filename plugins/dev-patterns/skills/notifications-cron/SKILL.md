---
name: notifications-cron
description: >
  Push notification and cron job patterns with NestJS + Expo Notifications: time- and
  level-triggered notifications (reminders, "stock low") as scheduled scans of current state,
  action-triggered pushes through event subscribers, mark-sent-after-success, and Expo push
  receipts. Invoke automatically when implementing scheduled checks, reminders, alerts,
  notification subscribers, or push logic via Expo Notifications.
---

# Notifications & Cron

## Project-specific cron schedule and urgency rules

Define the project's crons (schedule per job), trigger table, and recipient rules in the
project's spec (e.g. `PROJECT.md`, or a dedicated notifications spec). The patterns below
apply to any project — the business rules belong in the spec.

## Which mechanism — scan or subscriber

| Trigger | Mechanism | Examples |
|---|---|---|
| **Time** — something becomes due | Scheduled job scanning current state | appointment / dose reminders, "report ready for N days", expiry warnings |
| **Level** — a quantity crosses a threshold | Scheduled job scanning current state | stock low, quota almost used, balance below minimum |
| **Action** — a user or system did something | Domain event + subscriber | invitation accepted, emergency reported, ownership transferred |

Why time and level are scans, not subscribers: `dev-core:domain-events` → "Time- or
level-triggered notifications are scheduled scans". In short, a subscriber only sees the write
paths that publish the event — the nightly automatic stock decrement that never publishes
`stock.low` silently skips the alert; a scan sees every path. A single value judged when it is
submitted (a reading out of range) is an action — an event is fine there.

How the jobs are fired (in-process `@Cron` vs an external tick, the schedule registry, the run
log): `dev-patterns:jobs-queues` → "Scheduled jobs" and `dev-core:resilience-patterns` →
"Scheduled jobs".

## Non-negotiable notification rules

- **Critical** urgency can never be silenced by the user
- Maximum 3 pushes per hour per user (except Critical)
- Invalid push token → remove after 3 consecutive failures
- Emergency-type events (e.g. `incident.emergency`) → notify **all** members, no preference
  filters (see the critical alert subscriber pattern below)
- Push sends from a cron must be marked as sent (e.g. a `sent_*` table) only **after** a
  successful send, so a failed send is retried on the next tick (see `dev-core:resilience-patterns`)
- Invalid-token detection uses Expo **push receipts**, read by a separate cron after the fact
  (a send ticket being `ok` does not mean delivered): increment a consecutive-failure counter
  on the user per `DeviceNotRegistered`/delivery failure, reset it to 0 on success, and clear
  the push token only once it reaches 3

## Scheduled scan pattern (reminders and level alerts)

```typescript
// notifications/jobs/send-due-reminders.job.ts
@Injectable()
export class SendDueRemindersJob {
  constructor(
    private readonly reminders: IReminderQueries,     // reads current state — no event involved
    private readonly sentLog: ISentNotificationRepository,
    private readonly pushService: IPushNotificationService,
  ) {}

  @Cron(CRON_SCHEDULES['send-due-reminders'].expression, { name: 'send-due-reminders' })
  async run(now = new Date()): Promise<{ sent: number; failed: number }> {
    // Everything due in the window that was NOT sent yet — the scan is the source of truth
    const due = await this.reminders.findDueNotSent({ from: subMinutes(now, 15), to: now });

    const results = await Promise.allSettled(
      due.map(async (r) => {
        await this.pushService.send({
          token: r.recipientPushToken,
          title: 'Appointment soon',
          body: `${r.title} at ${formatInZone(r.startsAt, r.subjectTimeZone)}`,
          data: { type: 'APPOINTMENT_REMINDER', appointmentId: r.appointmentId },
        });
        // Mark AFTER a successful send; a UNIQUE (kind, target_id, recipient_id, slot) makes a
        // concurrent or repeated run a no-op instead of a duplicate push
        await this.sentLog.markSent('APPOINTMENT_REMINDER', r.appointmentId, r.recipientId, r.slot);
      }),
    );
    return {
      sent: results.filter((x) => x.status === 'fulfilled').length,
      failed: results.filter((x) => x.status === 'rejected').length,
    };
  }
}
```

- The query does the work: "due in the window **and** no row in the sent log". A failed send
  leaves no row, so the next tick picks it up; a window wider than the cadence absorbs a
  missed tick.
- **Level alerts** use the same shape: `findBelowThresholdNotAlerted()` scans current levels.
  Key the sent-log row on the *episode* (e.g. cleared when the level goes back above the
  threshold) so the alert fires once per drop, not on every tick.
- Times in the message are formatted in the **subject's** zone (whose schedule it is), plus the
  recipient's when it differs — `dev-core:date-time`.

## Critical alert subscriber pattern (action-triggered — all members, no exception)

```typescript
@EventSubscriber('alert.critical')
export class SendCriticalAlertPushSubscriber {
  async handle(event: CriticalAlertEvent): Promise<void> {
    const allMembers = await this.memberRepo.findAllByTenantId(event.tenantId);

    // Promise.allSettled — individual failure does not block others
    await Promise.allSettled(
      allMembers.map(m =>
        this.pushService.send({
          token: m.pushToken,
          title: '🚨 Critical Alert',
          body: event.description,
          priority: 'high',
          data: { type: 'CRITICAL', alertId: event.alertId },
        })
      )
    );
  }
}
```

## Graceful degradation — push never brings down the main operation

```typescript
// In the Use Case — publish the event; InMemoryEventBus (Promise.allSettled) absorbs and logs
// push-subscriber failures. Do NOT wrap publish in try/catch — it masks DI misconfiguration
// (missing EVENT_BUS provider). See dev-core:error-handling.
await this.eventBus.publish(new IncidentCreatedEvent(...));
```

In a scan, the same rule holds per recipient: `Promise.allSettled`, count the failures, and
let the job's run log record them — one bad token never stops the batch.
