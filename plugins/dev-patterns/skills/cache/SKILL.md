---
name: cache
description: >
  Cache patterns with Upstash Redis.
  Invoke automatically when implementing query caching, invalidation,
  cache repositories, Redis-based rate limiting, or any Redis usage in the project.
---

# Cache — Upstash Redis

## Core principle

Cache is infrastructure. The domain and use cases never import Redis directly.
The cache repository is injected via interface — the same as any other repository.

---

## Interface ICacheRepository

```typescript
// domain/services/i-cache.repository.ts
export const CACHE_REPOSITORY = Symbol('CACHE_REPOSITORY');

export interface ICacheRepository {
  get<T>(key: string): Promise<T | null>;
  set<T>(key: string, value: T, ttlSeconds: number): Promise<void>;
  delete(key: string): Promise<void>;
  deleteByPattern(pattern: string): Promise<void>;
  exists(key: string): Promise<boolean>;
}
```

---

## Implementation with Upstash Redis

```typescript
// infrastructure/cache/upstash-cache.repository.ts
@Injectable()
export class UpstashCacheRepository implements ICacheRepository {
  constructor(@Inject(REDIS_CLIENT) private readonly redis: Redis) {}

  async get<T>(key: string): Promise<T | null> {
    const value = await this.redis.get(key);
    if (!value) return null;
    return JSON.parse(value as string) as T;
  }

  async set<T>(key: string, value: T, ttlSeconds: number): Promise<void> {
    await this.redis.set(key, JSON.stringify(value), { ex: ttlSeconds });
  }

  async delete(key: string): Promise<void> {
    await this.redis.del(key);
  }

  async deleteByPattern(pattern: string): Promise<void> {
    // Upstash supports SCAN — use instead of KEYS to avoid blocking
    let cursor = 0;
    do {
      const [nextCursor, keys] = await this.redis.scan(cursor, { match: pattern, count: 100 });
      cursor = Number(nextCursor);
      if (keys.length) await this.redis.del(...keys);
    } while (cursor !== 0);
  }

  async exists(key: string): Promise<boolean> {
    return (await this.redis.exists(key)) === 1;
  }
}
```

---

## Cache key pattern

```
<entity>:<id>                        → single record
<entity>:user:<userId>               → list by user
<entity>:list:<userId>:<date>        → daily list by user
```

Generic examples:

```typescript
export const CacheKeys = {
  resource:          (id: string)     => `resource:${id}`,
  resourceList:      (userId: string) => `resource:user:${userId}`,
  userSettings:      (userId: string) => `user:${userId}:settings`,
  itemsByDate:       (userId: string, date: string) => `items:list:${userId}:${date}`,
} as const;
```

---

## TTL by data type

TTL values are project-specific. Define them in the project spec (e.g. `PROJECT.md`) or a project complement skill.
As a baseline: real-time data → 0; frequently-changing data → 2–5 min; reference data → 10–30 min.

---

## Cache in Use Case — Cache-Aside pattern

```typescript
// application/use-cases/order/get-order-list.use-case.ts
export class GetOrderListUseCase {
  constructor(
    private readonly orderRepo: IOrderRepository,
    private readonly cache: ICacheRepository,
  ) {}

  async execute(input: GetOrderListInput): Promise<OrderListOutput> {
    const cacheKey = CacheKeys.resourceList(input.userId);

    // 1. Try cache first
    const cached = await this.cache.get<OrderListOutput>(cacheKey);
    if (cached) return cached;

    // 2. Fetch from database
    const orders = await this.orderRepo.findByUser(input.userId);
    const output = OrderMapper.toOutput(orders);

    // 3. Save to cache
    await this.cache.set(cacheKey, output, 120); // 2 minutes

    return output;
  }
}
```

---

## Cache invalidation — via Domain Events

Cache is never invalidated manually inside write use cases.
Invalidation happens via event subscriber, keeping the use case clean.

```typescript
// infrastructure/subscribers/invalidate-order-cache.subscriber.ts
@Injectable()
@EventSubscriber('order.placed')
export class InvalidateOrderCacheSubscriber
  implements IEventSubscriber<OrderPlacedEvent>
{
  constructor(private readonly cache: ICacheRepository) {}

  async handle(event: OrderPlacedEvent): Promise<void> {
    await this.cache.delete(CacheKeys.resourceList(event.userId));
    await this.cache.delete(CacheKeys.resource(event.orderId));
  }
}
```

Cache-invalidating events:

| Event | Cache keys to invalidate |
|---|---|
| `order.placed` | `orders:list:{userId}`, `order:{orderId}` |
| `user.updated` | `user:{userId}`, `users:list` |

---

## Rate limiting with Redis

```typescript
// infrastructure/cache/redis-rate-limiter.ts
export class RedisRateLimiter {
  async check(key: string, limit: number, windowSeconds: number): Promise<boolean> {
    const count = await this.redis.incr(key);
    if (count === 1) await this.redis.expire(key, windowSeconds);
    return count <= limit;
  }
}

// Rate limit keys:
// rate:auth:<ip>          → 10 req / 15min
// rate:api:<userId>       → 300 req / 1min
// rate:export:<userId>    → 10 req / 1h
```

---

## Required environment variables

```bash
# Add to .env.example
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=
```
