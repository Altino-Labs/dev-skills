---
name: mobile-ux-patterns
description: >
  Screen-level UX patterns for React Native + Expo Router apps (native and web via
  react-native-web). Invoke automatically when designing a screen structure,
  implementing a CRUD list screen, a form modal, an empty state, a date-ordered list,
  or any visual hierarchy decision (page title vs section title, header vs content).
---

# Mobile UX Patterns

Generic patterns for React Native + Expo Router screens.
Project-specific tokens (colors, spacing, fonts), role-based visibility rules,
navigation structure, canonical reference screens and UI copy language live in the
project's spec / UX spec (e.g. `PROJECT.md`) (and in a project-local complement skill, if one exists).

> Section numbers are stable identifiers referenced from other docs — they are not
> strictly sequential (some sections were added out of order). Cite them as
> `mobile-ux-patterns §N`.
>
> Code samples use English UI strings and neutral example domains (`orders`,
> `projects`, `items`, `members`…). Replace with your app's copy and entities.

---

## 1. List-first pattern (CRUD screens)

Every screen that manages a resource type follows this structure — no exceptions:

1. **List of existing entries** — scrollable cards, most recent first
2. **"+ New" button** — compact, top-right, visible only to users with create permission
3. **Empty state** — CTA button if user can create; neutral message if read-only
4. **Create/edit form** — always a modal bottom-sheet, never inline in the screen body

---

## 2. Button positioning and sizing

### Action button (create / primary action)

Compact, right-aligned, in a header row placed **above** the list content:

```typescript
<View style={styles.screenHeader}>
  {canCreate && (
    <TouchableOpacity style={styles.addBtn} onPress={openModal}>
      <Text style={styles.addBtnText}>+ New</Text>
    </TouchableOpacity>
  )}
</View>

screenHeader: {
  flexDirection: 'row',
  justifyContent: 'flex-end',
  paddingHorizontal: 16,
  paddingTop: 8,
  paddingBottom: 4,
},
addBtn: {
  borderRadius: 8,
  paddingHorizontal: 14,
  paddingVertical: 8,
},
```

Rules:
- **Never** full-width for action buttons outside forms (`flex: 1`, `alignSelf: 'stretch'`, or `marginHorizontal` filling the container)
- When the screen has a segment toggle (e.g. "Today / History"), the action button goes **above** the toggle — never between the toggle and the list
- Full-width is reserved exclusively for **form submission buttons** inside modals (§7)

### Tag / multi-value inputs — auto-flush on save

When a form field accumulates values into an array via an "add" button (tag inputs, chip lists), the `onSave` handler must **automatically include** any text the user typed but did not explicitly add:

```typescript
// User typed 'urgent' but didn't press '+' before pressing Save
async function handleSave() {
  const pending = tagInput.trim();
  const finalTags =
    pending && !tags.includes(pending) ? [...tags, pending] : tags;

  // Use finalTags (not tags) in the DTO
  await save({ items: finalTags.length > 0 ? finalTags : undefined });
}
```

Why: users expect "fill in the field → press Save" to work. The explicit "add to list" step is an implementation detail of the UI, not a mental model the user has. Requiring it causes silent data loss — the field appears saved but the value was never included.

---

### Card action buttons — size and placement

Action buttons inside list cards always use **`size="sm"`** (`height: 32, paddingHorizontal: 12`).
Using the default `size="md"` (`height: 44`) inside a card makes buttons disproportionately tall relative to the card content.

```typescript
// ✅ Always size="sm" inside cards
<Button label="Edit"       size="sm" variant="secondary" onPress={openEdit} />
<Button label="Deactivate" size="sm" variant="ghost"     onPress={confirmDeactivate} />
<Button label="Close"      size="sm" variant="danger"    onPress={confirmClose} />

// ❌ Never default (md) inside a card — 44px height is too tall for card context
<Button label="Edit" variant="secondary" onPress={openEdit} />
```

Rule: `size="sm"` applies to **all** card action buttons: primary transitions, secondary (edit), destructive (cancel/deactivate/close), and inline confirmation buttons (Cancel / Confirm inside the confirmBox).

### Floating FAB (absolute bottom-right)

Screens that have a global create action (not scoped to a specific list section or toggle) use a **floating circular FAB** anchored to the bottom-right corner of the screen.

Use a single shared `FAB` component (e.g. `src/components/FAB.tsx`) — never reimplement it locally per screen:

```typescript
import { FAB } from '@/components/FAB';

{canCreate && <FAB onPress={openCreate} />}
```

Render the "+" as a **vector icon** (SVG from the icon kit), not a text "+" glyph — many custom fonts have asymmetric ascent/descent that leaves a bare `Text` "+" visibly off-center even with `lineHeight`/`translateY` fixes; a vector icon sidesteps the problem entirely instead of compensating for it. Fix the position inside the component at `bottom: 24, right: 24` (**never `right: 16`** — symmetry with `bottom` gives a balanced corner offset regardless of screen width).

Apply it to every list screen whose create action is global to the screen.

When the FAB context changes per tab (e.g. a screen with a "Recurring / One-off" toggle where each tab creates a different kind of item), use an inline header action per tab instead of a single FAB.

#### The screen owns the create action — child panels expose it via a ref

When a tab's content is a child component (e.g. `DetailPanel`) that used to render its own
"+ New" button, remove that internal button and let the screen-level create action drive it.
The child exposes its `openCreate` through `forwardRef` + `useImperativeHandle`, and the
screen dispatches to the right target for the active tab:

```typescript
// Screen — one create action, routed per active tab
function handleCreate() {
  if (activeTab === 'list') openCreateModal();
  else detailPanelRef.current?.openCreate();
}

<DetailPanel ref={detailPanelRef} resourceId={resourceId} />
```

```typescript
export type DetailPanelHandle = { openCreate: () => void };

export const DetailPanel = forwardRef<DetailPanelHandle, Props>(
  function DetailPanel({ resourceId }, ref) {
    // ... all useState calls ...
    useImperativeHandle(ref, () => ({ openCreate }));  // ← before any early return
    if (isPending) return <LoadingState />;
    // ...
    function openCreate() { /* ... */ }   // function declaration — hoisted, safe to reference above
  }
);
```

**Place `useImperativeHandle` before any early return** — hooks must be called
unconditionally, otherwise the handle disappears while the panel is loading and the
screen's create action silently does nothing.

### Destructive / secondary actions

Placed inline in the card, below the item content. Do not stack them vertically or make them full-width.

---

## 3. Date-ordered listings

When items are grouped by date, the **most recent group must appear first**.

Never rely on object key insertion order — always sort explicitly at render time:

```typescript
function groupByDate<T>(
  items: T[],
  getDateStr: (item: T) => string  // returns 'YYYY-MM-DD' or ISO string
): Record<string, T[]> {
  const groups: Record<string, T[]> = {};
  for (const item of items) {
    const key = getDateStr(item).slice(0, 10);
    if (!groups[key]) groups[key] = [];
    groups[key].push(item);
  }
  return groups;
}

// At render time — always sort descending:
Object.entries(groupByDate(items, (i) => i.confirmed_at ?? i.created_at))
  .sort(([a], [b]) => b.localeCompare(a))   // 'YYYY-MM-DD' is lexicographically sortable
  .map(([date, group]) => (
    <View key={date}>
      <Text style={styles.sectionTitle}>{formatDate(date)}</Text>
      {group.map(item => <ItemCard key={item.id} item={item} />)}
    </View>
  ))
```

**Why `.reverse()` on the input array is not enough:**
`.reverse()` changes the order of items within each group, but when iterating a plain
`Record<string, T[]>`, JavaScript preserves **key insertion order** — which depends on
which date appeared first in the *original* (reversed) array. If items from different
dates are interleaved in the source data, group order is unpredictable.
The explicit `.sort()` on `Object.entries()` is the only safe approach.

> Note: the group key above slices the UTC ISO string. For `timestamptz` values, derive
> the key in the user's timezone instead (see §10b "Detecting today's record").

---

## 4. Visual title hierarchy

| Level | Context | Typical style |
|---|---|---|
| Page title | Screen name — appears once, either in the navigation header or in the body (never both) | `fontSize: 20`, `fontWeight: '700'` |
| Section title | Group label within the content area | `fontSize: 13`, `fontWeight: '600'`, `textTransform: 'uppercase'`, `letterSpacing: 0.5` |

Rules:
- **Never** use page-title font weight (`700`) or size (`≥ 18`) for section labels — it implies the section is a full separate screen
- **Never** show the screen name in two places at once (see §5)
- Section titles identify a subset of items (e.g. a date group, a category) — they are always smaller and lighter than the page title

---

## 5. No duplicate titles (header vs content)

If the navigation header already shows the screen name (via Tab label, breadcrumb, or Stack title):
- **Remove** the `<Text>` title from the content body, **or**
- **Suppress** the header title: `headerTitle: () => null`

Showing the same label in two places is not thoroughness — it signals an unresolved
design decision and visually wastes space.

---

## 6. Empty state

| Situation | Content |
|---|---|
| User can create — **no FAB on screen** | Descriptive message + CTA button that opens the create form |
| User can create — **FAB present on screen** | Descriptive message only — no CTA |
| Read-only access | Neutral descriptive message — no CTA |

**FAB + EmptyState CTA is a duplication antipattern.** When a floating FAB is the primary create action, the EmptyState must not repeat it as a button. Two entry points for the same action create visual noise and imply the FAB is not obvious enough. The FAB alone is sufficient — it is always visible regardless of list state.

Pick one FAB screen as the project's canonical example of "FAB present → EmptyState without CTA" and make every other FAB screen follow it.

Message guidelines:
- Describe what will appear here, not just that there is nothing: "No orders yet. Register the customer's orders to track their delivery." ✅
- Avoid vague filler: "Nothing here yet!" ❌ / "No items" ❌
- Neutral messages for read-only must not imply the user can do something they cannot

### Empty vs. failed — never show the empty state for a query that failed

"No items yet — tap + to create one" is a statement about the data. If the list query **failed**
(no connection, server error), that statement is false — and it invites the user to re-create
something that already exists. This matters most once the app can open without a server (a cached
session): every list screen will hit this path.

Order of checks in every list screen:

```tsx
const { data, isPending, isError, error, refetch } = useItems(parentId);

if (isPending) return <LoadingState />;
if (isError && !data) return <ErrorState error={error} onRetry={() => void refetch()} />;
// …list, or <EmptyState …/> when data is genuinely empty
```

- **Failed with no data** → a shared `ErrorState`: title "Couldn't load", the error's message as
  description (the API client should already translate "server unreachable" into a friendly,
  localized message — never show raw native/network text), and a **"Try again"** button that refetches.
- **Failed but cached data exists** → keep showing the data; a slightly stale list beats an error screen.
- Screens with several lists (e.g. active + history) apply the rule per list, where that list's
  empty state would render.
- Same reasoning for anything gated on server state: if "has the user seen this tour?" can't be
  loaded, treat it as **unknown** and don't start the tour.

One shared `ErrorState` component, styled as a sibling of `EmptyState` — not per-screen ad-hoc
error blocks.

---

## 7. Modal bottom-sheet for forms

Create and edit forms open as a **modal sliding from the bottom**. Never render a form
inline in the list body — it breaks the list-first scanning pattern and creates layout
instability as the form opens and closes. (Exception: short status-transition forms — §27.)

### Required structure

**CRITICAL:** the `ScrollView` must be INSIDE the sheet, never outside (wrapping the `View`).
If the `ScrollView` wraps the sheet's `View`, the overlay's `justifyContent: 'flex-end'`
stops working and the modal appears centered or squashed on screen instead of anchored to the bottom.

Every create modal must have a **✕ button in the top-right corner** to close it.
This does not replace the "Cancel" button in the footer — both are kept.

### Variant A — with handle (quick-create modals)

Use when the form is compact and the gesture handle is enough of a modal indicator
(e.g. a daily log entry, a quick note, a short "new item" form).

```typescript
<Modal visible={show} animationType="slide" transparent onRequestClose={close}>
  <View style={styles.overlay}>           {/* flex:1, rgba overlay, justifyContent:'flex-end' */}
    <View style={styles.sheet}>           {/* bg:#FFF, borderTopRadius:20, maxHeight:'90%' */}
      <View style={styles.handle} />      {/* 36×4 gray, alignSelf:'center', marginTop:12 */}
      <View style={styles.titleRow}>      {/* flexDirection:'row', alignItems:'center', paddingHorizontal:20, paddingBottom:12, borderBottom */}
        <Text style={styles.title}>{isEdit ? 'Edit X' : 'New X'}</Text>   {/* flex:1, 17px bold */}
        <TouchableOpacity onPress={close} hitSlop={8}>
          <Text style={{ fontSize: 18, color: '#6B7280' }}>✕</Text>
        </TouchableOpacity>
      </View>
      <ScrollView keyboardShouldPersistTaps="handled">
        {/* form fields */}
        <View style={{ flexDirection: 'row', gap: 12, marginTop: 8 }}>
          <Button label="Cancel" variant="secondary" style={{ flex: 1 }} onPress={close} />
          <Button label="Save"   variant="primary"   style={{ flex: 1 }} onPress={submit} />
        </View>
      </ScrollView>
    </View>
  </View>
</Modal>
```

### Variant B — no handle, generous header (full-registration modals)

Use when the form has many fields and the header works as a visual anchor
(e.g. a full "New / Edit <entity>" form, a multi-step picker + form).

```typescript
<Modal visible={show} animationType="slide" transparent onRequestClose={close}>
  <KeyboardAvoidingView style={styles.overlay} behavior={Platform.OS === 'ios' ? 'padding' : 'height'}>
    <View style={[styles.sheet, { overflow: 'hidden' }]}>   {/* overflow:'hidden' so rounded corners clip child backgrounds */}
      <View style={styles.sheetHeader}>   {/* flexDirection:'row', paddingHorizontal:24, paddingTop:24, paddingBottom:16, bg:#FFF, borderBottom:#F3F4F6 */}
        <Text style={{ flex: 1, fontSize: 18, fontWeight: '700' }}>New X</Text>
        <TouchableOpacity onPress={close} hitSlop={8}>
          <Text style={{ fontSize: 18, color: '#6B7280' }}>✕</Text>
        </TouchableOpacity>
      </View>
      <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={{ padding: 24, paddingTop: 16, paddingBottom: 40 }}>
        {/* fields */}
      </ScrollView>
    </View>
  </KeyboardAvoidingView>
</Modal>
```

**`height` vs `maxHeight` on a sheet with an inner `ScrollView`:**
- `maxHeight: '90%'` only works when the content grows organically and does not use `flex: 1`.
- If the `ScrollView` needs `flex: 1` to fill the remaining space (e.g. pickers with variable
  content), use `height: '88%'` (fixed value), not `maxHeight`. `flex: 1` inside a parent with no
  defined height collapses to zero.

The `flex: 1` on the Cancel/Confirm pair is the **only correct use** of equal-width
buttons in this stack — both actions are equally available and neither should dominate.

### Shared `BottomSheetModal` component

For Variant B modals (no handle, fixed header), use a shared component instead of the raw pattern. It guarantees an identical header on every screen automatically.

```typescript
import { BottomSheetModal, sheetBodyStyle } from '@/components/BottomSheetModal';

// Scrollable form — shrinks to content (maxHeight)
<BottomSheetModal visible={show} onClose={close} title="New X">
  <ScrollView keyboardShouldPersistTaps="handled" contentContainerStyle={sheetBodyStyle}>
    {/* fields */}
  </ScrollView>
</BottomSheetModal>

// Picker with inner flex:1 — fixed height required
<BottomSheetModal visible={show} onClose={close} title="New reading" height="88%">
  <ScrollView style={{ flex: 1 }}>
    {/* picker content */}
  </ScrollView>
</BottomSheetModal>

// Two-level picker — leftElement for a ‹ back button on step 2
<BottomSheetModal
  visible={show}
  onClose={close}
  title={step === 'groups' ? 'New reading' : activeGroup?.label ?? ''}
  height="88%"
  leftElement={step === 'params' ? (
    <TouchableOpacity onPress={() => setStep('groups')}
      hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}>
      <Text style={{ fontSize: 28, color: '#374151', lineHeight: 32 }}>‹</Text>
    </TouchableOpacity>
  ) : undefined}
>
  ...
</BottomSheetModal>
```

**`sheetBodyStyle`** — canonical body padding (`paddingHorizontal: 24, paddingTop: 16, paddingBottom: 40`). Use it as the ScrollView's `contentContainerStyle` or as the `style` of a wrapper View.

**`height` vs `maxHeight`**:
- `maxHeight` (default `'92%'`): the sheet shrinks to the content's size — form modals
- fixed `height` (e.g. `"88%"`): for pickers whose inner `ScrollView` uses `flex: 1` — without a defined height the scroll collapses to zero

**Beware of double spacing**: if the first child already has its own `marginTop: 16`, override the `sheetBodyStyle` `paddingTop` to `0`:
```typescript
contentContainerStyle={[sheetBodyStyle, { paddingTop: 0 }]}
```

### Create and edit forms must expose the same fields

The create form must include all the same fields as the edit form. Presenting a "minimal create" with only required fields — expecting the user to open edit to fill in the rest — is an antipattern:
- Users do not know the optional fields exist at create time
- It forces a two-step workflow for a single conceptual action
- Saved records appear incomplete in the list until edited

**Rule:** every field that appears in the edit modal must appear in the create modal, unless that field depends on the server-generated entity ID to function (e.g., file attachments that need the FK to exist first).

---

## 8. Permission-based navigation filtering

Navigation items the user cannot access **must never appear** in the UI — not even as
disabled links. Showing a link to an inaccessible page looks like a bug.

Rules:
- Filter the navigation list **before rendering** based on the user's role/permissions
- A compact note at the bottom of the menu informs how many sections were omitted and why:
  *"N sections are not available for your role in this team."*
- Items hidden due to permission are **completely absent** from the DOM — not grayed out,
  not locked, not conditionally styled. Absent.

```typescript
// Pattern: filter menu items before rendering
const visibleItems = ALL_ITEMS.filter((item) => userCanAccess(item, userRole));
const hiddenCount = ALL_ITEMS.length - visibleItems.length;

return (
  <>
    {visibleItems.map(item => <MenuItem key={item.route} {...item} />)}
    {hiddenCount > 0 && (
      <Text style={styles.hiddenNote}>
        {hiddenCount} {hiddenCount === 1 ? 'section is not available' : 'sections are not available'} for your role in this team.
      </Text>
    )}
  </>
);
```

Why not grayed out: a disabled link implies "you could do this in another context" or
"this will be available soon." Neither is true for a role restriction — it is a permanent
boundary for this user in this context.

---

## 10. Header breadcrumb spacing

Elements placed in `headerRight` / `headerLeft` via React Navigation / Expo Router
receive **no default horizontal margin** — they render flush against the screen edge.

Always wrap `headerRight` content in a `View` with `paddingRight: 16`, and give the
`headerLeft` back button a 12px left offset:

```typescript
headerRight: () => (
  <View style={{ paddingRight: 16 }}>
    <Text numberOfLines={1}>{label}</Text>
  </View>
),
headerLeft: () => <BackButton onPress={handleBack} />,
```

Never apply horizontal margin directly to a `Text` inside `headerRight` — the `View`
wrapper gives you a reliable hit area and consistent spacing regardless of content width.

### Back button — circular icon, no label

The `headerLeft` back button is a **small circle** containing only the `‹` chevron — no
"Back" text label. The label wastes space and is redundant next to the context name in
`headerRight`.

```typescript
// BackButton component
<TouchableOpacity
  onPress={handleBack}
  hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}   // 34 + 2×8 = 50 ≥ 44 (§18)
  style={headerStyles.backBtn}
  activeOpacity={0.7}
>
  <Text style={headerStyles.backChevron}>‹</Text>
</TouchableOpacity>

// Styles
backBtn: {
  marginLeft: 12,
  width: 34,
  height: 34,
  borderRadius: 17,
  backgroundColor: '#F3F4F6',   // gray-100 — neutral, doesn't compete with content
  alignItems: 'center',
  justifyContent: 'center',
},
backChevron: {
  fontSize: 20,
  color: '#374151',              // gray-700 — readable but not dominant
  fontWeight: '400',
  lineHeight: 20,                // ← equal to fontSize: removes font leading
  marginTop: 2,                  // ← nudge for iOS San Francisco vertical centering
  includeFontPadding: false,     // ← Android: removes extra top/bottom cell padding
},
```

**Why `lineHeight === fontSize` + `marginTop: 2`:** the `‹` glyph on iOS San Francisco has
a tall ascender that shifts it above the visual midpoint when the container uses
`justifyContent: 'center'` with the default `lineHeight`. Setting `lineHeight` equal to
`fontSize` neutralises the leading; the `marginTop: 2` compensates for the remaining
optical offset of this particular glyph.

---

## 9. Profile / user identity row

Use this pattern whenever a screen needs to show the logged-in user and provide access to
their profile settings.

**Visual structure:**

```
[ avatar ]  Name                    ›
            Subtitle (role / type)
```

**Rules:**
- The **entire row** is a single `TouchableOpacity` that navigates to the profile screen
- A **chevron** (`›`) on the right makes the row look tappable without a separate "Edit" label
- **Never** mix descriptive labels with action links in the same line
  (e.g. `Admin · My profile` is wrong — it conflates a data attribute with a navigation action)
- Use an **avatar circle with initials** as the placeholder before the user uploads a photo

```typescript
// Initials helper
function initials(fullName?: string): string {
  if (!fullName) return '?';
  return fullName
    .split(' ')
    .filter(Boolean)
    .slice(0, 2)
    .map((n) => n[0].toUpperCase())
    .join('');
}

// Component
<TouchableOpacity style={styles.profileRow} onPress={() => router.push('/profile')}>
  <View style={styles.avatar}>
    <Text style={styles.avatarText}>{initials(user?.full_name)}</Text>
  </View>
  <View style={styles.profileInfo}>
    <Text style={styles.name}>{user?.full_name}</Text>
    <Text style={styles.subtitle}>{userTypeLabel(user?.user_type)}</Text>
  </View>
  <Text style={styles.chevron}>›</Text>
</TouchableOpacity>

// Styles
profileRow:  { flex: 1, flexDirection: 'row', alignItems: 'center', gap: 12 }
avatar:      { width: 40, height: 40, borderRadius: 20, backgroundColor: '#3B82F6',
               alignItems: 'center', justifyContent: 'center' }
avatarText:  { color: '#FFF', fontSize: 14, fontWeight: '700' }
profileInfo: { flex: 1 }
name:        { fontSize: 15, fontWeight: '700', color: '#111827' }
subtitle:    { fontSize: 12, color: '#6B7280', marginTop: 1 }
chevron:     { fontSize: 20, color: '#D1D5DB', lineHeight: 22 }
```

**Why not `Name · My profile`:** embedding a navigation link inline with a descriptive
label creates two problems: (1) it's unclear whether the label or the link is the tappable
part; (2) the user has to read the subtitle to understand they can navigate — the chevron
communicates this immediately without any text.

---

## 10b. Timezone-aware date/time display

### Rule

All timestamps are stored in UTC. The frontend must convert them to the user's local timezone before display.

**Never** extract the time directly from an ISO string (e.g. `iso.substring(11, 16)`) — that reads the UTC offset embedded in the string, not the local time. This bug is invisible in UTC+0 environments but breaks for every other timezone.

### `date` vs `timestamptz` — two different display rules

PostgreSQL has two date-related types that require different display treatment:

| DB type | Example return from Supabase | Correct function |
|---|---|---|
| `timestamptz` | `"2026-06-01T14:30:00Z"` | `formatDate(iso, tz)` / `formatTime(iso, tz)` |
| `date` | `"2026-06-01T00:00:00Z"` ← midnight UTC | `fromIsoDate(iso)` |

**The `date` column trap:** the Supabase JS client / API layer may serialize PostgreSQL `date` columns as midnight UTC timestamps (`"YYYY-MM-DDT00:00:00Z"`). `new Date("2026-06-01T00:00:00Z")` in UTC-3 becomes May 31 at 21:00 — displaying the **wrong day**. Always verify the column type in the migration before choosing the display function.

### Format utils

```typescript
// utils package — APP_LOCALE is the app's display locale (e.g. 'en-US', 'pt-BR')
const APP_LOCALE = 'en-US';

function deviceTimezone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

// For date-only fields (PostgreSQL `date` type) — no timezone conversion.
// Builds the string from the Y-M-D parts; adjust the order to the app's locale.
export function fromIsoDate(iso: string | null | undefined): string {
  if (!iso) return '';
  const [y, m, d] = iso.slice(0, 10).split('-');
  return `${d}/${m}/${y}`;
}

// For timestamp fields (PostgreSQL `timestamptz`) — timezone-aware
// Also handles date-only strings and midnight UTC (from date columns) safely
export function formatDate(iso: string | null | undefined, timeZone?: string): string {
  if (!iso) return '';
  const s = iso.trim();
  if (
    /^\d{4}-\d{2}-\d{2}$/.test(s) ||                           // pure date string
    /^\d{4}-\d{2}-\d{2}T00:00:00(\.\d+)?(Z|\+00:00)$/.test(s) // midnight UTC (date column)
  ) {
    return fromIsoDate(s);
  }
  return new Date(s).toLocaleDateString(APP_LOCALE, { timeZone: timeZone ?? deviceTimezone() });
}

export function formatTime(iso: string | null | undefined, timeZone?: string): string {
  if (!iso) return '';
  return new Date(iso).toLocaleTimeString(APP_LOCALE, {
    timeZone: timeZone ?? deviceTimezone(),
    hour: '2-digit', minute: '2-digit',
  });
}

export function formatDateTime(iso: string | null | undefined, timeZone?: string): string {
  if (!iso) return '';
  return new Date(iso).toLocaleString(APP_LOCALE, { timeZone: timeZone ?? deviceTimezone() });
}
```

**Usage rule:**
```typescript
// ✅ date column (birth_date, start_date, due_date, requested_date…)
fromIsoDate(record.birth_date)

// ✅ timestamptz column with real time (scheduled_at, created_at…)
formatDate(event.scheduled_at, tz)
formatTime(event.scheduled_at, tz)

// ⚠️ formatDate also works for date columns (safe fallback), but fromIsoDate is explicit
```

### Timezone state — AsyncStorage + Zustand, not just API

Store the user's timezone preference in **both** AsyncStorage (immediate persistence) **and** the API DB (`users.timezone TEXT`). Never rely solely on the API to apply a UI preference.

**Why:** if the API call fails, the DB migration hasn't run yet, or the user's session expires, the timezone reverts to default. Storing it locally makes it robust.

```typescript
// auth.store.ts — pattern for any UI preference that must take effect immediately
const PREF_KEY = 'user_timezone';
const APP_DEFAULT_TZ = 'UTC'; // set to the app's primary market timezone (IANA id)

interface AuthState {
  user: User | null;
  isLoading: boolean;
  timezoneOverride: string | null;   // ← local AsyncStorage value
  setTimezoneOverride: (tz: string | null) => Promise<void>;
  loadFromStorage: () => Promise<void>;
  logout: () => Promise<void>;
  // ...
}

// setTimezoneOverride: writes to Zustand (immediate re-render) + AsyncStorage (persistence)
setTimezoneOverride: async (tz) => {
  set({ timezoneOverride: tz });
  tz
    ? await AsyncStorage.setItem(PREF_KEY, tz)
    : await AsyncStorage.removeItem(PREF_KEY);
},

// loadFromStorage: reads AsyncStorage first, syncs from API second
loadFromStorage: async () => {
  const [[, token], [, storedTz]] = await AsyncStorage.multiGet(['access_token', PREF_KEY]);
  if (!token) { set({ isLoading: false }); return; }
  const user = await apiRequest<User>('/auth/me');
  set({ user, isLoading: false, timezoneOverride: storedTz ?? user.timezone ?? null });
},

// logout: clear local preferences too
logout: async () => {
  await AsyncStorage.multiRemove(['access_token', 'refresh_token', PREF_KEY]);
  set({ user: null, timezoneOverride: null });
},
```

```typescript
// Hook — reads local override first, then API value, then app default
export function useUserTimezone(): string {
  return useAuthStore(
    (s) => s.timezoneOverride ?? s.user?.timezone ?? APP_DEFAULT_TZ,
  );
}

// Saving a preference — apply locally BEFORE the API call
async function handleSave() {
  await setTimezoneOverride(selectedTz);  // immediate effect
  try {
    const updated = await updateProfile({ timezone: selectedTz });
    setUser(updated);
  } catch (e) {
    showError(e);  // local pref already applied — no rollback needed
  }
}

// Using it in a screen
const tz = useUserTimezone();
<Text>{formatTime(item.scheduled_time, tz)}</Text>
```

### Writing to timestamp columns — always send UTC

The database stores **everything in UTC**. The frontend always sends `toISOString()` for any
date/time field. **Never** send a local date string to the API.

```typescript
// ✅ Always — for any timestamptz column
recorded_at: new Date().toISOString()    // "2026-06-26T02:30:00Z"
end_date:    new Date().toISOString()

// ❌ Never — local date strings are not UTC
recorded_at: new Date().toLocaleDateString('sv-SE', { timeZone: tz })
```

### Detecting "today's record" from a `timestamptz` column

When searching for the record that belongs to "today", convert both sides to the user's
local timezone — **never** compare `.slice(0, 10)` on a UTC string.

```typescript
const tz = useUserTimezone();
const todayStr = new Date().toLocaleDateString('sv-SE', { timeZone: tz }); // "2026-06-26"

const todayEntry = items.find((item) =>
  item.date_field
    ? new Date(item.date_field).toLocaleDateString('sv-SE', { timeZone: tz }) === todayStr
    : false
);
```

(`'sv-SE'` is used purely because it formats as `YYYY-MM-DD` — not a display locale.)

**Pre-condition:** the column must store real UTC timestamps. If migrating from `DATE` to
`TIMESTAMPTZ`, the migration must backfill existing rows as a real local time converted to
UTC — not just `::timestamptz` (which gives midnight UTC = wrong day in UTC- timezones).
See the `migrations` skill (event dates section) for the correct `AT TIME ZONE` backfill pattern.

### Profile UI — combobox for option lists

A text field for IANA identifiers is error-prone. Use a **combobox**: a trigger button that opens a Modal with a FlatList of options. See §16 for the full pattern.

### DB column

```sql
ALTER TABLE users ADD COLUMN timezone TEXT;  -- nullable, no default
```

`NULL` = no explicit preference → app falls back to AsyncStorage override or app default.

---

## 71. Date navigator — screens that show one day at a time

When a screen shows data for a **single day** and the user needs to browse past days, put a
date navigator at the top of the content (where a filter row would go — same 16px top spacing
as §35), not a date picker field.

```
‹   Today · Jul 04             ›
‹   Fri, Jul 04, 2026          ›   (past dates)
```

```typescript
// State — initialize to today in the user's timezone (§10b)
const todayStr = new Date().toLocaleDateString('sv-SE', { timeZone: tz }); // 'YYYY-MM-DD'
const [selectedDate, setSelectedDate] = useState(todayStr);
const isToday = selectedDate === todayStr;

// Navigation — UTC noon avoids DST / day-shift edge cases
function goToPrevDay() {
  const d = new Date(selectedDate + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() - 1);
  setSelectedDate(d.toISOString().slice(0, 10));
}
function goToNextDay() {
  if (isToday) return;
  const d = new Date(selectedDate + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() + 1);
  setSelectedDate(d.toISOString().slice(0, 10));
}

// Label
const formattedDate = isToday
  ? `Today · ${new Date(selectedDate + 'T12:00:00Z').toLocaleDateString(APP_LOCALE, { day: '2-digit', month: 'short', timeZone: 'UTC' })}`
  : new Date(selectedDate + 'T12:00:00Z').toLocaleDateString(APP_LOCALE, { timeZone: 'UTC', weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' });
```

```tsx
<View style={styles.dateNav}>
  <TouchableOpacity style={styles.dateNavBtn} onPress={goToPrevDay} activeOpacity={0.6}>
    <Text style={styles.dateNavArrow}>‹</Text>
  </TouchableOpacity>
  <Text style={styles.dateNavLabel}>{formattedDate}</Text>
  <TouchableOpacity style={styles.dateNavBtn} onPress={goToNextDay} disabled={isToday} activeOpacity={0.6}>
    <Text style={[styles.dateNavArrow, isToday && styles.dateNavArrowDisabled]}>›</Text>
  </TouchableOpacity>
</View>
```

```typescript
dateNav: {
  flexDirection: 'row',
  alignItems: 'center',
  backgroundColor: '#F9FAFB',
  borderRadius: 10,
  marginHorizontal: 16,
  marginTop: 16,          // §35
  marginBottom: 8,
  paddingHorizontal: 4,
  paddingVertical: 4,
  borderWidth: 1,
  borderColor: '#E5E7EB',
},
dateNavBtn:  { width: 36, height: 36, alignItems: 'center', justifyContent: 'center', borderRadius: 8 },
dateNavArrow: { fontSize: 22, color: '#374151', fontWeight: '400', lineHeight: 22, includeFontPadding: false },
dateNavArrowDisabled: { color: '#D1D5DB' },
dateNavLabel: { flex: 1, textAlign: 'center', fontSize: 14, fontWeight: '600', color: '#111827', textTransform: 'capitalize' },
```

**Rules:**
- `›` is **always disabled** when `selectedDate === todayStr` — browsing the future is meaningless
- Pass `selectedDate` to the data hook and include it in the React Query `queryKey`, so
  navigating triggers a fresh fetch automatically
- **Empty state adapts** (§6): on a past day, change the title (e.g. "No readings on this day")
  and the description, and **hide the CTA** — creating data for a past day from this
  screen is usually wrong
- Build `Date` objects from a `YYYY-MM-DD` string with `T12:00:00Z` (UTC noon) — midnight UTC
  shifts the displayed day by one in UTC− timezones
- `dateNavBtn` is 36×36; widen the hit area with `hitSlop` to reach 44 (§18)

---

## 11. Bottom tab bar — max 5 items, equal visual spacing

### Item count

A bottom tab bar must have **3–5 items maximum**. Never use horizontal scroll in a bottom nav — hidden tabs break discoverability (users don't know more tabs exist).

When a screen has more than 4 sections, use a **"More" overflow item**: the 4 most-used daily actions appear as tabs; everything else lives in the "More" list screen.

**Criteria for choosing the 4 main tabs:** actions performed multiple times per day — not overviews, profile sections, or occasionally-visited pages. Those belong in "More".

### Equal spacing with variable-length labels

**Never use `flex: 1` on tab items** — it forces equal width on all tabs, causing long labels (e.g. "Notifications", "Subscriptions") to truncate while short ones ("More") waste space.

**Correct pattern: `justifyContent: 'space-evenly'` on the container, no `flex` on tabs.**

Each tab sizes to its label width; the runtime distributes equal gaps between all items and the container edges.

```typescript
container: {
  flexDirection: 'row',
  height: 56,
  backgroundColor: '#FFF',
  borderTopWidth: 1,
  borderTopColor: '#E5E7EB',
  justifyContent: 'space-evenly',  // equal gaps, natural item widths
  alignItems: 'stretch',
},
tab: {
  justifyContent: 'center',
  alignItems: 'center',
  position: 'relative',
  paddingHorizontal: 2,            // minimal — don't add horizontal padding that eats space
},
tabText: {
  fontSize: 12,
  fontWeight: '400',
  color: '#6B7280',
  textAlign: 'center',
},
tabTextActive: {
  fontWeight: '600',
  color: '#3B82F6',
},
activeIndicator: {
  position: 'absolute',
  bottom: 0,
  left: 8,
  right: 8,
  height: 2,
  borderRadius: 1,
  backgroundColor: '#3B82F6',
},
```

### `adjustsFontSizeToFit` does not work on React Native Web

`adjustsFontSizeToFit` is a native-only prop — it has no effect in a browser. **Never rely on it to prevent truncation.** Use `justifyContent: 'space-evenly'` + natural tab widths instead.

### Active state indicator

Use a 2px colored underline at the bottom of the active tab (via `position: 'absolute', bottom: 0`) instead of — or in addition to — font weight change. The underline is visible regardless of label length and works with `space-evenly` layout.

---

## 12. Disclosure chevron (›) — navigation rows only

A trailing chevron (`›`) signals "tap here to go somewhere." Use it **only on rows that navigate to another screen.**

**Never** place a chevron next to an action button or destructive link (e.g. "Log out"). When a chevron and an action label are visually adjacent, the user reads the chevron as belonging to the action — implying the action leads somewhere, which is wrong for in-place actions like logout.

```
✅ [Avatar]  Jane Doe                    ›   ← profile row, navigates to /profile
             Admin

❌ [Avatar]  Jane Doe          ›  Log out   ← › reads as belonging to Log out
```

---

## 13. Safe area insets — never hardcode top padding

Do not hardcode `paddingTop` values to compensate for the status bar (e.g. `paddingTop: 56`). The correct value varies by device (iPhone SE vs Pro Max vs Android) and is **zero on web**.

Always use `useSafeAreaInsets` from `react-native-safe-area-context`:

```typescript
import { useSafeAreaInsets } from 'react-native-safe-area-context';

export default function MyScreen() {
  const insets = useSafeAreaInsets();

  return (
    <View style={[styles.header, { paddingTop: insets.top + 12 }]}>
      {/* content */}
    </View>
  );
}
```

- **Web:** `insets.top === 0` → only the 12px base padding applies, no wasted space
- **iOS native:** `insets.top` = real status bar height (~44–59px depending on model)
- **Android:** `insets.top` = real status bar height

Remove `paddingTop` from `StyleSheet.create` and apply it inline so it receives the dynamic value.

---

## 14. Expo Router — `index` route resolves to folder root

In Expo Router, `index.tsx` inside a folder is accessed via the **folder's URL**, not `/folder/index`.

```typescript
// ❌ Wrong — produces "Unmatched Route"
router.push(`/resources/${id}/index`)

// ✅ Correct
router.push(`/resources/${id}`)
```

When building overflow menus (e.g. "More") that link back to the index tab, check the route key and substitute the folder path:

```typescript
onPress={() =>
  router.push(
    item.route === 'index'
      ? `/resources/${resourceId}`
      : `/resources/${resourceId}/${item.route}`,
  )
}
```

---

## 15. UI preferences — apply locally before the API

User-facing preferences (timezone, language, theme, display density…) must take effect **immediately** when the user changes them. Never make the UX dependent on an API round-trip.

**Rule:** for any preference that visibly changes the UI, write it to AsyncStorage + Zustand state **before** the API call. The API sync is a best-effort background operation.

```typescript
async function handleSavePreference(value: string) {
  // 1. Apply immediately — Zustand triggers re-render everywhere
  await setPreferenceOverride(value);

  // 2. Sync to API — fire and forget, failure doesn't affect UX
  try {
    await updateProfile({ preference: value });
  } catch {
    // Local preference already applied. Log or notify, but don't revert.
  }
}
```

**Why not rollback on API failure?** The user explicitly chose this preference. Rolling it back on a transient API error creates inconsistency and confusion. The local value is authoritative; the API is secondary storage.

**Loading order in the store:**

```typescript
loadFromStorage: async () => {
  const [[, token], [, localPref]] = await AsyncStorage.multiGet(['access_token', 'pref_key']);
  const user = await apiRequest<User>('/auth/me');
  // Local AsyncStorage wins over API — it reflects the user's last explicit choice
  set({ user, prefOverride: localPref ?? user.preference ?? null });
},
```

**Logout must clear local preferences:**
```typescript
logout: async () => {
  await AsyncStorage.multiRemove(['access_token', 'refresh_token', 'pref_key']);
  set({ user: null, prefOverride: null });
},
```

---

## 16. Dropdown / combobox in React Native

React Native has no `<select>` element. For option lists with 5+ items, use a **combobox**: a trigger row that opens a bottom-sheet Modal with a scrollable list.

**Do not** render all options inline in the form — it bloats the screen and is visually noisy for long lists.

```typescript
// Trigger — shows selected label, opens sheet on tap
<TouchableOpacity style={styles.trigger} onPress={() => setOpen(true)}>
  <Text style={styles.triggerText}>
    {OPTIONS.find((o) => o.value === selected)?.label ?? selected}
  </Text>
  <Text style={styles.triggerArrow}>▾</Text>
</TouchableOpacity>

// Sheet — Modal sliding from bottom
<Modal visible={open} transparent animationType="slide" onRequestClose={() => setOpen(false)}>
  {/* Tap outside to dismiss */}
  <TouchableOpacity style={{ flex: 1, backgroundColor: 'rgba(0,0,0,0.4)' }}
    activeOpacity={1} onPress={() => setOpen(false)} />

  <SafeAreaView style={{ backgroundColor: '#FFF', maxHeight: '60%',
    borderTopLeftRadius: 16, borderTopRightRadius: 16 }}>

    {/* Header */}
    <View style={{ flexDirection: 'row', justifyContent: 'space-between',
      padding: 16, borderBottomWidth: 1, borderBottomColor: '#E5E7EB' }}>
      <Text style={{ fontSize: 16, fontWeight: '700' }}>Label</Text>
      <TouchableOpacity onPress={() => setOpen(false)}>
        <Text style={{ color: '#3B82F6' }}>Close</Text>
      </TouchableOpacity>
    </View>

    {/* Options */}
    <FlatList
      data={OPTIONS}
      keyExtractor={(item) => item.value}
      renderItem={({ item }) => {
        const active = selected === item.value;
        return (
          <TouchableOpacity
            style={[styles.item, active && styles.itemActive]}
            onPress={() => { setSelected(item.value); setOpen(false); }}
          >
            <Text style={[styles.itemText, active && styles.itemTextActive]}>
              {item.label}
            </Text>
            {active && <Text style={{ color: '#3B82F6', fontWeight: '700' }}>✓</Text>}
          </TouchableOpacity>
        );
      }}
    />
  </SafeAreaView>
</Modal>
```

**Key styles:**
```typescript
trigger:       { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
                 borderWidth: 1, borderColor: '#D1D5DB', borderRadius: 8,
                 paddingHorizontal: 12, height: 36, backgroundColor: '#FFF' }  // §40 — never paddingVertical
triggerText:   { flex: 1, fontSize: 14, color: '#111827' }
triggerArrow:  { fontSize: 14, color: '#6B7280', marginLeft: 8 }
item:          { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
                 paddingHorizontal: 16, paddingVertical: 14,
                 borderBottomWidth: 1, borderBottomColor: '#F3F4F6' }
itemActive:    { backgroundColor: '#EFF6FF' }
itemText:      { fontSize: 14, color: '#374151' }
itemTextActive:{ color: '#1D4ED8', fontWeight: '600' }
```

**When to use each approach:**

| Options | Component |
|---|---|
| 2–4 mutually exclusive | Inline toggle buttons (e.g. a `user_type` / role selector) |
| 5–20 | Combobox (this pattern) |
| 20+ with search | Combobox + `TextInput` filter above the `FlatList` |

Exception within the 5–20 range: a **fixed set of very short codes** (≤ 8 options, each
≤ 4 characters, e.g. sizes or grades) where seeing every option at once helps the user
can use the chip grid of §16b instead of a combobox.

### Combobox inside a modal bottom-sheet

When the trigger is inside a form that is already a `Modal`, **a second `Modal` cannot be used** for the picker (React Native Web renders it behind the first — see the `react-native-web` skill, Modal stacking).

> See §59: for a picker inside a **scrolling** sheet (`ScrollView` / `BottomSheetModal`), the later rule is a `transparent` `Modal` — an absolute panel anchors to the scroll content, not the screen. The absolute-panel pattern below remains the choice when the panel's container has no scrolling parent.

**Also do not use an inline expanding list** — it pushes all form fields below the trigger downward, distorting the layout every time the picker opens or closes.

**Correct pattern: absolute panel within the modal sheet.**

The picker panel is a `View` with `position: 'absolute', bottom: 0` placed *outside* the `ScrollView` but *inside* a `modalSheet` wrapper that holds the entire bottom-sheet. This makes the panel rise from the sheet's bottom, overlaying form content without shifting it.

**Required structure:**

```tsx
<Modal visible={showModal} animationType="slide" transparent>
  <KeyboardAvoidingView style={styles.modalOverlay} behavior={...}>

    {/* modalSheet — position:'relative' establishes the containing block */}
    <View style={styles.modalSheet}>

      {/* Form content — scrollable, never distorted by picker */}
      <ScrollView keyboardShouldPersistTaps="handled">
        <View style={styles.modalContent}>
          {/* ... form fields ... */}
          <TouchableOpacity style={styles.pickerTrigger}
            onPress={() => setPickerOpen(v => !v)}>
            <Text style={styles.pickerTriggerText}>{selectedLabel}</Text>
            <Text style={styles.pickerArrow}>▾</Text>
          </TouchableOpacity>
          {/* ... more form fields — NEVER pushed by picker ... */}
        </View>
      </ScrollView>

      {/* Picker panel — absolute, outside ScrollView, inside modalSheet */}
      {pickerOpen && (
        <>
          {/* Dismiss area: covers the form above the panel */}
          <TouchableOpacity style={styles.pickerDismissArea}
            activeOpacity={1} onPress={() => setPickerOpen(false)} />

          <View style={styles.pickerPanel}>
            <View style={styles.pickerPanelHeader}>
              <Text style={styles.pickerPanelTitle}>Title</Text>
              <TouchableOpacity onPress={() => setPickerOpen(false)}>
                <Text style={styles.pickerPanelClose}>Close</Text>
              </TouchableOpacity>
            </View>
            <ScrollView style={{ maxHeight: 280 }}>
              {OPTIONS.map(opt => ( /* ... */ ))}
            </ScrollView>
          </View>
        </>
      )}
    </View>

  </KeyboardAvoidingView>
</Modal>
```

**Critical rule:** `backgroundColor` and `borderTopRadius` must be on `modalSheet`, **not** on `modalContent`. `modalContent` only holds padding. If they are on `modalContent` (inside the `ScrollView`), React Native cannot use it as a positioning reference for the absolute panel.

**Styles:**

```typescript
modalOverlay: { flex: 1, backgroundColor: 'rgba(0,0,0,0.5)', justifyContent: 'flex-end' },
modalSheet: {
  position: 'relative',         // ← contains the absolute picker panel
  backgroundColor: '#FFF',
  borderTopLeftRadius: 20,
  borderTopRightRadius: 20,
  maxHeight: '90%',
},
modalContent: { padding: 24, paddingBottom: 40 },  // no bg, no radius

pickerDismissArea: { position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 },
pickerPanel: {
  position: 'absolute', bottom: 0, left: 0, right: 0,
  backgroundColor: '#FFF',
  borderTopLeftRadius: 16, borderTopRightRadius: 16,
  borderTopWidth: 1, borderTopColor: '#E5E7EB',
  shadowColor: '#000', shadowOffset: { width: 0, height: -3 },
  shadowOpacity: 0.08, shadowRadius: 8, elevation: 8,
},
pickerPanelHeader: {
  flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center',
  paddingHorizontal: 16, paddingVertical: 14,
  borderBottomWidth: 1, borderBottomColor: '#E5E7EB',
},
pickerPanelTitle: { fontSize: 16, fontWeight: '700', color: '#111827' },
pickerPanelClose: { fontSize: 14, color: '#3B82F6', fontWeight: '500' },
```

**Z-order rule:** `pickerDismissArea` and `pickerPanel` are both `position: 'absolute'`. Declare `pickerDismissArea` first in JSX — it has lower z-order, so tapping outside the panel hits the dismiss area; tapping on the panel items works normally.

---

## 16b. Chip grid — fixed set of very short codes

Use a **chip grid** instead of a combobox (§16) when the option set is small (≤ 8 items), every
value is very short (≤ 4 characters — sizes, grades, codes) and the user benefits from seeing
all options at once.

```typescript
const ROWS = [['XS', 'S', 'M', 'L'], ['XL', 'XXL', '3XL', '4XL']];   // explicit rows, explicit order

function ChipGrid({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <View style={styles.grid}>
      {ROWS.map((row, ri) => (
        <View key={ri} style={styles.row}>
          {row.map((opt) => {
            const selected = value === opt;
            return (
              <TouchableOpacity
                key={opt}
                style={[styles.chip, selected && styles.chipSelected]}
                onPress={() => onChange(selected ? '' : opt)}  // tap again to deselect
                activeOpacity={0.7}
              >
                <Text style={[styles.chipText, selected && styles.chipTextSelected]}>{opt}</Text>
              </TouchableOpacity>
            );
          })}
        </View>
      ))}
    </View>
  );
}

grid:             { gap: 8 },
row:              { flexDirection: 'row', gap: 8 },
chip:             { flex: 1, height: 36, borderRadius: 8, borderWidth: 1,   // §40 — 36px standard
                    borderColor: '#D1D5DB', backgroundColor: '#FFF',
                    alignItems: 'center', justifyContent: 'center' },
chipSelected:     { backgroundColor: '#3B82F6', borderColor: '#3B82F6' },
chipText:         { fontSize: 14, fontWeight: '500', color: '#374151' },
chipTextSelected: { color: '#FFF', fontWeight: '700' },
```

**Rules:**
- Start with no chip selected (`''`) — same rule as every selection group (§46)
- Tapping the selected chip **deselects** it — optional fields must support clearing
- At most 4 chips per row — more makes chips too narrow to tap comfortably (§18)
- Hard-code the rows as an array, not `flexWrap` — explicit rows guarantee a consistent layout.
  For longer, variable-length labels use the balanced `EnumButtons` rows of §64 instead

---

## 17. Design tokens — color palette and spacing scale

Never hard-code hex values or pixel values inline. Use these named tokens everywhere.
(The values below are a sensible default palette — replace with the project's brand tokens.)

### Color palette

```typescript
// packages/ui/src/tokens.ts
export const colors = {
  // Brand
  primary:        '#3B82F6',   // blue-500 — buttons, active states, links
  primaryDark:    '#1D4ED8',   // blue-700 — active text in lists
  primaryLight:   '#EFF6FF',   // blue-50  — selected row background

  // Semantic
  danger:         '#EF4444',   // red-500  — destructive actions, error borders
  dangerLight:    '#FEF2F2',   // red-50   — error message background
  success:        '#10B981',   // emerald-500 — confirmations, positive states
  successLight:   '#ECFDF5',   // emerald-50
  warning:        '#F59E0B',   // amber-500 — overdue, alerts
  warningLight:   '#FFFBEB',   // amber-50

  // Neutrals
  textPrimary:    '#111827',   // gray-900 — headings, primary content
  textSecondary:  '#374151',   // gray-700 — body text
  textMuted:      '#6B7280',   // gray-500 — subtitles, placeholders
  textDisabled:   '#9CA3AF',   // gray-400 — disabled inputs

  // Surfaces
  surface:        '#FFFFFF',
  surfaceAlt:     '#F9FAFB',   // gray-50  — alternate row, input background
  border:         '#E5E7EB',   // gray-200 — dividers, card borders
  borderFocus:    '#3B82F6',   // same as primary — focused input border
  borderSubtle:   '#F3F4F6',   // gray-100 — very light dividers inside cards

  // Overlay
  overlay:        'rgba(0,0,0,0.5)',  // modal backdrop
  overlayLight:   'rgba(0,0,0,0.4)',  // combobox backdrop
} as const;
```

### Spacing scale

```typescript
export const spacing = {
  xs:   4,
  sm:   8,
  md:   12,
  base: 16,   // standard screen horizontal padding
  lg:   20,
  xl:   24,
  '2xl': 32,
  '3xl': 40,  // modal bottom padding (home indicator clearance)
} as const;
```

### Typography scale

```typescript
export const typography = {
  // Page titles (screen headers, modal titles)
  pageTitle:   { fontSize: 20, fontWeight: '700' as const, color: colors.textPrimary },
  // Section labels inside content areas
  sectionTitle:{ fontSize: 13, fontWeight: '600' as const, color: colors.textMuted,
                 textTransform: 'uppercase' as const, letterSpacing: 0.5 },
  // Primary text in cards and lists
  body:        { fontSize: 15, fontWeight: '400' as const, color: colors.textSecondary },
  bodyStrong:  { fontSize: 15, fontWeight: '600' as const, color: colors.textPrimary },
  // Secondary text, metadata
  caption:     { fontSize: 13, fontWeight: '400' as const, color: colors.textMuted },
  captionStrong:{ fontSize: 13, fontWeight: '600' as const, color: colors.textSecondary },
  // Input labels and helper text
  label:       { fontSize: 14, fontWeight: '500' as const, color: colors.textSecondary },
  helper:      { fontSize: 12, fontWeight: '400' as const, color: colors.textMuted },
  // Error messages below inputs
  error:       { fontSize: 12, fontWeight: '400' as const, color: colors.danger },
  // Tab bar labels
  tabLabel:    { fontSize: 12, fontWeight: '400' as const },
  tabLabelActive: { fontSize: 12, fontWeight: '600' as const },
} as const;
```

**Rules:**
- Never use `fontWeight: '700'` on body or caption text — it implies a title
- Never use `fontSize < 12` — below this threshold text fails accessibility contrast requirements at normal sizes
- Line height: leave unset for single-line labels; use `lineHeight: fontSize * 1.5` for multiline body text

---

## 18. Minimum touch target sizes

Every tappable element must meet the platform minimum:

| Platform | Minimum | Source |
|---|---|---|
| iOS | 44 × 44 pt | Apple HIG |
| Android | 48 × 48 dp | Material Design |
| Both | 44 × 44 | Use the more conservative iOS rule |

**Pattern:** if the visible element is smaller, expand the hit area with padding or `hitSlop`:

```typescript
// Option A — padding (visible element expands too)
<TouchableOpacity style={{ padding: 12 }} onPress={onPress}>
  <Text style={{ fontSize: 14 }}>Action</Text>
</TouchableOpacity>

// Option B — hitSlop (visual stays small, hit area expands invisibly)
<TouchableOpacity
  hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
  onPress={onPress}
>
  <Icon size={20} />
</TouchableOpacity>
```

**Most common violations to watch:**
- Inline "Remove" / "Edit" text links without padding
- Chevron `›` icons at the end of rows
- Password "Show/Hide" toggle (use `paddingHorizontal: 12, paddingVertical: 10`)
- Close `✕` buttons on modals — must be at least 44×44

---

## 19. Form validation UX — when and how to show errors

### Timing rule

| Trigger | Rule |
|---|---|
| **On submit** | Show errors on all invalid fields simultaneously |
| **On blur** (field loses focus) | Show error only for that field — if already submitted once |
| **While typing** | Clear the error as soon as the field becomes valid; never show "too short" while the user is still typing |

Never validate on every keystroke — it creates a hostile experience where the user is corrected before finishing the thought.

```typescript
const [submitted, setSubmitted] = useState(false);
const [errors, setErrors] = useState<Record<string, string>>({});

function validate(fields: FormFields): Record<string, string> {
  const errs: Record<string, string> = {};
  if (!fields.name.trim())   errs.name   = 'Name is required';
  if (!fields.date)          errs.date   = 'Date is required';
  return errs;
}

// On submit:
async function handleSubmit() {
  setSubmitted(true);
  const errs = validate(fields);
  if (Object.keys(errs).length > 0) { setErrors(errs); return; }
  await save(fields);
}

// On blur (only after first submit attempt):
function handleBlur(field: string) {
  if (!submitted) return;
  const errs = validate(fields);
  setErrors((prev) => ({ ...prev, [field]: errs[field] ?? '' }));
}

// While typing — clear error as soon as valid:
function handleChange(field: string, value: string) {
  setFields((prev) => ({ ...prev, [field]: value }));
  if (errors[field]) {
    const errs = validate({ ...fields, [field]: value });
    if (!errs[field]) setErrors((prev) => ({ ...prev, [field]: '' }));
  }
}
```

### Visual error state on inputs

```typescript
// Input container — red border when error
inputRow: {
  borderWidth: 1,
  borderColor: colors.border,
  borderRadius: 8,
  paddingHorizontal: spacing.md,
  paddingVertical: spacing.sm,
},
inputRowError: {
  borderColor: colors.danger,
  backgroundColor: colors.dangerLight,
},

// Error message below the input
<View style={[styles.inputRow, error && styles.inputRowError]}>
  <TextInput ... />
</View>
{error ? <Text style={typography.error}>{error}</Text> : null}
```

### Required field indicator

Add `*` to the label of required fields only. Never mark optional fields with "(optional)" — it's noise. Mark only the exceptions. (For the shared label component, see §37 / §55.)

```typescript
<Text style={typography.label}>
  Customer name <Text style={{ color: colors.danger }}>*</Text>
</Text>
```

---

## 20. Loading states — skeleton screens and button spinners

### List loading — skeleton cards

Never show a blank white screen or a centered spinner for a list that is loading for the first time. Use skeleton cards that match the shape of the real content.

```typescript
function SkeletonCard() {
  return (
    <View style={styles.card}>
      {/* Title placeholder */}
      <View style={{ height: 14, width: '60%', backgroundColor: '#E5E7EB', borderRadius: 4 }} />
      {/* Subtitle placeholder */}
      <View style={{ height: 12, width: '40%', backgroundColor: '#F3F4F6',
                     borderRadius: 4, marginTop: 8 }} />
    </View>
  );
}

// In the screen — show 4 skeletons while loading
{isLoading && !data
  ? Array.from({ length: 4 }).map((_, i) => <SkeletonCard key={i} />)
  : data?.map(item => <ItemCard key={item.id} item={item} />)
}
```

**Rules:**
- Skeleton background: `#E5E7EB` (gray-200) for primary shapes, `#F3F4F6` (gray-100) for secondary
- Match skeleton shape to real content: same height, same border-radius, similar widths
- Show skeletons only on the **first** load (`isLoading && !data`). Subsequent refreshes use pull-to-refresh (§21) — no skeleton replacement

### Button loading state

While a mutation is in flight, the submit button must be disabled and show a loading label. Never let the user double-tap.

```typescript
<TouchableOpacity
  style={[styles.primaryBtn, loading && styles.primaryBtnDisabled]}
  onPress={handleSubmit}
  disabled={loading}
>
  <Text style={styles.primaryBtnText}>
    {loading ? 'Saving…' : 'Save'}
  </Text>
</TouchableOpacity>

primaryBtnDisabled: { opacity: 0.6 },
```

**Wording pattern for loading labels** (progressive form of the verb + ellipsis):

| Action | Loading label |
|---|---|
| Save | Saving… |
| Confirm | Confirming… |
| Delete | Deleting… |
| Send | Sending… |
| Load | Loading… |

The `…` (ellipsis character, U+2026) — never three dots `...` — signals in-progress action.

---

## 21. Pull-to-refresh

Every list screen that shows server data must support pull-to-refresh. It is the primary "I know something changed, give me the latest" gesture on mobile.

```typescript
import { FlatList, RefreshControl } from 'react-native';
import { useQueryClient } from '@tanstack/react-query';

export default function ItemsScreen() {
  const queryClient = useQueryClient();
  const [refreshing, setRefreshing] = useState(false);
  const { data } = useItemsQuery(resourceId);

  async function onRefresh() {
    setRefreshing(true);
    await queryClient.refetchQueries({ queryKey: ['items', resourceId] });
    setRefreshing(false);
  }

  return (
    <FlatList
      data={data ?? []}
      keyExtractor={(item) => item.id}
      renderItem={({ item }) => <ItemCard item={item} />}
      refreshControl={
        <RefreshControl
          refreshing={refreshing}
          onRefresh={onRefresh}
          tintColor={colors.primary}   // iOS spinner color
          colors={[colors.primary]}     // Android spinner color
        />
      }
    />
  );
}
```

**When using `ScrollView` instead of `FlatList`** (short lists that don't need virtualization):

```typescript
<ScrollView
  refreshControl={
    <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={colors.primary} />
  }
>
  {items.map(item => <ItemCard key={item.id} item={item} />)}
</ScrollView>
```

**Rules:**
- Always set `tintColor` / `colors` to `colors.primary` — the default gray is indistinguishable from a loading skeleton
- `onRefresh` must complete (set `refreshing: false`) even if the request throws — wrap in try/finally

---

## 22. Feedback after actions — toast and success states

The user must know their action succeeded. After a successful create / edit / delete, provide immediate, non-blocking feedback.

### Inline list confirmation (preferred)

After a successful mutation, React Query automatically refreshes the list via `invalidateQueries`. The new item appearing in the list is the primary success signal — no toast needed.

When the new item is not immediately visible (paged list, or item was deleted), show a transient toast.

### Toast / snackbar pattern

```typescript
// In the screen or a shared provider
const [toast, setToast] = useState<{ message: string; type: 'success' | 'error' } | null>(null);

function showToast(message: string, type: 'success' | 'error' = 'success') {
  setToast({ message, type });
  setTimeout(() => setToast(null), 3000);
}

// Usage after mutation
async function handleSave() {
  try {
    await createItem(dto);
    queryClient.invalidateQueries({ queryKey: ['items', resourceId] });
    setShowModal(false);
    showToast('Record saved.');
  } catch {
    showToast('Could not save. Please try again.', 'error');
  }
}

// Toast component — fixed at bottom, above tab bar
{toast && (
  <View style={[styles.toast, toast.type === 'error' && styles.toastError]}>
    <Text style={styles.toastText}>{toast.message}</Text>
  </View>
)}

toast: {
  position: 'absolute',
  bottom: 80,          // above tab bar height (56) + safe area
  left: 16,
  right: 16,
  backgroundColor: '#1F2937',   // gray-800 — neutral, works for both types
  borderRadius: 8,
  paddingHorizontal: 16,
  paddingVertical: 12,
  zIndex: 100,
},
toastError: {
  backgroundColor: colors.danger,
},
toastText: {
  color: '#FFF',
  fontSize: 14,
  fontWeight: '500',
  textAlign: 'center',
},
```

**Rules:**
- Toast auto-dismisses after 3 seconds — never require user interaction to dismiss a success toast
- Error toasts may persist longer (5 seconds) or require a tap to dismiss if the error message is actionable
- Never show a toast for a destructive action that was cancelled — only for completed actions
- Bottom `80` = tab bar height `56` + padding `24`. Adjust for screens without a tab bar (use `bottom: 24 + insets.bottom`)

---

## 23. Keyboard handling in forms

Mobile forms break when the keyboard covers input fields. Every form that opens in a modal or a full screen must handle keyboard avoidance.

### Inside a modal bottom-sheet

The modal is already anchored at the bottom — the keyboard pushes it up. Wrap the content in `KeyboardAvoidingView`:

```typescript
import { KeyboardAvoidingView, Platform } from 'react-native';

<Modal visible={showModal} animationType="slide" transparent onRequestClose={close}>
  <View style={{ flex: 1, backgroundColor: colors.overlay, justifyContent: 'flex-end' }}>
    <KeyboardAvoidingView
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
    >
      <ScrollView
        keyboardShouldPersistTaps="handled"
        contentContainerStyle={{ backgroundColor: colors.surface, borderTopLeftRadius: 20,
                                  borderTopRightRadius: 20, padding: spacing.xl,
                                  paddingBottom: spacing['3xl'] }}
      >
        {/* form fields */}
      </ScrollView>
    </KeyboardAvoidingView>
  </View>
</Modal>
```

**`keyboardShouldPersistTaps="handled"`** — required on `ScrollView` inside modals. Without it, tapping "Save" first dismisses the keyboard, requiring a second tap to submit.

### Input focus flow — `returnKeyType` + `ref` chain

For forms with multiple text inputs, configure the keyboard return key to advance to the next field:

```typescript
const nameRef   = useRef<TextInput>(null);
const emailRef  = useRef<TextInput>(null);
const notesRef  = useRef<TextInput>(null);

<TextInput
  ref={nameRef}
  returnKeyType="next"
  onSubmitEditing={() => emailRef.current?.focus()}
  blurOnSubmit={false}
  placeholder="Name"
/>
<TextInput
  ref={emailRef}
  returnKeyType="next"
  onSubmitEditing={() => notesRef.current?.focus()}
  blurOnSubmit={false}
  keyboardType="email-address"
  autoCapitalize="none"
  placeholder="E-mail"
/>
<TextInput
  ref={notesRef}
  returnKeyType="done"
  onSubmitEditing={handleSubmit}
  multiline
  placeholder="Notes"
/>
```

**`returnKeyType` mapping:**

| Position in form | `returnKeyType` |
|---|---|
| All fields except last | `"next"` |
| Last single-line field | `"done"` |
| Last field is multiline | `"default"` (multiline Enter = new line, not submit) |

**Rules:**
- Always set `blurOnSubmit={false}` on all fields except the last — otherwise the keyboard dismisses between fields
- `autoCapitalize="none"` on email and identifier fields
- `keyboardType="numeric"` on age, weight, quantity, and similar numeric-only fields
- `keyboardType="email-address"` on e-mail inputs

---

## 24. Filter toggle for lists with soft-delete (active / inactive / all)

When a resource uses soft-delete (`is_active` flag) instead of hard-delete, the list screen needs a way for the user to see and manage inactive items.

### When to show the filter

**Only show the filter when there is at least one inactive item.** A filter with only "active" records is noise — the toggle appears when it becomes useful.

```typescript
const inactiveCount = (items ?? []).filter((i) => !i.is_active).length;

{inactiveCount > 0 && (
  <View style={styles.filterRow}>
    {(['active', 'inactive', 'all'] as FilterMode[]).map((mode) => { ... })}
  </View>
)}
```

### Default and ordering

- Default filter: `'active'` — the user's daily workflow deals with active items
- Sort: **alphabetical** (`localeCompare`) applied before filtering, so order is stable across all filter modes
- Never sort by creation date unless the domain explicitly requires recency

```typescript
type FilterMode = 'active' | 'inactive' | 'all';
const [filter, setFilter] = useState<FilterMode>('active');

const sorted = [...(items ?? [])].sort((a, b) =>
  a.name.localeCompare(b.name, APP_LOCALE)   // pass the app's locale for correct accents/collation
);

const filtered = sorted.filter((item) => {
  if (filter === 'active') return item.is_active;
  if (filter === 'inactive') return !item.is_active;
  return true;
});
```

### Toggle visual (same as §1 segment toggle pattern)

```typescript
filterRow: {
  flexDirection: 'row',
  marginHorizontal: 16,
  marginTop: 16,        // canonical — matches header separator spacing (§35)
  marginBottom: 8,
  borderRadius: 10,
  backgroundColor: '#E5E7EB',
  padding: 3,
},
filterBtn:       { flex: 1, paddingVertical: 7, borderRadius: 8, alignItems: 'center' },
filterBtnActive: { backgroundColor: '#FFF' },
filterText:      { fontSize: 11, fontWeight: '500', color: '#6B7280' },
filterTextActive:{ color: '#111827', fontWeight: '600' },
```

Pick one reference screen and keep every filter identical to it (better: use the shared `FilterSelector` — §34/§36). Do NOT drift to `fontSize: 13/14`, `marginTop: 12`, `paddingVertical: 6/8`, or `borderRadius: 8` on the outer container.

### Empty state adapts to the active filter

```typescript
<EmptyState
  title={
    filter === 'inactive'
      ? 'No inactive items'
      : 'No items yet'
  }
  description={
    filter === 'inactive'
      ? 'All items are active.'
      : 'Create the first item.'
  }
  ctaLabel={filter !== 'inactive' && canCreate ? '+ New' : undefined}
  onCta={filter !== 'inactive' && canCreate ? openCreate : undefined}
/>
```

Never show a "create" CTA when the filter is `'inactive'` — the user is browsing history, not creating.

### Card actions per state

Active items and inactive items have different available actions:

```typescript
{item.is_active ? (
  <>
    <Button label="Edit"       size="sm" variant="secondary" onPress={() => openEdit(item)} />
    <Button label="Deactivate" size="sm" variant="ghost"     onPress={() => setConfirmDeactivate(item.id)} />
  </>
) : (
  <Button label="Reactivate" size="sm" variant="secondary" onPress={() => setConfirmReactivate(item.id)} />
)}
```

Confirmation box colors signal intent:
- **Deactivate** → yellow background (`#FEF3C7`) — destructive-adjacent, reversible
- **Reactivate** → blue background (`#EFF6FF`) — constructive, no danger

---

## 25. Friendly error messages in form catch blocks

Never display raw API error codes or `e.message` to the user. Map HTTP status codes to context-appropriate messages.

### Detection priority

```typescript
} catch (e: any) {
  if (e instanceof TypeError) {
    // fetch() threw before receiving any response — no internet or server down
    setError('Could not reach the server. Check your internet connection.');
  } else if (e?.statusCode === 401 || e?.statusCode === 403) {
    setError('...');   // context-specific: "invalid credentials", "no permission"
  } else if (e?.statusCode === 409) {
    setError('...');   // context-specific: "already registered", "already exists"
  } else if (e?.statusCode === 422) {
    setError('...');   // context-specific: domain validation failed
  } else {
    setError('Unexpected error. Please try again in a moment.');
  }
}
```

**`e instanceof TypeError`** detects network failure (fetch never connected). All API errors — including 401 — have a `statusCode` property and are **not** `TypeError` instances.

**Requires the HTTP client to attach `statusCode`** to every thrown error. If the client throws `new Error(message)` without `statusCode`, the catch block cannot classify the error. See `feature-slice` skill for the `apiRequest` pattern.

### Phrasing rules

| Status | Message pattern |
|---|---|
| Network (TypeError) | "Could not reach the server. Check your internet connection." |
| 401 on login | "Incorrect e-mail or password. Check and try again." |
| 401 on authenticated request | "Your session has expired. Please log in again." |
| 403 | "You don't have permission to perform this action." |
| 409 on create | "This [item] is already registered." |
| 422 | Describe the domain rule that was violated (if known). |
| Any other | "Unexpected error. Please try again in a moment." |

**Never** use "Error [code]: ..." or display the raw `message` field from the API response — it contains internal codes (`UNAUTHENTICATED`, `CONFLICT`) not intended for end users.

---

## 26. Filter toggle for workflow-status lists

Use this pattern when a resource has a **sequential lifecycle** (status enum), as opposed to §24 which covers soft-delete (boolean `is_active`). Key differences:

| | §24 Soft-delete | §26 Workflow status |
|---|---|---|
| Visibility | Only when inactive items exist | Always visible |
| Default | `'active'` | `'all'` |
| Options | 3 (active / inactive / all) | N statuses + "All" |
| Label font | 13px | 12px when 4+ options (fits in 400px) |
| CTA visibility | Hidden on `'inactive'` | Hidden on terminal/past-only states |

### Filter and sort per status group

For each filter, use the date that is **most meaningful for that state**:

| Filter | Sort | Date field |
|---|---|---|
| Initial state (e.g. REQUESTED) | Descending | Creation/request date |
| Intermediate state (e.g. SCHEDULED) | Ascending | Scheduled date (nearest first) |
| Terminal state (e.g. COMPLETED) | Descending | Completion date (most recent first) |
| All | By status priority, then per-group rule | — |

### "All" sort: status priority first

Assign a numeric priority to each status and sort by it first. Within each group, apply the same rule as the individual filter:

```typescript
const STATUS_PRIORITY: Record<MyStatus, number> = {
  [MyStatus.FIRST]:     0,
  [MyStatus.SECOND]:    1,
  [MyStatus.COMPLETED]: 2,
  [MyStatus.CANCELLED]: 3,
};

function sortItems(list: MyItem[], filter: FilterMode): MyItem[] {
  return [...list].sort((a, b) => {
    if (filter === 'all') {
      const pA = STATUS_PRIORITY[a.status];
      const pB = STATUS_PRIORITY[b.status];
      if (pA !== pB) return pA - pB;
      // Within SCHEDULED: ascending (nearest first); others: descending
      return a.status === MyStatus.SECOND
        ? itemDate(a) - itemDate(b)
        : itemDate(b) - itemDate(a);
    }
    return filter === 'second' ? itemDate(a) - itemDate(b) : itemDate(b) - itemDate(a);
  });
}
```

### "All" default: show the full picture

Unlike §24, defaulting to `'all'` is correct for workflow lists — the user wants to track the full pipeline, not just one stage.

### CTA rule for terminal states

Never show "create" CTA on past/terminal filter states:
```typescript
ctaLabel={filter !== 'completed' && canCreate ? '+ New' : undefined}
```

**Applies to the floating FAB too, not just the inline `EmptyState` CTA.** A new record
always starts in the "initial" state (e.g. a new ticket is always open, a new member is
always active) — showing "+" on a tab that displays a different status is
ambiguous about what pressing it would even create. Gate the FAB the same way:

```tsx
{canCreate && filter === 'active' && <FAB onPress={openCreate} />}
// or, for a multi-stage pipeline:
{canCreate && (filter === 'requested' || filter === 'scheduled') && <FAB onPress={openCreate} />}
```

### Exception states (e.g. CANCELLED) in "All" only

States that represent exceptions (cancellations, rejections) should appear only in the "All" view. Do not create a dedicated filter tab for them — they are not part of the daily workflow.

---

## 27. Inline transition forms for status workflows

When a resource moves through a lifecycle, expose state transitions as **action buttons on the card** that open a minimal inline form — never a modal.

### Modal vs inline decision

| Use case | Component |
|---|---|
| Create / full edit (many fields) | Modal bottom-sheet (§7) |
| Status transition (1–3 fields) | Inline form in the card |
| Destructive confirmation (no fields) | Inline confirm box (§2) |

The inline form avoids modal stacking (see the `react-native-web` skill, Modal stacking) and keeps the record in view while the user fills in the transition data.

### Single active transition state

Only one transition form should be open at a time. Use a single state object:

```typescript
type TransitionType = 'schedule' | 'complete'; // name your transitions

const [activeTransition, setActiveTransition] = useState<{
  type: TransitionType;
  itemId: string;
} | null>(null);
const [transitionDate, setTransitionDate]   = useState('');
const [transitionExtra, setTransitionExtra] = useState(''); // secondary field
const [transitionError, setTransitionError] = useState('');

function openTransition(type: TransitionType, itemId: string) {
  setActiveTransition({ type, itemId });
  setTransitionDate('');
  setTransitionExtra('');
  setTransitionError('');
}

function closeTransition() {
  setActiveTransition(null);
  setTransitionDate('');
  setTransitionExtra('');
  setTransitionError('');
}
```

Opening a new transition automatically closes any other open form/confirmation (call `closeTransition` + `setConfirmId(null)` before `openTransition`).

### Inline form rendering

```typescript
{activeTransition?.itemId === item.id && (
  <View style={styles.transitionBox}>
    <Text style={styles.transitionTitle}>
      {activeTransition.type === 'schedule' ? 'Schedule' : 'Record result'}
    </Text>
    {transitionError ? <Text style={styles.transitionError}>{transitionError}</Text> : null}
    <Input
      label="Date *"
      value={transitionDate}
      onChangeText={(v) => { setTransitionDate(applyDateMask(v)); setTransitionError(''); }}
      placeholder="DD/MM/YYYY"
      keyboardType="numeric"
      maxLength={10}
    />
    {/* Optional secondary field */}
    <Input label="Optional field" value={transitionExtra} onChangeText={setTransitionExtra} />
    <View style={styles.transitionActions}>
      <Button label="Cancel" size="sm" variant="secondary"
        onPress={closeTransition} style={{ flex: 1 }} />
      <Button label="Confirm" size="sm" variant="primary"
        onPress={() => handleTransition(item.id)}
        loading={updateMutation.isPending} style={{ flex: 1 }} />
    </View>
  </View>
)}
```

### Visual treatment by intent

```typescript
transitionBox: {
  marginTop: 12,
  padding: 12,
  borderRadius: 8,
  borderWidth: 1,
  // Constructive transition (moving forward in the lifecycle):
  backgroundColor: '#EFF6FF',  // blue-50
  borderColor: '#BFDBFE',      // blue-200
  // Destructive transition (cancellation): use yellow (#FEF3C7 / #FDE68A) instead
},
transitionTitle: { fontSize: 14, fontWeight: '600',
  color: '#1D4ED8' /* blue-700 for constructive, #78350F amber-900 for destructive */ },
transitionError: { fontSize: 12, color: '#EF4444', marginBottom: 8 },
transitionActions: { flexDirection: 'row', gap: 8, marginTop: 4 },
```

### Card action buttons — placement and hierarchy

Transition buttons follow the same compact/right-aligned rule as §2, but placed **inside the card** (not in a screenHeader):

```
[Schedule ●]  [Edit ○]  [Cancel ghost]
```

- Forward transition: `variant="primary"` (blue) — most important next action
- Edit: `variant="secondary"` (white outline) — secondary
- Destructive: `variant="ghost"` (text only) — least prominent

The forward transition button is omitted on terminal states (COMPLETED, CANCELLED). The "Cancel" action is omitted on COMPLETED and CANCELLED.

---

## 28. Direction-aware status badges

When a status value covers two opposite directions (e.g. "off-schedule" that can mean early
OR late), show different labels and colors based on which direction the deviation occurred.
**Never** collapse both directions into a single "Late"-style label.

### Pattern

```typescript
function directionalBadge(c: {
  status: MyStatus;
  actual_at: string | null;
  scheduled_at: string;
}) {
  if (c.status === MyStatus.ON_TIME)   return <Badge label="On time" variant="success" />;
  if (c.status === MyStatus.SKIPPED)   return <Badge label="Skipped" variant="danger"  />;
  // OFF_SCHEDULE: compare timestamps to determine direction
  if (c.actual_at && new Date(c.actual_at) < new Date(c.scheduled_at)) {
    return <Badge label="Early" variant="info"    />; // blue — before scheduled
  }
  return   <Badge label="Late"  variant="warning" />;  // amber — after scheduled
}
```

**Apply the same function in both the list view and the detail/history view.** Do not use
one badge function for the list and another for history — they must be consistent.

**Timestamp display in history** — when an event has both an actual and a scheduled time,
show both so the user understands the deviation:
```
16:09 (sched. 16:00)   ← confirmed_at (sched. scheduled_time)
00:11 (sched. 04:00)   ← early by 3h49m
```
Show only the scheduled time for SKIPPED (no actual event happened).

---

## 29. Two-level categorized picker (full-screen)

Use when there are **many items** (20+) organized in **named groups** (5–10 groups). A flat list
overwhelms the user; a bottom sheet accordion has small targets. The two-level full-screen
picker gives large touch targets and a clear mental model.

### When to use

- Parameter/metric selection across multiple categories (e.g. a catalog of measurable metrics grouped by area)
- Any resource selection where items naturally cluster into 5–10 distinct groups

### Level 1 — Group selection screen

Full-screen `Modal` (not transparent, `animationType="slide"`). Shows:

1. **"Recently used"** section (optional) — up to 3 chips with the most recently used items.
   Derived at render time from the existing data list — no server request needed.
2. **2-column grid of group cards** — each card shows group name, hint (2-3 example items), count.
   Last card is full-width when total group count is odd.

Each group card has a distinct background and accent color — visual differentiation makes scanning faster.

```typescript
// Group card — 47% width, color from a GROUP_META lookup
<TouchableOpacity
  style={[styles.groupCard, { backgroundColor: meta.bg }, isLastOdd && styles.groupCardFull]}
  onPress={() => { setActiveGroup(group); setPickerStep('params'); }}
>
  <Text style={[styles.groupCardName, { color: meta.accent }]}>{group.label}</Text>
  <Text style={[styles.groupCardHint, { color: meta.accent }]} numberOfLines={2}>{meta.hint}</Text>
  <Text style={[styles.groupCardCount, { color: meta.accent }]}>{group.params.length} items</Text>
</TouchableOpacity>
```

### Level 2 — Parameter list screen

Same Modal, different state (`pickerStep === 'params'`). Shows:

- Header with "‹ Groups" back button + group name title + "✕" close button
- List of items as rows with large touch targets (`paddingVertical: 18`)
- No accordion — all items visible at once within the group

```typescript
activeGroup?.params.map((param) => (
  <TouchableOpacity key={param} style={styles.paramRow} onPress={() => selectParam(param)}>
    <Text style={styles.paramRowText}>{ALL_PARAM_LABELS[param]}</Text>
    <Text style={styles.paramRowChevron}>›</Text>
  </TouchableOpacity>
))
```

### State

```typescript
type PickerStep = 'groups' | 'params';
const [pickerStep, setPickerStep] = useState<PickerStep>('groups');
const [activeGroup, setActiveGroup] = useState<ParamGroup | null>(null);

// Recents: derive at render time, no extra state
const recentParams = useMemo(() => {
  const seen = new Set<string>();
  const recent: string[] = [];
  for (const obs of [...items].sort((a, b) =>
    new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
  )) {
    if (!seen.has(obs.parameter)) { seen.add(obs.parameter); recent.push(obs.parameter); }
    if (recent.length >= 3) break;
  }
  return recent;
}, [items]);
```

### Opening the picker

```typescript
function openPicker() {
  setPickerStep('groups');   // always reset to groups on open
  setActiveGroup(null);
  setShowPicker(true);
}
```

---

## 30. Accordion picker within a modal (collapsible groups)

Use when parameter selection must stay **inside a form Modal** (no navigation to a new screen).
The picker appears as an absolute panel at the bottom of the modal sheet — **not a nested Modal**.
(See also §54 for the variant where the accordion *is* the modal's first step, and §66 for scroll-to-reveal.)

Groups start **collapsed by default** — the user sees all group names at a glance and expands
the one they need. Only one group open at a time.

```typescript
const [expandedGroup, setExpandedGroup] = useState<string | null>(null); // null = all collapsed

// Inside the absolute panel:
{GROUPS.map((group) => {
  const isOpen = expandedGroup === group.title;
  return (
    <View key={group.title}>
      <TouchableOpacity style={styles.accordionHeader}
        onPress={() => setExpandedGroup(isOpen ? null : group.title)}>
        <Text style={styles.accordionTitle}>{group.title.toUpperCase()}</Text>
        <View style={styles.accordionRight}>
          <Text style={styles.accordionCount}>{group.params.length}</Text>
          <Text style={styles.accordionChevron}>{isOpen ? '▾' : '▸'}</Text>
        </View>
      </TouchableOpacity>
      {isOpen && group.params.map((param) => (
        <TouchableOpacity key={param} style={styles.pickerItem}
          onPress={() => { setSelected(param); setPickerOpen(false); }}>
          <Text style={styles.pickerItemText}>{LABELS[param]}</Text>
          {selected === param && <Text style={styles.pickerCheck}>✓</Text>}
        </TouchableOpacity>
      ))}
    </View>
  );
})}
```

**Critical:** the panel must be `position: 'absolute', bottom: 0` inside a `position: 'relative'`
modal sheet — same pattern as §16 combobox. Never open a second (non-transparent) `Modal` for the picker.

**Reset on open:** always reset `expandedGroup` to `null` when opening the picker,
so the user sees groups collapsed on every open — not the last expanded group from a previous session.

---

## 31. Aggregated agenda / TODO screen — unified chronological list

When one screen aggregates pending items from several modules (tasks, appointments, reminders,
orders, alerts…), it displays **a single chronological list** — no separate sections per module type.
All pending items are merged and sorted by a derived sort key.

### Sort key per item type

Define, per item type, an ISO-like sort key so heterogeneous items interleave correctly:

| Type | Sort key |
|---|---|
| Immediate alerts (low stock, expiring document, pending request…) | `today T00:00` → `T00:03` (staggered so alert types keep a fixed relative order) |
| Items with a time-of-day today (e.g. recurring daily tasks) | `today T{scheduled_time}` |
| Items scheduled for today with optional time | `today T{scheduled_time ?? 23:59}` |
| Items with a date + slot time | `scheduled_date T{slot_time}` |
| Date-only items (appointments, deadlines…) | `reference_date T00:00` |

Items with no date anchor sort to end of list.

### Type tag in cards

Each card displays a small gray tag in the corner identifying its module
(e.g. `TASK · APPOINTMENT · ORDER · REMINDER`):

```typescript
typeTag:      { fontSize: 10, fontWeight: '600', color: '#6B7280',
                textTransform: 'uppercase', letterSpacing: 0.3 }
```

### Card actions for workflow items inside the agenda

Mirror the action buttons on the module's own cards:

| Status | Button 1 (primary) | Button 2 (secondary) |
|---|---|---|
| REQUESTED | Schedule | Edit |
| SCHEDULED | Complete | Edit |

On "Schedule" / "Complete": open an inline transition form (§27) within the agenda card — never navigate away.
On "Edit": deep-link (§32) to the module screen with `{entity}Id` + `action=view`.

### Query invalidation

After any create/update/cancel on a module that feeds the agenda, **always** invalidate
the agenda query key (e.g. `AGENDA_QUERY_KEY(scopeId)`) — not just the module query — so the
agenda reflects changes without a manual refresh.

### Items that stay visible past their date

Items with status `SCHEDULED` remain in the agenda even after their scheduled
date passes, until explicitly marked `COMPLETED` or `CANCELLED`. The backend must **not** filter
by `scheduled_date >= today` for these modules — an overdue, unresolved item is exactly what the
user needs to see.

---

## 32. Deep-link pattern — secondary-screen actions

When an action in screen A must pre-open a specific item or modal in screen B, use URL params
with a **cache-busting timestamp** to ensure the effect fires even when navigating to the same screen
repeatedly.

### Standard params

| Param | Purpose |
|---|---|
| `{entity}Id` | UUID of the target item (e.g. `orderId`, `taskId`, `itemId`) |
| `action` | What to do: `schedule`, `complete`, `view`, `edit`, `stock`, … |
| `tab` | Which filter tab to activate (`requested`, `scheduled`, …) |
| `t` | `Date.now()` — cache buster; triggers `useEffect` even for repeated nav to same item |

### Reading params in the target screen

```typescript
const { orderId, action, tab, t } = useLocalSearchParams<{
  orderId?: string; action?: string; tab?: string; t?: string;
}>();

useEffect(() => {
  if (!orderId) return;
  // open modal or transition form for orderId
}, [orderId, action, t]);  // t in deps ensures re-fire on repeated navigation
```

### Navigating with deep-link

```typescript
// From the agenda screen — open an item's stock/quantity modal
router.replace(
  `/projects/${projectId}/items?itemId=${item.id}&action=stock&t=${Date.now()}` as any
);

// From the agenda screen — open an order's schedule form
router.replace(
  `/projects/${projectId}/orders?orderId=${order.id}&action=schedule&tab=requested&t=${Date.now()}` as any
);
```

**Always use `router.replace`** (not `push`) for navigation between sibling screens inside the same
parent scope — avoids history accumulation (see the `expo-router` skill, `router.replace` vs `push`).

See also §60 (`returnTo`) for coming back to the caller after the edit, and §69 for when to open the
modal in place instead of navigating at all.

---

## 33. Two-line header — screens scoped to a parent entity

All screens under a parent-entity route (e.g. `projects/[id]/`) use a **two-line header** rendered
via `headerLeft` in that folder's `_layout.tsx`. The navigation header shows the screen title on
line 1 and the parent entity's name on line 2, with the user avatar on the right.

### Visual structure

```
┌─────────────────────────────────────────┐
│ [16px]  Screen Title              [JD]  │
│         Parent entity name              │
└─────────────────────────────────────────┘
```

### Implementation

```typescript
// In projects/[id]/_layout.tsx
const SCREEN_TITLES: Record<string, string> = {
  index: 'Home', todo: 'To do', more: 'More',
  orders: 'Orders', members: 'Team members', reports: 'Reports',
  // … one entry per route segment
};

// Styles
titleBlock: { paddingLeft: 16, paddingBottom: 12 },
headerTitle: { fontSize: 20, fontWeight: '700', color: '#111827' },
headerSub:   { fontSize: 13, fontWeight: '400', color: '#6B7280', marginTop: 1 },

// Stack.Screen options
headerLeft: () => (
  <View style={styles.titleBlock}>
    <Text style={styles.headerTitle}>{SCREEN_TITLES[segment] ?? segment}</Text>
    <Text style={styles.headerSub}>{parent?.name ?? ''}</Text>
  </View>
),
headerRight: () => (
  <View style={{ paddingRight: 16, alignSelf: 'stretch', justifyContent: 'center' }}>
    <AvatarButton onPress={() => router.push('/profile')} initials={userInitials} />
  </View>
),
headerShadowVisible: false,
headerBackground: () => (
  <View style={{ flex: 1, backgroundColor: '#FFF',
    borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: '#E5E7EB' }} />
),
```

### Required companion setting

In the parent `(app)/_layout.tsx`, the `Stack.Screen` for the scoped layout must have `gestureEnabled: false`:

```typescript
<Stack.Screen
  name="projects/[id]"
  options={{ headerShown: false, gestureEnabled: false }}
/>
```

This prevents the iOS swipe-back gesture from surfacing the native back button, which would conflict with the two-line header.

### Rules

- `paddingBottom: 12` on `titleBlock` is mandatory — it pushes the `hairlineWidth` border below the second-line text
- The spacer `headerLeft: () => <View style={{ width: 16 }} />` on sub-screens of Stack prevents the content from starting flush with the edge
- `SCREEN_TITLES` must match the menu labels in the "More" overflow screen exactly — keep a single source of truth

---

## 34. Filter selector — canonical style

All filter toggles (Active/Inactive/All, or workflow status tabs) use **exactly** these values:

```typescript
filterRow: {
  flexDirection: 'row',
  marginHorizontal: 16,
  marginTop: 16,        // standard header separator spacing
  marginBottom: 8,
  borderRadius: 10,     // outer container
  backgroundColor: '#E5E7EB',
  padding: 3,
},
filterBtn:       { flex: 1, paddingVertical: 7, borderRadius: 8, alignItems: 'center' },
filterBtnActive: { backgroundColor: '#FFF' },
filterText:      { fontSize: 11, fontWeight: '500', color: '#6B7280' },
filterTextActive:{ color: '#111827', fontWeight: '600' },
```

Designate one **reference screen** in the project. Deviations are bugs, not style choices.

**Banned values:**
- `fontSize: 13` or `fontSize: 14` on filter text → use `11`
- `marginTop: 12` on filterRow → use `16`
- `paddingVertical: 6` or `paddingVertical: 8` on filterBtn → use `7`
- `borderRadius: 8` on the outer container → use `10` (inner buttons use `8`)

---

## 35. Content top spacing — 16px standard

Every screen must have **16px of space** between the header separator and the first visible element.

| Screen type | How to apply |
|---|---|
| Has filter row at top | `marginTop: 16` on `filterRow` (already covered by §34) |
| No filter row (direct list) | `paddingTop: 16` on `listContent` or `contentContainerStyle` of the ScrollView/FlatList |

Never use `paddingTop: 0` or `paddingTop: 8` for content that begins immediately below the header — the header separator sits too close to the content without this spacing.

---

## 36. Filter tab shared component — `FilterSelector`

All filter toggles (active/inactive/all, or workflow status tabs) use a shared `FilterSelector` component. Extract it once — do not inline per screen.

```typescript
interface FilterTab {
  key: string;
  label: string;
}

export function FilterSelector({ tabs, value, onChange }: {
  tabs: FilterTab[];
  value: string;
  onChange: (key: string) => void;
}) {
  return (
    <View style={styles.row}>
      {tabs.map((tab) => {
        const active = tab.key === value;
        return (
          <TouchableOpacity
            key={tab.key}
            style={[styles.btn, active && styles.btnActive]}
            onPress={() => onChange(tab.key)}
          >
            <Text style={[styles.text, active && styles.textActive]} numberOfLines={1}>
              {tab.label}
            </Text>
          </TouchableOpacity>
        );
      })}
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    marginHorizontal: 16,
    marginTop: 16,
    marginBottom: 8,
    borderRadius: 10,
    backgroundColor: '#E5E7EB',
    padding: 3,
  },
  btn:       { flex: 1, paddingVertical: 7, borderRadius: 8, alignItems: 'center' },
  btnActive: { backgroundColor: '#FFF' },
  text:      { fontSize: 11, fontWeight: '500', color: '#6B7280', textAlign: 'center' },
  textActive:{ color: '#111827', fontWeight: '600' },
});
```

### No count indicators in filter tabs

**Do not** show counts (total items) inside or on filter tabs. Counts in tabs are visual noise for two reasons:

1. **Wrong semantic:** red badges communicate "unread / action required" (platform notifications). A count showing total items in a category is not an alert — the user reads it as urgency when it is just metadata.
2. **Redundant:** the count is visible when the user switches to that tab and sees the list. Previewing it on the tab itself does not help the user decide which tab to choose.

**Exception:** a count badge is appropriate only when it represents genuinely unread or actionable items — e.g., unseen notifications, items requiring an explicit user decision. Total item counts do not qualify.

---

## 37. Required field label — `FieldLabel` component

Never embed `*` directly in label text (`"Quantity *"`). Use a dedicated component that renders the asterisk as a separate `<Text>` so its size and position can be controlled independently.

```tsx
function FieldLabel({ text, required, compact }: { text: string; required?: boolean; compact?: boolean }) {
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', marginBottom: 6, marginTop: compact ? 0 : 16 }}>
      <Text style={{ fontSize: 14, color: '#374151', fontWeight: '500', lineHeight: 20 }}>{text}</Text>
      {required && (
        <Text style={{ fontSize: 18, color: '#374151', fontWeight: '500', marginLeft: 3, transform: [{ translateY: 3 }] }}>*</Text>
      )}
    </View>
  );
}
```

**Key points:**

- `transform: [{ translateY: N }]` — moves the asterisk down visually **without affecting layout**. Do NOT use `marginTop` to offset the asterisk: `marginTop` expands the parent View height, increasing spacing to the field below. The `translateY` approach is layout-neutral.
- The `translateY` value depends on the font — calibrate in the simulator. For the system font at `fontSize: 18` next to a label at `fontSize: 14`, a value of `3` is typically correct.
- Both texts share `lineHeight: 20` on the label text to normalize the row height. Remove `lineHeight` from the asterisk to let `translateY` work freely.
- Optional fields use `<FieldLabel text="Field" />` (no `required` prop) — same spacing, no asterisk.
- Inside an `inlineRow` (`flexDirection: 'row'`), use `compact` prop to suppress `marginTop: 16` and keep the label vertically aligned with sibling columns: `<FieldLabel text="Quantity" required compact />`.
- Use `compact` also right after a block whose last element already has its own bottom margin (e.g. `Input.container.marginBottom: 12` + `FieldLabel.marginTop: 16` = 28px of unwanted double gap).

---

## 38. Inline form validation errors — red banner, not Alert

**Never use `Alert.alert()` for form validation errors.** It pulls focus away, breaks keyboard flow, and feels like a system error rather than a field hint. (On web, `Alert.alert` with buttons is also a no-op — see the `react-native-web` skill.)

**Placement:** in the sticky footer (§43), just above the action buttons — not at the top of the ScrollView. The user is already looking at the bottom when they press Save; the error appears where their attention already is.

**Pattern:** `useState('')` for error, dismissible red banner in the footer, cleared on successful submission or by pressing ✕.

```tsx
const [error, setError] = useState('');

function handleSave() {
  if (!requiredField) { setError('Error message.'); return; }
  setError('');
  // proceed
}

// In JSX, inside the sticky footer View (above action buttons):
{error ? (
  <View style={styles.formError}>
    <Text style={styles.formErrorText}>{error}</Text>
    <TouchableOpacity onPress={() => setError('')} hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}>
      <Text style={styles.formErrorClose}>✕</Text>
    </TouchableOpacity>
  </View>
) : null}
```

```typescript
formError: {
  flexDirection: 'row',
  alignItems: 'center',
  backgroundColor: '#FEE2E2',
  padding: 10,
  borderRadius: 8,
  marginBottom: 12,
},
formErrorText: { flex: 1, fontSize: 13, color: '#991B1B' },
formErrorClose: { fontSize: 14, color: '#991B1B', marginLeft: 8, fontWeight: '600' },
```

Remove `Alert` from imports entirely when this pattern is adopted.

---

## 39. Mixed row — combo `flex:1` + fixed inputs side by side

When a repeatable entry has a label/category selector and one or more short inputs (e.g. HH:MM), place them on the same row to save vertical space.

```tsx
<View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
  <TouchableOpacity style={[styles.labelBtn, { flex: 1 }]} onPress={...}>
    <Text>{label}</Text>
    <Text>›</Text>
  </TouchableOpacity>

  <TextInput style={styles.timeInput} placeholder="HH" ... />
  <Text style={styles.timeSep}>:</Text>
  <TextInput style={styles.timeInput} placeholder="MM" ... />

  {!isOnly && <TouchableOpacity onPress={onRemove}><Text>✕</Text></TouchableOpacity>}
</View>

{showPicker && <View style={styles.pickerList}>...</View>}
```

- The combo gets `flex: 1` and expands to fill available space.
- Short inputs use a **fixed width** (e.g. `40px` for two-digit fields).
- Any dropdown/picker that opens from the combo renders **below the row** — never inline between the combo and the inputs.
- The remove button (`✕`) sits at the far right of the same row; keep it small (`fontSize: 12`, `padding: 4`) to not crowd the inputs.

### Labelled `Input` + `Select` side by side — `alignItems: 'flex-end'`

When one row holds several **labelled** `Input` and `Select` components (e.g. quantity + unit +
packaging), set `alignItems: 'flex-end'` on the row so every control sits on the same baseline
regardless of label height differences:

```tsx
<View style={[styles.inlineRow, { alignItems: 'flex-end' }]}>
  <View style={{ flex: 3 }}>
    <Input label="Quantity *" value={quantity} onChangeText={setQuantity} keyboardType="numeric" placeholder="500" />
  </View>
  <View style={{ flex: 2 }}>
    <Select label="Unit *" value={unit} onChange={setUnit} options={UNIT_OPTIONS} placeholder="kg..." />
  </View>
  <View style={{ flex: 3 }}>
    <Select label="Packaging" value={packaging} onChange={setPackaging} options={PACKAGING_OPTIONS} placeholder="box..." />
  </View>
</View>
```

**Critical:** every label in the row must use the same rendering mechanism — either all pass
the component's `label` prop or all use an external `FieldLabel` (§55). Never mix an external
`FieldLabel` with an internal `label` prop in the same row: the two render at different heights
and break the alignment even with `alignItems: 'flex-end'`.

---

## 40. Global form element height — 36px standard

All shared form primitives use **height 36, fontSize 14**. Do not override per-screen without a strong reason.

| Component | File | Style key | Value |
|---|---|---|---|
| `Input` | `src/components/Input.tsx` | `input.height` | 36 |
| `Input` | `src/components/Input.tsx` | `input.fontSize` | 14 |
| `Select` | `src/components/Select.tsx` | `trigger.height` | 36 |
| `Select` | `src/components/Select.tsx` | `triggerText.fontSize` | 14 |

Because `Input` and `Select` are global, changing the height there propagates to every form in the app automatically.

Local inline elements (e.g. `qtyInput`, `timePickerStyles.segment`, `labelComboBtn`) must also use `height: 36` so all controls on the same row sit flush. Mismatched heights cause vertical misalignment that is hard to spot in isolation but visible when elements share a row.

**When adding a new custom control** that sits beside an `Input` or `Select`, start at 36 and only deviate with explicit justification.

### Custom picker triggers — fixed `height`, never `paddingVertical`

A custom `TouchableOpacity` acting as a picker/select trigger must set `height: 36`, not derive
its height from vertical padding:

```typescript
// ✅ Correct — aligns with Input and Select
pickerTrigger: {
  flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
  borderWidth: 1, borderColor: '#D1D5DB', borderRadius: 8,
  paddingHorizontal: 12, height: 36, backgroundColor: '#FFF', marginBottom: 12,
},

// ❌ Wrong — paddingVertical: 12 produces a ~48px trigger, misaligned with Input (36px)
pickerTrigger: {
  paddingHorizontal: 12, paddingVertical: 12, ...
},
```

### Multiline fields — explicit height

The one deliberate exception to 36px is `Input multiline`. Always pair `multiline` with an
explicit `height` and `textAlignVertical: 'top'` — without them the field collapses to the
single-line height (and Android centers the text vertically):

| Lines | `height` | `textAlignVertical` | Use |
|---|---|---|---|
| 2 | `60` | `'top'` | Short address, short note |
| 3 | `72` | `'top'` | Notes, free-text description |

```tsx
<Input
  label="Notes"
  value={notes}
  onChangeText={setNotes}
  multiline
  style={{ height: 72, textAlignVertical: 'top' }}
/>
```

---

## 41. `showLabel` prop — hiding labels in inline/compact contexts

When a field component renders its own label (e.g. `TimePickerField` renders `<Text>Time</Text>`), add a `showLabel` prop defaulting to `true` so callers in compact rows can suppress it without forking the component.

```tsx
function TimePickerField({ value, onChange, showLabel = true }: {
  value: string;
  onChange: (v: string) => void;
  showLabel?: boolean;
}) {
  return (
    <View>
      {showLabel && <Text style={styles.label}>Time</Text>}
      {/* inputs */}
    </View>
  );
}

// Caller in compact row — no label rendered:
<TimePickerField value={entry.time} onChange={...} showLabel={false} />
```

**`parseParts` — allow empty time for placeholder display:**

```typescript
// CORRECT — empty string stays empty (shows HH / MM placeholders):
const parseParts = (v: string) => {
  const p = v.split(':');
  return [p[0] ?? '', p[1] ?? ''] as const;
};

// WRONG — forces 08:00 even when v === '', hiding the placeholder:
const parseParts = (v: string) => { const p = (v || '08:00').split(':'); ... };
```

Initialize new repeatable entries with `time: ''` (not `'08:00'`) so placeholder text is visible until the user types.

---

## 43. Sticky footer — error + buttons outside ScrollView

On long forms, keep action buttons (and the error banner) in a fixed footer **outside** the `ScrollView`. This way, when an error appears, the form content scrolls up — the buttons never move down.

**Requires `height` (not `maxHeight`) on the modal** so that `flex: 1` resolves correctly inside the sheet. Pass `height="92%"` to `BottomSheetModal` for forms that always fill the screen.

```tsx
<BottomSheetModal height="92%" ...>
  <View style={{ flex: 1 }}>

    {/* scrollable content */}
    <ScrollView
      style={{ flex: 1 }}
      contentContainerStyle={{ ...sheetBodyStyle, paddingBottom: 8 }}
      keyboardShouldPersistTaps="handled"
    >
      {/* form fields only */}
    </ScrollView>

    {/* fixed footer */}
    <View style={styles.modalFooter}>
      {error ? (
        <View style={styles.formError}>
          <Text style={styles.formErrorText}>{error}</Text>
          <TouchableOpacity onPress={() => setError('')} hitSlop={...}>
            <Text style={styles.formErrorClose}>✕</Text>
          </TouchableOpacity>
        </View>
      ) : null}
      <View style={styles.modalActions}>
        <Button label="Cancel" ... />
        <Button label="Save" ... />
      </View>
    </View>

  </View>
</BottomSheetModal>
```

```typescript
modalFooter: {
  paddingHorizontal: 24,
  paddingTop: 12,
  paddingBottom: 40,
  borderTopWidth: 1,
  borderTopColor: '#F3F4F6',
},
```

**Why `height` vs `maxHeight`:** `maxHeight` sizes the sheet to content; `flex: 1` on a child has no parent height to fill and collapses. `height` gives an explicit size that `flex: 1` can resolve against.

**Short-form variant (no ScrollView):** For forms that fit the screen without scrolling, use the default `maxHeight` and stack the content View + footer directly — no `flex: 1` wrapper needed. But override `paddingBottom` on `sheetBodyStyle` to `0`, otherwise the built-in `paddingBottom: 40` creates dead space between the last field and the footer.

```tsx
{/* No height prop — default maxHeight="92%" shrinks to content */}
<BottomSheetModal ...>
  <View style={{ ...sheetBodyStyle, paddingBottom: 0 }}>
    {/* form fields */}
  </View>
  <View style={styles.modalFooter}>
    {/* error banner + buttons */}
  </View>
</BottomSheetModal>
```

(Once the footer is extracted into a shared component, use it — see §57 `ModalFooter`.)

---

## 44. Day-of-week buttons — single row

Seven weekday buttons (`Mon`–`Sun`) must fit in one horizontal line. Use `flex: 1` on each button so they share width equally; remove `flexWrap`.

```typescript
// row container
daysRow: { flexDirection: 'row', gap: 4, marginBottom: 12 },

// each button
dayBtn: {
  flex: 1,
  paddingVertical: 7,
  borderRadius: 8,
  borderWidth: 1,
  borderColor: '#D1D5DB',
  alignItems: 'center',   // centers the label text horizontally
},
```

No `paddingHorizontal` needed — `flex: 1` already gives each button the right width. Three-letter labels ("Mon"/"Sun") fit comfortably at `fontSize: 13` within ~41px slots on a 375pt screen. Use three-letter abbreviations in any language.

---

## 45. Day-of-month + time inline (monthly frequency)

For monthly frequency, "Day of month (1–28)" and "Time" (HH:MM picker) sit side by side. Use `inlineRow` with `alignItems: 'flex-start'` so labels at the top align correctly when the two elements have different heights.

```tsx
<View style={[styles.inlineRow, { alignItems: 'flex-start' }]}>
  <View style={{ flex: 1 }}>
    <Input
      label="Day of month (1–28)"
      value={monthlyDay}
      onChangeText={setMonthlyDay}
      keyboardType="numeric"
      placeholder="e.g. 26"
    />
  </View>
  <TimePickerField value={monthlyTime} onChange={setMonthlyTime} />
</View>
```

`TimePickerField` has a fixed width (~100px: two 40px segments + colon + gaps). Wrapping `Input` in `flex: 1` fills the remaining space. `alignItems: 'flex-start'` prevents the picker from stretching vertically to match the Input container.

(Limiting the day to 1–28 avoids months without a 29th/30th/31st.)

---

## 42. Reset create-form state on cancel

Create modals accumulate state while the user fills the form. If the user cancels without submitting, reopen shows stale data. **Always extract a `resetXxxForm` function and call it from every exit path.**

```typescript
function resetCreateForm() {
  setFormName('');
  setFormQuantity('');
  setFormUnit('');
  // ... all form fields back to initial values ...
  setFormFreqType(FrequencyType.FIXED_TIME);
  setFormError('');
  setFormLabelPickerIdx(null);
  setFormParentId(null);
}
```

**Call sites — ALL of these must invoke the reset:**
1. `onClose` prop of the modal: `onClose={() => { setShowXxxModal(false); resetCreateForm(); }}`
2. "Cancel" button `onPress`
3. After successful submission (replaces the scattered `setFormXxx('')` calls)
4. The FAB / "+ New" handler that opens the modal (defensive — guarantees a clean form even if an exit path was missed)

**Edit modals are exempt** — their state is always seeded from the item being edited on open, so stale state is overwritten before the user sees it.

---

## 46. Selection groups — no default pre-selection

Button-group selectors (severity, category, shift, frequency, etc.) must **start with `null`**, not a pre-filled default. A pre-selected value gives the user false confidence that they've made a choice, and masks required fields.

```typescript
// ✗ wrong — "Medium" appears selected before the user does anything
const [severity, setSeverity] = useState<Severity>(Severity.MEDIUM);

// ✓ correct — all buttons start unselected
const [severity, setSeverity] = useState<Severity | null>(null);
```

**Validation:** treat `null` as a missing required field and show the standard error banner.

```typescript
if (!severity) { setCreateError('Select the severity.'); return; }
if (!category) { setCreateError('Select the category.'); return; }
```

**Reset:** `resetXxxForm()` must also set these back to `null`, not to a default value.

**Exception:** when editing an existing record, seed from the saved value — the user already chose it.

The same applies to label selectors in repeatable rows (e.g. a "label" combo per time entry): start with `label: ''` and show a gray "Select…" placeholder, never a pre-filled first option. For boolean toggles see §65.

---

## 47. Date + time on one row — side-by-side form fields

When a form requires a date **and** a time, the two fields share the same row (50% + 50%), not separate rows.

**Rule:** if the shared `Input` forwards `style` to the inner `TextInput` (not the container `View`), it cannot participate in the row's flex layout by itself. Wrap each `Input` in a `<View style={{ flex: 1 }}>`.

```tsx
<View style={{ flexDirection: 'row', gap: 8 }}>
  <View style={{ flex: 1 }}>
    <Input
      label="Date *"
      value={date}
      onChangeText={(v) => setDate(applyDateMask(v))}
      placeholder="DD/MM/YYYY"
      keyboardType="numeric"
      maxLength={10}
    />
  </View>
  <View style={{ flex: 1 }}>
    <Input
      label="Time"
      value={time}
      onChangeText={(v) => setTime(applyTimeMask(v))}
      placeholder="HH:MM"
      keyboardType="numeric"
      maxLength={5}
    />
  </View>
</View>
```

(A `flex: 2` date + `flex: 1` time split is also fine when the date mask is wider. With raw `TextInput`s, the same structure applies.)

**Time mask:**
```typescript
function applyTimeMask(raw: string): string {
  const digits = raw.replace(/\D/g, '').slice(0, 4);
  if (digits.length <= 2) return digits;
  return `${digits.slice(0, 2)}:${digits.slice(2)}`;
}
```

Combine the two fields into one UTC ISO string before sending (e.g. a `parseSeparatedToIso(date, time)` helper) — see §10b "always send UTC".

**Required vs. optional time:**
- If the time is required (e.g. a scheduled event that must happen at a precise moment), validate before saving: `if (!isValidTime(time)) { setError('...'); return; }`
- If it is optional (e.g. a "scheduled for" date where the hour is a nice-to-have), send `undefined` when empty: `scheduled_time: time.trim() || undefined`

Prefer the tappable picker input of §52 over masked text inputs when the platform picker is available.

---

## 48. Inline delete — trash icon + confirmation inside the card

Use this pattern for (soft-)deleting records in list cards when `Alert.alert` would break visual consistency (no loading state, looks like a system dialog, outside the app's component language).

### When to use

- The resource has soft-delete (`is_active` or `deleted_at`; see the project's data-model doc on reversible vs. permanent removal) — the backend keeps its existing endpoint (e.g. `POST /:id/archive`); only the UX changes
- The card already has an action row with buttons
- Delete is not the main action — it is a secondary/destructive action

### State and logic

```tsx
const [inlineAction, setInlineAction] = useState<'...' | 'delete' | null>(null);

function confirmDelete() {
  archiveMutation.mutate(item.id, { onSuccess: () => setInlineAction(null) });
}
```

### Card layout

```tsx
{/* Action row — hidden during confirmation */}
{!isReadOnly && inlineAction === null && (
  <View style={styles.cardActions}>
    <Button label="Main action" size="sm" onPress={...} />
    <Button label="Edit" size="sm" variant="secondary" onPress={...} />
    <View style={{ flex: 1 }} />
    <TouchableOpacity onPress={() => setInlineAction('delete')} style={styles.trashButton}>
      <MaterialCommunityIcons name="trash-can-outline" size={18} color="#9CA3AF" />
    </TouchableOpacity>
  </View>
)}

{/* Confirmation row — replaces the buttons */}
{!isReadOnly && inlineAction === 'delete' && (
  <View style={styles.deleteConfirm}>
    <Text style={styles.deleteConfirmText}>Delete this item?</Text>
    <View style={styles.deleteConfirmActions}>
      <Button label="No" size="sm" variant="secondary" onPress={() => setInlineAction(null)} />
      <Button
        label="Yes, delete"
        size="sm"
        variant="danger"
        onPress={confirmDelete}
        loading={archiveMutation.isPending}
      />
    </View>
  </View>
)}
```

### Canonical styles

```typescript
cardActions: { flexDirection: 'row', gap: 8, marginTop: 10, flexWrap: 'wrap', alignItems: 'center' },
trashButton: { padding: 4 },
deleteConfirm: {
  flexDirection: 'row',
  alignItems: 'center',
  justifyContent: 'space-between',
  marginTop: 10,
  paddingTop: 10,
  borderTopWidth: 1,
  borderTopColor: '#F3F4F6',
},
deleteConfirmText: { fontSize: 13, color: '#6B7280', flex: 1 },
deleteConfirmActions: { flexDirection: 'row', gap: 8 },
```

### Rules

- The trash icon is **always on the right** of the action row, separated from the other buttons (§68 refines this: prefer `marginLeft: 'auto'` over a `flex: 1` spacer when the row wraps)
- The confirmation **replaces** the whole action row — it does not appear below it
- The "Yes, delete" button has `loading={mutation.isPending}` — without visual feedback the action would be silent
- After `onSuccess`, reset `inlineAction` to `null`; the card disappears automatically if the list filters out deleted items
- **Never use `Alert.alert` for delete confirmation** — it has no loading state and breaks the app's visual language
- Items in an immutable status (e.g. a COMPLETED/APPLIED historical record) **get no trash icon** — history is not erased

---

## 49. Scroll-to-top when opening an inline form

When an inline form (§27) opens inside a list card, the card must be scrolled to the **top of the `ScrollView`'s viewport** — not merely revealed. This guarantees the whole form is visible regardless of content size.

### Mandatory pattern

Every screen that uses inline forms in list cards must implement this mechanism. Without it, the user has to scroll manually to see the form when the card is in the middle or at the end of the list.

### Implementation

```tsx
// 1. Refs in the screen
const scrollRef = useRef<ScrollView>(null);
const scrollY = useRef(0); // current offset — never state (avoids re-render)

// 2. ScrollView — attach ref + track offset
<ScrollView
  ref={scrollRef}
  onScroll={(e) => { scrollY.current = e.nativeEvent.contentOffset.y; }}
  scrollEventThrottle={16}
  ...
>

// 3. Handler in the screen
function handleScrollTo(cardRef: React.RefObject<View | null>) {
  setTimeout(() => {
    cardRef.current?.measure((_fx, _fy, _w, _h, _px, cardPy) => {
      (scrollRef.current as any)?.measure(
        (_fx2: number, _fy2: number, _w2: number, _h2: number, _px2: number, scrollPy: number) => {
          // cardPy and scrollPy are screen coordinates (include status bar + header)
          // subtracting scrollPy converts to a position relative to the ScrollView viewport
          const target = scrollY.current + (cardPy - scrollPy) - 8;
          scrollRef.current?.scrollTo({ y: Math.max(0, target), animated: true });
        },
      );
    });
  }, 150); // wait for the layout to expand before measuring
}

// 4. Prop on the card component
interface CardProps {
  // ...
  onScrollTo?: (cardRef: React.RefObject<View | null>) => void;
}

// 5. Inside the card component
const cardRef = useRef<View>(null);

function openInline(action: 'schedule' | 'complete') {
  setInlineAction(action);
  setTimeout(() => onScrollTo?.(cardRef), 50); // 50ms before the measure (150ms total)
}

// Wrap the card with a ref'd View — a shared Card component usually doesn't forwardRef
return (
  <View ref={cardRef}>
    <Card padding={14}>
      {/* ... */}
    </Card>
  </View>
);

// 6. Pass the handler to every card
{items.map((item) => (
  <ItemCard
    key={item.id}
    // ...
    onScrollTo={handleScrollTo}
  />
))}
```

On a screen with several card types (e.g. an aggregated agenda, §31), keep one `scrollRef`/`scrollY` for the whole screen and a ref map per card type (`Record<id, RefObject<View>>`); each `openXxxForm(id)` triggers the scroll.

### Why two nested `measure()` calls

`measure()` returns screen coordinates (including status bar + header + tabs). `scrollTo` operates on the `ScrollView`'s content. The formula:

```
target = scrollOffset + (cardPy - scrollPy) - 8px
```

- `scrollOffset` = current offset of the scroll content
- `cardPy - scrollPy` = card position **inside the viewport** (relative to the ScrollView's top, not the screen's)
- `- 8` = visual breathing room above the card

Using just `scrollOffset + cardPy - 8` (without subtracting `scrollPy`) scrolls too far — the card ends up above the visible top.

### `scrollEventThrottle={16}`

Required so `onScroll` fires often enough (≈60fps). Without it, `scrollY.current` gets stale and the calculation is off.

### 150ms delay

The 150ms `setTimeout` exists because the inline form expands the card before it is in the rendered layout. Measuring before the layout expands returns the card's position *before* the expansion.

---

## 50. Bidirectional action modal — segmented control + colored preview

When an action can go in opposite directions (e.g. add / remove stock), use a single `BottomSheetModal` with a segmented control instead of two buttons that open different modals.

### When to use

- The main action has two mutually exclusive modes (add/remove, activate/deactivate, credit/debit)
- Both modes operate on the same item
- The per-mode conditional fields fit in a scroll without needing a fixed `height`

### State structure

```typescript
const [stockTarget, setStockTarget] = useState<Item | null>(null);
const [stockMode, setStockMode] = useState<'add' | 'remove'>('add');
const [stockQty, setStockQty] = useState('');
// per-mode conditional fields:
const [stockAddSource, setStockAddSource] = useState<'purchase' | 'transfer' | 'other'>('purchase');
const [stockSupplier, setStockSupplier] = useState('');
const [stockTransferDate, setStockTransferDate] = useState('');
const [stockRemoveReason, setStockRemoveReason] = useState<'expired' | 'lost' | 'correction'>('correction');
const [stockError, setStockError] = useState('');
```

### Colored preview per mode

A preview block that shows the future state **before** saving. Its color changes with the mode:

```tsx
const previewStock = stockTarget
  ? stockMode === 'add'
    ? stockTarget.stock_count + (parseInt(stockQty, 10) || 0)
    : Math.max(0, stockTarget.stock_count - (parseInt(stockQty, 10) || 0))
  : 0;

// In JSX:
<View style={[styles.stockPreview, stockMode === 'remove' && styles.stockPreviewRemove]}>
  <Text style={[styles.stockPreviewLabel, stockMode === 'remove' && styles.stockPreviewTextRemove]}>
    After {stockMode === 'add' ? 'adding' : 'removing'}
  </Text>
  <Text style={[styles.stockPreviewQty, stockMode === 'remove' && styles.stockPreviewTextRemove]}>
    {previewStock} units
  </Text>
</View>
```

Canonical styles:
```typescript
stockPreviewRemove: { backgroundColor: '#FEF2F2' },       // soft red background
stockPreviewTextRemove: { color: '#991B1B' },              // dark red text
// (stockPreview base: backgroundColor: '#EFF6FF', color: '#1D4ED8')
```

### Segmented control

```tsx
<View style={styles.stockModeRow}>
  {(['add', 'remove'] as const).map((mode) => (
    <TouchableOpacity
      key={mode}
      style={[styles.stockModeBtn, stockMode === mode && styles.stockModeBtnActive]}
      onPress={() => { setStockMode(mode); setStockError(''); }}
    >
      <Text style={[styles.stockModeText, stockMode === mode && styles.stockModeTextActive]}>
        {mode === 'add' ? 'Add' : 'Remove'}
      </Text>
    </TouchableOpacity>
  ))}
</View>
```

Canonical styles:
```typescript
stockModeRow: { flexDirection: 'row', gap: 8, marginBottom: 16 },
stockModeBtn: { flex: 1, paddingVertical: 9, borderRadius: 8, borderWidth: 1, borderColor: '#D1D5DB', alignItems: 'center' },
stockModeBtnActive: { borderColor: '#3B82F6', backgroundColor: '#EFF6FF' },
stockModeText: { fontSize: 14, color: '#6B7280', fontWeight: '500' },
stockModeTextActive: { color: '#1D4ED8', fontWeight: '600' },
```

### Per-mode conditional fields

Render completely different blocks per mode using `{stockMode === 'add' ? <...> : <...>}`. Each block can have sub-options (source, reason) rendered as a button group or `Select`.

### Error position

Modal without a fixed `height` (auto-sizing): the error goes **inside the `ScrollView`**, right above the Cancel/Save buttons — not in a sticky footer (which requires a fixed `height` to work). See §43 for the fixed-footer variant.

### Open function (full reset)

```typescript
function openStockModal(item: Item) {
  setStockTarget(item);
  setStockMode('add');          // always starts on Add
  setStockQty('');
  setStockAddSource('purchase');
  setStockSupplier(item.last_supplier ?? '');   // prefill from the last operation when useful
  setStockTransferDate('');
  setStockRemoveReason('correction');
  setStockError('');
}
```

### Deep-link: unify `action=stock` and `action=adjust`

Both external actions (e.g. "Restock" and "Adjust" on an agenda screen) must open the same modal:

```typescript
if (action === 'stock' || action === 'adjust') {
  openStockModal(target);
} else {
  openEditModal(target);
}
```

---

## 51. `toggleCard` — three variants + canonical form order

### Variant 1 — Standalone toggle (no sub-form)

Used when the toggle does not reveal additional fields.

```tsx
<View style={styles.toggleCard}>
  <View style={styles.boolToggleRow}>
    <Text style={styles.boolToggleLabel}>Send reminders</Text>
    <TouchableOpacity
      style={[styles.boolToggleSwitch, value && styles.boolToggleSwitchOn]}
      onPress={() => setValue(!value)}
      activeOpacity={0.8}
    >
      <View style={[styles.boolToggleThumb, value && styles.boolToggleThumbOn]} />
    </TouchableOpacity>
  </View>
</View>
```

### Variant 2 — Expandable toggle (with sub-form)

Used when turning the toggle on reveals related fields. `toggleCardBody` has `borderTopWidth: 1` to visually separate the toggle from the fields.

```tsx
<View style={styles.toggleCard}>
  <View style={styles.boolToggleRow}>
    <Text style={styles.boolToggleLabel}>Requires approval document</Text>
    <TouchableOpacity ...>
      <View style={[styles.boolToggleThumb, value && styles.boolToggleThumbOn]} />
    </TouchableOpacity>
  </View>
  {value && (
    <View style={styles.toggleCardBody}>
      <DateInputWithPicker label="Document valid until" ... />
      <Input label="Warn before expiry (days)" ... />
    </View>
  )}
</View>
```

### Variant 3 — Titled card (group of related fields)

Used to group fields that have no toggle but belong to the same sub-domain (e.g. stock).

```tsx
<View style={[styles.toggleCard, { marginTop: 14 }]}>
  <Text style={styles.stockCardTitle}>STOCK</Text>
  <View style={[styles.inlineRow, { alignItems: 'flex-end' }]}>
    <View style={{ flex: 1 }}>
      <Input label="Initial" value={formInitialStock} ... />
    </View>
    <View style={{ flex: 1 }}>
      <Input label="Minimum" value={formStockAlertThreshold} ... />
    </View>
  </View>
</View>
```

`marginTop: 14` when the card immediately follows a frequency block — the `TimePickerField` has no bottom margin of its own.

### Styles

```typescript
toggleCard: {
  borderWidth: 1,
  borderColor: '#E5E7EB',
  borderRadius: 10,
  paddingHorizontal: 14,
  paddingTop: 3,
  paddingBottom: 6,
  marginBottom: 8,
  backgroundColor: '#F9FAFB',
},
toggleCardBody: {
  marginTop: 8,
  paddingTop: 12,
  borderTopWidth: 1,
  borderTopColor: '#E5E7EB',
},
stockCardTitle: {
  fontSize: 13,
  fontWeight: '600',
  color: '#6B7280',
  textTransform: 'uppercase',
  letterSpacing: 0.4,
  marginTop: 8,
  marginBottom: 4,
},
```

### Canonical field order in complex registration forms

For a rich entity form (identity + schedule + quantity + flags), order the sections by the
registrant's reasoning — *what it is → how/when it happens → how much there is → special rules*:

```
1. Identification   Name · secondary identifiers · type/unit · origin · reason
2. Schedule         Frequency (selector) + dynamic fields (times / days / condition)
3. Quantity         [Variant 3 card]  Initial (create only) · Minimum
4. Rules            [Variant 1/2 cards]  boolean behaviors, each with its sub-form
```

Write the concrete order for each such entity into the project's UX spec so create and edit stay identical (§7).

### `FieldLabel compact` after frequency selectors

`FieldLabel` without `compact` has `marginTop: 16`, which creates excessive space after the frequency-type selector. Always use `compact` on the sub-labels that appear inside the frequency section:

```tsx
<FieldLabel text="Days of the week" compact />   {/* ✓ correct */}
<FieldLabel text="Days of the week" />            {/* ✗ double margin */}
```

---

## 52. Picker input — single tappable field with a DateTimePicker modal

### The pattern

Date and time fields must be **single tappable fields** that open a modal with the native picker — never two separate HH + MM inputs, nor a directly editable `TextInput` for structured values.

Provide two shared components (e.g. in `src/components/`):
- `DateInputWithPicker` — date (in the app's display format) with a calendar icon + picker
- `TimeInputWithPicker` — time HH:MM with a clock icon + picker

### `TimeInputWithPicker` — variants

```tsx
// Compact (inside a row with other fields, no label)
<TimeInputWithPicker value={entry.time} onChange={...} compact />

// Full (standalone, with label)
<TimeInputWithPicker value={weeklyTime} onChange={...} label="Time" />
```

**`compact`:** an 82×36 `TouchableOpacity` with the value and a `clock-outline` icon. Use: the time column of a repeatable schedule row.

**Full:** a full-width `TouchableOpacity` mimicking `Input` (border, paddingHorizontal 12, height 36) with the label above and the icon on the right. The whole field is tappable — it does not use a `TextInput` with `editable={false}` because that would swallow the touch; the field is a `TouchableOpacity` with a read-only `Text`.

### Modal structure (iOS)

```tsx
<Modal visible transparent animationType="slide" onRequestClose={close}>
  <TouchableOpacity style={overlay} activeOpacity={1} onPress={close} />
  <View style={sheet}>
    <View style={toolbar}>
      <TouchableOpacity onPress={close}><Text style={cancel}>Cancel</Text></TouchableOpacity>
      <TouchableOpacity onPress={confirm}><Text style={confirmStyle}>Confirm</Text></TouchableOpacity>
    </View>
    <DateTimePicker value={pickerTime} mode="time" display="spinner" locale={APP_LOCALE} style={picker} />
  </View>
</Modal>
```

Android: `DateTimePicker display="default"` with no custom modal — it closes and commits directly in `onChange` (`if (Platform.OS === 'android') { setShow(false); if (selected) onChange(...); }`).

Web: an `Input` with a mask (`applyTimeMask` auto-inserts `:` after 2 digits — §47). There is no `DateTimePicker` on web.

### Empty initial state in create forms

Time pickers in **create** forms start at `''` — the placeholder shows `--:--`. Never `'08:00'` or any default, since that presumes the user's time.

Exception: **edit** forms pre-populate with the saved value, falling back to `'08:00'` only if the field has no value in the database.

### Auto-fill from predefined labels

When a time label (e.g. "Breakfast") is associated with a canonical time, apply the default **every time the label changes** — not only when the field is empty:

```typescript
const LABEL_DEFAULT_TIME: Record<string, string> = {
  'On waking':     '06:00',
  'Breakfast':     '07:30',
  'Before lunch':  '11:30',
  'After lunch':   '13:00',
  'Afternoon':     '15:30',
  'Dinner':        '19:00',
  'Bedtime':       '22:00',
};

// In the label picker's onPress:
const defaultTime = LABEL_DEFAULT_TIME[opt];
next[idx] = {
  ...next[idx],
  label: opt,
  time: defaultTime ?? next[idx].time,  // ?? not || — replaces the existing value
};
```

Using `??` guarantees the default wins over the previous value. The user adjusts in the picker afterwards if they want a different time. An "Other" label applies no default.

---

## 53. Footer separator, N-per-row chips and sub-picker panel

### Footer separator — fixed buttons outside the ScrollView

Every form modal must have its action buttons in a `View` **outside the `ScrollView`**, with a visual separator:

```tsx
<BottomSheetModal visible={...} onClose={...} title="...">
  <ScrollView contentContainerStyle={{ ...sheetBodyStyle, paddingBottom: 16 }}>
    {/* form fields */}
  </ScrollView>
  <View style={styles.footer}>
    <Button label="Cancel" variant="secondary" onPress={onClose} style={{ flex: 1 }} />
    <Button label="Save" onPress={handleSubmit} style={{ flex: 1 }} />
  </View>
</BottomSheetModal>
```

**Canonical footer style:**
```typescript
footer: {
  flexDirection: 'row',
  gap: 12,
  paddingHorizontal: 24,
  paddingTop: 12,
  paddingBottom: 40,        // home indicator clearance
  borderTopWidth: 1,
  borderTopColor: '#E5E7EB',
}
```

**`paddingBottom: 16` on the ScrollView** (reduced from 40): home-indicator clearance belongs to the footer, not the content. Use 40 on the ScrollView only when there is no fixed footer.

**The separator is always visible** — regardless of content length. It is a visual marker that delimits the action zone.

(Superseded in implementation by the shared `ModalFooter` — §57 — but the visual spec is the same.)

### Asterisk on required fields — `required` prop

Never embed `*` in the label text (`label="Name *"`). Use a `required` prop on every shared field component:

```tsx
<Input label="Name" required ... />
<Select label="Type" required ... />
<DateInputWithPicker label="Date" required ... />
<TimeInputWithPicker label="Time" required ... />
```

For inline labels (not via a `label` prop):
```tsx
<View style={{ flexDirection: 'row', alignItems: 'center' }}>
  <Text style={styles.fieldLabel}>Shifts covered</Text>
  <Text style={{ fontSize: 18, fontWeight: '500', color: '#374151', marginLeft: 3, transform: [{ translateY: 3 }] }}>*</Text>
</View>
```

Canonical pattern: `fontSize: 18` + `alignItems: 'center'` + `translateY: 3`. Do not add `lineHeight` to the asterisk — it changes the box and breaks the alignment. Use one visually confirmed form as the project's reference and match it everywhere.

### N-per-row chips — `flexGrow` + `flexBasis`

For N chips per row that fill the full width in a container with `flexWrap: 'wrap'`:

```typescript
// 3 chips per row:
remindChip: {
  flexGrow: 1,
  flexBasis: '30%',   // 3 × 30% = 90% < 100% → 3 fit; flexGrow fills the rest
  alignItems: 'center',
  paddingVertical: 6,
  borderRadius: 20,
  borderWidth: 1,
  borderColor: '#D1D5DB',
  backgroundColor: '#FFF',
}

// For 2 per row: flexBasis: '45%'
// For 4 per row: flexBasis: '22%'
```

This is fine for short, uniform labels (e.g. "1 day", "3 days", "7 days"). For labels of **varying length**, percentage `flexBasis` is unreliable — use the deterministic `chunkBalanced` rows of §64.

Use an explicit array (`const OPTIONS = ['a', 'b', 'c']`) to guarantee order — `Object.keys()` orders integer-like keys before string keys, breaking the intended sequence.

### Sub-picker panel — visual differentiation

When a selection panel opens **inside a modal** (e.g. a list of contacts overlaying a form), differentiate its background:

```typescript
pickerPanel: {
  position: 'absolute',
  bottom: 0, left: 0, right: 0,
  backgroundColor: '#F8FAFC',        // slightly gray vs. the parent modal's white
  borderTopLeftRadius: 16,
  borderTopRightRadius: 16,
  borderTopWidth: 1,
  borderTopColor: '#E5E7EB',
  shadowColor: '#000',
  shadowOffset: { width: 0, height: -3 },
  shadowOpacity: 0.12,               // stronger than the parent modal
  shadowRadius: 10,
  elevation: 10,
}
```

(If the parent scrolls, render this panel inside a transparent `Modal` instead of `position: 'absolute'` — §59.)

**`paddingBottom: 24` on the panel's inner ScrollView** — so the last item is not clipped by the device's rounded corners.

---

## 54. Catalog picker: accordion + form in the same modal

Use when the user picks one item from a grouped catalog (metrics, parameters, templates…) and then fills a form specific to that item.

### Flow pattern

Two-level picker with no navigation — everything inside the same `BottomSheetModal`:

```
step = 'browse'   →   accordion groups + "Recent" chips
step = 'form'     →   ItemFormContent in the same modal
```

**Transition:** tapping an item (accordion or chip) sets `selectedParam` and switches `step` to `'form'`. The modal neither closes nor opens a new one — the content swaps internally.

**Dynamic title and back button:**
```tsx
<BottomSheetModal
  title={step === 'browse' ? 'New reading' : PARAM_LABELS[selectedParam]}
  height={step === 'browse' ? '88%' : undefined}
  maxHeight={step === 'form' ? '92%' : undefined}
  leftElement={step === 'form' ? <BackBtn onPress={goBackToBrowse} /> : undefined}
>
  {step === 'browse' ? renderBrowse() : renderForm()}
</BottomSheetModal>
```

### Group accordion

A single level of expansion — `expandedGroup: string | null`. Tapping the same group collapses it.

```tsx
// One color for every group — no per-category color semantics
const GROUP_ACCENT = '#3B82F6';
const GROUP_BORDER = '#BFDBFE';

<TouchableOpacity
  style={[styles.groupWrapper, { borderLeftColor: GROUP_ACCENT }]}
  onPress={() => setExpandedGroup(isExpanded ? null : group.label)}
>
  <Text style={[styles.groupName, { color: GROUP_ACCENT }]}>{group.label}</Text>
  <Text style={[styles.groupChevron, isExpanded && styles.groupChevronExpanded]}>›</Text>
</TouchableOpacity>

{isExpanded && (
  <View style={[styles.paramList, { borderTopColor: GROUP_BORDER }]}>
    {group.params.map(param => (
      <TouchableOpacity style={styles.paramRow} onPress={() => selectParam(param)}>
        <Text style={styles.paramRowText}>{PARAM_LABELS[param]}</Text>
      </TouchableOpacity>
    ))}
  </View>
)}
```

**Color rule:** use one color for all groups. 8 groups with 8 distinct colors are decoration without semantics — the accordion already provides enough visual separation. (Contrast with §29's full-screen grid, where distinct card colors help scanning large tiles.)

### `ItemFormContent` — component with an imperative handle

When the form for an item is complex (many states, multiple fields) and must be driven by the parent (to validate and save), use `forwardRef + useImperativeHandle`:

```tsx
export interface ItemFormHandle {
  buildValue(): Record<string, unknown> | null;
  validate(): string | null;  // null = valid; string = specific error message
  reset(): void;
}

export const ItemFormContent = forwardRef<
  ItemFormHandle,
  { param: string }
>(({ param }, ref) => {
  // per-item local state
  useImperativeHandle(ref, () => ({ buildValue, validate, reset }));
  return <>{renderForm()}</>;
});
```

**In the parent screen:**
```tsx
const formRef = useRef<ItemFormHandle>(null);

async function handleSave() {
  const error = formRef.current?.validate();
  if (error) { setFormError(error); return; }
  const value = formRef.current?.buildValue() ?? null;
  if (!value) return;
  await createReading.mutateAsync({ ..., value });
}

// When going back to browse:
function goBackToBrowse() {
  formRef.current?.reset();
  setSelectedParam(null);
  setStep('browse');
}
```

### `validate()` — specific messages per item

Instead of a generic message ("fill at least one field"), expose `validate()` with precise messages:

```typescript
function validate(): string | null {
  switch (param) {
    case 'DIMENSIONS':
      if (!width && !height) return 'Fill in width and height before saving.';
      if (!width) return 'Fill in the width before saving.';
      if (!height) return 'Fill in the height before saving.';
      return null;
    default:
      return buildValue() === null ? 'Fill in the field before saving.' : null;
  }
}
```

### Catalog curation rule — measurement vs. event

Before adding an item to a "measurements" catalog, check that it really is one:

> **Measurement** = a value or state that is measured/assessed. It has a scale or magnitude.
> **Event / incident** = something that happened. It has no value — it has a description, a severity and someone who must act.

Items that look like measurements but are events belong in the incidents module, not the catalog.
**Practical criterion:** if the user needs to notify the team about the fact, it is an incident. If it is a number or level for the history, it is a measurement. Prefixes like "sudden …" are a strong signal of an event, not a monitorable state.

### `required` in internal sub-components

Local sub-components (`FieldLabel`, `BoolToggle`, `StyledInput`) must follow the same pattern as the shared `Input`:

```typescript
// labelRow — same as Input.tsx
labelRow: { flexDirection: 'row', alignItems: 'center', marginBottom: 4 },
label:    { fontSize: 14, fontWeight: '500', color: '#374151', lineHeight: 20 },
asterisk: { fontSize: 18, fontWeight: '500', color: '#374151', marginLeft: 3, transform: [{ translateY: 3 }] },
```

**`BoolToggle` with `required`:** wrap the text in a `View flex:1 flexDirection:'row'` to keep the label + buttons layout:

```tsx
<View style={styles.boolRow}>
  <View style={styles.boolLabelWrap}>   {/* flex: 1, flexDirection: 'row', alignItems: 'center' */}
    <Text style={styles.boolLabel}>{label}</Text>
    {required && <Text style={styles.asterisk}>*</Text>}
  </View>
  <View style={styles.boolOptions}>...</View>
</View>
```

Remove `flex: 1` from `boolLabel` — the `flex: 1` moves to the wrapper.

---

## 57. ModalFooter — canonical modal footer component

**Absolute rule:** every bottom-sheet modal with action buttons uses `<ModalFooter>`. Using `<View style={styles.footer}>` with inline buttons is forbidden — that is exactly the technical debt the component eliminates.

```typescript
import { ModalFooter } from '@/components/ModalFooter';

<ModalFooter error={error} onDismissError={() => setError('')}>
  <Button label="Cancel" variant="secondary" style={{ flex: 1 }} onPress={close} />
  <Button label="Save"   style={{ flex: 1 }} onPress={submit} loading={isPending} />
</ModalFooter>
```

**Props:**
| Prop | Type | When to use |
|---|---|---|
| `children` | `ReactNode` | Action buttons (any combination) |
| `error` | `string \| undefined` | Error message — hidden when empty |
| `onDismissError` | `() => void \| undefined` | When provided, shows a ✕ to dismiss the error |

**When to omit `onDismissError`:** validation errors (required field, invalid format) should have the ✕. Generic API errors may optionally omit it (the error disappears on the next submit).

**What the component encapsulates:**
- Border-top `#E5E7EB`
- Padding `24 × 12 × 40` (horizontal × top × bottom — 40 for the home indicator)
- Error row: background `#FEE2E2`, flex layout with text + ✕ (§38)
- Button row: `flexDirection: 'row', gap: 12`

---

## 55. FieldLabel — shared component

**Rule:** labels outside `<Input>`, `<Select>`, `<DateInputWithPicker>` and `<TimeInputWithPicker>` use **exclusively** the shared `<FieldLabel>` component (§37). No local copies.

```typescript
import { FieldLabel } from '@/components/FieldLabel';

<FieldLabel text="Frequency" required />
<FieldLabel text="Days of the week" compact />   // compact suppresses marginTop: 16
```

**Props:**
| Prop | Type | Default | When to use |
|---|---|---|---|
| `text` | `string` | required | — |
| `required` | `boolean` | `false` | Adds the `*` next to it |
| `compact` | `boolean` | `false` | Suppresses `marginTop: 16` — use right after type selectors/pickers |

**Canonical asterisk style** (do not change):
```typescript
{ fontSize: 18, fontWeight: '500', color: '#374151', marginLeft: 3, transform: [{ translateY: 3 }] }
// NO lineHeight — adding it breaks the alignment
```

---

## 56. Navigation — always through a coordinator hook (`useAppNav()`)

**Absolute rule:** no screen imports `useRouter` from Expo Router directly. All navigation code goes through a typed coordinator hook (e.g. `useAppNav()`), which builds URLs (including deep-link params like `action`, `t`, `returnTo`) in one place.

```typescript
// ❌ NEVER in screens
import { useRouter } from 'expo-router';

// ✅ ALWAYS
import { useAppNav } from '@/navigation/useAppNav';
const nav = useAppNav();
nav.goToProjectOrders(projectId, { orderId, action: 'edit' });
```

See the `expo-router` skill for the coordinator pattern and its full method list.

---

## 58. Entity picker — controlled selection with "not registered" (external) support

Pattern for picking a related entity (a contact, supplier, professional, assignee…) that may or may
not be registered in the app. It replaces 3–6 local states + 80+ lines of JSX per screen with a
single controlled value. Example name: `ContactPicker`.

### Controlled type

```typescript
export interface ContactPickerValue {
  contactId: string | null;  // UUID of the registered contact; null if external
  contactName: string;       // name filled by the system or typed by the user
  role: string;              // secondary attribute (e.g. specialty / company)
  isExternal: boolean;       // true = "Other (not registered)"
}

export const emptyContactPicker: ContactPickerValue = {
  contactId: null, contactName: '', role: '', isExternal: false,
};
```

### Basic usage

```typescript
const [contactPicker, setContactPicker] = useState<ContactPickerValue>(emptyContactPicker);

// In JSX:
<ContactPicker
  scopeId={projectId}
  label="Requested by"
  value={contactPicker}
  onChange={setContactPicker}
/>

// In the submit DTO:
contact_id:   contactPicker.contactId ?? undefined,
contact_name: contactPicker.contactName.trim() || undefined,
```

### Initialization in openEdit

```typescript
// Entity with a contact_id FK + free-text contact_name:
setContactPicker(
  rec.contact_id
    ? { contactId: rec.contact_id, contactName: rec.contact_name ?? '', role: '', isExternal: false }
    : rec.contact_name
    ? { contactId: null, contactName: rec.contact_name, role: '', isExternal: true }
    : emptyContactPicker
);

// Entity with only a free-text name column:
setOwnerPicker(
  rec.owner_name
    ? { contactId: null, contactName: rec.owner_name, role: '', isExternal: true }
    : emptyContactPicker
);
```

### Relevant props

| Prop | Default | Use |
|---|---|---|
| `panelTitle` | generic (e.g. `'Contact'`) | Distinguish two pickers of the same kind on one form (e.g. `panelTitle="Owner"` vs `"Reviewer"`) |
| `showRole` | `false` | Shows the secondary-attribute field for externals |
| `onPickRegistered` | — | Autofill other fields: `(c) => { if (c.address) setLocation(c.address); }` |
| `required` | `false` | Adds `*` to the label |

### Name consistency between create and reload

When a registered entity is selected, save its **name together with the id** (`contact_name = c.full_name` alongside `contact_id`). This avoids a join with the related table on edit/reload and keeps the label stable:

```typescript
// Correct — saves the name with the ID:
contact_id:   picker.contactId ?? undefined,
contact_name: picker.contactName.trim() || undefined,

// Wrong — saving only the ID forces the reload to look up the name:
contact_id: picker.contactId ?? undefined,
```

---

## 59. Picker inside a ScrollView/BottomSheetModal — use `Modal transparent`, not `position: absolute`

### Problem

`position: absolute` inside a `ScrollView` is **relative to the scrollable content**, not the screen. An absolutely positioned panel inside a `BottomSheetModal` with a scrolling body appears in the middle of the form, not at the bottom of the screen.

### Root cause

The `ScrollView` creates a scroll context with `overflow: scroll`. Any child with `position: absolute` anchors to the top of the content — which may be hundreds of pixels beyond the top of the viewport. Its appearance changes as you scroll.

### Correct solution

Use `<Modal visible={open} transparent animationType="slide">` for the picker. A `Modal` is rendered outside the `View` tree — no scroll, no overflow, always at the screen root.

```typescript
// ❌ NEVER — inside a ScrollView or another Modal via position:absolute
{open && (
  <>
    <TouchableOpacity style={{ position: 'absolute', top: 0, left: 0, right: 0, bottom: 0 }}
      onPress={() => setOpen(false)} />
    <View style={{ position: 'absolute', bottom: 0, left: 0, right: 0, ... }}>
      {/* panel */}
    </View>
  </>
)}

// ✅ ALWAYS — a transparent Modal escapes any parent ScrollView
<Modal
  visible={open}
  transparent
  animationType="slide"
  onRequestClose={() => setOpen(false)}
>
  {/* Overlay fills the upper space and closes on tap */}
  <TouchableOpacity
    style={{ flex: 1, backgroundColor: 'rgba(0,0,0,0.35)' }}
    activeOpacity={1}
    onPress={() => setOpen(false)}
  />
  {/* Panel — no position:absolute, anchored to the bottom by flex */}
  <View style={panelStyles}>
    {/* header + list */}
  </View>
</Modal>
```

### Why it works

A `Modal` with `transparent` creates a new rendering context over the whole UI. The `TouchableOpacity flex:1` pushes the panel `View` to the bottom of the screen via flexbox — no dependence on absolute coordinates.

### Canonical styles

```typescript
overlay: {
  flex: 1,
  backgroundColor: 'rgba(0,0,0,0.35)',
},
panel: {
  backgroundColor: '#F8FAFC',
  borderTopLeftRadius: 16,
  borderTopRightRadius: 16,
  borderTopWidth: 1,
  borderTopColor: '#E5E7EB',
  shadowColor: '#000',
  shadowOffset: { width: 0, height: -3 },
  shadowOpacity: 0.12,
  shadowRadius: 10,
  elevation: 10,
  // NO position: absolute, NO fixed bottom/left/right
},
```

### When to use `position: absolute` vs `Modal transparent`

| Situation | Use |
|---|---|
| Picker inside a `ScrollView` or `BottomSheetModal` | `Modal transparent` |
| Picker inside a `View` that has **no** scrolling parent | `position: absolute` (§16) |
| Two stacked `Modal`s (react-native-web) | `position: absolute` in the parent Modal (§16 — acrobatic, avoid) |

Apply it in every shared picker component (`DateInputWithPicker`, `TimeInputWithPicker`, entity pickers like §58).

---

## 60. `returnTo` — go back to the caller after a deep-link edit

When a card on an aggregator screen (e.g. the agenda, §31) opens a module's edit modal via deep-link (§32), closing it (save or cancel) must bring the user back to the aggregator — not leave them on the module screen.

(Prefer §69/§70 — opening the module's modal in place on the caller screen — when the modal can be reused; `returnTo` is for when it can't.)

### Implementation

**NavOpts:** add `returnTo?: 'todo'` (or a union of caller keys) to each module's navigation options interface.

**Navigation coordinator:** include `returnTo` in the URL:
```typescript
if (opts.returnTo) parts.push(`returnTo=${opts.returnTo}`);
```

**Caller (aggregator screen):** pass `returnTo: 'todo'` only on the "Edit" buttons:
```typescript
nav.goToProjectOrders(projectId, { orderId: o.id, action: 'edit', returnTo: 'todo' })
```

**Module screen (callee):** `shouldReturnToCaller` ref pattern:
```typescript
const { orderId, action, t, returnTo } = useLocalSearchParams<{ ...; returnTo?: string }>();
const nav = useAppNav();
const shouldReturnToCaller = useRef(false);

// In the modal auto-open useEffect:
shouldReturnToCaller.current = returnTo === 'todo';  // set ONLY here

function handleEditClose() {
  const goBack = shouldReturnToCaller.current;
  shouldReturnToCaller.current = false;   // immediate reset
  setEditingItem(null);
  if (goBack) nav.goToProjectTodo(projectId);
}
```

### Rules

- The ref is set ONLY in the deep-link `useEffect` — if the user later opens the modal manually, `shouldReturnToCaller` stays `false`
- `handleEditClose` replaces every occurrence of `setModal(false)` / `setEditItem(null)` for that modal (`onClose` prop, Cancel button, mutation `onSuccess`)
- Do not use `returnTo` on secondary actions like "Schedule" or "Complete" — only on "Edit"

---

## 61. Agenda card — inline badge next to the title + due date with countdown

### Inline badge next to the name

To place status badges (`Requested`, `Scheduled`) on the same line as the title, without pushing the `typeTag` (§31):

```tsx
<View style={styles.cardTitleRow}>
  <View style={{ flex: 1, flexDirection: 'row', flexWrap: 'wrap', alignItems: 'center', columnGap: 6, rowGap: 2 }}>
    <Text style={[styles.cardTitle, { flex: 0, flexShrink: 1 }]}>{name}</Text>
    {isRequested && <Badge label="Requested" variant="warning" />}
    {isScheduled && <Badge label="Scheduled" variant="primary" />}
  </View>
  <Text style={styles.typeTag}>MODULE</Text>
</View>
```

`flex: 0, flexShrink: 1` on the text lets it shrink without taking all the space. `flexWrap: 'wrap'` makes the badge wrap to the next line if the name is very long.

### Due date with countdown

Pure helper (no timezone math) to compute days from today:

```typescript
function daysFromToday(isoDate: string, today: string): number {
  const [ty, tm, td] = today.split('-').map(Number);
  const [vy, vm, vd] = isoDate.substring(0, 10).split('-').map(Number);
  return Math.round((Date.UTC(vy, vm-1, vd) - Date.UTC(ty, tm-1, td)) / 86_400_000);
}
```

Render (only when the item is requested and the date is available):
```tsx
{isRequested && item.requested_date && (() => {
  const days = daysFromToday(item.requested_date, today);
  const suffix = days === 0
    ? 'today'
    : days > 0 ? `in ${days} day${days !== 1 ? 's' : ''}`
    : `${-days} day${-days !== 1 ? 's' : ''} ago`;
  return (
    <Text style={styles.cardDetail}>
      Due {formatDate(item.requested_date)} ({suffix})
    </Text>
  );
})()}
```

`today` must be computed once at the screen root in the **user's timezone**:
`new Date().toLocaleDateString('sv-SE', { timeZone: tz })` with `tz = useUserTimezone()` (§10b) — never
a hardcoded zone and never `new Date().toISOString().slice(0, 10)` (that is the UTC day).

---

## 62. Floating "back to top" button — long lists with infinite scroll

Screens with a long, infinitely-scrolling list (history, logs, feeds…) need a quick way back to
the top without dragging repeatedly.

### When to use

Any `ScrollView`/list whose content grows without bound (cursor pagination). Do not use it on
short lists that already fit on screen.

### Pattern

A floating circular, **secondary** button (gray, smaller than the primary FAB) that only appears
after the user scrolls past a threshold — never visible with the list at the top, so it doesn't
add noise when it isn't useful.

Use a single shared `ScrollTopButton` component — don't reimplement it locally (it tends to get
copy-pasted almost identically into every list screen before being extracted):

```tsx
import { ScrollTopButton } from '@/components/ScrollTopButton';

const mainScrollRef = useRef<ScrollView>(null);
const [showScrollTop, setShowScrollTop] = useState(false);

<ScrollView
  ref={mainScrollRef}
  onScroll={(e) => {
    setShowScrollTop(e.nativeEvent.contentOffset.y > 500);
    // ...other onScroll logic (e.g. fetchNextPage for infinite scroll)
  }}
  scrollEventThrottle={200}
>
  {/* ...content... */}
</ScrollView>

{showScrollTop && (
  <ScrollTopButton onPress={() => mainScrollRef.current?.scrollTo({ y: 0, animated: true })} />
)}
```

`ScrollTopButton` renders an `ArrowUpIcon` (vector SVG from the icon kit), not a "↑" text
glyph — same reason the FAB uses a vector plus icon (§2): an isolated text symbol suffers from the
custom font's baseline/ascent asymmetry.

### Position — mirrors the FAB, never stacks

When the screen already has a primary FAB (§2, `bottom: 24, right: 24`), the back-to-top button
goes in the **opposite** corner (`bottom: 24, left: 24`) — never stacked above the FAB. This keeps
visual symmetry and avoids two targets competing for the same thumb zone.
Fixed position inside the component itself (`colors.textMuted` — gray, secondary, never the FAB's
primary color), `width/height: 48` (smaller than the 56 FAB — reinforces the secondary hierarchy).

**500px threshold:** enough not to flicker on short screens with a little scroll, but early
enough to appear before the user loses patience dragging manually.

**Why not tap-the-status-bar (the iOS convention):** it only works on native iOS — there is no
equivalent on Android or on web (react-native-web). The floating button is the only solution that
works the same on all three platforms.

### Mandatory `paddingBottom` — floating buttons cover the end of the list

Every screen with a FAB (`bottom:24 right:24`) and/or this back-to-top button
(`bottom:24 left:24`) must reserve empty space at the end of the list's `contentContainerStyle`
— otherwise, when scrolling to the end, the **last card rises until it sits under the floating
buttons**, hiding or covering that card's action buttons.

```typescript
listContent: { paddingHorizontal: 16, paddingBottom: 88, flexGrow: 1 },
```

`88` is the canonical value — it covers the FAB's height (56) + its offset (24) with 8px of extra
slack. Always use this exact value on every screen with a FAB, not an approximate number —
inconsistency between screens is itself a polish bug (a typical regression: most screens with `88`
and one with `32`, clipping the last card).

### Never use `gap` on a container of `Card`s

If the shared `Card` component already embeds `marginBottom: 12`, and the list container also
has `gap: 12` in `contentContainerStyle`, the two add up — the real spacing becomes 24px, double
the standard seen on every other screen that uses `Card` without an extra `gap`.

```typescript
// ❌ gap + Card's marginBottom add up → 24px between cards, off-standard
listContent: { padding: 16, gap: 12, flexGrow: 1 },

// ✅ Card already handles spacing — nothing extra on the container
listContent: { padding: 16, paddingBottom: 88, flexGrow: 1 },
```

---

## 63. Optional notes (`notes`) on every enum group — always or conditional

Any form field that is fundamentally a categorical choice (enum) gets an optional free-text
"Notes" field right below it, for the case where the category alone doesn't describe everything
the user wants to record ("Poor" doesn't say *why*).

### Two variants — always visible vs. conditional

| Situation | Behavior |
|---|---|
| The field itself is optional, or it is the only input on the screen | Notes **always visible** below the option group |
| The field is a required `BoolToggle` where "No" produces no record (`buildValue` returns `null` when false) | Notes render only **after "Yes" is selected** — showing it before is noise, since there is nothing to annotate about an event that didn't happen |

```tsx
// Always-visible variant — continuous states (quality, level, condition…)
<FieldLabel text="Quality" required />
<EnumButtons options={Object.values(Quality)} labels={QUALITY_LABELS} value={quality} onChange={setQuality} fillLine />
<StyledInput label="Notes" value={qualityNotes} onChangeText={setQualityNotes} placeholder="How was the quality?" multiline />

// Conditional variant — yes/no events (required BoolToggle)
<BoolToggle label="Was there a delay?" value={hadDelay} onChange={setHadDelay} required />
{hadDelay && (
  <StyledInput label="Notes" value={delayNotes} onChangeText={setDelayNotes} placeholder="When did it happen, what was going on..." multiline />
)}
```

### Placeholder — a contextual question, never generic

**Never** use `"Details..."` as a placeholder — it's lazy and doesn't guide the user on
what to write. Phrase it as a natural question specific to the field:

```
✅ "How is the mood today?"             (a continuously varying state)
✅ "How was the night?"                  (a state over a period)
✅ "What did you notice about X?"        (an observation being reported, not a state)
✅ "Anything to highlight about X?"      (open question where "how is" isn't natural)
❌ "Details..."
❌ "Details about X..."                  (functional but mechanical — prefer a question)
```

Rule for picking the question: `"How is/was the X?"` for states that vary continuously;
`"What did you notice about X?"` for assessments where the user is reporting an observation;
`"Anything to highlight about X?"` for fields with no natural "how is" (e.g. meals, deliveries).

### `buildValue` — never send an empty string

```typescript
return { level: quality, ...(qualityNotes.trim() ? { notes: qualityNotes.trim() } : {}) };
```

`notes` only goes into the object if there is real content after `trim()` — avoids saving
`notes: ""` in the database, which would pollute the card with an empty "Notes" row.

### List card — don't forget to read `value.notes`

When adding Notes to a field, it's easy to forget to update the list card's display `switch`
to show them — the field saves correctly in the database but stays invisible on screen until
someone adds the `v(obs, 'notes')` read to that item's branch. **Always update both places
together**, never just the form:

```tsx
} else if (p === 'QUALITY') {
  const level = v(obs, 'level') as Quality | undefined;
  if (level) rows.push({ label: 'Quality', value: QUALITY_LABELS[level] ?? level });
  const notes = v(obs, 'notes') as string | undefined;
  if (notes) rows.push({ label: 'Notes', value: notes });   // ← easy to forget
}
```

---

## 64. Balanced `EnumButtons` — `fillLine` + `maxPerRow` (chunkBalanced)

When a button group (`EnumButtons`, see §46) has options whose text varies a lot in length
(e.g. "Great" vs "Very poor"), natural flexbox wrapping leaves an orphan button alone on a line,
small and misaligned with the rest of the group.

### The solution that does NOT work — percentage `flexBasis`

A first attempt is to give the buttons `flexGrow: 1, flexBasis: '30%'`, hoping the percentage
forces a predictable N-per-row wrap. **It is not reliable** — the result depends on the
container's real runtime width (which varies by device), so the same code can produce 4+1 on one
screen and 3+2 on another. Abandon it.

### The solution that works — deterministic chunking in code

```typescript
// Split into rows of at most `maxPerRow` items, with balanced sizes
// (e.g. 5 items, max 3 → [3, 2] — never a single item on its own row).
function chunkBalanced<T>(items: T[], maxPerRow: number): T[][] {
  const rows = Math.max(1, Math.ceil(items.length / maxPerRow));
  const base = Math.floor(items.length / rows);
  const remainder = items.length % rows;
  const chunks: T[][] = [];
  let idx = 0;
  for (let r = 0; r < rows; r++) {
    const size = base + (r < remainder ? 1 : 0);
    chunks.push(items.slice(idx, idx + size));
    idx += size;
  }
  return chunks;
}
```

Each row becomes its own `View` with `flexDirection: 'row'` — since it only contains that
row's items, `flexGrow: 1` on the buttons always splits 100% of **that row's** width among them,
without depending on a precomputed percentage. Deterministic on any screen size.

```tsx
function EnumButtons<T extends string>({ options, labels, value, onChange, fillLine, maxPerRow }: {
  options: T[]; labels: Record<T, string>; value: T | null; onChange: (v: T) => void;
  fillLine?: boolean; maxPerRow?: number;
}) {
  if (fillLine) {
    const rows = chunkBalanced(options, maxPerRow ?? options.length);
    return (
      <View style={styles.enumFillContainer}>
        {rows.map((row, i) => (
          <View key={i} style={styles.enumFillRow}>
            {row.map((opt) => renderBtn(opt, styles.enumBtnFillLine, styles.enumBtnTextFillLine))}
          </View>
        ))}
      </View>
    );
  }
  return <View style={styles.enumRow}>{options.map((opt) => renderBtn(opt))}</View>;
}
```

```typescript
enumFillContainer: { gap: 8, marginBottom: 16 },
enumFillRow: { flexDirection: 'row', gap: 8 },
enumBtnFillLine: { flexGrow: 1, alignItems: 'center' },   // do NOT use `flex: 1` — see below
enumBtnTextFillLine: { textAlign: 'center' },
```

### `maxPerRow` — when to omit vs. specify

| Case | `maxPerRow` |
|---|---|
| Options fit on one line without squeezing (e.g. 4 short options) | Omit — default is `options.length`, a single stretched line |
| 5 options of moderate length | `3` → wraps 3+2 |
| Long labels that would squeeze in a larger fraction (multi-word labels) | `2` → wraps in pairs, each with more room |

### Fixed bug — `flex: 1` breaks long words

`flex: 1` is shorthand for `flexGrow: 1, flexShrink: 1, flexBasis: 0%` — the `flexShrink: 1`
lets the button shrink **below** its own text size, forcing a mid-word break
("Excellent" → "Excellen" / "t" on two lines).

```typescript
// ❌ flex:1 forces equal width for all, ignores content — breaks long words
enumBtnFillLine: { flex: 1, alignItems: 'center' },

// ✅ pure flexGrow — flexBasis:'auto' (content size) + flexShrink:0 (RN default,
//    never shrinks below the text) — grows to fill leftover space, never squashes
enumBtnFillLine: { flexGrow: 1, alignItems: 'center' },
```

### Shared component — `EnumButtonGroup`

Extract it to a shared `EnumButtonGroup` component once more than one screen needs it. When every
call site uses `fillLine`, drop the prop (always balanced by row). Signature:
`<EnumButtonGroup options={} labels={} value={} onChange={} maxPerRow={} />`. Any new single-choice
button group must import from there — never recreate `chunkBalanced` locally in a screen.

---

## 65. Tri-state `BoolToggle` — never pre-selected (extension of §46)

Rule §46 ("Selection groups — no default pre-selection") covers `EnumButtons`, but the same
problem exists in any Yes/No pair: if the initial state is `boolean` (`false` by default), the
"No" button appears visually checked before the user touches anything — a false sense of a choice
made, and it masks required fields that haven't actually been answered yet.

```tsx
// ❌ value: boolean — "No" is born checked (useState(false))
function BoolToggle({ value, onChange }: { value: boolean; onChange: (v: boolean) => void }) {
  return (
    <TouchableOpacity style={[styles.boolOption, value && styles.boolOptionActive]} onPress={() => onChange(true)}>
      <Text>Yes</Text>
    </TouchableOpacity>
    // ...
    <TouchableOpacity style={[styles.boolOption, !value && styles.boolOptionActive]} onPress={() => onChange(false)}>
      <Text>No</Text>
    </TouchableOpacity>
  );
}

// ✅ value: boolean | null — no button checked until the user taps
function BoolToggle({ value, onChange }: { value: boolean | null; onChange: (v: boolean) => void }) {
  return (
    <TouchableOpacity style={[styles.boolOption, value === true && styles.boolOptionActive]} onPress={() => onChange(true)}>
      <Text>Yes</Text>
    </TouchableOpacity>
    // ...
    <TouchableOpacity style={[styles.boolOption, value === false && styles.boolOptionActive]} onPress={() => onChange(false)}>
      <Text>No</Text>
    </TouchableOpacity>
  );
}
```

`onChange` still receives only `boolean` (`true`/`false`) — only the input `value` becomes
tri-state. The corresponding state always starts as `useState<boolean | null>(null)`, including in
the form's `reset()`.

**Zero change in validation behavior:** fields that already treated `false` as "not filled"
(`hadDelay ? {...} : null` in `buildValue`) keep working the same — `null` and `false` are both
falsy in the `if`. The change is purely visual.

---

## 66. Accordion in a modal — scroll-to-reveal + reset when returning from a child step

Complements the accordion picker of §30/§54: when the user expands a group whose content goes past
the visible viewport, the screen must scroll by itself to reveal the bottom of the expanded
content — without requiring the user to drag manually to confirm it opened.

### Measure and scroll after the layout settles

```typescript
const scrollRef = useRef<ScrollView>(null);
const scrollY = useRef(0);
const groupRefs = useRef<Record<string, View | null>>({});

function scrollToRevealGroup(label: string) {
  setTimeout(() => {   // wait for the accordion to expand in the layout before measuring
    const groupEl = groupRefs.current[label];
    const scrollEl = scrollRef.current;
    if (!groupEl || !scrollEl) return;
    groupEl.measure((_x, _y, _w, groupHeight, _px, groupPy) => {
      (scrollEl as unknown as View).measure((_x2, _y2, _w2, viewportHeight, _px2, scrollPy) => {
        const groupTopInScroll = scrollY.current + (groupPy - scrollPy);
        const groupBottomInScroll = groupTopInScroll + groupHeight;
        const viewportBottom = scrollY.current + viewportHeight;
        if (groupBottomInScroll > viewportBottom) {
          const target = groupBottomInScroll - viewportHeight + 16;   // 16px breathing room
          scrollEl.scrollTo({ y: Math.max(0, target), animated: true });
        }
      });
    });
  }, 150);
}

function toggleGroup(label: string) {
  const opening = expandedGroup !== label;
  setExpandedGroup(opening ? label : null);
  if (opening) scrollToRevealGroup(label);
}
```

Same double-`measure()` formula as §49 (card scroll-to-top), adapted to reveal the **bottom**
instead of the top: it only scrolls if `groupBottomInScroll > viewportBottom` — if the group
already fits entirely on screen, the scroll is left alone.

### Bug: returning from a child step remounts the ScrollView from scratch

When the modal toggles between a "browse" step (list + accordion) and a "form" step (form for a
selected item) via conditional rendering (`modalStep === 'browse' ? renderBrowse() : renderForm()`),
the "browse" `ScrollView` **unmounts completely** when moving to the form — and remounts from
scratch (offset 0) on return. `expandedGroup` (parent state, not `ScrollView` state) stays set, but
the scroll position that revealed the group's bottom is lost — the user comes back and sees only
the top of the list, with the expanded group "cut off" outside the viewport.

```typescript
// Redo the scroll-to-reveal whenever returning to 'browse' with a group already expanded —
// the real ScrollView is always at offset 0 at that point (it has just remounted).
useEffect(() => {
  if (modalStep !== 'browse' || !expandedGroup) return;
  scrollY.current = 0;
  scrollToRevealGroup(expandedGroup);
  // eslint-disable-next-line react-hooks/exhaustive-deps
}, [modalStep]);
```

**Why the `!expandedGroup` guard matters:** the same effect also fires on the modal's initial
open (`modalStep` becomes `'browse'` on first mount) — in that case `expandedGroup` is `null`
(reset by `openModal()`), so the guard prevents an unwanted scroll right on opening.

---

## 67. Card footer with two mutually exclusive states — left/right slots

When a card has a transition action on the left (e.g. a "Mark as resolved" button)
and a status badge on the right (e.g. "Resolved"), and **the two never appear together**
(the action only exists while the status hasn't been reached), the naive approach is to make the
whole `View` conditional on there being content — but that breaks right alignment when
only the badge is present.

### The problem

```tsx
// ❌ With justifyContent:'space-between' and only 1 child rendered, that child
// goes to the START of the line, not the end — space-between distributes space
// BETWEEN items; with only one, there is no "between" to distribute.
<View style={{ flexDirection: 'row', justifyContent: 'space-between' }}>
  {!resolved && canResolve && <Button label="Mark as resolved" />}
  {resolved && <Badge label="Resolved" />}
</View>
```

### The solution — two slots always present, conditional content inside

```tsx
<View style={styles.cardFooter}>
  <View>
    {!item.resolved_at && canResolve ? (
      <Button label="Mark as resolved" size="sm" variant="primary" onPress={...} />
    ) : item.resolved_at ? (
      <Badge label="Resolved" variant="success" />
    ) : null}
  </View>
  <Badge label={SEVERITY_LABEL[item.severity]} variant={SEVERITY_VARIANT[item.severity]} />
</View>
```

```typescript
cardFooter: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', marginTop: 12 },
```

The left slot's `<View>` is always rendered (even empty) — this guarantees `space-between` always
has two real children to distribute space between, so the second element (the severity badge,
always present) stays anchored to the right regardless of whether the left slot has content.

**When a status badge occupies the same slot as the action button** (like "Resolved" taking the
place of "Mark as resolved" once resolved), putting it in the left slot — not the right one next to
the badge that already lives there — makes it visually clear that both represent the same "row
state", never coexisting.

---

## 68. Card pattern: inline badge + edit at the top + trash at the bottom

Canonical card for every module with CRUD:

- **Title + status badge**: same line, side by side (not on separate lines nor with the badge
  pushed to the opposite corner) — `flexDirection: 'row', flexWrap: 'wrap',
  alignItems: 'center', columnGap: 6, rowGap: 2`, title with `flex: 0, flexShrink: 1`
  to allow wrapping on long names without squashing the badge (same as §61).
- **Edit icon** (`square-edit-outline`, `size={20}`, `#3B82F6`): top-right corner of the
  `cardHeader`, never a text "Edit" button.
- **Trash icon** (`trash-can-outline`, `size={23}`, `#9CA3AF`): bottom-right corner of
  `cardActions`, isolated — never next to the pencil, never competing for space with the primary
  action buttons. (Delete confirmation flow: §48.)

### Pushing the trash to the right corner — `marginLeft:'auto'`, not a `flex:1` spacer

Two techniques look equivalent but **are not** when the container has `flexWrap: 'wrap'`:

```tsx
// ❌ Explicit spacer — behavior diverges from marginLeft:'auto' when the
// line wraps (flexWrap:'wrap'); a real cause of misalignment between modules
// that appeared to use "the same" code.
<View style={{ flex: 1 }} />
<TouchableOpacity onPress={...}><Icon .../></TouchableOpacity>

// ✅ marginLeft:'auto' on the element itself — same technique in every module
<TouchableOpacity style={styles.pushRight} onPress={...} hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}>
  <MaterialCommunityIcons name="trash-can-outline" size={23} color="#9CA3AF" />
</TouchableOpacity>
```

```typescript
pushRight: { marginLeft: 'auto' },
```

Standardize on `pushRight` (or a shared `cardStyles.pushRight`) in every file that has a
trash/secondary action at the end of a button row — never reintroduce the spacer.

### `alignItems: 'center'` mandatory on `cardActions`

Without it, the container uses `stretch` (the flexbox default) and the icon — which has no fixed
height of its own like `Button` — is anchored to the top of the row instead of vertically centered
with the buttons beside it:

```typescript
cardActions: { flexDirection: 'row', gap: 8, marginTop: 10, flexWrap: 'wrap', alignItems: 'center' },
```

### Size calibration across different glyphs

MaterialCommunityIcons icons don't have the same "visual weight" at the same numeric `size`
— `trash-can-outline` looks visibly smaller than `square-edit-outline` at the same size, because
of how each glyph fills its own square. Calibration: edit `size={20}`, trash `size={23}`
(~15% larger) so both read as "the same size" to the eye. Adjust both together if recalibrating —
never only one.

Use the same three values (`pushRight`, `alignItems:'center'`, sizes 20/23) on every CRUD card.

---

## 69. Standalone create modal — invoked from another screen, without navigating

When screen A needs to offer "create a module-B item" (e.g. an agenda FAB menu offering
"New appointment"), **do not navigate to screen B just to open its create modal.** Navigating
renders the whole screen (list, tabs, local FAB) only for it to be covered by the modal a moment
later — no value, and it causes a flash of the wrong screen behind the modal (even with
`useLayoutEffect` — see the `expo-router` skill — the flash gets smaller but doesn't go away,
because the screen behind always exists).

**Extension of the inline pattern (§27) to full popups.** §27 already solves this for *status
transitions* of an existing item (inline form inside the card, never a modal, never navigation) —
transition-form components extracted to `src/features/<module>/` and rendered directly on the
calling screen. *Creating* a new item needs a bigger form (a full `BottomSheetModal`, not an inline
card) — same idea, different shape:

```tsx
// src/features/orders/OrderCreateModal.tsx
interface Props {
  projectId: string;
  mode: 'requested' | 'scheduled';   // when the module distinguishes stages
  onDone: () => void;                // success — only closes the local modal
  onCancel: () => void;              // cancel/✕ — only closes the local modal
}

export function OrderCreateModal({ projectId, mode, onDone, onCancel }: Props) {
  const createOrder = useCreateOrder(projectId); // its own hook, not passed in from outside
  const [contactPicker, setContactPicker] = useState(emptyContactPicker);
  // ...all form state is local to this component...

  async function handleSubmit() {
    // validate, build the DTO, call the mutation
    await createOrder.mutateAsync(dto);
    onDone();
  }

  return (
    <BottomSheetModal visible onClose={onCancel} title={...}>
      {/* full form */}
    </BottomSheetModal>
  );
}
```

On the calling screen (e.g. the agenda):

```tsx
const [activeCreateModal, setActiveCreateModal] = useState<CreateModalKey | null>(null);

{activeCreateModal === 'order-requested' && (
  <OrderCreateModal
    projectId={projectId}
    mode="requested"
    onDone={() => setActiveCreateModal(null)}
    onCancel={() => setActiveCreateModal(null)}
  />
)}
```

**Rules:**
- The component **owns its own state and its own mutation hook** — the calling screen only passes
  the scope id + parameters that change the form's mode, never manages fields.
- `onDone`/`onCancel` **don't need to invalidate cache manually** — if the `useCreateXxx` hooks
  already invalidate the relevant query keys in `onSuccess` (which should be the standard for every
  mutation — see `feature-slice`), closing the modal is enough; the list behind updates by itself
  on the next render.
- If the original screen (B) already has a create component extracted as a separate function in
  its own file (not moved to `src/features/`), **don't duplicate it** — just add `export` to it and
  import it directly from the route file (`import { CreateModal as XCreateModal } from '../[id]/b-screen'`).
  A route file can have named exports besides `export default` — Expo Router only looks at the
  default to build the route table.
- Components shared between the new forms and the originals (e.g. a reminder-offset picker in
  `src/components/`) must be reused in the new ones even if the original screen files still have
  divergent local copies — it's not mandatory to migrate legacy code just because you're working
  nearby, but it is mandatory not to introduce a *third* copy.

### `height` vs `maxHeight` on the new modal — don't force `height="92%"` "to make sure it shows"

The rule already exists in §43 and in `BottomSheetModal` (default `maxHeight` `'92%'` — shrinks to
content). A real trap: adding `height="92%"` by mistake to a **short** create modal (4 fields) in an
attempt to "make sure the modal fills the screen" — the result is a large empty band between the
last field and the footer, because `height` pins the sheet at 92% of the screen **always**, with or
without enough content to fill it. Only use a fixed `height` when the inner `ScrollView` uses
`flex: 1` (manual fixed footer, §43) — in that case it *needs* a defined parent height to resolve,
otherwise it collapses. A form without that `flex: 1` (most of them) should have no `height` —
`maxHeight` already handles it.

### Short, static list inside a `BottomSheetModal` — `View`, not `ScrollView`

A `ScrollView` without explicit height/flex, inside a sheet with `maxHeight` (not `height`), can
have ambiguous sizing — dead space remains between the content and the sheet's footer even after
removing hardcoded height caps (`maxHeight: 360` etc.). If the list is short and never really needs
to scroll (e.g. a menu of 10 short options), swap it for a plain `View` — no sizing ambiguity on any
platform, RN or react-native-web.

---

## 70. Inline edit modal — extension of the create pattern (§69) to edit an existing item

Same motivation as §69 (don't navigate to the module screen just to open a modal), applied to
**editing** an existing item instead of creating a new one — e.g. a pencil icon on an agenda card
opening `OrderEditModal` / `TaskEditModal` directly over the agenda itself, without navigating to
the module screen. Same ownership rule: the extracted component owns its own form state and its own
mutation hook (`useUpdateXxx`); the calling screen only passes the scope id + the complete record +
`onDone`/`onCancel`.

**Key difference from §69 — aggregator DTOs are deliberately "thin":**
the items the agenda already fetches (e.g. `AgendaOrderItem`) don't have all the fields a full edit
form needs (e.g. `notes`, `location`, `contact_id`). You can't pass the agenda item straight to the
edit modal. The calling screen must fetch the module's complete list via the existing hook
(`use<Thing>s(scopeId)`) and do a client-side `.find(id)` before rendering the modal:

```tsx
const { data: orders } = useOrders(projectId);
const order = orders?.find((o) => o.id === editOrderId);

{order && (
  <OrderEditModal
    projectId={projectId}
    order={order}
    onDone={() => setEditOrderId(null)}
    onCancel={() => setEditOrderId(null)}
  />
)}
```

**Lesson — explicit `mode` from the caller, never derived from a separate query:**
when the same edit modal must behave differently depending on the item's stage (e.g. "Edit
request" vs. "Edit active item" — the latter exposes a whole scheduling section, the former
doesn't), **do not derive that mode from a field of a separately fetched query**
(`item.status` via `useItem(...)`). A sibling mutation (e.g. activating the item) may not have
revalidated that query yet at the instant the modal opens right afterwards — the modal then reads
the stale status and picks the wrong mode. The calling screen already knows, unambiguously, which
card/branch triggered the edit (the pencil on the "Requested" card vs. the one on the "Active" card)
— pass that as an explicit prop instead of trying to infer it:

```tsx
interface Props {
  item: Item;
  mode: 'request' | 'active';   // decided by the card that opened it, never by item.status
  onDone: () => void;
  onCancel: () => void;
}
```

§69's reuse rules (don't duplicate an existing local `EditModal` — just export and import it; shared
components must be reused in the new ones even if the original still has a divergent copy) apply
equally here.
