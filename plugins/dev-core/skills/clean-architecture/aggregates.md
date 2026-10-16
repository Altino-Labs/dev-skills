# Aggregate Root and OCP/Strategy
> Sub-file of the `dev-core:clean-architecture` skill. Read when designing aggregate boundaries,
> implementing child entities, or applying the Open/Closed Principle via Strategy.

---

## Aggregate Root pattern

An **aggregate** is a cluster of domain objects (entities + value objects) that must be
kept consistent as a unit. The **aggregate root** is the only public entry point to that cluster:
all reads and writes to child entities must go through it.

### Design principle — aggregate as a transaction boundary

> "Design aggregates around business transactions, not around object graphs."
> — Vaughn Vernon, *Implementing Domain-Driven Design*

**The key question:** "What is the smallest set of objects that must be consistent after this operation?"

This explains the canonical `Order`/`OrderItem` boundary:
- "Add item to order" is one business transaction — `Order` header and `OrderItem` must be consistent together.
- `Customer` is NOT part of the `Order` aggregate: no single operation requires both to change simultaneously; they synchronize via events.

**Prefer small aggregates.** A large aggregate means more objects lock in every transaction — higher contention, lower throughput.

### Rules

1. **Single entry point** — use cases interact only with the root, never directly with children.
2. **Invariant enforcement** — the root is responsible for all business rules spanning children.
3. **One repository per aggregate** — no repository for child entities; persistence goes through the root.
4. **Children created through the root** — never instantiated independently by a use case.
5. **Identity boundary** — a child entity's identity is meaningful only inside its aggregate.
6. **Prefer small aggregates** — if in doubt, exclude. Cross-aggregate consistency via domain events is cheaper than wide locks.

### Example — Order aggregate (Evans, *Domain-Driven Design*, ch. 6)

```typescript
// domain/entities/order-item.entity.ts
export interface OrderItemProps {
  id: string;
  productId: string;
  quantity: number;
  unitPrice: Money;
}

export class OrderItem {
  private constructor(
    public readonly id: string,
    public readonly productId: string,
    public readonly quantity: number,
    public readonly unitPrice: Money,
  ) {}

  static create(props: OrderItemProps): OrderItem {
    return new OrderItem(props.id, props.productId, props.quantity, props.unitPrice);
  }

  get subtotal(): Money {
    return this.unitPrice.multiply(this.quantity);
  }
}

// domain/entities/order.entity.ts — the AGGREGATE ROOT
// This is the canonical Order shape used by every example in these skills.
export interface OrderProps {
  id: string;
  customerId: string;
  items: OrderItem[];
  status: OrderStatus;
  currency: string;
}

export class Order {
  private constructor(
    public readonly id: string,
    public readonly customerId: string,
    private readonly _items: OrderItem[],
    public readonly status: OrderStatus,
    public readonly currency: string,
  ) {}

  static create(props: { id: string; customerId: string; currency: string }): Order {
    return new Order(props.id, props.customerId, [], OrderStatus.DRAFT, props.currency);
  }

  static reconstitute(props: OrderProps): Order {
    return new Order(props.id, props.customerId, props.items, props.status, props.currency);
  }

  // Children created through the root — ALL invariants of the operation checked here.
  //
  // The item id is passed in from the Use Case (not generated internally) so that
  // the Use Case can return item_id in the output without traversing the aggregate.
  // Generating ids in the Use Case is correct: id assignment is an application-layer
  // concern, just as in Order.create({ id, customerId, currency }).
  //
  // quantity: plain number — VO detection protocol applied: no decrement behaviour,
  // no format rule, no multi-field invariant. The only bound (> 0) is enforced by
  // the guard below. If decrement behaviour were needed, Quantity VO would apply.
  addItem(id: string, productId: string, quantity: number, unitPrice: Money): Order {
    if (this.status !== OrderStatus.DRAFT)
      throw new OrderNotEditableException(this.id);
    if (quantity <= 0)
      throw new InvalidValueException('ORDER_ITEM_QUANTITY_INVALID', 'Item quantity must be greater than zero.');
    if (unitPrice.currency !== this.currency)
      throw new OrderCurrencyMismatchException(this.id, unitPrice.currency, this.currency);

    const item = OrderItem.create({ id, productId, quantity, unitPrice });
    return new Order(this.id, this.customerId, [...this._items, item], this.status, this.currency);
  }

  // Invariant spanning children — enforced at the root
  get total(): Money {
    return this._items.reduce((sum, item) => sum.add(item.subtotal), Money.zero(this.currency));
  }

  get items(): readonly OrderItem[] { return this._items; }
}
```

```typescript
// domain/repositories/i-order.repository.ts
// One repository for the aggregate — OrderItem has no repository of its own
export interface IOrderRepository {
  findById(id: string): Promise<Order | null>;
  save(order: Order): Promise<Order>;   // persists root + all children atomically
}
```

```typescript
// use-cases/add-item-to-order.use-case.ts
export class AddItemToOrderUseCase {
  constructor(private readonly orders: IOrderRepository) {}

  async execute(input: AddItemInput): Promise<AddItemOutput> {
    const order = await this.orders.findById(input.orderId);
    if (!order) throw new OrderNotFoundException(input.orderId);

    // The Use Case generates the item id — same pattern as Order.create({ id, ... }).
    // This avoids traversing the aggregate after save to recover the id:
    //   order.items[order.items.length - 1].id  ← Law of Demeter violation (child entity)
    const itemId = generateId();

    // Mutation goes through the root — use case never touches OrderItem directly
    const updated = order.addItem(itemId, input.productId, input.quantity, input.unitPrice);
    const saved = await this.orders.save(updated);
    return this.toOutput(saved, itemId);
  }

  private toOutput(order: Order, itemId: string): AddItemOutput {
    return {
      order_id:    order.id,
      item_id:     itemId,              // no traversal — id is known from the Use Case
      total_items: order.items.length,
    };
  }
}
```

### What signals an aggregate boundary

| Signal | Implication |
|---|---|
| Must be consistent after one atomic operation | Belongs to the same aggregate |
| Child cannot exist without parent | Child belongs to the parent's aggregate |
| Business rule spans parent + child | Root must enforce it |
| Child is always loaded with the parent | Single aggregate, single repository |
| Child can be shared between parents | It is its own aggregate root |
| Child has meaningful identity outside the parent | It is its own aggregate root |
| Two objects change together only occasionally | Separate aggregates — use domain events |
| Including the object widens every transaction | Exclude it; keep aggregates small |

### Anti-patterns

```typescript
// ❌ WRONG — use case bypasses the root and mutates a child directly
const item = await this.orderItemRepository.findById(itemId);
item.quantity = newQuantity;
await this.orderItemRepository.save(item);
// The Order aggregate never knew — total is now wrong

// ✅ CORRECT — mutation goes through the root
const order = await this.orderRepository.findById(orderId);
const updated = order.updateItemQuantity(itemId, newQuantity);
await this.orderRepository.save(updated);
```

```typescript
// ❌ WRONG — repository for the child entity (should not exist)
export interface IOrderItemRepository {
  findById(id: string): Promise<OrderItem | null>;
  save(item: OrderItem): Promise<void>;
}

// ✅ CORRECT — child persistence is delegated to the root's repository
export interface IOrderRepository {
  save(order: Order): Promise<Order>;   // atomically saves root + all children
}
```

---

## OCP — Open/Closed Principle

**Rule:** when behavior varies by type, status, or role — use the Strategy pattern.
Never use `if/switch` chains on entity type inside Use Cases or repositories.
Adding a new variant means adding a new class, not editing an existing Use Case.

### Anti-pattern to avoid

```typescript
// ❌ WRONG — every new order type requires editing this Use Case
export class CalculateDiscountUseCase {
  async execute(order: Order): Promise<Money> {
    if (order.type === OrderType.STANDARD) return Money.zero(order.currency);
    if (order.type === OrderType.PREMIUM)  return order.total.multiply(0.10);
    if (order.type === OrderType.VIP)      return order.total.multiply(0.20);
    // PARTNER type added tomorrow → this Use Case must be opened again
    throw new Error('Unknown order type');
  }
}
```

### Correct pattern — Strategy + Factory

```typescript
// domain/value-objects/discount-policy.vo.ts
export interface DiscountPolicy {
  calculate(order: Order): Money;
}

export class StandardDiscountPolicy implements DiscountPolicy {
  calculate(order: Order): Money { return Money.zero(order.currency); }
}

export class PremiumDiscountPolicy implements DiscountPolicy {
  calculate(order: Order): Money { return order.total.multiply(0.10); }
}

export class VipDiscountPolicy implements DiscountPolicy {
  calculate(order: Order): Money { return order.total.multiply(0.20); }
}

export class PartnerDiscountPolicy implements DiscountPolicy {
  calculate(order: Order): Money { return order.total.multiply(0.15); }
}

// Factory: adding a new type means adding an entry here — nowhere else
export class DiscountPolicyFactory {
  static for(type: OrderType): DiscountPolicy {
    const policies: Record<OrderType, DiscountPolicy> = {
      [OrderType.STANDARD]: new StandardDiscountPolicy(),
      [OrderType.PREMIUM]:  new PremiumDiscountPolicy(),
      [OrderType.VIP]:      new VipDiscountPolicy(),
      [OrderType.PARTNER]:  new PartnerDiscountPolicy(),
    };
    return policies[type] ?? new StandardDiscountPolicy();
  }
}

// Use Case: never changes when new order types appear
export class CalculateDiscountUseCase {
  async execute(order: Order): Promise<Money> {
    return DiscountPolicyFactory.for(order.type).calculate(order);
  }
}
```

### When Strategies need injected dependencies — factory as a port

The static factory above works only when Strategies are **pure classes with no constructor arguments**.
When a Strategy needs an injected dependency, switch to DI registration: the factory becomes a
port (interface in the domain) and the composition root / DI container builds it with the
strategies already wired.

**Detection rule:** if any Strategy class has a constructor with parameters, use DI.

```typescript
// domain/discount-policy.factory.ts — interface only (plus a DI token if the container needs one)
export interface IDiscountPolicyFactory {
  for(type: OrderType): DiscountPolicy;
}
```

```typescript
// composition root — the only place that knows the concrete strategies and their dependencies
export function buildDiscountPolicyFactory(loyalty: ILoyaltyRepository): IDiscountPolicyFactory {
  const std  = new StandardDiscountPolicy();        // no constructor args — pure
  const prem = new PremiumDiscountPolicy(loyalty);  // needs ILoyaltyRepository
  const vip  = new VipDiscountPolicy();             // pure
  return {
    for: (type: OrderType): DiscountPolicy =>
      ({ [OrderType.STANDARD]: std, [OrderType.PREMIUM]: prem, [OrderType.VIP]: vip }[type] ?? std),
  };
}
```

With a DI container, register the strategies as providers and the factory as a provider built
from them (see the stack plugin, e.g. `dev-patterns:clean-architecture`).

```typescript
// Use Case: identical to static factory version
export class CalculateDiscountUseCase {
  constructor(
    private readonly factory: IDiscountPolicyFactory,
    private readonly orders: IOrderRepository,
  ) {}

  async execute(input: CalculateDiscountInput): Promise<Money> {
    const order = await this.orders.findById(input.orderId);
    if (!order) throw new OrderNotFoundException(input.orderId);
    return this.factory.for(order.type).calculate(order);
  }
}
```

**Decision rule — static vs DI factory:**

| Strategies have | Pattern | Why |
|---|---|---|
| No constructor args (pure) | Static factory — `DiscountPolicyFactory.for()` | Simpler; no module wiring needed |
| Constructor args (injected deps) | DI factory — factory port built by the composition root / DI container | Maintains DIP; strategies fully testable |

### When OCP applies vs does NOT apply

| Signal | Action |
|---|---|
| `if (type === 'A') ... else if (type === 'B')` in a Use Case | Extract Strategy per type |
| `switch (status)` with distinct business logic per status | Extract Strategy per status |
| Adding a new enum value requires editing an existing Use Case | Factory + Strategy missing |
| Simple data routing (different query filter per type) | OCP does NOT apply — filter inside repo method |

OCP applies when each branch contains **distinct business logic**, not just a different query filter.
