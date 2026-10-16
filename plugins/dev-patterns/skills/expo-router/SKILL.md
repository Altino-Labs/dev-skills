---
name: expo-router
description: >
  Expo Router navigation patterns for React Native + Web apps in pnpm monorepos.
  Invoke automatically when implementing tab navigation, stack navigation, breadcrumbs,
  back buttons, usePathname, useGlobalSearchParams, href:null screens, or router.replace vs push.
---

# Expo Router — Navigation Patterns

## 1. Dynamic route params inside nested Tabs — use `useGlobalSearchParams`

In tab screens nested inside a dynamic route (`[id]/_layout.tsx`), `useLocalSearchParams()` returns `{}` on web — the parent segment is not propagated.

**Rule:** always use `useGlobalSearchParams()` in any tab screen that is a child of a dynamic route.

```typescript
// WRONG — returns {} for tab screens inside [entityId]/_layout.tsx
const { id } = useLocalSearchParams<{ id: string }>();

// CORRECT — reads the full URL at any nesting depth
const { id } = useGlobalSearchParams<{ id: string }>();
```

**Why it matters:** when `id` is undefined, a query with `enabled: !!id` stays permanently disabled (`isPending: true` in React Query v5) — the screen shows an infinite loading state. A hard reload works by accident because the router has already processed the URL before the first render.

**When to apply:** every tab screen inside a `[param]/_layout.tsx`.

---

## 2. `useFocusEffect` in a Tabs layout fires on every tab switch — place it in individual screens

Do **not** call `useFocusEffect` in the `_layout.tsx` of a `<Tabs>` navigator on web. The URL-based navigation causes the layout to "lose and regain focus" on every tab switch, triggering cancellation/refetch loops.

**Rule:** place `useFocusEffect` with `queryClient.refetchQueries` in each individual tab screen, not in the shared `_layout`.

```typescript
// In each individual tab screen (NOT in _layout.tsx):
useFocusEffect(useCallback(() => {
  if (entityId) qc.refetchQueries({ queryKey: ['module', entityId] });
}, [entityId, qc]));
```

**Why:** on native, `_layout.tsx` stays "focused" while switching between child tabs. On web, every URL change triggers a focus event on the parent layout.

---

## 3. Tab bar icons — use a custom `tabBar` component instead of `tabBarIcon`

`tabBarIcon: () => null` combined with `tabBarStyle: { height: 52 }` appears to work but is fragile on web — React Navigation does not reliably compute the layout when the icon is null.

**Definitive solution:** pass a custom React component via the `tabBar` prop on `<Tabs>`.

```typescript
function AppTabBar({ state, navigation }: { state: any; navigation: any }) {
  const VISIBLE = ['tab1', 'tab2', 'tab3'];
  const LABELS: Record<string, string> = { tab1: 'Label 1', tab2: 'Label 2', tab3: 'Label 3' };

  return (
    <View style={{ flexDirection: 'row', height: 52, backgroundColor: '#FFF', borderTopWidth: 1, borderTopColor: '#E5E7EB' }}>
      {(state.routes as { key: string; name: string }[])
        .filter((r) => VISIBLE.includes(r.name))
        .map((route) => {
          const isFocused = state.routes[state.index]?.name === route.name;
          return (
            <TouchableOpacity
              key={route.key}
              style={{ flex: 1, justifyContent: 'center', alignItems: 'center' }}
              onPress={() => navigation.navigate(route.name)}
            >
              <Text style={{ fontSize: 13, fontWeight: isFocused ? '600' : '400', color: isFocused ? '#3B82F6' : '#6B7280' }}>
                {LABELS[route.name]}
              </Text>
            </TouchableOpacity>
          );
        })}
    </View>
  );
}

// Use on the Tabs navigator:
<Tabs tabBar={(props) => <AppTabBar {...props} />}>
```

**Type note:** `@react-navigation/bottom-tabs` may not be a direct dependency. Use `{ state: any; navigation: any }` to avoid a problematic import.

---

## 4. Tab bar outline — surgical CSS, not global `* { outline: none }`

Injecting `* { outline: none !important }` globally removes outlines from text inputs and links, breaking keyboard accessibility.

**Correct approach — scoped to tab bar items only:**
```typescript
tabBarItemStyle: {
  // @ts-ignore — web-only property
  outline: 'none',
}
```

---

## 5. `src/app` root — two configs required together

To use `src/app` as the Expo Router root instead of `app/`, both settings are required:

```json
// app.json
{ "expo": { "router": { "root": "src/app" } } }
```

```bash
# When starting Metro
EXPO_ROUTER_APP_ROOT=src/app npx expo start --web --port 8082
```

Using only one of them is not sufficient. Confirm in the Metro log:
```
Using src/app as the root directory for Expo Router.
```

---

## 6. Web proxy with pnpm — preserve all query params when rewriting bundle URL

With pnpm + `shamefully-hoist=true` + Expo SDK 52 (expo-router v4), Metro generates in the HTML:
```html
src="../../node_modules/.pnpm/expo-router@4.x.x_.../node_modules/expo-router/entry.bundle?..."
```

The proxy must rewrite only the relative path prefix to absolute, preserving **all** query params (especially `transform.routerRoot`):

```javascript
html = html.replace(/src="[^"]*\.\.\/node_modules\//g, 'src="/node_modules/');
```

**Never** replace the full URL with `/node_modules/expo-router/entry.bundle?platform=web` — that loses `transform.routerRoot` and Expo Router falls back to `app/` instead of `src/app`.

**pnpm v11+ (Expo SDK 53+):** Metro generates absolute `.pnpm` paths it can serve directly. Rewriting breaks it (Metro returns 404 for the clean path). Use a transparent proxy instead — see `feature-slice §7`.

---

## 7. Stack vs Tabs layout — when the outer layout must be Stack

When `(app)/_layout.tsx` uses `<Tabs>` and contains dynamic routes (`items/[id]`), Expo Router auto-detects sub-routes and displays raw paths in the outer tab bar: `"items/index"`, `"items/[id]"`, etc.

**Rule:** use `<Stack>` with `headerShown: false` as the outer layout whenever the app has Tabs nested inside dynamic routes.

```typescript
// (app)/_layout.tsx — correct
<Stack screenOptions={{ headerShown: false }}>
  <Stack.Screen name="dashboard" />
  <Stack.Screen name="items/[id]" />  {/* [id] has its own Tabs internally */}
</Stack>
```

**Pattern:** list/dashboard uses Stack; detail view uses Tabs internally.

---

## 8. `Stack.Screen name` for nested dynamic routes uses the full path

```typescript
// Structure: (app)/items/[id]/_layout.tsx
// WRONG — "No route named 'items' exists"
<Stack.Screen name="items" />

// CORRECT
<Stack.Screen name="items/[id]" />
```

**Why:** when there is no `items/index.tsx` or `items/_layout.tsx` (only `items/[id]/`), Expo Router registers the route as `items/[id]`, not as `items`.

---

## 9. Hide tab bar entries with `href: null`

To add screens in a `[id]/` directory that are navigable via `router.push()` but must NOT appear in the tab bar, declare them in `_layout.tsx` with `href: null`:

```tsx
// src/app/(app)/items/[id]/_layout.tsx
<Tabs.Screen name="detail-a" options={{ href: null, title: 'Detail A' }} />
<Tabs.Screen name="detail-b" options={{ href: null, title: 'Detail B' }} />
<Tabs.Screen name="history"  options={{ href: null, title: 'History' }} />
```

Without `href: null`, Expo Router may auto-include the route in the tab bar when it detects the file in the directory.

---

## 10. `router.push()` — never include group names or explicit `/index`

Route groups (`(app)`, `(auth)`) are transparent in URLs — never include them in `router.push()`. The `/index` segment is never explicit.

```typescript
// WRONG — "Unmatched Route" on Expo Router web
router.push(`/(app)/items/${id}/index`)
router.push('/dashboard/index')

// CORRECT
router.push(`/items/${id}`)
router.push('/dashboard')
```

**Review systematically** every `router.push()`, `router.replace()`, `<Link href>`, and `href` in `Tabs.Screen` before completing any screen that navigates to routes inside groups.

---

## 11. Suppress the center title in a header — use `headerTitle: () => null`

Using `headerLeft` + `headerRight` does **not** suppress the center title. It still appears between the two elements.

For a header with only back (left) + breadcrumb (right) and no center text:

```typescript
screenOptions={{
  headerTitle: () => null,          // suppresses title on ALL screens
  headerLeft: () => <BackButton />,
  headerRight: () => <BreadcrumbRight />,
}}
```

---

## 12. `usePathname()` must be inside a React component, not in `screenOptions` render functions

```typescript
// WRONG — violates Rules of Hooks
headerRight: () => { const p = usePathname(); return <Text>{p}</Text>; }

// CORRECT — hook inside a React component
function BreadcrumbRight() {
  const p = usePathname();
  return <Text>{p.split('/').pop()}</Text>;
}
headerRight: () => <BreadcrumbRight />
```

The component updates reactively when switching tabs — `usePathname()` always reflects the active route.

---

## 13. Dynamic breadcrumb from active tab — `pathname.split('/').pop()`

To know which tab is active inside `[id]/_layout.tsx`:

```typescript
const pathname = usePathname();
const segment = pathname.split('/').pop() ?? 'index';
// On /items/abc123/details → segment = 'details'
// On /items/abc123        → segment = 'abc123' → treat as 'index'
```

Maintain a `SEGMENT_LABEL` map with all expected segments and their human-readable labels.

---

## 14. Intra-tabs navigation — always use `router.replace`, never `router.push` or `router.navigate`

**The problem with `router.push` / `router.navigate` inside Tabs:**
Each call adds an entry to the history stack. After several cycles of "sub-screen → tab → sub-screen → tab", the history accumulates entries and `router.back()` must traverse all of them before reaching the root screen — effectively locking backward navigation.

**`router.back()` inside Tabs has no memory of which tab came before:**
The default `backBehavior` of the Tabs navigator is `initialRoute`. `router.back()` returns to the first registered tab, not to the previously visited one.

**Rule:** inside a Tabs flow with `href: null` sub-screens, use `router.replace` at every navigation point:

```typescript
// WRONG — pushes history, makes back-navigation unpredictable
router.push('/items/id/sub-screen');
router.navigate('/items/id/tab-name');
router.back();  // may not go where expected

// CORRECT — replaces current entry, keeps history clean
router.replace('/items/id/sub-screen');   // from tab to sub-screen
router.replace('/items/id/tab-name');     // back button in sub-screen
router.replace('/dashboard');             // exit Tabs entirely
```

**Navigation pattern:**
- Tab aggregator → sub-screens: `router.replace`
- Back button in sub-screens: `router.replace('/tabs/origin')`
- Back button in normal tabs: `router.replace('/root-screen')`

**Context-aware back button:** create a `BackButton` component using `usePathname()` that detects whether the current screen is a sub-screen of an aggregator tab and decides between `router.replace` to the tab origin or `router.replace` to the root screen.

---

## 15. Every navigation item must have a functional handler

Never generate a nav item with an empty `onPress: () => {}` or a placeholder comment. It renders as tappable but does nothing — a silent UX bug with no error.

Every item in a navigation list or overflow menu must do one of:
1. Navigate: `router.replace('/path')`
2. Inform: `Alert.alert('Coming soon', 'This feature is not yet available.', [{ text: 'OK' }])`
3. Be removed from the list entirely

```typescript
// ❌ Silent bug
{ label: 'Reports', onPress: () => { /* Phase 3 */ } }

// ✅ Navigate
{ label: 'Reports', onPress: () => router.replace(`/items/${id}/reports`) }

// ✅ Inform
{ label: 'Reports', onPress: () => Alert.alert('Coming soon', '', [{ text: 'OK' }]) }
```

---

## 16. Deep-link navigation to auto-open a modal — navKey + timestamp pattern

When navigating from screen A to screen B with a URL param that tells B to auto-open a modal (e.g. `taskId` + `action`), a `useRef` guard prevents re-opening the same modal if the user closes it and clicks the same item again (the ref remembers it was already opened).

**Problem:** `useRef.current = taskId` is set on first open. Closing the modal and re-navigating to the same `taskId` does nothing because the ref still holds that value.

**Solution:** include `t=Date.now()` in the URL and form the navKey as `${taskId}-${action}-${t}`. Each navigation generates a unique timestamp, so the ref check always passes:

```typescript
// In screen A (navigation call)
router.replace(`/projects/${projectId}/tasks?tab=open&taskId=${id}&action=view&t=${Date.now()}`);

// In screen B (useEffect)
const { taskId, action, t } = useLocalSearchParams<{ taskId?: string; action?: string; t?: string }>();
const autoOpenedRef = useRef<string | null>(null);

useEffect(() => {
  if (!taskId || !action || !t) return;
  const navKey = `${taskId}-${action}-${t}`;
  if (autoOpenedRef.current === navKey) return; // already handled
  autoOpenedRef.current = navKey;

  const task = tasks?.find(x => x.id === taskId);
  if (!task) return;
  if (action === 'complete') openComplete(task);
  else openEdit(task);
}, [taskId, action, t, tasks]);
```

**Note:** `t` should come from the URL, not generated inside the `useEffect` — the URL param is stable across re-renders; `Date.now()` inside the effect would change on every render.

---

## 17. Layout `useEffect` runs AFTER child screen's first render — use URL params as fallback

When a `_layout.tsx` uses `useEffect` to set shared state (Zustand, context, etc.) based on a URL param, that effect fires **after all child screens complete their initial render**. Any child screen that reads from that shared state sees the old/null value on first render.

```typescript
// _layout.tsx
useEffect(() => {
  if (id) store.setActiveEntityId(id); // ← fires AFTER child screens render
}, [id]);

// child-screen.tsx
const activeId = useStore(s => s.activeEntityId); // ← null on first render
const entity = items?.find(e => e.id === activeId); // ← null even though URL has id
```

**Root cause:** React renders the tree top-down, but `useEffect` runs bottom-up after the full commit — children render before parents' effects fire.

**Fix: read the URL param directly in the child screen as an immediate fallback.**

```typescript
// child-screen.tsx
const { id: urlEntityId } = useGlobalSearchParams<{ id?: string }>();
const storeEntityId = useStore((s) => s.activeEntityId);
// urlEntityId is synchronously available on first render; storeEntityId catches up after layout effect
const resolvedEntityId = urlEntityId ?? storeEntityId;

const entity = items?.find((e) => e.id === resolvedEntityId) ?? null;
```

**Why `urlEntityId` is immediately available:** `useGlobalSearchParams` reads from the router context synchronously — the URL is resolved before any component renders. The `useEffect` in the layout is what lags behind.

**Rule:** any child screen inside a `[param]/_layout.tsx` that depends on state SET by the layout's `useEffect` must read the URL param directly as a same-render fallback. Never assume shared state is populated on first render.

---

## 18. Navigating "up" to a parent Stack from inside a nested Tab — use `router.dismiss()`

When a component is rendered inside a Tab navigator that is itself a child of a Stack, calling `router.navigate('/parent-route')` does **not** pop the Stack — it resolves the route within the current navigator context and may **push** it as a new entry, causing:

- Forward (push-from-right) animation instead of the expected back animation
- Title flickering: navigation state updates before the animation completes, so `usePathname()` in the parent layout re-renders with the new route during the outgoing transition

**Rule:** to return to a route that is **below** the current Stack entry, use `router.dismiss()`.

```typescript
// WRONG — from inside a Tab nested in a Stack, navigate() pushes instead of pops
router.navigate('/dashboard'); // ← adds /dashboard on top; forward animation; title flickers

// CORRECT — pops the current Stack entry, revealing whatever is below
router.dismiss(); // ← dismisses 1 level; correct back animation; no flickering
```

**Why `dismiss()` works from any nesting depth:**

| Context | Stack before | `router.dismiss()` result |
|---|---|---|
| `/profile` (Stack.Screen) | `[dashboard, profile]` | Pops `profile` → `dashboard` ✓ |
| `/items/${id}/settings` (Tab inside Stack.Screen) | `[dashboard, items/${id}]` | Pops `items/${id}` → `dashboard` ✓ |

`router.dismiss(n?)` always targets the **closest ancestor Stack** and pops `n` entries (default 1). It works identically whether the calling component is a Stack.Screen directly or a Tab screen nested inside one.

**Variants:**
- `router.dismiss()` — pop 1 Stack level (use when you know the target is exactly 1 level up)
- `router.dismiss(n)` — pop `n` Stack levels
- `router.dismissAll()` — pop everything back to the Stack root

**When to use each:**
- `router.dismiss()` → going "back" one level from any context
- `router.navigate('/route')` → navigating between siblings at the **same** Stack level
- `router.push('/route')` → explicitly adding a new entry (forward navigation)

---

## 19. Coordinator pattern — the app's single navigation interface

**Absolute rule:** no screen imports `useRouter` directly. All navigation code goes exclusively through an app-level hook such as `useAppNav()`.

```typescript
// ❌ NEVER — breaks separation of responsibilities
import { useRouter } from 'expo-router';
const router = useRouter();
router.replace(`/projects/${id}/tasks`);

// ✅ ALWAYS — the app's public navigation interface
import { useAppNav } from '../../src/navigation/useAppNav';
const nav = useAppNav();
nav.goToProjectTasks(projectId);
```

**Why:** the coordinator centralizes push-vs-replace decisions, timestamp generation for cache-busting / re-triggering deep links (`t=${Date.now()}`, §16), and the exact URL structure — call sites don't need to know any of it. Changing a route shape or a push/replace decision becomes a one-file change.

**Files (recommended layout):**
- `src/navigation/AppCoordinator.ts` — TypeScript interface listing every destination
- `src/navigation/createAppCoordinator.ts` — implementation (receives Expo's `Router`)
- `src/navigation/useAppNav.ts` — hook: `const nav = useAppNav()`

**Exception:** `createAppCoordinator.ts` may call `router.*` — it is the only authorized place. Because it's a plain factory receiving a `Router`, it is unit-testable with a mocked router.

**Shape of the interface (example):**
```typescript
// Auth / root
nav.goToRoot()                              // router.replace('/')
nav.goToLogin()                             // router.replace('/(auth)/login')
nav.goToDashboard()                         // router.replace('/dashboard')
nav.goToRegister()                          // router.push('/(auth)/register')

// Own profile
nav.goToProfile()                           // router.push('/profile')

// Entity — main sections
nav.goToProjectRoot(projectId)
nav.goToProjectSettings(projectId)          // push (enters the stack)
nav.goToProjectSection(projectId, section)  // dynamic route (e.g. a "more" menu)

// Entity — sub-modules with deep-link options (§16)
nav.goToProjectTasks(projectId, opts?)      // opts: { tab?, taskId?, action?: 'edit'|'complete'|'create' }

// Primitives
nav.back()
nav.dismiss()  // NOT back() — pops the parent Stack (§18)
```

Keep the interface file as the single source of truth for the list of destinations; don't duplicate it in docs.

---

## 20. Deep-link auto-open on mount — `useLayoutEffect` when nothing async is needed

§16's navKey+timestamp pattern uses `useEffect`. That's correct when the effect needs to
find an item inside a list that's still loading (edit/schedule/complete flows — the effect
has to wait for the query to resolve before it can call `items.find(...)`). It is **not**
the best choice for pure **creation** flows, where nothing needs to be awaited — the modal's
initial field values don't depend on any fetched entity.

For create-only auto-open effects, use `useLayoutEffect` instead:

```typescript
const autoCreateRef = useRef<string | null>(null);

useLayoutEffect(() => {
  if (action !== 'create') return;
  const navKey = t ?? '0';
  if (autoCreateRef.current === navKey) return;
  autoCreateRef.current = navKey;
  openCreate(); // no list lookup — safe to call before first paint
}, [action, t]);
```

**Why it helps:** `useLayoutEffect` runs synchronously after the commit, before the browser/
native paints the frame — the modal-opening state update lands in the same visual frame as
the mount, instead of one tick later (`useEffect`, which is scheduled after paint). This
meaningfully reduces — but does not eliminate — the flash of the screen behind the modal; the
underlying screen still mounts and exists, just covered sooner. It does **not** help when the
effect body needs data from a query that's still `isPending` — `useLayoutEffect` can't make
an async fetch resolve any faster, so edit/schedule/complete flows keep `useEffect`.

**Better than a flash-reduction trick: don't navigate at all when the caller only needs a
create modal.** If the entry point (e.g. a menu on a different screen) only wants to offer
"create a new X," render a standalone create-modal component directly on the calling screen
instead of navigating to X's own screen and auto-opening there — see `mobile-ux-patterns`
§69 (standalone create modal invoked from another screen, without navigating). Reach for
`useLayoutEffect` + deep-link auto-open only when the target really is another screen's full
context (e.g. editing an item that belongs to a list only that screen owns), not as a
substitute for the standalone modal when creation is all that's needed.

## 21. Typed routes in CI — generate them before lint and type-check

With `experiments.typedRoutes: true`, Expo generates `.expo/types/router.d.ts` and
`expo-env.d.ts` (both gitignored) **only when `expo start` runs**. Without them,
`router.push` accepts any string; with them, only real routes type-check. So lint and
type-check give **different results depending on whether Metro ever ran on the machine**:
a fresh clone or CI sees route `as any` casts as "unnecessary" (and may hit implicit-`any`
errors elsewhere), while a dev machine needs them.

Generate the types as part of the scripts themselves — the documented CI approach is
`expo customize tsconfig.json`:

```json
{
  "scripts": {
    "typegen": "EXPO_ROUTER_APP_ROOT=app expo customize tsconfig.json < /dev/null > /dev/null",
    "lint": "pnpm typegen && eslint .",
    "type-check": "pnpm typegen && tsc --noEmit"
  }
}
```

Set `EXPO_ROUTER_APP_ROOT` to the project's real router root. Verify on a simulated clean
checkout (move `.expo/` and `expo-env.d.ts` aside, run lint and type-check, restore).
Don't fix the divergence by dropping `.expo/types` from `tsconfig.json` — that throws away
route checking everywhere.
