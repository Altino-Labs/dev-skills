# Anti-Corruption Layer (ACL)
> Sub-file of the `dev-core:clean-architecture` skill. Read when integrating an external system
> (auth provider, email API, payment gateway, storage) into a Use Case.

---

## What the ACL solves

The ACL protects the domain model from contamination by external system models.
Every integration with an external service needs an ACL.

> "When integrating with another system, create a layer that translates between the
> external model and your own. This layer speaks the other system's language on one side
> and your domain language on the other."
> — Eric Evans, *Domain-Driven Design*

```typescript
// ❌ WITHOUT ACL — the auth vendor's SDK types contaminate the Use Case
export class RegisterUserUseCase {
  constructor(private readonly vendor: AuthVendorClient) {}  // external type in domain

  async execute(input: RegisterUserInput): Promise<void> {
    const { data } = await this.vendor.auth.signUp({ email: input.email, password: input.password });
    // 'data.user.id', 'data.user.user_metadata' — the vendor's model, not the domain's
    // Replacing the vendor now requires rewriting every Use Case that touches auth
  }
}
```

## ACL structure

```
External System  ──→  ACL Adapter   ──→  Domain Interface  ──→  Use Case
(auth vendor)         (translates)        (IAuthProvider)        (domain model only)
```

```typescript
// domain/auth/i-auth-provider.ts — domain language, zero external imports

export interface AuthResult {
  user_id:   string;
  email:     string;
  full_name: string | null;
}

export interface IAuthProvider {
  register(email: string, password: string, fullName: string): Promise<AuthResult>;
  verifyToken(token: string): Promise<AuthResult | null>;
}
```

```typescript
// infrastructure/auth/vendor-auth.provider.ts — ACL: translates the vendor's model → domain
export class VendorAuthProvider implements IAuthProvider {
  constructor(private readonly vendor: AuthVendorClient) {}

  async register(email: string, password: string, fullName: string): Promise<AuthResult> {
    const { data, error } = await this.vendor.admin.createUser({
      email, password, user_metadata: { full_name: fullName },
    });
    if (error || !data.user) throw new UserRegistrationException(email, error?.message);

    // Translation: vendor model → domain model. External field names stay here.
    return {
      user_id:   data.user.id,
      email:     data.user.email!,
      full_name: data.user.user_metadata?.full_name ?? null,
    };
  }

  async verifyToken(token: string): Promise<AuthResult | null> {
    const { data, error } = await this.vendor.getUser(token);
    if (error || !data.user) return null;
    return { user_id: data.user.id, email: data.user.email!, full_name: data.user.user_metadata?.full_name ?? null };
  }
}
```

```typescript
// auth/use-cases/register-user.use-case.ts — zero vendor imports
export class RegisterUserUseCase {
  constructor(
    private readonly auth: IAuthProvider,
    private readonly users: IUserRepository,
    private readonly eventBus: IEventBus,
  ) {}

  async execute(input: RegisterUserInput): Promise<RegisterUserOutput> {
    const result = await this.auth.register(input.email, input.password, input.full_name);
    const user   = User.create({ id: result.user_id, email: Email.create(result.email), fullName: input.full_name });
    const saved  = await this.users.save(user);
    await this.eventBus.publish(new UserRegisteredEvent(saved.id, saved.email.value));
    return { user_id: saved.id, email: saved.email.value };
  }
}
```

## Where ACL adapters live

```
domain/
  auth/i-auth-provider.ts           ← domain interface (domain's language)
  email/i-email-service.ts

infrastructure/
  auth/vendor-auth.provider.ts      ← ACL adapter (translates the auth vendor → domain)
  email/vendor-email.provider.ts    ← ACL adapter (translates the email API → domain)
```

## ACL vs DIP — complementary, not synonymous

| | DIP | ACL |
|---|---|---|
| **Problem** | High-level module coupled to a concretion | External model leaking into domain |
| **Solution** | Interface + injection of the abstraction | Adapter that translates between models |
| **Scope** | Any volatile dependency | External system integrations only |

`SqlOrderRepository` is DIP. `VendorAuthProvider` is both DIP and ACL.

## Detection rule — when an ACL is required

An ACL is missing when a Use Case contains any of these:

```typescript
// ❌ External SDK import inside a Use Case
import { AuthVendorClient } from 'auth-vendor-sdk';
import EmailApi from 'email-vendor-sdk';

// ❌ External field naming convention reaching the domain
data.user.user_metadata.full_name   // auth vendor's model inside Use Case
response.data[0].email_address      // email API's model inside Use Case

// ❌ External error type handled directly in the Use Case
if (error.code === 'auth/email-already-in-use') { ... }
```

If any of these appear inside a Use Case or entity: the ACL is missing.

A concrete adapter for a specific auth vendor lives in the stack
plugin (e.g. `dev-patterns:clean-architecture`).
