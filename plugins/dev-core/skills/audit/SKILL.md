---
name: audit
description: >
  Full-repository, multi-dimension audit protocol for any stack. Invoke only when the human asks
  for a full audit, a new audit round or a periodic health check across the whole repository
  (or an explicitly scoped subsystem) — not for reviewing a single branch (use
  `dev-core:pre-merge`). Determines the round number, dispatches appsec, tech-lead (including
  performance), qa, dba and devops in parallel plus a self-run docs/process check, consolidates
  ONE globally numbered findings list, persists it (session log + commit) and opens one tracker
  issue per finding BEFORE any fix, then fixes in PRs batched by dimension and closes the round
  with a note.
---

# Full Audit

## Rules

1. **Findings never live only in the conversation.** The list is written to the session log and
   committed **before any fix starts**. A round once ran to the end and was lost to a context
   compaction — nothing recoverable but the fact it happened.
2. **One global numbering.** Findings are `#1…#N` across all dimensions, ordered by dimension
   then severity — never numbered per dimension. PRs, issues and the log all refer to
   "audit item #N".
3. **One tracker issue per finding**, labelled by dimension, cross-referenced with the item
   number. Every finding, not just the deferred ones.
4. **Fix in PRs batched by dimension**, not one PR per item. Each PR names the items it closes.
5. **Deferral is explicit.** A deferred finding gets a reason in the log and a comment on its
   issue; the issue stays open.
6. **Never "fix" a finding by shrinking the docs or the spec to match a lesser implementation.**
   When the code does less than the documentation promises, the fix is implementing it — or an
   explicit, human-approved product decision recorded as such, not a quiet doc edit.
7. **Read-only discovery.** Agents in Step 1 do not modify code.
8. **The human triggers it.** Agents never start an audit on their own.

---

## Step 0 — Determine the round number

Search both the PR history and the session log for previous rounds, e.g.:

```bash
gh pr list --state all --search "audit round" --json title --limit 100
grep -n "audit round\|Audit round" SESSION.md | tail
```

Take the highest round found, add 1. A round that was started but never produced a log entry
or a PR is **void** — reuse its number instead of skipping it.

State the round number and the scope (whole repository or a named subsystem) before Step 1.

---

## Step 1 — Dispatch the dimensions in parallel

Discovery has no ordering dependency (unlike `pre-merge`'s sequence): dispatch every agent in
the **same message** so they run concurrently. Each gets the scope and this prompt shape:

```
Full audit — round <N>. Review <scope> for <dimension checklist>.
Report findings as: [SEVERITY] <file>:<line> — <description>, one per line, most severe first.
Read-only — do not modify code.
```

Each agent also reads `.claude/agent-context/<agent>.md` and the project's delta skills.

### 1. Security — `dev-core:appsec`

- Authentication and authorization on every endpoint; ownership vs role checks right for each
  resource; the permission matrix in the project docs matches the code
- Data-access policies (row-level security or equivalent) on every table; no cross-tenant read
  through a foreign reference the policy doesn't check
- Injection: SQL, shell (commands built with unescaped input), path traversal
- Secrets: none hardcoded or logged; `.env.example` in sync; no default grants left open on
  sensitive database functions
- Dependencies: known vulnerabilities with an available fix not applied
- Sensitive data encrypted where the project says it is; stack traces not exposed in production
- Rate limiting and security headers (`dev-core:api-contracts`)
- Audit trail for sensitive actions (deletion, role change, privileged access, deploys)
- Privacy: deletion/consent flows behave as documented; retention matches what the product
  promises (`dev-core:privacy-compliance`)

### 2. Architecture and performance — `dev-core:tech-lead`

- Layer violations: use cases importing infrastructure, domain logic in controllers
  (`dev-core:clean-architecture`)
- Duplication: identical or near-identical logic reimplemented in several places — the most
  recurring finding in practice
- Cohesion and naming across parallel modules; monolithic files that should decompose
- Completeness: TODOs in shipped code, half-finished abstractions
- **Performance** (no separate agent — it rides with architecture rather than being dropped):
  N+1 queries, missing indexes on filtered columns, unbounded list queries, needless client
  re-renders or bundle bloat

### 3. Tests — `dev-core:qa`

The bar of `dev-core:pre-merge`'s qa table, applied to the whole repository: every use case's
success path and named exceptions, every domain branch, a contract test per endpoint (401,
error envelope, wire casing), mutation score against the project's targets
(`dev-core:test-patterns`), end-to-end coverage of each major flow's golden path if the project
has an e2e suite.

### 4. Data integrity and reliability — `dev-core:dba`

- Migrations: constraints match the domain invariants; no drift between access policies and the
  schema; irreversible migrations marked (`dev-core:migrations`)
- Repositories that swallow an infrastructure failure and return it as a business result (empty
  list, `null`, a silent not-found) — check whether a finding like this from a previous round
  was actually closed before assuming it was
- Resilience: timeouts, retries and idempotency on external calls
  (`dev-core:resilience-patterns`); orphaned data from partial multi-step writes
- Backups: exist, cover stored files too, and a restore was actually drilled

### 5. Infrastructure and operations — `dev-core:devops`

- CI/CD: workflow permissions scoped; branch protection actually enforced (or its absence
  written down); lint/type-check/tests cover every app (check the task count)
- Secrets rotation cadence (`dev-core:secrets-rotation`)
- Configuration drift between local, staging and production
- Every deploy workflow exercised end to end since its last edit
- Error tracking and alerting wired, with privacy defaults (`dev-core:logging-observability`)

### 6. Documentation and process — run it yourself, no subagent

- Version headers and status lines in the project docs match the code
- ADRs still match reality — no decision silently reversed
- Every previous round has a log entry or merged PRs referencing its items; **a round number
  referenced somewhere with no record is itself a finding**
- Cross-cutting hygiene that isn't architecture (type-safety escapes, stale comments, dead config)

---

## Step 2 — Consolidate one numbered list

Merge all six outputs into a **single, continuously numbered list**, ordered
Security → Architecture → Tests → Data → Infrastructure → Process, and by severity inside each:

```
#1  [CRITICAL] Security       — <file>:<line> — <description>
#2  [HIGH]     Security       — <file>:<line> — <description>
#8  [WARNING]  Architecture   — <file>:<line> — <description>
…
```

Severity vocabulary follows `dev-core:pre-merge`: tech-lead CRITICAL / WARNING / SUGGESTION;
appsec CRITICAL / HIGH / MEDIUM / LOW; for qa, dba, devops and process use CRITICAL / HIGH /
MEDIUM / LOW (LOW for anything purely cosmetic). Deduplicate findings reported by two agents
under the dimension where the fix belongs.

---

## Step 3 — Persist before any fix

This step is the reason the skill exists.

1. **Session log** — add an entry to the project's session log (e.g. `SESSION.md`):
   `## [date] — Audit round <N>`, listing **every** finding (not a summary) with its number,
   severity, dimension, location and description. Future sessions must be able to grep
   "audit item #N".
2. **Commit it now**, before the first fix. A written but uncommitted file is what gets lost.
   If the project's rules require asking before committing, ask — framed as "save the
   findings", not as a code commit. Don't skip persisting because nobody asked for a commit.
3. **One issue per finding** in the project's tracker:
   - title `[SEVERITY] <Dimension> — <short description>`
   - body: full description, `file:line`, "Audit item #N, round <N>", pointer to the log entry
   - a dimension label (e.g. `audit:security`, `audit:architecture`, `audit:tests`,
     `audit:data`, `audit:infra`, `audit:process`), and the round, if the board has a field
     for it
4. **Cross-reference**: write the issue number next to each item in the log
   ("audit item #7 (issue #142)"), and amend the commit or add a follow-up one.
5. If the project keeps a living tracker page for audits, update it; if a previous round
   linked one, check it's still the source of truth before writing to it.
6. Only now: triage with the human and start fixing.

---

## Step 4 — Fix and close out

- **Batch by dimension** — one PR for the security items, one for architecture, etc. (split a
  dimension only when a PR would be too large to review). Follow `dev-core:git`.
- Each PR body names the items it closes ("Audit items #1 (HIGH) and #2 (MEDIUM), round <N>")
  and closes each issue with its **own** keyword (`Closes #141, Closes #142` — a single keyword
  before a comma-separated list closes only the first). Never put fix/close/resolve next to an
  issue number the PR does **not** resolve, even in a negative sentence.
- After merge, confirm each issue is actually closed.
- **Deferred** items: one line in the log with the reason, at the moment of deferral, and a
  comment on the issue; the issue stays open.
- **Closing note**: when every item is closed or explicitly deferred, add a note to the round's
  log entry — "round <N> complete: X fixed (PRs …), Y deferred (issues …)".

---

## Invocation

```
"Run a full audit, round <N>"   (or "run the audit again")
→ Step 0  round number and scope
→ Step 1  appsec, tech-lead, qa, dba, devops in parallel + the docs/process check yourself
→ Step 2  one globally numbered list
→ Step 3  session log + commit + one issue per finding, before any fix
→ Step 4  PRs batched by dimension; deferrals with reasons; closing note
```

A project can add a delta skill (`.claude/skills/<project>-audit/`) with its tracker commands,
board fields, label names and extra checklist items for its domain.
