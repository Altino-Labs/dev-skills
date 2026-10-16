---
name: secrets-rotation
description: >
  Reusable patterns for zero-downtime secret management and rotation.
  Invoke automatically when rotating credentials, handling an exposed secret,
  defining where each type of secret should be stored, or implementing
  a rotation process in production.
---

# Secrets Rotation

## Where each secret lives

Store each secret in the secret store of the platform that consumes it — never in the repo.
The examples name one possible stack; use your project's equivalents.

| Secret | Where to store |
|---|---|
| Backend variables | The deploy platform's environment variables / secret manager (e.g. Railway → Environment Variables, AWS Secrets Manager, Kubernetes Secrets) |
| CI/CD variables | The CI's secret store (e.g. GitHub → Secrets) |
| Sensitive mobile variables | The mobile build service's secrets (e.g. EAS environment variables with `secret` visibility) |
| Web (server-side) variables | The web host's environment variables (e.g. Vercel → Environment Variables) |
| Initial bootstrap | A local, gitignored file (e.g. `.bootstrap-secrets` — never commit) |

**Absolute rules:**
- `.env` with real values is never committed — only `.env.example` with empty keys, or the
  stack's equivalent template (Spring profiles / `application-*.yml` with placeholders, .NET
  `appsettings.*.json` without secrets + user-secrets for local values)
- Separate API keys per environment — staging and production never share the same key
- Secrets never in logs, never in API responses, never in error messages

---

## Zero-downtime rotation — required process

Never revoke the old secret before the new one is in production.

```
Step 1: Generate new secret in the external service
        (keep the old one active — two valid secrets simultaneously)

Step 2: Add the new secret to the platform (deploy platform, CI secrets, etc.)
        (do not remove the old one yet)

Step 3: Deploy the new version
        (the application now uses the new secret)

Step 4: Confirm the new secret is working
        (monitor logs and health check for 15 minutes)

Step 5: Revoke the old secret in the external service
        (now safe — no instance uses it anymore)
```

---

## Exposed secret — immediate response

If a secret was committed, sent in a message, or appeared in a log:

```
1. Revoke the secret immediately in the external service
   (do not wait — assume it was compromised)

2. Generate a new secret

3. Update on platforms (deploy platform, CI, mobile build service — e.g. Railway, GitHub, EAS)

4. Deploy immediately

5. Check service access logs for suspicious activity

6. If it is JWT_SECRET: all existing tokens become invalid
   — users will need to log in again (acceptable)

7. Remove the secret from Git history:
   git filter-repo (the maintained successor of git filter-branch) or BFG Repo Cleaner
   + force push on all branches
   + notify collaborators to re-clone
```

---

## Recommended rotation frequency

| Secret | Frequency |
|---|---|
| JWT_SECRET | 90 days |
| TOKEN_HASH_PEPPER (optional key for hashing refresh tokens) | Only if compromised — rotating it invalidates every stored refresh token (all users log in again) unless the server verifies with both the old and the new pepper during a transition window (dual hash) |
| External service API keys (e.g. a Resend API key; a Supabase service-role / secret API key) | 90 days |
| CI/CD and deploy-platform tokens (e.g. Railway, GitHub, Vercel, an Expo/EAS access token, a Supabase CLI access token used by CI) | 180 days |
| Data encryption keys (e.g. pgcrypto) | Only if compromised |
| Database passwords (e.g. the Supabase database password) | Only if compromised |

Where a common provider's credentials fall:

| Provider | Credential | Bucket |
|---|---|---|
| Vercel | Access token used by CI / deploy scripts | CI/CD and deploy-platform tokens |
| Expo (EAS) | `EXPO_TOKEN` (personal or robot access token) | CI/CD and deploy-platform tokens |
| Supabase | Service-role / secret API key | External service API keys |
| Supabase | CLI access token used by CI (`SUPABASE_ACCESS_TOKEN`) | CI/CD and deploy-platform tokens |
| Supabase | Database password | Database passwords |
| Resend | API key | External service API keys |

Public client keys (e.g. a Supabase anon / publishable key, an Expo public env var) are not
secrets — they ship in the client — and need no scheduled rotation.

---

## Generating secure secrets

```bash
# JWT Secret (minimum 64 characters)
openssl rand -base64 48

# Opaque tokens: 32 random bytes from a CSPRNG (a UUID v4 has only 122 random bits)
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='       # base64url
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"   # e.g. Node

# Hex for encryption keys
openssl rand -hex 32
```

---

## Secrets audit checklist

Run periodically or before go-live:

- [ ] No secrets in committed `.env` files
- [ ] No secrets in source code (`grep -r "password\|secret\|token" src/`)
- [ ] No secrets in CI/CD logs
- [ ] `.env.example` (or the stack's equivalent template) updated with all required variables (no values)
- [ ] Different API keys between staging and production
- [ ] Pending rotation for secrets older than 90 days
- [ ] Access to production secrets restricted to the infra team

---

## Required variables in .env.example (or the stack's equivalent)

Every project must list every variable it reads, with empty values — in `.env.example`, or the
stack's equivalent (Spring profiles / `application-*.yml` placeholders, .NET
`appsettings.*.json` + user-secrets). Example for a TypeScript/Node
project on one possible stack (Upstash, Sentry, Resend) — adapt names and services to yours:

```bash
# App
NODE_ENV=
PORT=                     # most PaaS (e.g. Railway) inject PORT — read it, not a custom name

# Auth
JWT_SECRET=
TOKEN_HASH_PEPPER=        # optional — refresh tokens are opaque; this only keys their stored hash

# Database
DATABASE_URL=

# Cache
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=

# Observability
SENTRY_DSN=
LOG_LEVEL=

# Email
RESEND_API_KEY=
EMAIL_FROM=
```
