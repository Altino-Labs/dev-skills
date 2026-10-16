# Date and Time Patterns
> Sub-file of `feature-slice` skill. Read when working with date inputs, timezone
> display, date-dependent queries, or grouping records by local calendar date.

---

## Date inputs — DD/MM/YYYY format

Use the app locale's display format in the UI (example: DD/MM/YYYY). The API always receives YYYY-MM-DD (ISO 8601). Apply an automatic mask as the user types.

```typescript
// Apply DD/MM/YYYY mask as user types
function applyDateMask(raw: string): string {
  const digits = raw.replace(/\D/g, '').slice(0, 8);
  if (digits.length <= 2) return digits;
  if (digits.length <= 4) return `${digits.slice(0, 2)}/${digits.slice(2)}`;
  return `${digits.slice(0, 2)}/${digits.slice(2, 4)}/${digits.slice(4)}`;
}

// Convert DD/MM/YYYY → YYYY-MM-DD for the API
function toIsoDate(ddmmyyyy: string): string {
  const [d, m, y] = ddmmyyyy.split('/');
  return `${y}-${m}-${d}`;
}

// Validate real date in the past
function validateDDMMYYYY(value: string): boolean {
  if (!/^\d{2}\/\d{2}\/\d{4}$/.test(value)) return false;
  const [d, m, y] = value.split('/').map(Number);
  const date = new Date(y, m - 1, d);
  return (
    date.getFullYear() === y &&
    date.getMonth() === m - 1 &&
    date.getDate() === d &&
    date < new Date()
  );
}

// In TextInput:
<TextInput
  value={birthDate}
  onChangeText={(text) => setBirthDate(applyDateMask(text))}
  placeholder="DD/MM/YYYY"   // in the app's UI language
  keyboardType="numeric"
  maxLength={10}
/>

// When sending to API:
birthDate: toIsoDate(birthDate.trim())  // converts to YYYY-MM-DD
```

---

## React Query v5 — `isLoading` is `true` for disabled queries without data

In React Query v5, `isLoading` equals `isPending` equals `status === 'pending'`. A query with `enabled: false` that has never fetched data has `status: 'pending'` → `isLoading: true`.

**Consequence:** if a required param (e.g. `resourceId`) is empty because `useGlobalSearchParams` returns `{}` on first render in Expo Router web, the query stays `enabled: false` → infinite loading spinner.

**Solution:** use `isPending && isFetching` to test "is actually fetching", and guard before hooks:

```typescript
const { id } = useGlobalSearchParams<{ id: string }>();
const { data, isPending, isFetching } = useQuery({
  queryKey: ['items', id],
  queryFn: () => fetchItems(id!),
  enabled: !!id,
});

if (!id) return <LoadingSpinner />;             // guard AFTER hooks
if (isPending && isFetching) return <LoadingSpinner />;
```

---

## React Query — QueryClient must be created outside the component

```typescript
// CORRECT — created once at module level
const queryClient = new QueryClient({
  defaultOptions: { queries: { ... } },
});

export default function RootLayout() {
  return <QueryClientProvider client={queryClient}>...</QueryClientProvider>;
}
```

If created inside the component without `useState`, a new `QueryClient` is generated on every render — the cache is lost on every re-render.

---

## React Query — recommended QueryClient configuration for Expo Router web

```typescript
const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 0,                // always stale → refetch on mount
      gcTime: 1800000,             // 30 min in cache (avoids spinner when returning to tab)
      refetchOnWindowFocus: false, // avoids refetch on browser window focus
      retry: 1,
    },
  },
});
```

`staleTime: 0` + `gcTime: 30min`: first visit shows a brief spinner; subsequent visits show cached data while refetch runs in the background.

---

## React Query — tabs that stay mounted need `useFocusEffect` for refetch

By default, tabs in React Navigation / Expo Router do NOT unmount when switching tabs. `refetchOnMount` only fires on the first visit.

**Solution:** add `useFocusEffect` in each individual screen that needs fresh data:

```typescript
import { useFocusEffect } from 'expo-router';
import { useCallback } from 'react';
import { useQueryClient } from '@tanstack/react-query';

const qc = useQueryClient();
useFocusEffect(useCallback(() => {
  if (id) qc.refetchQueries({ queryKey: ['module', id] });
}, [id, qc]));
```

**Do not** put `useFocusEffect` in the `_layout.tsx` of Tabs — in Expo Router web it fires on EVERY tab change, cancelling fetches in a loop.

---

## React Query — date-dependent queries must include the local date in the query key

Any query whose result changes with the current day must include the local date in `queryKey`. Without this, the cache from the previous day is reused after midnight.

```typescript
export function useDailyItems(resourceId: string, tz: string) {
  const today = new Date().toLocaleDateString('sv-SE', { timeZone: tz }); // "2026-06-25"
  return useQuery({
    queryKey: ['resources', resourceId, 'daily', today], // key changes at midnight
    queryFn: () => getDailyItems(resourceId, tz),
    enabled: !!resourceId,
  });
}

async function getDailyItems(resourceId: string, tz: string) {
  const date = new Date().toLocaleDateString('sv-SE', { timeZone: tz });
  return apiRequest(`/resources/${resourceId}/daily?date=${date}`);
}
```

**Why `sv-SE`:** the Swedish locale returns `YYYY-MM-DD` — the only unambiguous ISO format that the backend accepts directly.

---

## Detecting "today's record" — timezone-safe comparison

Never compare `.slice(0, 10)` on a UTC ISO string — that reads the UTC date, which is wrong for users in UTC- timezones.

```typescript
const tz = useUserTimezone();
const todayStr = new Date().toLocaleDateString('sv-SE', { timeZone: tz }); // "2026-06-26"

const todayEntry = entries.find((e) =>
  e.date_field
    ? new Date(e.date_field).toLocaleDateString('sv-SE', { timeZone: tz }) === todayStr
    : false
);
```

**Pre-condition:** the column must store real UTC timestamps. If migrating from `DATE` to `TIMESTAMPTZ`, the migration must backfill existing rows as a real local time converted to UTC — not just cast to midnight UTC. See `migrations` § "Date and time" (event dates / backfill).

---

## Writing to PostgreSQL `date` columns — never use `toISOString()`

When a column is declared as `date` (not `timestamptz`), **never** send `toISOString()` or its slice. At 23:30 UTC-3, `new Date().toISOString()` returns `"2026-06-26T02:30:00Z"` — PostgreSQL extracts `2026-06-26` (the next UTC day) while the user intended `2026-06-25`.

```typescript
const tz = useUserTimezone(); // IANA timezone from the auth/user Zustand store

// ❌ NEVER — extracts UTC date, wrong for UTC- users near midnight
body: { purchased_at: new Date().toISOString() }
body: { purchased_at: new Date().toISOString().slice(0, 10) }

// ✅ ALWAYS — local date in the user's timezone
body: { purchased_at: new Date().toLocaleDateString('sv-SE', { timeZone: tz }) }
// → "2026-06-25"  (correct regardless of UTC offset)
```

**Rule:** `date` column → `toLocaleDateString('sv-SE', { timeZone: tz })`. `timestamptz` column → `toISOString()`.

**How to distinguish:** check the migration — `date NOT NULL` → sv-SE pattern; `timestamptz` → `toISOString()`.

**Never hardcode the timezone in the frontend** — a hard-coded zone is a backend fallback only; always send the user's stored IANA `tz`.

---

## Grouping history by local calendar date

When displaying historical records grouped by day, always group by the **user's local date**, not the UTC date string.

```typescript
function groupByLocalDate<T>(
  items: T[],
  getTimestamp: (item: T) => string | null | undefined,
  tz: string,
): Record<string, T[]> {
  const groups: Record<string, T[]> = {};
  for (const item of items) {
    const ts = getTimestamp(item);
    const date = ts
      ? new Date(ts).toLocaleDateString('sv-SE', { timeZone: tz })
      : '';
    if (!groups[date]) groups[date] = [];
    groups[date].push(item);
  }
  return groups;
}

// Usage:
const tz = useUserTimezone();
const grouped = groupByLocalDate(confirmations, (c) => c.confirmed_at, tz);
const sortedDates = Object.keys(grouped).sort().reverse(); // descending
```

**Rule:** never use `.slice(0, 10)` on a `timestamptz` field for display grouping. Only safe for `date` fields.
