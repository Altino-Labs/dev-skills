# Backend Authentication and Authorization
> Sub-file of `dev-patterns:auth-security`. Read when implementing JWT guards, permission
> decorators, role-based authorization, refresh token rotation, Supabase auth integration, or
> rate limiting. Rules and anti-patterns: `dev-core:auth-security`.

---

## JWT Module configuration

```typescript
// infrastructure/auth/auth.module.ts
JwtModule.registerAsync({
  inject: [ConfigService],
  useFactory: (config: ConfigService) => ({
    secret: config.getOrThrow('JWT_SECRET'),
    signOptions: {
      expiresIn: '15m',
      issuer: 'your-app-api',
      audience: 'your-app-client',
    },
  }),
})
```

### JWT payload

```typescript
export interface JwtPayload {
  sub: string;       // userId
  email: string;
  iat: number;       // issued at
  exp: number;       // expiry
  iss: string;       // 'your-app-api'
  aud: string;       // 'your-app-client'
}
```

Never include sensitive data in the payload (national IDs, address, role). Role is fetched from the database on each request — **never from the token**.

### Global authentication guard

> ⚠️ **Two patterns exist — choose based on the token signing algorithm:**
>
> | Auth provider | Signing | Pattern to use |
> |---|---|---|
> | **Supabase** (CLI v2+, cloud) | **ES256** (asymmetric) | **Skip to "Supabase as auth provider" below** — `supabase.client.auth.getUser(token)` |
> | Project-issued JWTs | **HS256** (symmetric secret) | Pattern below — `AuthGuard('jwt')` + `JWT_SECRET` |
>
> Using `AuthGuard('jwt')` with an ES256 token fails silently: the guard returns HTTP 401
> on every authenticated request. Build and tests pass (guard is mocked in unit tests);
> the failure only surfaces in production smoke testing.

**Pattern for HS256 projects (self-issued JWTs only):**

```typescript
// infrastructure/auth/guards/jwt-auth.guard.ts
@Injectable()
export class JwtAuthGuard extends AuthGuard('jwt') implements CanActivate {
  constructor(private readonly reflector: Reflector) { super(); }

  canActivate(context: ExecutionContext): boolean | Promise<boolean> {
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (isPublic) return true;
    return super.canActivate(context) as Promise<boolean>;
  }
}
```

Register globally in `AppModule` — all endpoints are protected by default:

```typescript
providers: [{ provide: APP_GUARD, useClass: JwtAuthGuard }]
```

### Decorator `@Public()` — endpoints that don't need auth

```typescript
export const IS_PUBLIC_KEY = 'isPublic';
export const Public = () => SetMetadata(IS_PUBLIC_KEY, true);

@Public()
@Post('auth/login')
async login(@Body() dto: LoginDto) { ... }
```

Typical public endpoints (list the project's real ones in its own docs):
- `POST /api/v1/auth/register`
- `POST /api/v1/auth/login`
- `POST /api/v1/auth/refresh`
- `GET  /api/v1/invitations/:token` — lookup by an emailed, unguessable token
- health checks (`/api/v1/health/live`, `/api/v1/health/ready` with the global prefix)

Anything that acts *as* a user (e.g. accepting an invitation into the caller's account)
is **not** public, even if it is reached through an emailed token link — it needs
`@CurrentUser()`.

### Decorator `@CurrentUser()` — inject authenticated user

```typescript
export const CurrentUser = createParamDecorator(
  (_: unknown, ctx: ExecutionContext): AuthUser => {
    return ctx.switchToHttp().getRequest().user;
  },
);
```

---

## Role-based permission matrix

The matrix itself and the two-level rule (membership, then role): `dev-core:auth-security`.

### Role authorization guard

```typescript
// infrastructure/auth/guards/resource-member.guard.ts
@Injectable()
export class ResourceMemberGuard implements CanActivate {
  constructor(
    private readonly memberRepo: IMemberRepository,
    private readonly reflector: Reflector,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const requiredRoles = this.reflector.get<MemberRole[]>(ROLES_KEY, context.getHandler());
    const request = context.switchToHttp().getRequest();
    const user: AuthUser = request.user;
    const resourceId = request.params.resourceId ?? request.params.id ?? request.body.resourceId;

    if (!resourceId) throw new InvalidValueException('RESOURCE_ID_REQUIRED', 'A resource identifier is required to perform authorization.');

    const member = await this.memberRepo.findByUserAndResource(user.id, resourceId);

    if (!member || !member.acceptedAt) throw new ForbiddenOperationException('FORBIDDEN', 'Operation not allowed');

    if (requiredRoles?.length && !requiredRoles.includes(member.role)) {
      throw new ForbiddenOperationException('FORBIDDEN', 'Operation not allowed');
    }

    request.member = member;
    return true;
  }
}
```

### Decorator `@RequireRoles()` — restrict by role

```typescript
export const ROLES_KEY = 'roles';
export const RequireRoles = (...roles: MemberRole[]) => SetMetadata(ROLES_KEY, roles);

@Post(':resourceId/invite')
@UseGuards(ResourceMemberGuard)
@RequireRoles('ADMIN')
async inviteMember(
  @Param('resourceId') resourceId: string,
  @Body() dto: InviteMemberDto,
  @CurrentUser() user: AuthUser,
) {
  return this.useCase.execute({ ...dto, resourceId, invitedBy: user.id });
}
```

---

## Refresh Token — backend use case

```typescript
async execute(refreshToken: string): Promise<RefreshOutput> {
  // Stored as a hash only — hash the presented token, then look it up (dev-core:auth-security)
  const tokenHash = createHash('sha256').update(refreshToken).digest('hex');   // node:crypto
  const stored = await this.tokenRepo.findByTokenHash(tokenHash);

  if (!stored)             throw new UnauthorizedException('INVALID_REFRESH_TOKEN', 'Invalid refresh token');
  if (stored.revokedAt)    throw new UnauthorizedException('REVOKED_REFRESH_TOKEN', 'Refresh token revoked');
  if (stored.expiresAt < new Date()) throw new UnauthorizedException('EXPIRED_REFRESH_TOKEN', 'Refresh token expired');

  // Rotate: revoke current, issue new pair
  await this.tokenRepo.revoke(stored.id);

  const user = await this.userRepo.findById(stored.userId);
  return this.issueTokenPair(user);
}
```

Refresh tokens are **opaque** (32 random bytes — `randomBytes(32).toString('base64url')` from `node:crypto`; a UUID v4 has only 122 random bits), stored in the `refresh_tokens` table **as a hash** (`token_hash`, unique index) with `expiresAt` and `revokedAt`. Native clients get the token in the response body; web clients only as an `httpOnly`, `Secure`, `SameSite` cookie set by the server (`dev-core:auth-security`). Never store refresh tokens in localStorage.

---

## Supabase as auth provider — required pattern

When the project uses **Supabase as the auth provider**, do not use `passport-jwt` with a fixed secret.

**Why:** Supabase CLI v2.x+ uses **ES256** (ECDSA) to sign tokens locally. `passport-jwt` with `algorithms: ['HS256']` fails silently, returning 401 even with a valid token.

**Correct pattern — `CanActivate` delegating to Supabase:**

```typescript
@Injectable()
export class JwtAuthGuard implements CanActivate {
  constructor(private readonly supabase: SupabaseService) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();
    const authHeader = request.headers['authorization'];

    if (!authHeader?.startsWith('Bearer '))
      throw new UnauthorizedException('MISSING_TOKEN', 'Authorization token is required.');

    const token = authHeader.slice(7);
    const { data, error } = await this.supabase.client.auth.getUser(token);

    if (error || !data?.user)
      throw new UnauthorizedException('INVALID_TOKEN', 'Token is invalid or has expired.');

    request.user = { id: data.user.id, email: data.user.email, user_metadata: data.user.user_metadata };
    return true;
  }
}
```

Register the guard in the `@Global()` AuthorizationModule.

> **If this guard is registered as `APP_GUARD`**, it must honor `@Public()` too —
> otherwise every public route returns 401. Inject `Reflector` and check
> `IS_PUBLIC_KEY` first, exactly as in the HS256 guard above:
>
> ```typescript
> const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC_KEY, [
>   context.getHandler(), context.getClass(),
> ]);
> if (isPublic) return true;
> ```

**When to use `passport-jwt`:** only if the project issues its own JWTs (not delegating to Supabase). In that case, use `algorithms: ['HS256']` with a dedicated `JWT_SECRET`.

---

## Rate limiting — `@nestjs/throttler`

Limits and rationale: `dev-core:auth-security` (auth endpoints) and `dev-core:api-contracts`
(general rules).

**Setup — global default + per-route override:**

```typescript
// main.ts — trustProxy is mandatory behind Railway/any reverse proxy, otherwise every
// request resolves to the proxy's IP and per-IP throttling becomes a no-op
new FastifyAdapter({ logger: false, trustProxy: true });

// app.module.ts
ThrottlerModule.forRoot([{ name: 'default', ttl: 60_000, limit: 120 }]), // safety net for the whole API
providers: [
  { provide: APP_GUARD, useClass: ThrottlerGuard },   // register before JwtAuthGuard
  { provide: APP_GUARD, useFactory: (...) => new JwtAuthGuard(...) },
]
```

```typescript
// auth.controller.ts — tighter limits on sensitive routes
@Public()
@Throttle({ default: { limit: 5, ttl: 900_000 } })   // 5 per 15 min
@Post('login')
async loginUser(@Body() dto: LoginDto) { ... }

@Public()
@Throttle({ default: { limit: 10, ttl: 300_000 } })  // refresh is lower-risk, higher volume
@Post('refresh')
async refresh(...) { ... }
```

Same pattern on any invite endpoint (e.g. `POST /projects/:id/invite`) to stop invite spam —
`{ limit: 10, ttl: 3_600_000 }` (10/hour).

Keep the named throttle profiles (e.g. `AUTH_ACTION_THROTTLE`, `TOKEN_LINK_THROTTLE`,
`INVITE_CREATE_THROTTLE`) in one shared file (e.g. `src/shared/rate-limits.ts`).

**Known limitation:** the default storage is in-memory — each API instance has its own
counter. Fine for a single instance; if the API ever runs more than one replica, move to
Redis-backed storage (Upstash, already used for cache — see `dev-patterns:cache`) or the limits
become per-instance instead of global.

---

## Authenticated ≠ authorized in this stack

The other anti-patterns are in `dev-core:auth-security`. In NestJS, the authorization guard
goes next to the authentication guard on every resource route:

```typescript
// ❌ Wrong — only verifies the user is logged in; any user accesses any resource
@UseGuards(JwtAuthGuard)
@Get(':customerId/shipments')
async list(@Param('customerId') customerId: string) {
  return this.useCase.execute({ customerId });
}

// ✅ Correct — JwtAuthGuard authenticates; ResourceMemberGuard authorizes
@UseGuards(JwtAuthGuard, ResourceMemberGuard)
@Get(':customerId/shipments')
async list(@Param('customerId') customerId: string, @CurrentUser() user: AuthUser) {
  return this.useCase.execute({ customerId, requestedBy: user.id });
}
```
