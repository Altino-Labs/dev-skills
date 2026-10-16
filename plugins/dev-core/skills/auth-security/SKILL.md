---
name: auth-security
description: >
  Authentication and authorization for any stack: the login/refresh flow, JWT access tokens
  and opaque refresh tokens (lifetimes, rotation, revocation, where they are verified), the
  role-based permission matrix, roles from the database vs roles/scopes in token claims (a
  trade-off), endpoint protection (deny by default, server-side authorization always — at the
  edge or as policy checks in the application layer — client-side guards are UX only), CSRF
  protection for cookie-based auth, secure token storage on clients
  (Keychain/Keystore on native, httpOnly cookies on web, and the explicit lower-security web
  fallback), an external auth provider behind an anti-corruption layer, rate limiting on auth
  endpoints, the absolute auth security rules and the anti-patterns. Invoke automatically when
  implementing login, token refresh, guards/middleware, permission checks, or any logic
  involving user identity or role/permission verification, in any language or framework.
---

# Auth & Security

> **How to read the examples.** Every example in this skill is framework-free TypeScript —
> plain classes, interfaces and functions, no decorators, no framework, no JWT, auth-provider,
> storage or HTTP-client library. Read it as pseudo-code and translate it to the project's
> language and idioms. Stack-specific implementations (the JWT module, guards and decorators,
> the auth-provider integration, the client token storage, the refresh interceptor, the auth
> store, route protection, env var names) live in stack plugins — e.g.
> `dev-patterns:auth-security` for NestJS + Supabase + Expo — and in the project's own delta
> skill (`.claude/skills/<project>-auth-security/`), when they exist. Load them together with
> this skill.

## Authentication flow overview

```
[Native] POST /api/v1/auth/login  →  200 { "access_token": "...", "refresh_token": "..." }
[Web]    POST /api/v1/auth/login  →  200 { "access_token": "..." }
                                     + Set-Cookie: refresh_token=...; HttpOnly; Secure; SameSite=Strict; Path=/api/v1/auth
                                                       ↓
                                        Access token:  JWT, short-lived  (Authorization: Bearer header)
                                        Refresh token: opaque, long-lived (httpOnly cookie on web,
                                                                           device secure storage on native)
                                                       ↓
                                        Access expired  → POST /api/v1/auth/refresh
                                                          (native: token in the body; web: the cookie)
                                        Refresh expired → back to login
```

**Refresh-token transport depends on the client.** Native clients receive the refresh token
in the JSON body and send it back in the body. Web clients receive it **only** as an
`httpOnly`, `Secure`, `SameSite` cookie set by the server — never in the response body, so no
script can read it — and the browser sends it back on `/auth/refresh` and `/auth/logout`. The
server tells the two apart by an explicit client type (e.g. a separate web route or a
`client_type` field), never by guessing. The only web exception is the documented
lower-security fallback in "Secure token storage on clients".

Token fields on the wire follow the API's casing convention like every other field (this
plugin's default: snake_case — `dev-core:api-contracts`).

---

## Access token (JWT)

- **Lifetime:** short — 15 minutes for self-issued tokens; auth providers often default to
  1 hour. Record the project's real value.
- **Verified on every request, on the server**, at the edge (a global guard/middleware), before
  any controller or use case runs: signature, `exp`, `iss`, `aud`, and the expected signing
  algorithm. Never trust a token the server didn't verify.
- **Payload is minimal:** `sub` (user ID), `email`, `iat`, `exp`, `iss`, `aud`. Never sensitive
  data (government IDs, address). Whether the role travels in the token is a trade-off — see
  "Where roles come from" below; this plugin's default keeps it out and reads it from the
  database on each request.
- **Signing algorithm:** symmetric (HS256, shared secret ≥ 64 characters) only when the
  project issues its own tokens. When an external provider issues them, it may sign
  asymmetrically (e.g. ES256) and change keys or algorithm between versions — verify through
  the provider (its verification API or published keys), never with a hard-coded secret and
  algorithm. A mismatch fails silently: every authenticated request returns 401 while builds
  and mocked unit tests pass; it only shows up in a real smoke test.

## Refresh token

- **Opaque** (≥ 128 bits from a cryptographically secure random generator, e.g. 32 random
  bytes encoded as hex or base64url — a UUID v4 carries only 122 random bits), not a JWT —
  stored server-side **as a hash only** (`refresh_tokens`: `token_hash`, `user_id`,
  `expires_at`, `revoked_at`). A leaked table then yields no usable tokens.
- **Lookup hashes first:** the server hashes the presented token (e.g. SHA-256 — the token is
  high-entropy, so a fast hash is enough; optionally keyed with a server-side pepper, see
  `dev-core:secrets-rotation`) and looks up by `token_hash` (unique index). Never query by the
  raw token. If the code ever compares a presented secret with a stored one in application
  code, use a constant-time comparison.
- **Provider-owned refresh tokens:** the hash-at-rest and lookup-by-hash rules above assume
  the application issues its own refresh tokens. When an external auth provider issues and
  stores them (a hosted identity service), the application never sees their storage: record
  that in the project's delta skill, and check — and record — the provider's actual behaviour
  (how tokens are stored, whether they rotate on every use, reuse detection, revocation on
  logout, lifetime).
- **Lifetime:** long — 30 days to months. Record the project's real value.
- **Rotation on every use:** each refresh revokes the presented token and issues a new
  access + refresh pair.
- **Revocation:** logout revokes the refresh token on the server — clearing the client alone
  leaves it valid for months.

```typescript
async function refresh(presented: string): Promise<TokenPair> {
  // presented comes from the body (native) or the httpOnly cookie (web)
  const stored = await tokenRepo.findByTokenHash(hashToken(presented));   // never by the raw token

  if (!stored)                       throw new UnauthorizedException('INVALID_REFRESH_TOKEN', 'Invalid refresh token');
  if (stored.revokedAt)              throw new UnauthorizedException('REVOKED_REFRESH_TOKEN', 'Refresh token revoked');
  if (stored.expiresAt < new Date()) throw new UnauthorizedException('EXPIRED_REFRESH_TOKEN', 'Refresh token expired');

  // Rotate: revoke current, issue new pair (the new refresh token is stored as its hash)
  await tokenRepo.revoke(stored.id);
  const user = await userRepo.findById(stored.userId);
  return issueTokenPair(user);   // the edge returns it in the body (native) or as Set-Cookie (web)
}
```

---

## Role-based permission matrix

Define the project's permission matrix in the project spec (e.g. `PROJECT.md`) — it is the
single source of truth; code and reviews refer to it.

Example structure (adapt roles and resources to your domain):

| Resource     | Admin       | Editor      | Viewer      |
|---|---|---|---|
| Users        | Full access | Read-only   | No access   |
| Content      | Full access | Full access | Read-only   |
| Settings     | Full access | No access   | No access   |

Authorization is checked at two levels, on the server:

1. **Membership/ownership** — the user belongs to (or owns) the resource being accessed; an
   invitation that wasn't accepted yet does not count.
2. **Role** — the user's role on that resource allows the operation.

**UX rule:** resources with "No access" must never appear in the UI — not even disabled.

### Where roles come from — a trade-off

| | Roles from the database on each request | Roles/scopes in token claims |
|---|---|---|
| Typical setup | Self-issued tokens; per-resource roles (membership tables) | OIDC provider issues them (Keycloak, Microsoft Entra ID, AWS Cognito, Auth0) |
| Role change / revocation | Instant — the next request sees it | Applies at the next token refresh — acceptable **only with short-lived access tokens** (minutes) |
| Cost | One lookup per request (cacheable for seconds) | None per request |
| Fits | Roles that vary per resource (member of project A as editor, of B as viewer) | Coarse, global roles/scopes (`admin`, `orders:write`) |

Both are valid; pick one per kind of role and record it. They combine well: global
roles/scopes from claims, per-resource membership from the database. If roles come from
claims, verify them like the rest of the token (signature, `iss`, `aud`) and map them to the
application's own role names in the anti-corruption layer — never branch on provider-specific
claim names in use cases.

```typescript
// Authorization check at the edge — runs after authentication, before the use case
async function authorize(user: AuthUser, resourceId: string, requiredRoles: Role[]): Promise<Member> {
  const member = await memberRepo.findByUserAndResource(user.id, resourceId);
  if (!member || !member.acceptedAt) throw new ForbiddenOperationException('FORBIDDEN', 'Operation not allowed');
  if (requiredRoles.length && !requiredRoles.includes(member.role)) throw new ForbiddenOperationException('FORBIDDEN', 'Operation not allowed');
  return member;   // made available to the handler
}
```

---

## Endpoint and route protection

- **Deny by default:** every endpoint requires authentication unless explicitly marked
  public. Typical public endpoints (list the project's real ones in its own docs): register,
  login, refresh, lookup by an emailed unguessable token (e.g. `GET /invitations/:token`),
  health checks.
- Anything that acts *as* a user (e.g. accepting an invitation into the caller's account) is
  **not** public, even when reached through an emailed token link.
- **Authenticated ≠ authorized.** Every endpoint touching a resource runs both the
  authentication check and the authorization check above.
- **Where the check lives — two equivalent options.** (a) **At the edge**
  (guard/middleware/route policy) — the use case then assumes an authorized caller
  (`dev-core:clean-architecture`); or (b) **resource-based policy checks in the application
  layer** — the use case loads the resource and asks an authorization service/policy whether
  the caller may act on it (Spring `@PreAuthorize` / method security, ASP.NET Core
  `IAuthorizationService.AuthorizeAsync(user, resource, policy)`, Django object permissions /
  django-guardian, Pundit/CanCan). Pick one per project and apply it consistently. Either
  way the non-negotiables are the same: **always server-side, before the mutation, and
  tested** (a test per role that must be denied).
- **Server-side authorization always.** Client-side route guards (redirect to login when not
  authenticated, hiding screens a role can't use) are UX only — anyone can call the API
  directly.
- **Clients refresh silently.** On a 401 the client exchanges the refresh token once
  (deduplicating concurrent refreshes), retries the original request once, and if refresh
  fails clears the tokens and redirects to login **without surfacing an error** — throwing
  would let a calling screen display "UNAUTHENTICATED". The silent redirect is the last-resort
  safety net, not the normal path.

---

## Secure token storage on clients

| Client | Where tokens live |
|---|---|
| Native mobile (iOS/Android) | The device's secure storage — Keychain (iOS) / Keystore (Android). Never plain app storage (unencrypted at rest). |
| Web (preferred) | Refresh token in an `httpOnly`, `Secure`, `SameSite` cookie set by the server; access token in memory only. Script can't read either from storage. |
| Web (fallback) | Only when a web build must hold tokens client-side (e.g. one codebase shared with native and no cookie-based session): browser storage (e.g. `localStorage`). This is an **explicit lower-security fallback** — any script running on the origin can read it, so an XSS becomes token theft. Treat web as a lower-security context: strict CSP (`dev-core:api-contracts`), short access-token lifetime, refresh rotation, and document the decision. |

Never put tokens in browser storage by default — only through that documented fallback.

---

## CSRF — when auth rides on cookies

Browsers attach cookies to cross-site requests automatically, so any state-changing request
authenticated by a cookie can be forged from another site. This applies when:

- the web client's refresh token lives in a cookie (the `/auth/refresh` and `/auth/logout`
  endpoints above), or
- the app is server-rendered with cookie sessions (Django, Rails, Spring MVC, ASP.NET MVC,
  Laravel).

Rules for cookie-authenticated requests:

- Cookies are `HttpOnly`, `Secure`, and `SameSite=Strict` (or `Lax` when cross-site top-level
  navigation must keep the session). `SameSite` is the first layer, not the only one.
- **Every state-changing request (POST/PUT/PATCH/DELETE) carries a CSRF token** — synchronizer
  token (stored in the server session, the framework default in Django/Rails/Spring Security/
  ASP.NET antiforgery) or double-submit (a random value in a non-httpOnly cookie echoed in a
  header and compared server-side). Keep the framework's built-in protection on; never disable
  it to "make the API work".
- GET/HEAD never change state.

APIs authenticated **only** by a bearer token in the `Authorization` header don't need CSRF
tokens — the browser never attaches that header on its own. The moment any endpoint accepts a
cookie as credential, it needs the protection above.

---

## External auth provider behind an anti-corruption layer

When an external provider (hosted identity service, OAuth/OIDC provider) handles sign-in and
issues tokens, keep it behind a port the application owns
(`dev-core:clean-architecture` → `acl.md`):

```typescript
// Application-owned port — no provider types cross it
export interface ITokenVerifier {
  verify(accessToken: string): Promise<AuthUser | null>;   // null = invalid/expired
}

export interface AuthUser { id: string; email: string; }
```

- The adapter calls the provider (its verification API or published keys) and maps the
  provider's user/claims to the application's own `AuthUser`. Provider SDK types never reach
  use cases or the domain.
- The global authentication guard depends on the port, not on the provider — swapping
  providers, or moving from self-issued tokens to a provider, touches one adapter.
- Membership and roles stay in the application's own tables, not in provider metadata — the
  provider authenticates; the application authorizes.

---

## Rate limiting on auth endpoints

Every public auth endpoint (login, register, refresh, password reset) and every invite /
spam-prone endpoint needs a tighter limit than the rest of the API — brute force, credential
stuffing and account enumeration all target these specifically. General rules (keys, proxy
trust, shared counters, `429` + `Retry-After`): `dev-core:api-contracts`.

| Endpoint | Typical limit |
|---|---|
| Login / password actions | 5 / 15 min per IP |
| Refresh | 10 / 5 min (lower risk, higher volume) |
| Invite creation | 10 / hour per user |

Keep the named limit profiles in one shared place so a policy change is a one-line edit.

---

## Absolute auth security rules

- Access token: **never** in browser storage by default — in memory (web) or the device's
  secure storage (native); browser storage only as the documented web fallback above
- Refresh token: **never** in browser storage by default — `httpOnly` cookie (web) or the
  device's secure storage (native); browser storage only as the documented web fallback above
- Signing secret (self-issued tokens): **minimum 64 characters**, rotate every 90 days
  (`dev-core:secrets-rotation`)
- Refresh tokens: rotate on every use (issue new pair, revoke the previous one); store only
  their hash and look them up by the hash of the presented token
- Logout: always revoke the refresh token on the backend — not just clear the client
- Role: from the database on each request, or from verified token claims **only** with
  short-lived access tokens (see "Where roles come from")
- Cookie-authenticated state-changing requests: `SameSite` cookies + CSRF token
- Password: never log, never serialize, never include in error responses
  (`dev-core:logging-observability` → never log)

---

## Anti-patterns

### Role read from an unverified token, or a long-lived token

```typescript
// ❌ Wrong — decoding without verifying, and a per-resource role baked into a token that lives
// for hours: forgeable, and a demotion takes effect only when the token expires
const { role } = decodeJwt(token);
if (role !== 'OWNER') throw new ForbiddenOperationException('FORBIDDEN', 'Operation not allowed');

// ✅ Correct (per-resource role) — fetched from the database on each request
const member = await memberRepo.findByUserAndResource(user.id, resourceId);
if (member?.role !== 'OWNER') throw new ForbiddenOperationException('FORBIDDEN', 'Operation not allowed');

// ✅ Also correct (global role/scope) — from the claims of a *verified*, short-lived token,
// mapped to the application's own names by the token verifier (ACL)
if (!authUser.scopes.includes('orders:write')) throw new ForbiddenOperationException('FORBIDDEN', 'Operation not allowed');
```

### Authenticated treated as authorized

```typescript
// ❌ Wrong — only verifies the user is logged in; any user reads any customer's shipments
route('GET /customers/:customer_id/shipments', [authenticate], (req) =>
  listShipments.execute({ customerId: req.params.customer_id }));

// ✅ Correct — authenticate, then authorize on the resource
route('GET /customers/:customer_id/shipments', [authenticate, authorizeMember()], (req) =>
  listShipments.execute({ customerId: req.params.customer_id, requestedBy: req.user.id }));
```

### Authorization scattered, skipped, or after the mutation

Both placements are valid (edge guard, or a policy check in the application layer); what is
wrong is mixing them ad hoc, querying membership tables inline in random use cases, or
checking after the write.

```typescript
// ❌ Wrong — ad hoc inline query, and the check runs after the mutation
class CancelShipmentUseCase {
  async execute(input: CancelInput) {
    const shipment = await this.repo.save((await this.repo.findById(input.shipmentId))!.cancel());
    const member = await this.memberRepo.findByUserAndResource(input.userId, shipment.customerId);
    if (!member) throw new ForbiddenOperationException('FORBIDDEN', 'Operation not allowed');  // too late
    return shipment;
  }
}

// ✅ Option (a) — the edge guarantees authorization; the use case assumes an authorized caller
class CancelShipmentUseCase {
  async execute(input: CancelInput) {
    const shipment = await this.repo.findById(input.shipmentId);
    if (!shipment) throw new ShipmentNotFoundException(input.shipmentId);
    return this.repo.save(shipment.cancel());
  }
}

// ✅ Option (b) — resource-based policy check through an application-owned port, before the mutation
class CancelShipmentUseCase {
  async execute(input: CancelInput) {
    const shipment = await this.repo.findById(input.shipmentId);
    if (!shipment) throw new ShipmentNotFoundException(input.shipmentId);
    await this.authz.ensure(input.caller, 'shipment:cancel', shipment);   // throws ForbiddenOperationException
    return this.repo.save(shipment.cancel());
  }
}
```

### Not revoking the refresh token on logout

```typescript
// ❌ Wrong — clears only the client; the token is still valid on the server for months
async function logout() {
  await tokenStorage.clear();
}

// ✅ Correct — revoke on the backend first, then clear the client
async function logout() {
  // native: token in the body; web: the browser sends the httpOnly cookie, the server
  // revokes it and clears the cookie
  await api.post('/auth/logout', { refresh_token: await tokenStorage.getRefreshToken() });
  await tokenStorage.clear();
}
```

### Exposing a password or token in logs

```typescript
// ❌ Wrong — password or token appears in logs on error
logger.error('Login failed', { email, password, error });

// ✅ Correct — identify the subject only, never the secret
logger.error('Login failed', { email, error: error.message });
```
