---
name: pre-merge
description: >
  Pre-merge gate protocol. Invoke before merging any feature branch to main or develop.
  Orchestrates tech-lead → appsec → qa in sequence and produces a consolidated go/no-go verdict.
---

# Pre-Merge Gate

## When to invoke

Before merging any feature branch to `main` or `develop`.
All three reviews are mandatory — none can be skipped.

## Which agents run each step

| Step | Agent | Where it comes from |
|---|---|---|
| tech-lead | `dev-core:tech-lead` | the `dev-core` plugin |
| appsec | `dev-core:appsec` | the `dev-core` plugin |
| qa | `dev-core:qa` | the `dev-core` plugin |
| (optional) pre-deploy | `dev-core:devops` | the `dev-core` plugin |

Plugin agents read project-specific rules from `.claude/agent-context/<agent>.md` when that
file exists (e.g. `.claude/agent-context/appsec.md`) — make sure it's up to date before
running the gate.

---

## Sequence

```
Step 1 → tech-lead    architecture, patterns, cohesion, completeness
Step 2 → appsec       security, auth, data-access policies (RLS or equivalent), sensitive data, headers
Step 3 → qa           test coverage, contract tests, factories, threshold

Step 4 → consolidated verdict
```

**Rule:** if any step is BLOCKED, do not proceed to the next step.
Fix all blocking issues, re-run the blocked step, then continue.

---

## Severity and blocking criteria

### tech-lead findings

| Tier | When to use | Blocks merge? |
|---|---|---|
| 🔴 CRITICAL | Incorrect behavior, Clean Architecture violation, wrong enum | **Always** |
| 🟡 WARNING | Must fix before merge — an edit form without an endpoint in the project's update convention (e.g. PATCH, if that is the convention), inconsistent naming | Yes, unless the human documents the justification in the project's session log (if it keeps one) or the PR body before merging |
| 💡 SUGGESTION | Non-blocking improvement — renaming, extraction | Never |

### appsec findings

| Severity | When to use | Blocks merge? |
|---|---|---|
| CRITICAL | Authentication bypass, RLS (or equivalent data-access policy) missing, secret exposed | **Always** |
| HIGH | Significant security hole — missing guard, data leak risk | **Always** |
| MEDIUM | Notable concern — missing rate limit, weak header (`dev-core:api-contracts`) | Yes, unless justified in writing |
| LOW | Minor note — logging detail, cosmetic | Never |

### qa findings

| Tier | When to use | Blocks merge? |
|---|---|---|
| COVERAGE | Use Cases: missing test for any success scenario or any named domain exception the Use Case can throw. Domain (Entities, VOs): any branch uncovered. Mutation score below the project's threshold **only if the project explicitly opted into a mutation gate**. | **Always** |
| MISSING | Contract test absent for a new endpoint | **Always** |
| INCOMPLETE | Contract test exists but missing 401, error envelope, or the response-casing assertion (e.g. `assertSnakeCase`) | Yes |
| NOTE | Minor gap — factory missing a named state, test name unclear. Mutation score below the targets (domain ≥ 80%, use cases ≥ 60%) in a project without a mutation gate — mutation testing is report-only by default (`dev-core:test-patterns`, "Mutation testing — report-only first"; for TypeScript stacks also `dev-patterns:test-patterns` — Stryker). | Never |

---

## Consolidated verdict format

After all three reviews, produce this block verbatim:

```
## Merge Gate — <branch-name>

### Step 1 — tech-lead:   APPROVED ✓  |  BLOCKED ✗
### Step 2 — appsec:      APPROVED ✓  |  BLOCKED ✗
### Step 3 — qa:          APPROVED ✓  |  BLOCKED ✗

---
### Final verdict:  APPROVED ✓  |  BLOCKED ✗

### Blocking issues (must fix before merge):
- [CRITICAL/WARNING/HIGH/MEDIUM/COVERAGE/MISSING/INCOMPLETE] <file>:<line> — <description>

### Non-blocking notes:
- [SUGGESTION/LOW/NOTE] <file>:<line> — <description>

### Re-review required after fixes:  YES  |  NO
```

If there are no blocking issues, write "None." under "Blocking issues".
If there are no non-blocking notes, write "None." under "Non-blocking notes".

---

## Re-review protocol after fixes

**Who implements the fixes:** the human routes each blocking finding to whoever implements it —
the project's specialist agents if it has them (typically a backend developer agent for
logic/architecture issues, a DBA agent for migration/schema gaps, a frontend developer agent
for UI findings), otherwise the main session. Reviewer agents do not self-assign fixes from a
BLOCKED verdict.

**Written justification for WARNING / MEDIUM:** when a WARNING or MEDIUM finding is accepted
without fixing, the human must document the decision in one of these canonical locations
before the merge proceeds:
- the project's session log, if it keeps one (e.g. a `SESSION.md` with a "Decisions made"
  section — one line per accepted finding), OR
- the PR body under a `## Decisions` heading (always available)

An undocumented accepted WARNING is still a merge blocker.

> **Session log format (optional):** a project that wants a session log but has none can start one, e.g.:
> ```markdown
> # SESSION.md
> ## Decisions made
> <!-- One line per accepted WARNING/MEDIUM: YYYY-MM-DD · finding summary · reason accepted -->
> ```
> A session log is project-specific operational state — never commit secrets or business rules to it.
> Its location (and when it is loaded) is defined by the project's own docs (e.g. `CLAUDE.md`).

| Severity of fixed issue | Re-review scope |
|---|---|
| CRITICAL or HIGH or COVERAGE | Full re-review by the relevant agent |
| WARNING or MEDIUM or MISSING or INCOMPLETE | Targeted re-check of the affected files only |
| Only SUGGESTIONs/LOW/NOTE fixed | No re-review required |

The re-review must produce a new consolidated verdict block before the merge proceeds.

---

## Who triggers the gate

The human runs the gate explicitly. Agents do not self-trigger.

Recommended invocation:
```
"Run the pre-merge gate on branch feat/<name>"
→ Step 1: use dev-core:tech-lead to review
→ Step 2: use dev-core:appsec to review
→ Step 3: use dev-core:qa to verify coverage
→ Produce consolidated verdict
```

---

## Optional step — pre-deploy check before production

The merge gate (Steps 1–3) approves merging to `main`. Before deploying to production,
run the `dev-core:devops` agent pre-deploy checklist (or the project's local `devops`
agent, if it overrides the plugin one):

```
"Run the pre-deploy checklist for production deploy of <version>"
→ devops verifies: migrations reviewed, backup confirmed, env vars set,
  all tests passing on main, correct branch and clean working tree.
→ devops ALWAYS requires explicit human confirmation before executing
  any command in the production environment.
```

This step is **separate from the merge gate** — a merge to `main` and a production deploy
are two distinct events. The human decides when to trigger the deploy after the merge is approved.
