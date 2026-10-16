---
name: railway-nestjs
description: >
  Reusable patterns for deploying NestJS applications on Railway.
  Invoke automatically when configuring Railway, writing a NestJS Dockerfile,
  implementing health checks, graceful shutdown, or automatic deploy via GitHub.
---

# Railway + NestJS

## Recommended service structure

```
Railway Project: <project-name>
├── api-production    ← branch main
└── api-staging       ← branch develop
```

Do not create Redis on Railway — use Upstash (serverless, cheaper for MVPs).

---

## `@fastify/*` plugin versions — mandatory compatibility

The `@fastify/*` plugins have major versions tied to the Fastify major version.
NestJS 10 uses **Fastify 4** internally. Installing plugins v12+/v7+/v9+ causes a crash on startup:
`FastifyError: fastify-plugin: @fastify/helmet - expected '5.x' fastify version, '4.x' is installed`

| Plugin | NestJS 10 (Fastify 4) | NestJS 11+ (Fastify 5) |
|---|---|---|
| `@fastify/helmet` | `^11.x` | `^13.x` |
| `@fastify/static` | `^6.x` | `^10.1.2`+ |
| `@fastify/multipart` | `^8.x` | `^10.x` |
| `@fastify/cors` | `^8.x` | `^10.x` |

The "NestJS 11+" versions above are the ones actually verified together in a real
NestJS 10 → 11 migration — not just the first major that's nominally Fastify-5-compatible. Picking an
earlier Fastify-5-compatible major (e.g. `@fastify/static@^7.x`) may still carry CVEs that
only got patched in a later minor/major — see skill `nestjs-fastify` for the full peer
dependency chain and the CVE this specifically closes.

**How to verify the Fastify version used by NestJS:**
```bash
node -e "console.log(require('@nestjs/platform-fastify').FastifyAdapter.name)"
cat node_modules/fastify/package.json | grep '"version"'
```

Before installing any `@fastify/*` plugin, confirm the Fastify major version in use.
Never use `^latest` for Fastify plugins — always pin to the correct major.

---

## NestJS Dockerfile for monorepo

```dockerfile
# apps/api/Dockerfile
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
COPY apps/api/package*.json ./apps/api/
COPY packages/ ./packages/
RUN npm ci
COPY apps/api ./apps/api
RUN npm run build -w apps/api

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/apps/api/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
EXPOSE 3000
CMD ["node", "dist/main.js"]
```

---

## Required health checks

```typescript
// interfaces/http/health/health.controller.ts
@Controller('health')
@Public()
export class HealthController {
  @Get('live')   // Railway uses this — is the app up?
  live() { return { status: 'ok' }; }

  @Get('ready')  // CI/CD uses this — is the app ready to receive traffic?
  async ready() {
    return {
      status: 'ok',
      timestamp: new Date().toISOString(),
      checks: {
        database: await this.db.ping(),
        cache:    await this.redis.ping(),
      },
    };
  }
}
```

**Configure in Railway:**
```
Health check path: /health/live
Restart policy: always
```

---

## Required graceful shutdown

```typescript
// apps/api/src/main.ts
async function bootstrap() {
  const app = await NestFactory.create(AppModule);

  app.enableShutdownHooks();

  ['SIGTERM', 'SIGINT'].forEach(signal => {
    process.on(signal, async () => {
      await app.close();
      process.exit(0);
    });
  });

  await app.listen(process.env.APP_PORT ?? 3000);
}
```

Without graceful shutdown, Railway kills the process abruptly during deploys,
which can corrupt in-flight requests.

---

## Minimum environment variables per service

```bash
NODE_ENV=production         # or staging
APP_PORT=3000
DATABASE_URL=               # connection pooler (port 6543 in Supabase)
JWT_SECRET=                 # minimum 64 characters — generate with: openssl rand -base64 48
TOKEN_HASH_PEPPER=          # optional — keys the stored refresh-token hash (refresh tokens are opaque)
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=
SENTRY_DSN=
```

---

## Automatic deploy

Railway detects pushes to the configured branch and deploys automatically.

```
Production service → branch: main
Staging service    → branch: develop
```

After each deploy, Railway runs the health check. If `/health/live` does not respond
within 30s, the deploy is automatically rolled back.

---

## Rollback

```bash
# Via CLI
railway rollback --service api-production

# Migrations (if down is implemented)
npm run migrate:rollback --env production
```

---

## Limits and costs

| Plan | CPU | RAM | Cost |
|---|---|---|---|
| Free ($5 credit/month) | Shared | 512MB | ~$0 |
| Hobby ($5/service) | Shared | 512MB | $10/month (2 services) |
| Pro | Dedicated | Configurable | Pay-as-you-go |

**Trigger to scale:** consistent usage > $5/month in credits or p95 latency > 800ms.
