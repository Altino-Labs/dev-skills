---
name: date-time
description: >
  Time-zone model for any stack: instants stored in UTC (timestamptz or equivalent), calendar
  dates stored as dates, wall-clock routines as local time + zone; the SUBJECT's zone (a store,
  a patient, a venue) stored as an IANA name and kept separate from the VIEWER's zone; never
  fixed offsets — convert per instant (DST); the client sends its zone on every request and the
  server rejects offsets; scheduled jobs read the stored zone; "today/tomorrow" only in the zone
  it was computed in; date→timestamp backfills at local noon; date-utility tests pinned to a
  zone west of UTC (in CI too); zone names validated against the runtime's list. Invoke
  automatically when storing, filtering, grouping or displaying dates and times, computing
  "today", scheduling reminders or jobs, migrating date columns, or testing date utilities, in
  any language or framework.
---

# Date and Time

> Examples are pseudo-code. Stack plugins carry the concrete helpers (e.g.
> `dev-patterns:nestjs-fastify` for filtering rows by local day, `dev-patterns:migrations` for
> date backfills in PostgreSQL); the project's delta skill names its zone source and defaults.

## Rules

1. **Instants are stored in UTC** (`timestamptz`, `Instant`, `DateTimeOffset` normalized to UTC).
   An instant is "this moment, everywhere": an appointment, a confirmation, a log entry.
2. **Calendar dates are stored as dates** (`date`, `LocalDate`), not as midnight timestamps. A
   birth date or "the day of the visit" has no time and no zone.
3. **Wall-clock routines are stored as local time + the zone they belong to.** "Every day at
   20:00" is `20:00` in the subject's zone — not an instant, and not a UTC time.
4. **The subject's zone is data.** Whatever the times are *about* (a restaurant, a patient, a
   venue, an account) has its own zone, stored as an **IANA name** (`America/Sao_Paulo`,
   `Europe/Lisbon`), and it is **separate from the viewer's zone** (the person looking).
5. **Never use fixed offsets** (`-03:00`, `UTC+1`, `- 180 minutes`). The offset of a zone changes
   with daylight saving time and with law; convert **per instant** with a tz database.
6. **The client sends its zone on every request** (a header such as `X-Timezone: Europe/Lisbon`,
   set once in the API client). The server validates it is a known zone **name** and **rejects
   offsets** (400). A missing header falls back to a documented default, only for old clients.
7. **Scheduled jobs have no request — they read the stored zone** (the subject's, or the
   recipient's for personal preferences). Never a server-wide constant for user-facing times.
8. **"Today", "tomorrow", "yesterday" only in the zone they were computed in.** When two zones
   are involved (subject and viewer), show an explicit date with weekday instead
   (`Sat 18/10, 00:00`) — "tomorrow" is ambiguous across zones.
9. **Date → timestamp backfills use local noon** in the subject's (or the app's) zone, never
   midnight: noon survives any offset up to ±12 h and DST shifts without changing the day.
10. **Date-utility tests run pinned to a zone west of UTC** (e.g. `TZ=America/Sao_Paulo`),
    locally **and in CI**. A UTC runner hides the whole class of "parsed as UTC midnight → the
    day before" bugs.
11. **Validate zone names against the runtime's list** (`Intl.supportedValuesOf('timeZone')`,
    `zoneinfo.available_timezones()`, `ZoneId.getAvailableZoneIds()`, `TimeZoneInfo`), and
    canonicalize aliases. A database CHECK with the same rule is a cheap safety net.

---

## Which zone does each computation use?

| Computation | Zone |
|---|---|
| Subject's "today", agenda, routine times, reminders for the subject's events | **Subject's** zone |
| Forms that receive times for the subject | **Subject's** zone (say so when the viewer's differs: "Lisbon time — the venue's zone") |
| Extra line "in your zone: …" on a card | **Viewer's** zone, shown only when it differs **at that instant** |
| Personal preferences ("remind me the day before at 18:00") | **Recipient's** zone (fallback: subject's) |
| Interpreting what the viewer just typed or said ("in 2 hours") | **Viewer's** zone → stored as an instant |
| Reports | Subject's zone for the data; viewer's zone for "generated at" |
| Server maintenance jobs (cleanup, rotation) | Server/app zone — not user-facing |

---

## Changing the subject's zone

Decide per kind of data, and tell the user before saving:

- **Routines** (wall-clock times) **keep the clock**: 20:00 stays 20:00 in the new zone.
- **Scheduled instants** (appointments, flights) **keep the instant**; only their display moves.
- Expected side effect: on the day of the change, an item already confirmed at the old instant
  may show as pending again (same clock time, different instant). Accept it or handle it — but
  decide explicitly.

When the device's zone differs from the profile's (travel), **offer** to switch — never switch
silently — and remember the answer per (device zone, profile zone) pair so it doesn't nag.

---

## Patterns

### Instant → local day / time, per instant

```
localDate(instant, zone)   = tz.format(instant, zone, "yyyy-MM-dd")
localTime(instant, zone)   = tz.format(instant, zone, "HH:mm")

// UTC range of a local calendar day — compute both ends separately (DST days are 23 or 25 h)
dayRange(date, zone) = [ tz.toInstant(date + "T00:00", zone),
                         tz.toInstant(nextDay(date) + "T00:00", zone) )   // half-open

// a routine's next occurrence
nextAt(wallTime "20:00", zone, now) = tz.toInstant(localDate(now, zone) + "T20:00", zone)
                                      → if <= now, use the next local day
```

Never `instant + offset`, never `toISOString().substring(0, 10)` for a local date (that is the
UTC date), never compare a date string with a timestamp string.

### The zone on every request

```
client:  apiClient.headers["X-Timezone"] = deviceOrProfileZone()     // once, centrally
server:  zone = header("X-Timezone") ?? DEFAULT_ZONE                 // default only for old clients
         if not isKnownZoneName(zone): reject 400 INVALID_TIMEZONE   // "-03:00" is rejected
```

Endpoints about a subject use the **subject's stored zone**, not the header; the header is the
viewer's zone.

### Scheduled jobs

```
for each subject with due items:
    zone  = subject.timezone                           // stored, IANA
    today = localDate(now, zone)
    for each routine at wallTime: fireAt = tz.toInstant(today + "T" + wallTime, zone)
    message = time in subject's zone
              + (recipient.zone differs at fireAt ? " (" + localTime(fireAt, recipient.zone)
                                                    + " your time, " + shortDateWithWeekday + ")" : "")
```

### Backfilling a date column into a timestamp

```sql
-- PostgreSQL: the date as local noon in the zone it was recorded in, stored as UTC
UPDATE t SET happened_at = (happened_on + time '12:00') AT TIME ZONE '<zone>';
```

---

## Testing

- Pin the test process to a zone **west of UTC** for every suite that touches dates
  (`TZ=America/Sao_Paulo <test command>` in the package script, so CI inherits it). Better:
  run the date suites twice in CI, in UTC and in the west-of-UTC zone.
- Functions that read "now" take an explicit zone and a controllable clock (fake timers / an
  injected clock); never depend on the machine's zone.
- Cover: an instant near local midnight; a subject and a viewer in different zones; a DST
  transition in either zone (e.g. the European change while the other zone has none); a day of
  23 and of 25 hours; an invalid zone name and an offset string rejected.
- Verify the new test **fails on the old code in the pinned zone** — a date test that passes
  everywhere may be testing nothing.

---

## Anti-patterns

| Anti-pattern | Why it breaks |
|---|---|
| Storing a calendar date as midnight UTC | West of UTC it displays as the day before |
| `toISOString().slice(0, 10)` as "today" | That is the UTC date; wrong for hours every evening (or morning) |
| A fixed offset constant (`-03:00`, `-180`) | Wrong after a DST change or a law change; wrong for any other zone |
| One server-wide zone constant in user-facing jobs | Every subject outside that zone gets reminders at the wrong time |
| Using the viewer's zone for the subject's "today" | Two members in different zones see different "today" lists, and confirmations don't match |
| "Tomorrow at 00:00" shown across zones | Ambiguous: whose tomorrow? |
| Treating any instant at 00:00 UTC as "date only" | A real event at that instant (21:00 the evening before, west of UTC) shows on the wrong day |
| Date tests on a UTC runner only | The bug class exists only west (or east) of UTC; CI stays green |
