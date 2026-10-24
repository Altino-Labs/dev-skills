# Frontend Token Management and Route Protection
> Sub-file of `dev-patterns:auth-security`. Read when implementing token storage, the
> refresh interceptor, the auth Zustand store, or route protection in Expo Router or Next.js.
> Rules: `dev-core:auth-security`.

---

## Token storage — Expo (SecureStore on native, explicit web fallback)

`expo-secure-store` backs onto the iOS Keychain / Android Keystore — use it for the session
tokens (`access_token`, `refresh_token`) on iOS and Android, **never AsyncStorage**, which is
unencrypted at rest on both platforms. SecureStore has **no web implementation**, so on web
(react-native-web) the service falls back to AsyncStorage (backed by `localStorage`). That is
the explicit lower-security web fallback from `dev-core:auth-security`: the web build is
treated as a lower-security context.

```typescript
// shared/services/token.service.ts
import { Platform } from 'react-native';
import * as SecureStore from 'expo-secure-store';
import AsyncStorage from '@react-native-async-storage/async-storage';

// Native: Keychain / Keystore. Web: SecureStore has no implementation → AsyncStorage
// (localStorage) — the documented lower-security fallback.
const isWeb = Platform.OS === 'web';
const getItem = (key: string) => (isWeb ? AsyncStorage.getItem(key) : SecureStore.getItemAsync(key));
const setItem = (key: string, value: string) =>
  isWeb ? AsyncStorage.setItem(key, value) : SecureStore.setItemAsync(key, value);

export const tokenService = {
  getAccessToken:  () => getItem('access_token'),
  setAccessToken:  (t: string) => setItem('access_token', t),
  getRefreshToken: () => getItem('refresh_token'),
  setRefreshToken: (t: string) => setItem('refresh_token', t),
  async clear() {
    if (isWeb) {
      await AsyncStorage.multiRemove(['access_token', 'refresh_token']);
      return;
    }
    await SecureStore.deleteItemAsync('access_token');
    await SecureStore.deleteItemAsync('refresh_token');
  },
};
```

All token reads and writes go through `tokenService` — never AsyncStorage or SecureStore
directly from features.

---

## Automatic refresh interceptor

Lives in the mobile app's API client module (e.g. `src/lib/api-client.ts`). On every 401:
1. Attempts to exchange the stored `refresh_token` for a new `access_token`
2. If refresh succeeds → retries the original request once with the new token
3. If refresh fails → clears both tokens and calls `router.replace('/login')` **silently** — no error is shown

**Critical rule:** never `throw` when the refresh fails. Throwing propagates the error to the calling hook/mutation, which may display it to the user ("UNAUTHENTICATED"). The correct behaviour is a silent redirect.

```typescript
// src/lib/api-client.ts
import { router } from 'expo-router';

let refreshPromise: Promise<string | null> | null = null;

async function attemptRefresh(): Promise<string | null> {
  // Deduplicates concurrent refresh calls — only one in-flight at a time
  if (refreshPromise) return refreshPromise;
  refreshPromise = (async () => {
    try {
      // Always through tokenService — SecureStore on native, the web fallback on web.
      const refresh_token = await tokenService.getRefreshToken();
      if (!refresh_token) return null;
      const res = await fetch(`${BASE_URL}/auth/refresh`, { method: 'POST', ... });
      if (!res.ok) return null;
      const { access_token } = await res.json();
      await tokenService.setAccessToken(access_token);
      return access_token;
    } catch { return null; }
    finally { refreshPromise = null; }
  })();
  return refreshPromise;
}

// Inside apiRequest, on 401:
if (res.status === 401 && !skipRefresh) {
  const newToken = await attemptRefresh();
  if (!newToken) {
    await tokenService.clear();
    router.replace('/login' as any);  // silent redirect — never throw here
    return undefined as T;
  }
  res = await makeRequest(newToken);  // retry once with new token
}
```

**Session lifetime (typical Supabase Auth setup — record the project's real values):**
- `access_token` (JWT): short-lived (Supabase default `jwt_expiry = 3600`, i.e. 1 hour) — refreshed automatically and transparently
- `refresh_token`: long-lived (months), rotated on each use
- Silent 401 redirect is the last-resort safety net, not the normal path

---

## Authentication store (Zustand)

```typescript
// shared/store/auth.store.ts
interface AuthState {
  user: AuthUser | null;
  isAuthenticated: boolean;
  login: (credentials: LoginDto) => Promise<void>;
  logout: () => Promise<void>;
}

export const useAuthStore = create<AuthState>((set) => ({
  user: null,
  isAuthenticated: false,

  login: async (credentials) => {
    // Wire fields are snake_case (dev-core:api-contracts)
    const { access_token, refresh_token, user } =
      await apiClient.post('/api/v1/auth/login', credentials);
    await tokenService.setAccessToken(access_token);
    await tokenService.setRefreshToken(refresh_token);
    set({ user, isAuthenticated: true });
  },

  logout: async () => {
    // Revoke on the backend first, then clear the client
    await apiClient.post('/api/v1/auth/logout', { refresh_token: await tokenService.getRefreshToken() });
    await tokenService.clear();
    set({ user: null, isAuthenticated: false });
  },
}));
```

---

## Route protection — Mobile (Expo Router)

UX only — the API enforces authorization on every request.

```typescript
// app/(app)/_layout.tsx
export default function AppLayout() {
  const { isAuthenticated } = useAuthStore();

  if (!isAuthenticated) {
    return <Redirect href="/login" />;
  }

  return <Stack />;
}
```

## Route protection — Web (Next.js middleware)

```typescript
// middleware.ts
export function middleware(request: NextRequest) {
  const token = request.cookies.get('access_token');
  const isPublicPath = PUBLIC_PATHS.some(p => request.nextUrl.pathname.startsWith(p));

  if (!token && !isPublicPath) {
    return NextResponse.redirect(new URL('/login', request.url));
  }
}

export const config = { matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'] };
```

## `@supabase/ssr` — browser cookies are readable by JavaScript

`createBrowserClient` from `@supabase/ssr` stores the session (access **and** refresh token) in
cookies that the browser client itself writes and reads — so they are **not `httpOnly`**. Any
XSS on the origin can read and exfiltrate the refresh token. That is the same lower-security
web posture as the documented browser-storage fallback (`dev-core:auth-security` → secure
token storage), not the `httpOnly`-cookie default — record it as such if you accept it.

Server-side alternative (BFF) when the web app must meet the `httpOnly` default:
- Only server code (Next.js route handlers / server actions / middleware with
  `createServerClient`, or your own API) talks to Supabase Auth and holds the tokens.
- The server sets the session as `httpOnly`, `Secure`, `SameSite` cookies; browser code never
  touches tokens and calls the server, which forwards the access token to the API.
- Add CSRF protection for cookie-authenticated state-changing requests
  (`dev-core:auth-security`).

## Next.js BFF for an admin web app

The concept and its rules: `dev-core:auth-security` → "Backend-for-frontend (BFF) for an admin
web app". In Next.js (App Router):

- **Auth route handlers** — `app/api/auth/{login,logout,session,mfa/*}/route.ts`, using
  `createServerClient` from `@supabase/ssr`. `session` returns `{ user: { email }, is_admin }`,
  never a token. The browser calls them through a small `auth-api.ts`; no Supabase client is
  ever created in browser code.
- **One cookie helper** — every session cookie write (route handlers **and** the middleware's
  token refresh) goes through one function that sets `httpOnly`, `SameSite=Strict`,
  `path: '/'` and `Secure` in production, so no call site forgets a flag.
- **API proxy** — `app/api/proxy/[...path]/route.ts` forwards to a **server-only** env var
  (e.g. `API_ORIGIN_URL`, no `NEXT_PUBLIC_` prefix). It reads the session, sets
  `Authorization: Bearer`, copies only `content-type`, `accept` and `idempotency-key` from the
  incoming request, never forwards cookies, and answers 400 to any `.` / `..` segment (check
  the decoded segments). The client's API base URL is `'/api/proxy'`.
- **Same-origin check** — mutating `/api/*` handlers require `Origin` to equal the request's own
  origin (missing → 403).
- **Middleware** never redirects `/api/*` — each route answers JSON (401/403) and checks its
  own session; page routes redirect to `/login`.
- **CSP** `connect-src 'self'` plus the error tracker's ingest host (`next.config` headers).
- When the API sits behind Cloudflare with Bot Fight Mode, the proxy (a Vercel/serverless
  function = datacenter traffic) must call the API's **origin** URL with an origin-auth header,
  not the proxied hostname — `dev-patterns:cloudflare-setup` → "Bot Fight Mode blocks datacenter traffic".
