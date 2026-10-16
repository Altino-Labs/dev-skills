# Value Objects
> Sub-file of the `dev-core:clean-architecture` skill. Read when creating a Value Object, running the
> VO detection protocol, or deciding between `create()` and `reconstitute()`.

---

## Value Object pattern

Value Objects encapsulate validation and behavior for domain primitives.
Use them whenever a primitive has invariants, formatting, or comparison logic.

```typescript
export class ValueObjectName {
  private constructor(public readonly value: string) {}

  static create(raw: string): ValueObjectName {
    if (!raw || raw.trim().length === 0)
      throw new InvalidValueException('VALUE_OBJECT_INVALID', 'Description of the rule violated.');
    return new ValueObjectName(raw.trim());
  }

  equals(other: ValueObjectName): boolean { return this.value === other.value; }
  toString(): string { return this.value; }
}
```

**Rules:** constructor is always `private` (or the language's equivalent: an unexported
constructor in Go, a factory-only module function in Python) · immutable (TS `readonly`; Java
`record`/`final`, C# `record`/`init`, Python `@dataclass(frozen=True)`, Go unexported fields
with no setters) · compared by value via `equals()` (or the language's value equality —
records, frozen dataclasses, `==` on comparable structs) · never throws transport (HTTP)
exceptions · lives in the domain's value-objects folder (in this plugin's TS layout:
`domain/value-objects/<name>.vo.ts`)

**`toString()` rule** (JS/TS — a plain object prints as `[object Object]`; in other languages
implement the equivalent: `__str__`/`__repr__` in Python, `toString()` in Java, `ToString()`
in C#, `String()` (`fmt.Stringer`) in Go — records and dataclasses often provide one already):
- VO wrapping a `string` → always implement `toString(): string { return this.value; }` — prevents `[object Object]` in string templates and logs
- VO wrapping a `number` → implement `toString(): string { return String(this.value); }`
- VO wrapping multiple fields (e.g. `Money`, `DateRange`) → implement a meaningful representation: `Money` → `${this.amount} ${this.currency}`; `DateRange` → `${this.start.toISOString()} / ${this.end.toISOString()}`

## VO detection protocol — run before mapping any entity field to a primitive

| Question | If YES → |
|---|---|
| Does this field have a specific format? (email, phone, document, URL) | Create a VO |
| Does this field have a numeric bound? (quantity ≥ 0, rating 1–5, percentage 0–100) | Create a VO |
| Does this field represent money or currency? | Create `Money` VO |
| Do two fields together form an invariant? (start ≤ end, min price ≤ max price) | Create a VO for the pair |
| Does this field appear in validation logic in more than one place? | Create a VO |

If all answers are NO → plain primitive is correct.

| Field pattern | VO decision | Why |
|---|---|---|
| `email: string` | `Email` VO | Format + normalization (lowercase, trim) |
| `phone: string` | `Phone` VO | Format varies by country; normalization required |
| `price: number` | `Money` VO | Currency + non-negative invariant + arithmetic |
| `quantity: number` | `Quantity` VO | Non-negative + decrement guard |
| `start_date + end_date` | `DateRange` VO | end ≥ start invariant |
| `id: string` | plain `string` | No format, no behavior — just an identifier |
| `notes: string` | plain `string` | Free text, no format or behavior |
| `status: enum` | plain `enum` | Lifecycle handled by use case transitions |

**When the DB schema shows a plain type, do not assume a plain primitive is correct.**
`customer_code text`, `price numeric`, `stock_count integer` in SQL say nothing about invariants.
Always run the detection protocol above before deciding.

## `create()` vs `reconstitute()` — two trust boundaries

| Method | Called from | Validates? | Purpose |
|---|---|---|---|
| `create(raw)` | Controller / DTO boundary | Yes — full invariant check | User-supplied input may be invalid |
| `reconstitute(stored)` | Repository (loading from DB) | No — trusts persisted data | Data was already validated on write |

```typescript
// ❌ WRONG — runs full validation on every DB read
Email.create(row.email)      // throws if stored email no longer matches new regex

// ✅ CORRECT — trusts persisted data; validation already ran on write
Email.reconstitute(row.email)
```

## Canonical Value Object examples

### Money — exact decimal, explicit rounding

Never represent money as a binary float (`float`/`double`/JS `number`): `0.1 + 0.2` is
`0.30000000000000004`, `1.005 * 100` is `100.49999999999999`, and `10.05` is stored as
`10.050000000000000710…`. The rules:

- **Use the language's exact decimal type** — Python `Decimal`, Java `BigDecimal`, C#
  `decimal`, Go a decimal library (e.g. `shopspring/decimal`) — and the database's exact type
  (`NUMERIC`/`DECIMAL`).
- **Integer minor units only where no exact decimal exists** (e.g. JavaScript/TypeScript): store
  cents as an integer (or `bigint`) and convert at the edges.
- **Never accept a binary float at the boundary.** Amounts arrive as decimal strings (or
  integers) in the DTO and come back from a `NUMERIC` column as strings; parse them exactly.
- **Make the rounding mode explicit**, chosen per business rule — e.g. half-even (banker's) vs
  half-up — and round **once**, at the step the rule names. Never rely on a default you did not
  choose (JavaScript's `Math.round` rounds ties toward +∞; Java's `BigDecimal.setScale`
  requires a mode for inexact results).
- **The currency exponent varies** — USD/EUR 2 minor digits, JPY 0, KWD 3 (ISO 4217). Never
  hard-code `* 100`.

TypeScript has no exact decimal, so the canonical example uses integer minor units:

```typescript
// Money — exact integer minor units, explicit rounding, per-currency exponent
export type RoundingMode = 'HALF_EVEN' | 'HALF_UP';

// ISO 4217 minor-unit exponent — in production, a full table or a currency library
const MINOR_DIGITS: Record<string, number> = { USD: 2, EUR: 2, BRL: 2, JPY: 0, KWD: 3 };

export class Money {
  private constructor(
    private readonly minor: bigint,   // integer minor units: cents for USD, yen for JPY
    public readonly currency: string,
  ) {}

  // Boundary: a decimal STRING ('10.50', as sent in the DTO or returned by a NUMERIC column)
  // or a safe integer. A fractional JS number is rejected — it is already a binary
  // approximation (10.05 is stored as 10.050000000000000710…).
  static create(amount: string | number, currency: string): Money {
    const money = Money.parse(amount, currency);
    if (money.minor < 0n) throw new InvalidValueException('MONEY_NEGATIVE', 'Amount cannot be negative.');
    return money;
  }

  static reconstitute(amount: string | number, currency: string): Money {
    return Money.parse(amount, currency);
  }

  static zero(currency: string): Money {
    Money.digits(currency);   // validates the currency
    return new Money(0n, currency);
  }

  // Exact decimal string for serialisation and the NUMERIC column — never a JS number
  get amount(): string {
    const d = Money.digits(this.currency);
    const s = this.minor.toString().padStart(d + 1, '0');
    return d === 0 ? s : `${s.slice(0, -d)}.${s.slice(-d)}`;
  }

  add(other: Money): Money {
    this.assertSameCurrency(other);
    return new Money(this.minor + other.minor, this.currency);
  }

  subtract(other: Money): Money {
    this.assertSameCurrency(other);
    if (this.minor < other.minor)
      throw new InvalidValueException('MONEY_INSUFFICIENT', 'Insufficient amount for subtraction.');
    return new Money(this.minor - other.minor, this.currency);
  }

  // factor is a quantity or a rate, not money. It is read exactly from its decimal form
  // (String(0.15) === '0.15'), multiplied in integers and rounded ONCE with an explicit mode.
  multiply(factor: number | string, rounding: RoundingMode = 'HALF_EVEN'): Money {
    const [num, den] = Money.ratio(factor);
    return new Money(Money.divide(this.minor * num, den, rounding), this.currency);
  }

  // Same exact path, rounding to the target currency's minor unit (USD 2 → JPY 0 digits)
  convert(rate: number | string, target: string, rounding: RoundingMode = 'HALF_EVEN'): Money {
    const [num, den] = Money.ratio(rate);
    const shift = Money.digits(target) - Money.digits(this.currency);
    const scale = 10n ** BigInt(Math.abs(shift));
    return shift >= 0
      ? new Money(Money.divide(this.minor * num * scale, den, rounding), target)
      : new Money(Money.divide(this.minor * num, den * scale, rounding), target);
  }

  equals(other: Money): boolean {
    return this.minor === other.minor && this.currency === other.currency;
  }

  toString(): string { return `${this.amount} ${this.currency}`; }

  private assertSameCurrency(other: Money): void {
    if (other.currency !== this.currency)
      throw new InvalidValueException('MONEY_CURRENCY_MISMATCH', 'Currencies differ.');
  }

  private static digits(currency: string): number {
    const d = MINOR_DIGITS[currency];
    if (d === undefined) throw new InvalidValueException('MONEY_UNKNOWN_CURRENCY', `Unknown currency ${currency}.`);
    return d;
  }

  private static parse(amount: string | number, currency: string): Money {
    if (typeof amount === 'number' && !Number.isSafeInteger(amount))
      throw new InvalidValueException('MONEY_NOT_EXACT', 'Send fractional amounts as decimal strings.');
    const m = /^(-?)(\d+)(?:\.(\d+))?$/.exec(String(amount));
    if (!m) throw new InvalidValueException('MONEY_INVALID', `Not a decimal amount: ${amount}`);
    const [, sign, int, frac = ''] = m;
    const d = Money.digits(currency);
    if (frac.length > d)
      throw new InvalidValueException('MONEY_TOO_PRECISE', `${currency} has ${d} minor digits.`);
    const minor = BigInt(int + frac.padEnd(d, '0'));
    return new Money(sign ? -minor : minor, currency);
  }

  // '0.15' → [15n, 100n]; rejects negatives and exponent notation
  private static ratio(factor: number | string): [bigint, bigint] {
    const m = /^(\d+)(?:\.(\d+))?$/.exec(String(factor));
    if (!m) throw new InvalidValueException('MONEY_INVALID_FACTOR', `Invalid factor: ${factor}`);
    const [, int, frac = ''] = m;
    return [BigInt(int + frac), 10n ** BigInt(frac.length)];
  }

  // n / d rounded to an integer; n, d ≥ 0 (Money is non-negative)
  private static divide(n: bigint, d: bigint, rounding: RoundingMode): bigint {
    const q = n / d, twiceR = 2n * (n % d);
    if (twiceR !== d) return twiceR > d ? q + 1n : q;            // not a tie
    return rounding === 'HALF_UP' || q % 2n === 1n ? q + 1n : q;  // tie: half-up, or to even
  }
}
```

**DB round-trip — `NUMERIC` column, string in both directions:**

```
create('10.50', 'USD')       → minor = 1050n
persist money.amount         → '10.50'  (NUMERIC column)
reconstitute('10.50', 'USD') → minor = 1050n  ✓
```

**Arithmetic and rounding (each value checked by running the class above):**

```typescript
Money.create('0.10', 'USD').add(Money.create('0.20', 'USD')).amount  // '0.30'
Money.create('10.50', 'USD').multiply(3).amount                       // 1050 × 3 = 3150 → '31.50'

// 10% of 10.25 = 102.5 cents — an exact tie, so the rounding mode decides:
Money.create('10.25', 'USD').multiply('0.10', 'HALF_EVEN').amount     // 102.5 → 102 (even) → '1.02'
Money.create('10.25', 'USD').multiply('0.10', 'HALF_UP').amount       // 102.5 → 103        → '1.03'
// 10% of 10.35 = 103.5 cents → 104 under both modes                  // '1.04'

Money.create('1500', 'JPY').multiply(0.15).amount                     // 1500 × 15 / 100 = 225 → '225'
Money.create('12.34', 'USD').convert(151.25, 'JPY').amount            // 1234 × 15125 / 10⁴ = 1866.425 → '1866'

Money.create(10.05, 'USD')     // throws MONEY_NOT_EXACT — fractional float at the boundary
Money.create('1.005', 'USD')   // throws MONEY_TOO_PRECISE — USD has 2 minor digits
Money.create('10.5', 'JPY')    // throws MONEY_TOO_PRECISE — JPY has 0 minor digits
```

```typescript
// Email — formatted string with normalization
export class Email {
  private constructor(public readonly value: string) {}

  static create(raw: string): Email {
    const normalized = raw?.trim().toLowerCase();
    if (!normalized || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized))
      throw new InvalidValueException('EMAIL_INVALID', 'Invalid email format.');
    return new Email(normalized);
  }

  static reconstitute(stored: string): Email { return new Email(stored); }
  equals(other: Email): boolean { return this.value === other.value; }
  toString(): string { return this.value; }
}
```

```typescript
// DateRange — two dates with relational invariant
export class DateRange {
  private constructor(public readonly start: Date, public readonly end: Date) {}

  static create(start: Date, end: Date): DateRange {
    if (end < start)
      throw new InvalidValueException('DATE_RANGE_INVALID', 'End date must be after start date.');
    return new DateRange(start, end);
  }

  static reconstitute(start: Date, end: Date): DateRange { return new DateRange(start, end); }
  contains(date: Date): boolean { return date >= this.start && date <= this.end; }
  overlaps(other: DateRange): boolean { return this.start <= other.end && this.end >= other.start; }
  equals(other: DateRange): boolean {
    return this.start.getTime() === other.start.getTime() && this.end.getTime() === other.end.getTime();
  }
}
```

```typescript
// Quantity — non-negative integer with decrement guard
export class Quantity {
  private constructor(public readonly value: number) {}

  static create(value: number): Quantity {
    if (!Number.isInteger(value) || value < 0)
      throw new InvalidValueException('QUANTITY_INVALID', 'Quantity must be a non-negative integer.');
    return new Quantity(value);
  }

  static reconstitute(value: number): Quantity { return new Quantity(value); }

  decrement(): Quantity {
    if (this.value === 0)
      throw new InvalidValueException('QUANTITY_UNDERFLOW', 'Cannot decrement a zero quantity.');
    return new Quantity(this.value - 1);
  }

  add(n: number): Quantity {
    if (n < 0)
      throw new InvalidValueException('QUANTITY_NEGATIVE_ADD', 'Use decrement() to reduce quantity.');
    return Quantity.create(this.value + n);
  }
  equals(other: Quantity): boolean { return this.value === other.value; }
  toString(): string { return String(this.value); }
}
```

**Using VOs inside an Entity:**

```typescript
export interface EntityNameProps {
  id: string;
  email: Email;         // VO — format validated on creation
  price: Money;         // VO — currency and non-negative invariant
  validity: DateRange;  // VO — start ≤ end invariant
  stock: Quantity;      // VO — non-negative, decrement guard
}

export class EntityName {
  private constructor(
    public readonly id: string,
    public readonly email: Email,
    public readonly price: Money,
    public readonly validity: DateRange,
    public readonly stock: Quantity,
  ) {}

  static reconstitute(props: EntityNameProps): EntityName {
    return new EntityName(props.id, props.email, props.price, props.validity, props.stock);
  }
  // static create(...) for new entities, as in entities.md
}

// Controller / DTO boundary — user input: use create()
const email = Email.create(dto.email);
const price = Money.create(dto.price, dto.currency);

// Repository — loading from DB: use reconstitute() on the VOs and on the entity
return EntityName.reconstitute({
  id:       row.id,
  email:    Email.reconstitute(row.email),
  price:    Money.reconstitute(row.price, row.currency),
  validity: DateRange.reconstitute(new Date(row.starts_at), new Date(row.ends_at)),
  stock:    Quantity.reconstitute(row.stock_count),
});
```
