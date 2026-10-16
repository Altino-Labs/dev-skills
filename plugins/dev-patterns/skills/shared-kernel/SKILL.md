---
name: shared-kernel
description: >
  Organization rules and boundaries for shared packages.
  Invoke automatically when creating or modifying any file in packages/,
  when defining shared types between backend and frontend, or when deciding
  whether an artifact belongs in a package or in a specific app.
---

# Shared Kernel

## Package structure

```
packages/
├── shared-types/   ← DTOs, enums and shared interfaces between apps
├── utils/          ← Pure functions with no framework dependency
└── ui/             ← Design tokens (colors, spacing, typography)
```

---

## `packages/shared-types` — API contracts

### What belongs here

- API request and response DTOs
- Enums used by both backend and frontend
- Pagination and response envelope interfaces
- API error types

### What does NOT belong here

- Validation logic (`class-validator`) — stays in the backend
- React or React Native components
- Any framework imports (NestJS, Next.js, Expo)

### package.json and tsconfig

```json
{
  "name": "@your-app/shared-types",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts"
}
```

```json
{
  "compilerOptions": {
    "module": "CommonJS",
    "moduleResolution": "Node",
    "rootDir": "./src",
    "outDir": "./dist"
  }
}
```

### Dates rule

Always `string` (ISO 8601), never `Date`. `Date` does not serialize reliably.

```typescript
createdAt: string; // "2024-05-28T14:32:00.000Z"  ← ✅
createdAt: Date;                                   // ❌
```

---

### ESM packages (NestJS 12 / `nodenext` consumers) and TypeScript 6

When the consuming apps are ESM (NestJS 12, Vitest), packages are ESM too:

```json
{
  "type": "module",
  "main": "./dist/index.js",
  "types": "./dist/index.d.ts",
  "exports": { ".": { "types": "./dist/index.d.ts", "import": "./dist/index.js" } }
}
```

```json
{
  "compilerOptions": {
    "module": "nodenext",
    "moduleResolution": "nodenext",
    "rootDir": "./src",
    "outDir": "./dist",
    "types": ["node"]
  }
}
```

- Relative imports carry `.js` (`export * from './enums.js'`).
- **TypeScript 6+:** `rootDir` is mandatory with `outDir` (TS5011), and `types` defaults to `[]`
  — list `@types/*` explicitly. Exclude `*.spec.ts` from the build tsconfig.
- Not yet verified: an Expo app importing these ESM packages through Metro (check before relying on it).

---

## `packages/utils` — pure functions

### What belongs here

- Date, time, currency formatting
- Pure validations (national IDs, email, phone)
- Stateless business calculations
- String, array, object helpers

### Absolute rule

```typescript
// Zero imports of React, React Native, NestJS, Next.js, DOM
// Zero side effects
// Input → Output deterministic
```

### package.json — dependency on shared-types

`packages/utils` imports types from `@your-app/shared-types`. Declare explicitly:

```json
{
  "name": "@your-app/utils",
  "dependencies": {
    "@your-app/shared-types": "workspace:*"
  }
}
```

### tsconfig — do NOT use `references`

```json
{
  "compilerOptions": {
    "module": "CommonJS",
    "moduleResolution": "Node",
    "rootDir": "./src",
    "outDir": "./dist"
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
```

**Do NOT add `"references": [{"path": "../shared-types"}]`** — causes TS6306 error
("Referenced project must have setting 'composite': true") without adding real value.
pnpm workspace resolves the dependency via shared-types `dist/`.

---

## `packages/ui` — design tokens

### What belongs here

- Color palette (not components)
- Spacing, typography, border radius
- Tokens as TypeScript constants — no JSX

```typescript
export const colors = {
  primary: { 50: '#f0fdf4', 500: '#22c55e', 900: '#14532d' },
  danger:  { 50: '#fff1f2', 500: '#ef4444', 900: '#7f1d1d' },
} as const;

export const spacing = { xs: 4, sm: 8, md: 16, lg: 24, xl: 32, xxl: 48 } as const;
```

### What does NOT belong here

- React or React Native components
- CSS styles or RN StyleSheet
- Dynamic theme logic (dark mode)

---

## Package dependency rule

```
apps/mobile  →  can import: shared-types, utils, ui
apps/web     →  can import: shared-types, utils, ui
apps/api     →  can import: shared-types, utils (does NOT import: ui)

packages/shared-types  →  zero external dependencies
packages/utils         →  can import: shared-types (workspace:*)
packages/ui            →  can import: utils (workspace:*)
```

A package never imports from an `app`.

---

## When to create a package vs keep inside the app

| Criterion | Package | Inside the app |
|---|---|---|
| Used by 2+ apps | ✅ Always a package | — |
| No framework dependency | ✅ Package | — |
| Platform-specific | — | ✅ Inside the app |
| UI component | — | ✅ Inside the app |
| Portable business logic | ✅ Package (utils) | — |

---

## shared-types versioning

Breaking changes affect both backend **and** frontend simultaneously.

1. Add the new type (without removing the old one)
2. Update backend to support both
3. Update frontend to use the new one
4. Remove the old type (next sprint)

Never remove or rename a field in `shared-types` without coordinating with all apps.

---

## Package build order

```bash
# Always in this order — utils depends on shared-types
# Replace @your-app/* with your actual package scope (e.g. @acme/*, @my-project/*)
pnpm --filter "@your-app/shared-types" build
pnpm --filter "@your-app/utils" build
pnpm --filter "@your-app/ui" build
```
