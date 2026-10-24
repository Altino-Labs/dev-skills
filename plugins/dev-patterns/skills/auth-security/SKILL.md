---
name: auth-security
description: >
  NestJS + Supabase + Expo implementation layer of dev-core:auth-security — JwtModule config
  and payload, the global JwtAuthGuard with @Public(), @CurrentUser(), ResourceMemberGuard
  with @RequireRoles(), the refresh-token use case, Supabase as auth provider (ES256 —
  delegate to auth.getUser, never passport-jwt with a fixed secret), @nestjs/throttler, the
  Expo SecureStore token service with its web fallback, the automatic refresh interceptor, the
  Zustand auth store, Expo Router and Next.js route protection, and the env vars. Invoke
  automatically (together with dev-core:auth-security) when implementing login, token
  refresh, guards, permission decorators, authentication middleware (backend or frontend), or
  any logic involving user identity or role/permission verification in this stack.
---

# Auth & Security — NestJS + Supabase + Expo implementation

**Load `dev-core:auth-security` first.** It holds the concepts and rules (the login/refresh
flow, access and refresh token lifetimes, rotation and revocation, the permission matrix,
deny-by-default endpoint protection, server-side authorization, secure token storage on each
client, the external provider behind an anti-corruption layer, rate limits on auth endpoints,
the absolute rules and the anti-patterns). This skill only shows how to implement them with
NestJS (Fastify), Supabase Auth, Expo/React Native and Next.js; it does not restate the rules.

## Backend — NestJS

All in [backend-auth.md](backend-auth.md):

- `JwtModule.registerAsync` config and the `JwtPayload` shape (self-issued HS256 tokens).
- Which global guard to use — **HS256 self-issued → `AuthGuard('jwt')` + `JWT_SECRET`;
  Supabase (ES256) → a `CanActivate` that delegates to `supabase.client.auth.getUser(token)`**.
  `passport-jwt` with `algorithms: ['HS256']` against a Supabase token returns 401 on every
  authenticated request while builds and mocked tests pass.
- `APP_GUARD` registration (all endpoints protected by default), `@Public()` (which every
  global guard must honor), `@CurrentUser()`.
- `ResourceMemberGuard` + `@RequireRoles()` — the two-level authorization check.
- The refresh-token use case (rotation, `refresh_tokens` table).
- `@nestjs/throttler`: global default, per-route `@Throttle()`, `trustProxy: true`, named
  profiles, in-memory storage limitation.
- The "authenticated ≠ authorized" anti-pattern in `@UseGuards` form.

## Frontend — Expo / React Native and Next.js

All in [frontend-auth.md](frontend-auth.md):

- Token service: **`expo-secure-store` (Keychain/Keystore) on iOS/Android; AsyncStorage only
  as the web fallback**, because SecureStore has no web implementation — web is treated as a
  lower-security context (`dev-core:auth-security` → secure token storage).
- The automatic refresh interceptor (deduplicated refresh, retry once, silent
  `router.replace('/login')`, never throw) and typical Supabase session lifetimes.
- The Zustand auth store (reads `access_token` / `refresh_token` from the login response).
- Route protection with Expo Router (`<Redirect>`) and the Next.js `middleware.ts`.
- `@supabase/ssr`: `createBrowserClient` keeps tokens in JS-readable (non-`httpOnly`) cookies —
  the caveat and the server-side (BFF) alternative.
- The Next.js BFF for an admin web app: auth route handlers, one cookie helper, the API proxy
  route (header allow-list, `.`/`..` refused), same-origin check, `connect-src 'self'`.

## Required environment variables

```bash
# Backend — add to .env.example
JWT_SECRET=                    # minimum 64 random characters
TOKEN_HASH_PEPPER=             # optional — keys the stored refresh-token hash (refresh tokens are opaque)
SUPABASE_JWT_SECRET=           # to validate Supabase Auth tokens

# Mobile — add to .env.example
EXPO_PUBLIC_API_URL=

# Web — add to .env.example
NEXT_PUBLIC_API_URL=
```

Rotation of these secrets: `dev-core:secrets-rotation`.
