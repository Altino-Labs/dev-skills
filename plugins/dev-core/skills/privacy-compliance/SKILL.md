---
name: privacy-compliance
description: >
  Privacy by design for systems that process personal data, with GDPR (EU) and LGPD (Brazil)
  side by side: legal bases (including special-category / sensitive data such as health —
  GDPR art. 9, LGPD art. 11), consent, data subject rights, DPO / encarregado, breach notice,
  international transfers, records of processing. Includes a per-new-field checklist
  (category, minimization, retention, erasure — archiving is not erasure — access scope,
  logs/backups/processors), a go-live checklist, the versioned Terms of Use / Privacy Policy
  acceptance pattern (version + timestamp stored together, sign-up refused with 422 before any
  side effect, blocking re-accept screen, legal pages reachable signed out, no invented legal
  facts), and a pointer to AI-transparency duties. Engineering guidance, not legal advice.
  Invoke automatically when adding a field or table that holds personal data, implementing
  consent, sign-up terms, account deletion or data export, writing legal pages, or preparing
  a go-live, in any language or framework.
---

# Privacy Compliance

> **Engineering guidance, not legal advice.** This skill tells engineers what to build and what
> to flag. Legal bases, retention periods, the privacy policy text and any regulatory filing
> are decided by the controller with a qualified lawyer. Article numbers are given to help the
> conversation with that lawyer — verify them against the current text and regulator guidance.

## Rules

1. **Every new field or table that holds personal data passes the per-field checklist** in the
   same change that introduces it. Findings are flagged for the human; they don't block a merge
   on their own, but every one is resolved before go-live.
2. **Special-category data (health, biometric, genetic, sexual life, religion, ethnicity…)
   needs its own legal basis** — the general ones are not enough.
3. **Archiving is not erasure.** Soft delete, `is_archived` or hiding a row does not satisfy an
   erasure request. Erasure covers the database, stored files, caches, search indexes, and the
   processors that hold copies; backups expire on a stated schedule (and the policy says so).
4. **A PDF report is not portability.** Portability means the subject's data in a structured,
   commonly used, machine-readable format (JSON, CSV).
5. **Consent is versioned.** Store which version of the Terms/Policy was accepted and when; a
   new version blocks use until it is accepted again.
6. **Never invent legal facts** — controller name, registration number, DPO, minimum age,
   jurisdiction, retention periods. Use visible placeholders and ship legal pages behind a
   draft banner until legal review.
7. **Every factual claim the legal text makes about the system is verified against the code**
   (what is collected, where it is stored, who it's shared with, how long it's kept, how deletion
   works). A policy that describes a system that doesn't exist is a liability.
8. **Personal data never reaches logs, error trackers or analytics** without minimization
   (`dev-core:logging-observability`).

---

## GDPR and LGPD side by side

| Topic | GDPR (EU 2016/679) | LGPD (Lei 13.709/2018) | Engineering consequence |
|---|---|---|---|
| Principles (purpose, minimization, retention) | art. 5 | art. 6 (I purpose, III necessity) | Every field has a stated purpose; no "might be useful later" |
| Legal bases | art. 6 | art. 7 | Record one basis **per purpose** (not per app) |
| Special-category / sensitive data (health…) | art. 9 — e.g. explicit consent, 9(2)(a) | art. 11 — e.g. specific and highlighted consent, 11(I) | Separate, explicit consent step or another art. 9 / art. 11 basis confirmed by counsel; flag every such field |
| Consent conditions | art. 7 (demonstrable, withdrawable) | arts. 8–9 (written or demonstrable; revocable, art. 8 §5) | Store version + timestamp; withdrawal as easy as giving it |
| Children | art. 8 (age 13–16, by member state) | art. 14 (parental consent for children) | Minimum age is a **placeholder** until counsel sets it; gate sign-up on it |
| Transparency | arts. 12–14 | art. 9 | Privacy policy reachable before sign-up and while signed out |
| Access / confirmation | art. 15 | art. 18 (I, II) | Endpoint or process to show the subject what is held |
| Rectification | art. 16 | art. 18 (III) | Editable profile fields; a process for the rest |
| Erasure | art. 17 | art. 18 (IV, VI); art. 16 (end of processing) | Real deletion path, including files and processors (rule 3) |
| Portability | art. 20 | art. 18 (V) | Machine-readable export (rule 4) |
| Objection / automated decisions | arts. 21–22 | art. 20 (review of automated decisions) | Human review path when a decision is automated |
| Privacy by design and by default | art. 25 | art. 46 §2 | This skill, applied from the first migration |
| Processors | art. 28 (contract / DPA) | arts. 37–40 (operador) | Processor list with a DPA for each |
| Records of processing | art. 30 | art. 37 | Maintained inventory: purpose, categories, basis, retention, recipients |
| Security | art. 32 | art. 46 | Encryption, access control, audit trail (`dev-core:auth-security`) |
| Breach — to the authority | art. 33: **72 hours** after awareness | art. 48 + ANPD regulation (Resolution CD/ANPD 15/2024: **3 business days**) | Incident runbook with the clock, owner and template |
| Breach — to data subjects | art. 34 (high risk) | art. 48 | Template message and a way to reach every affected user |
| Impact assessment | art. 35 (DPIA) | art. 38 (RIPD) | Expected for large-scale sensitive data — ask counsel early |
| DPO / encarregado | arts. 37–39 | art. 41 (exemptions for small agents by ANPD regulation) | Published contact channel in the policy and the app |
| International transfers | arts. 44–49 (adequacy, SCCs) | arts. 33–36 (ANPD standard clauses) | Know the region of every processor; record the transfer basis |

---

## Per-new-field checklist

Run for every new column, table, stored file type or third-party payload that holds personal
data. The `dev-core:appsec` and `dev-core:dba` agents apply it in review.

| Check | Question | Flag when |
|---|---|---|
| **Category** | Is it special-category / sensitive (health, biometric…) or a national identifier / financial? | Yes → confirm the legal basis before go-live |
| **Minimization** | Is it strictly needed for a stated feature? Is a coarser form enough (year instead of birth date, range instead of value)? | Purpose not evident from the feature |
| **Retention** | When is it deleted or anonymized? | No answer — "kept forever" needs a written justification |
| **Erasure** | Is it actually removed on account / subject deletion — rows, files, caches, indexes? | Only archived, or no deletion path |
| **Access scope** | Who can read it? Does the permission matrix and the data-access policy cover it? A new field inherits the table's policy — is that right for this field? | Wider audience than the feature needs |
| **Protection** | Does it need encryption at rest beyond the disk's (field-level)? Is it excluded from logs and error reports? | Sensitive and stored or logged in clear |
| **Copies** | Does it reach backups, analytics, error tracking, email, push payloads, an AI provider or other processors? | A new processor or a new copy not in the inventory |

Output format:

```
[PRIVACY-SENSITIVE]  <table>.<column> — special-category data; confirm legal basis before go-live
[PRIVACY-MINIMIZE]   <table>.<column> — purpose not evident; justify or remove
[PRIVACY-RETENTION]  <table>.<column> — no retention rule
[PRIVACY-ERASURE]    <table>.<column> — not cleared on deletion (archived only / file left behind)
[PRIVACY-ACCESS]     <table>.<column> — readable beyond need-to-know
[PRIVACY-COPIES]     <table>.<column> — reaches <processor/log/backup> not in the inventory
```

---

## Go-live checklist

Before processing real users' data:

- [ ] **Legal basis per purpose** recorded (and the special-category basis for each sensitive category)
- [ ] **Records of processing** inventory: purposes, categories, subjects, recipients, retention, transfers
- [ ] **Versioned consent** for Terms and Privacy Policy (pattern below), plus separate explicit
      consent where the sensitive-data basis is consent
- [ ] **Data subject rights** working end to end: access, rectification, erasure (rule 3),
      **portability in a machine-readable format** (rule 4), consent withdrawal
- [ ] **Retention** defined per category and implemented (scheduled cleanup or anonymization);
      backup retention stated in the policy
- [ ] **DPO / encarregado** contact published in the policy and reachable from the app
- [ ] **Breach runbook**: detection, the authority's clock (72 h GDPR / 3 business days ANPD),
      owner, notification templates for the authority and the subjects
- [ ] **Processor list** with a DPA (or equivalent clauses) for each, and each one's region
- [ ] **International transfers** identified with their legal mechanism
- [ ] **Privacy policy URL** published, reachable signed out, and set in the app stores'
      listing (both stores require one for apps that collect personal data)
- [ ] **Legal review done**: draft banner removed, no placeholder left
- [ ] **Error tracking and logs** scrubbed: no IPs, request bodies or personal fields
- [ ] Impact assessment (DPIA / RIPD) done or explicitly judged unnecessary by counsel

---

## Versioned Terms / Privacy acceptance

### Data

```sql
-- on the user (or a consent table, if the history of acceptances must be kept)
terms_version      text,
terms_accepted_at  timestamptz,
CONSTRAINT terms_acceptance_complete CHECK (
  (terms_version IS NULL) = (terms_accepted_at IS NULL)   -- set together, never one alone
)
```

The **current version** is a constant in one shared place (shared types / config) that both the
API and the clients read.

### API

```
POST /auth/register { …, accepted_terms_version }
  if accepted_terms_version != CURRENT_TERMS_VERSION:
      → 422 TERMS_NOT_ACCEPTED          // BEFORE any side effect:
                                        // no auth user, no row, no email sent
  create the account; store terms_version + terms_accepted_at (server clock) together

POST /auth/me/terms { version }        // signed-in user accepting a new version
  version must equal CURRENT_TERMS_VERSION, else 422
```

- The check runs first so a refused sign-up leaves nothing behind (no orphaned identity in the
  auth provider, no welcome email).
- The timestamp comes from the server, never from the client.
- Contract tests cover: missing version, old version, current version (`dev-core:test-patterns`).

### Clients

- **Sign-up**: an unchecked-by-default checkbox linking to both documents; submit disabled until
  checked; the version sent is the constant, not a string typed into the form.
- **Blocking re-accept screen**: when the signed-in user's `terms_version` is not the current
  one (or is null), show "We updated our terms" with links and an accept button before any
  other screen. Sign-out stays available.
- **Legal pages reachable signed out** — from the sign-in and sign-up screens and at a public
  URL (stores and email footers link to it).
- **Draft banner** ("preliminary version — under legal review") on both documents until counsel
  approves them; placeholders such as `[CONTROLLER NAME]`, `[DPO CONTACT]`, `[MINIMUM AGE]`,
  `[JURISDICTION]` stay visible, never filled with plausible guesses.
- Bumping the version is a deliberate change: new text, new constant, every user re-accepts.

---

## AI transparency

When users interact with an AI system (chat assistant, AI-generated content, voice), the EU AI
Act (Regulation 2024/1689, **art. 50**) requires telling them they are interacting with AI
unless it is obvious, and marking synthetic content. Also list the AI provider as a processor
(data sent, region, retention, whether it trains on the data) and, for automated decisions with
significant effect, provide the human-review path (GDPR art. 22 / LGPD art. 20). Confirm the
current obligations and dates with counsel.

---

## Related skills

- `dev-core:auth-security` — identity, access control, the permission matrix
- `dev-core:migrations` — access policies reviewed with each table
- `dev-core:logging-observability` — what never to log; error-tracker privacy defaults
- `dev-core:secrets-rotation` — encryption keys and credentials
- `dev-core:audit` — the security dimension includes a privacy pass
