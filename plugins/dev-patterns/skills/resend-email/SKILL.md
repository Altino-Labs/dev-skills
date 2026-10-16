---
name: resend-email
description: >
  Reusable patterns for transactional email sending with Resend.
  Invoke automatically when configuring Resend, implementing email sending
  in the backend, creating templates, or configuring email DNS records.
---

# Resend — Transactional Email

## Initial setup

```
1. Create account at resend.com
2. Add and verify domain
3. Configure DNS records at the provider (SPF, DKIM, DMARC)
4. Create separate API keys per environment
```

---

## Required DNS records

Resend provides the exact values when adding the domain. Configure in DNS:

```
Type   Name                    Value
TXT    @                       v=spf1 include:_spf.resend.com ~all
TXT    resend._domainkey        <DKIM key provided by Resend>
TXT    _dmarc                  v=DMARC1; p=none; rua=mailto:dmarc@<domain>
```

**Never proxy these records through Cloudflare** — disable the proxy on them.

---

## Backend installation and configuration

```bash
npm install resend
```

```typescript
// infrastructure/notifications/resend-email.service.ts
import { Resend } from 'resend';
import { Injectable } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

@Injectable()
export class ResendEmailService implements IEmailService {
  private readonly client: Resend;
  private readonly from: string;

  constructor(private readonly config: ConfigService) {
    this.client = new Resend(config.getOrThrow('RESEND_API_KEY'));
    this.from = config.getOrThrow('EMAIL_FROM'); // e.g. "App <noreply@example.com>"
  }

  async send(input: SendEmailInput): Promise<void> {
    const { error } = await this.client.emails.send({
      from: this.from,
      to: input.to,
      subject: input.subject,
      html: input.html,
    });

    // The Resend SDK NEVER rejects on an API-level failure — it always
    // resolves, with { data: null, error } on failure. It only logs the
    // error internally via its own console.error. Skipping this check means
    // every caller (including every event subscriber's try/catch) silently
    // treats a failed send as a success — this bit a real app in production.
    if (error) {
      throw new Error(`Resend API error: ${error.message}`);
    }
  }
}
```

**Always test this path live**, not just with mocks: trigger a real send that the Resend
account will reject (e.g. sending to an address other than the account owner's while in
Resend's test mode) and confirm the failure surfaces through your own logs — a passing test
suite with a mocked client will happily assert on a shape that doesn't match runtime reality.

---

## IEmailService interface (domain depends only on this)

```typescript
// domain/services/i-email.service.ts
export const EMAIL_SERVICE = Symbol('EMAIL_SERVICE');

export interface IEmailService {
  send(input: SendEmailInput): Promise<void>;
}

export interface SendEmailInput {
  to: string | string[];
  subject: string;
  html: string;
}
```

---

## Email subscriber pattern

```typescript
// infrastructure/subscribers/send-invitation-email.subscriber.ts
@Injectable()
@EventSubscriber('member.invited')
export class SendInvitationEmailSubscriber
  implements IEventSubscriber<MemberInvitedEvent>
{
  private readonly logger = new Logger(SendInvitationEmailSubscriber.name);

  constructor(@Inject(EMAIL_SERVICE) private readonly email: IEmailService) {}

  async handle(event: MemberInvitedEvent): Promise<void> {
    try {
      await this.email.send({
        to: event.invitedEmail,
        subject: "You've been invited",
        html: invitationTemplate(event),
      });
    } catch (error) {
      // Email is non-critical — logs but does not propagate. This catch only
      // fires at all if the email service throws on failure — see the
      // Resend error-check above; a service that silently swallows API
      // errors makes this whole try/catch dead code.
      this.logger.error(`Invitation email failed: ${(error as Error).message}`);
    }
  }
}
```

See `dev-patterns:logging-observability` for the `Logger` pattern used above.

---

## Environment variables

```bash
# Add to .env.example
RESEND_API_KEY=          # separate key per environment (staging ≠ production)
EMAIL_FROM=              # e.g. "MyApp <noreply@example.com>"
```

---

## Recommended addresses

```
noreply@example.com   ← transactional emails (no reply expected)
support@example.com   ← point to real support inbox
```

---

## Free tier limits

```
3,000 emails/month
1 custom domain
```

**Trigger for Pro ($20/month):** > 3,000 emails/month or need for multiple domains.
