# React Native Web — Platform Compatibility Patterns
> Sub-file of `react-native-web` skill. Read when handling platform differences between web and native: Alert.alert replacements, Modal stacking limitations, ScrollView bounds, outline styles, null API fields, Rules of Hooks on web, aria-hidden warnings, silent catch blocks, and key-presence checks.
> Section numbers match the main `SKILL.md` (gaps are sections that only live there); §15 exists only here.

---

## 1. `Alert.alert` is unreliable on web — never use for destructive actions

`Alert.alert(title, message, buttons)` with 2+ buttons delegates to `window.confirm()` in React Native Web. Chrome silently blocks `window.confirm()` in many contexts, resulting in nothing happening when the user clicks.

**Rule:** never use `Alert.alert` for destructive confirmations (delete, remove, cancel) in web-capable apps. Do not import `Alert` in those components.

**Solution for destructive actions:** inline confirmation inside the same component or modal — replace the "Remove" button with an inline confirmation panel on click:

```typescript
const [confirmRemove, setConfirmRemove] = useState(false);

{confirmRemove ? (
  <View style={styles.confirmPanel}>
    <Text>Are you sure?</Text>
    <View style={styles.row}>
      <TouchableOpacity onPress={() => setConfirmRemove(false)}>
        <Text>Cancel</Text>
      </TouchableOpacity>
      <TouchableOpacity onPress={onRemove} disabled={loading}>
        <Text>{loading ? 'Removing…' : 'Yes, remove'}</Text>
      </TouchableOpacity>
    </View>
  </View>
) : (
  <TouchableOpacity onPress={() => setConfirmRemove(true)}>
    <Text>Remove</Text>
  </TouchableOpacity>
)}
```

**Solution for non-destructive confirmations:** execute the action directly on click, without a dialog.

**Why `Alert.alert` with 1 button sometimes works:** it uses `window.alert()`, which is rarely blocked. The problem is specific to `window.confirm()` (2+ buttons).

---

## 3. `ReactNode` comes from `react`, not from `react-native`

```
error TS2305: Module '"react-native"' has no exported member 'ReactNode'
```

`ReactNode` is a React type. This error occurs when creating components with render slots (`rightElement?: ReactNode`).

```typescript
// WRONG
import { View, TextInput, ReactNode } from 'react-native';

// CORRECT
import React, { ReactNode } from 'react';
import { View, TextInput } from 'react-native';
```

**When to apply:** every component that accepts a prop typed as `ReactNode`.

---

## 4. Rules of Hooks — never return before all hooks

```typescript
// WRONG — hook violation
if (!id) return <LoadingSpinner />;        // early return
const { data } = useQuery({ ... });        // hook after return
```

On native this may work accidentally; on web, React StrictMode detects it and causes inconsistent behavior.

**Solution:** all hooks before any conditional return. Use `enabled: !!id` for queries:

```typescript
const { data } = useQuery({
  queryKey: ['entity', id],
  queryFn: () => fetchById(id!),
  enabled: !!id,   // query does not run if id is falsy
});

if (!id) return <LoadingSpinner />;  // guard AFTER all hooks
```

---

## 5. API fields return `null`, not `undefined` — use `!= null` to filter absent values

**The bug:** `field !== undefined` does not filter null values. APIs (Supabase, NestJS) return `null` for unfilled optional fields. `null !== undefined` is `true` → null fields pass the filter and render as the literal text "null kg", "null%", etc.

**Solution:** always use `!= null` (covers both `null` AND `undefined` with loose equality):

```typescript
// WRONG — null passes the filter
{record.score !== undefined && <Text>{record.score} pts</Text>}

// CORRECT
{record.score != null && <Text>{record.score} pts</Text>}
```

**When to apply:** any optional field from the API — `number | null`, `string | null`, any column the database may return as `null`.

---

## 6. Remove browser outline on `TextInput` — use a plain object, not `StyleSheet.create`

`outlineWidth={0}` as a prop and `outlineWidth: 0` inside `StyleSheet.create` do **not** reliably remove the native browser focus outline. This fails especially on multiline `TextInput` (renders as `<textarea>`) or when the input has child elements.

**Cause:** `StyleSheet.create` serializes styles to internal RN Web IDs; pure CSS properties like `outline` may not be mapped to the DOM. A plain object is applied directly as an inline style.

**Solution:** pass `outline: 'none'` as a plain object outside `StyleSheet.create`:

```typescript
// Outside StyleSheet.create — applied as direct CSS inline style
const noOutline = { outline: 'none' } as any;

// On TextInput:
<TextInput style={[styles.input, noOutline, style]} ... />
```

**Custom focus via state** (replace native outline with a container border):

```typescript
const [focused, setFocused] = useState(false);

// Container View:
style={[styles.inputRow, focused && !error ? styles.inputRowFocused : undefined]}

// TextInput:
onFocus={(e) => { setFocused(true); onFocus?.(e); }}
onBlur={(e)  => { setFocused(false); onBlur?.(e); }}

// Style:
inputRowFocused: {
  borderColor: '#3B82F6',
  // @ts-ignore
  boxShadow: '0 0 0 3px rgba(59,130,246,0.12)',
},
```

Insert `noOutline` **before** any external style so callers cannot accidentally override it.

---

## 8. Modal stacking — second Modal appears behind the first on web

In React Native Web, two simultaneously open `<Modal>` components do not respect z-index. The second modal renders behind the first, invisible to the user.

**Rule:** never open a second Modal on top of an active Modal.

**Solutions:**
- Place the confirmation **inline inside the parent modal content** (swap the button for a confirm panel in the same Modal)
- Close the parent modal before opening the second

**Correct pattern for inline confirmation inside a modal:**

```typescript
// Inside the Modal child component — local state, no second Modal
const [confirmRemove, setConfirmRemove] = useState(false);
// Renders inline confirmation panel on "Remove" click
```

**When to apply:** any flow that would otherwise use `Alert.alert` inside a Modal — use local `confirmRemove` state and inline UI instead.

---

## 15. Modal bottom-sheet — ScrollView requires a bounded container

On web, a `ScrollView` does not scroll if it has no explicit height limit. The content simply extends beyond the viewport without creating a scrollable area.

**Broken pattern — ScrollView wraps the content View:**
```typescript
// ❌ ScrollView expands to content height — nothing to scroll on web
<KeyboardAvoidingView style={styles.modalOverlay} behavior="padding">
  <ScrollView keyboardShouldPersistTaps="handled">
    <View style={styles.modalContent}>  {/* no height limit — grows forever */}
      {/* fields */}
    </View>
  </ScrollView>
</KeyboardAvoidingView>
```

**Correct pattern — bounded View wraps ScrollView:**
```typescript
// ✅ maxHeight on the sheet creates the scroll window
<KeyboardAvoidingView style={styles.modalOverlay} behavior={Platform.OS === 'ios' ? 'padding' : 'height'}>
  <View style={styles.modalSheet}>
    <ScrollView
      keyboardShouldPersistTaps="handled"
      contentContainerStyle={styles.modalScrollContent}
    >
      {/* fields */}
    </ScrollView>
  </View>
</KeyboardAvoidingView>

modalOverlay: {
  flex: 1,
  backgroundColor: 'rgba(0,0,0,0.5)',
  justifyContent: 'flex-end',
},
modalSheet: {
  backgroundColor: '#FFF',
  borderTopLeftRadius: 20,
  borderTopRightRadius: 20,
  maxHeight: '90%',        // ← this creates the bounded window that makes scroll work
},
modalScrollContent: {
  padding: 24,
  paddingBottom: 40,
},
```

**When to apply:** any Modal bottom-sheet whose content might exceed the screen height — forms with many fields, multi-entry editors, lists with dynamic items.

**Simpler modals** (2–3 fields, always fits on screen) can keep `<View style={modalContent}>` without a `ScrollView` at all.

Note: on web the user must click inside the modal area before mouse-wheel scroll activates. This is standard browser behaviour for `overflow: auto` containers — not a bug to work around.

---

## 11. "Blocked aria-hidden" Chrome warnings — do not attempt to fix

`Blocked aria-hidden on an element because its descendant retained focus` appears when switching tabs.

**Cause:** React Navigation / Expo Router Tabs apply `aria-hidden="true"` on inactive tabs. If a focusable element inside the tab being hidden still has focus at the moment of the switch, Chrome emits the warning — `aria-hidden` on a tree with a focused element is semantically invalid per WAI-ARIA spec.

**Is it an error?** No. The app works correctly. Appears only on web preview — iOS/Android native does not produce it.

**Can it be fixed in app code?** No. The `aria-hidden` is inserted by React Navigation internals. The definitive fix requires React Navigation to use the `inert` attribute instead — a library change.

**Action:** ignore these warnings. Do **not** try to fix them by manually adding `aria-hidden` or `inert` on screens — that would introduce real accessibility regressions.

---

## 13. Silent `catch {}` hides API failures from the user — always expose errors in the UI

**The bug:** empty `catch {}` blocks on API calls make the user see "nothing happens" when clicking a button, with no error feedback.

**Symptom:** button clicked → no visual response → user clicks multiple times → inconsistent data.

**Rule:** every `mutateAsync` / `fetch` call must have an error state exposed in the UI:

```typescript
// WRONG
try {
  await someApi.mutateAsync(id);
} catch {
  // silent
}

// CORRECT
const [error, setError] = useState<string | null>(null);

try {
  setError(null);
  await someApi.mutateAsync(id);
} catch (e: any) {
  setError(e.message ?? 'An error occurred.');
}

// In the JSX:
{error ? <Text style={styles.errorText}>{error}</Text> : null}
```

**When to apply:** review any component with an async action. Search for empty `catch {` blocks and add error state.

---

## 14. Presence check in objects — use `key in obj`, not `obj[key]`, when value may be `null`

**The bug:** `if (obj[key])` fails when the value is `null`, `0`, or `''` — all falsy. "Was it loaded / revealed?" logic breaks silently.

```typescript
// WRONG — null is falsy, toggle never switches to "Hide"
if (revealedItems[entryId]) { /* hide */ }
else { /* reveal */ }

// CORRECT — checks key presence regardless of value
if (entryId in revealedItems) { /* hide */ }
else { /* reveal */ }
```

**Display pattern with null value:**

```typescript
// WRONG — null ?? fallback shows fallback instead of the "revealed-empty" state
{revealedItems[entry.id] ?? '••••••••'}

// CORRECT — distinguishes "not revealed" (undefined) from "revealed as empty" (null)
{entry.id in revealedItems
  ? (revealedItems[entry.id] ?? '(empty)')
  : '••••••••'}
```

**When to apply:** any `Record<string, T | null>` state where key presence has different semantics from the value. Common in: password reveal, loaded-data caches, per-ID toggle states.
