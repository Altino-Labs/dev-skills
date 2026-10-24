---
name: bootstrap-project
description: >
  Stack-agnostic guide to start a new project with Claude Code agents: ingest the spec into an
  index the human reviews, choose the stack and record it as an ADR, install the plugins and
  create the project's .claude/ layer, write the durable context files (AGENTS.md, CLAUDE.md,
  PROJECT.md, SESSION.md/ROADMAP.md) from the templates shipped with this skill, set up the repo
  and a CI baseline that covers every app, provision infrastructure one confirmed step at a time
  (backups with a restore runbook, secrets-rotation cadence, error tracking with privacy
  defaults, production deferred behind an approval gate), and validate. Invoke when starting a
  new project or adopting dev-core in an existing repository that has no agent context yet.
---

# Bootstrap — New Project

> Stack-agnostic. A stack plugin can add a phase with the concrete scaffold for its stack — e.g.
> `dev-patterns:bootstrap-project` for the TypeScript stack of `dev-patterns` (monorepo layout,
> package scope, test fakes, the service-by-service provisioning order). Run this skill first;
> run the stack phase in place of "Scaffold" inside Phase 4.

## Rules

1. **Phases run in order; each ends at a checkpoint the human confirms.** Never start a phase
   while the previous checkpoint has an open item.
2. **Read before you build.** If a spec exists, index it (Phase 0) before choosing anything.
3. **Decisions are written before they are implemented.** The stack is an ADR before the first
   scaffold command; a business rule is in `PROJECT.md` before the first line of code that
   enforces it.
4. **State lives in the repo, not in the conversation.** Plans, decisions and pending items go
   to files that survive context compaction (`PROJECT.md`, `SESSION.md`, `ROADMAP.md`).
5. **Infrastructure is provisioned by the human, one step at a time** — what it is, why, the
   exact command — and the agent waits for "done" before the next step.
6. **Production is deferred** until there is a launch date, and is gated by an approval when
   it exists.

## Overview

```
Phase 0 — Ingest the spec          (only if a spec exists)
Phase 1 — Choose the stack         → ADR-001
Phase 2 — Plugins and .claude/
Phase 3 — Durable context files    → AGENTS.md, CLAUDE.md, PROJECT.md, SESSION.md, ROADMAP.md
Phase 4 — Repo, scaffold and CI baseline
Phase 5 — Infrastructure, in order, one confirmed step at a time
Phase 6 — Validate
```

---

## Phase 0 — Ingest the spec

Skip only when there is no written material. If the project arrives with a spec folder (briefs,
PDFs, spreadsheets, screenshots, meeting notes), index it **before** any design or code.

1. **Inventory** every file. For large material (dozens of files or long documents), dispatch
   parallel agents, each with a slice of the folder and the same output shape; merge their
   results yourself.
2. Write **`docs/SPEC-INDEX.md`**:

   | Section | Content |
   |---|---|
   | Files | One row per file: path, what it is (brief, flow, data model, screen, legal…), date/version if stated |
   | Modules | The functional areas the material describes, with the files that describe each |
   | Business rules | Each rule stated once, with its source file and location |
   | Screens | Each screen or flow mentioned, with its source |
   | Open questions | Ambiguities, and **contradictions** between files (quote both sides) |
   | Gaps | What a working system needs that the material does not cover (auth, roles, errors, empty states, data retention, notifications…) |

3. **Do not resolve contradictions or fill gaps by guessing.** List them; the human decides.
4. Commit the index and ask the human to review it.

**Checkpoint 0:** the human has reviewed `docs/SPEC-INDEX.md` and answered (or explicitly
deferred) each open question; answers are recorded in the index.

---

## Phase 1 — Choose the stack, as an ADR

The answer depends on the project; the **criteria** don't. Weigh, and write down:

| Criterion | Question |
|---|---|
| Team | What does the team already know well? Who maintains this in two years? |
| Product shape | Web only, mobile, both? Offline? Real-time? Heavy background jobs? |
| Data | Relational with strong consistency? Row-level access rules? Sensitive categories (health, financial)? |
| Compliance | Where must data live (region)? Which privacy law applies? (`dev-core:privacy-compliance`) |
| Hosting and cost | Managed services vs self-hosted; cost at zero users and at the first thousand |
| Ecosystem | Libraries for the hard parts (auth, payments, push, PDFs); maturity; release cadence |
| Agent support | Is there a stack plugin (e.g. `dev-patterns`) or will the project write its own deltas? |

Record the decision as **ADR-001** in `PROJECT.md` (or `project/ADR.md`), Nygard format:
**Context / Decision / Consequences**, with the alternatives considered and why they lost.
A one-line ADR is not an ADR — future agents need the reasoning.

**Checkpoint 1:** ADR-001 exists and the human approved it. No scaffold has run yet.

---

## Phase 2 — Plugins and the project's `.claude/`

```
/plugin marketplace add Altino-Labs/dev-skills
/plugin install dev-core@dev-skills
/plugin install dev-patterns@dev-skills     # only if ADR-001 chose the dev-patterns stack
```

Install at project scope when every contributor should get them, and review the diff of
`.claude/settings.json` the CLI writes. Never copy plugin skills or agents into the project —
fix or extend them in the plugin repo so every project benefits.

Create the project layer:

```
.claude/
├── constitution.md        ← non-negotiable rules (template: templates/constitution.md)
├── general-context.md     ← about the project, stack, identity model, vocabulary
│                            (template: templates/general-context.md)
├── settings.json          ← enabled plugins, permissions, project-only hooks
├── skills/
│   └── <project>-<skill>/ ← delta skills: ONLY what is specific to this project
│       └── SKILL.md
└── agent-context/
    └── <agent>.md         ← project rules a dev-core agent reads at start (e.g. appsec.md)
```

- **Delta skills** (`.claude/skills/<project>-<skill>/SKILL.md`) complement `dev-core:<skill>`
  (and the stack skill) with real paths, tables, ADRs and deliberate deviations; on conflict
  they win. A new project usually starts with **none** — they accumulate as decisions are made.
- **Agent context** (`.claude/agent-context/<agent>.md`) holds what a plugin agent must know
  about this project (sensitive data categories, where guards and fakes live). Create one only
  when needed. Don't write a local agent with the same name as a plugin agent — it shows up as
  a second agent, it doesn't replace the first.
- Plugin hooks and project hooks both run; don't repeat the `dev-core` safety hooks locally.

Templates for the context files ship with this skill: [`templates/constitution.md`](templates/constitution.md)
(including the **Working agreements** — generic lessons for agents) and
[`templates/general-context.md`](templates/general-context.md). Copy, replace every
`<placeholder>`, delete what doesn't apply.

**Checkpoint 2:** `/plugin` lists the plugins; a `dev-core:<skill>` loads; the `.claude/`
files exist (filled from the templates, no `<placeholder>` left in them).

---

## Phase 3 — Durable context files

| File | Role | Template |
|---|---|---|
| `AGENTS.md` | Entry point for any AI tool: loading order, conflict hierarchy, agent and skill tables, verification cycle | [`templates/AGENTS.md`](templates/AGENTS.md) |
| `CLAUDE.md` | One line pointing at `AGENTS.md` (Claude Code reads `CLAUDE.md`; other tools read `AGENTS.md`) | [`templates/CLAUDE.md`](templates/CLAUDE.md) |
| `PROJECT.md` | Domain: overview, ADRs, modules, user model, permissions matrix, business rules, enums, events, endpoints, scheduled jobs, data model, UX requirements | — (see below) |
| `INFRA.md` | Provisioned services, environments, env vars by name, runbooks | — (Phase 5 fills it) |
| `SESSION.md` | Session log: what was done, decisions, pending, needs human attention | [`templates/SESSION.md`](templates/SESSION.md) |
| `ROADMAP.md` | Multi-phase plans, written **before** the work starts | — |

- **`PROJECT.md`** starts from `docs/SPEC-INDEX.md`: modules, business rules and screens move
  in, open questions stay open (marked as such). Every enum's exact values live in one table
  there — migrations and code never invent values. When it grows past comfortable reading (a
  few thousand lines, or many teams editing it), split it into `project/*.md` (`ADR.md`,
  `MODULES.md`, `INFRA.md`, `UX.md`…) and keep `PROJECT.md` as the index.
- **`SESSION.md` and `ROADMAP.md` are what survives context compaction.** A plan that exists
  only in the conversation is lost the first time the context is compressed. Persist the plan,
  then start.
- Lessons that are not project-specific go back to the plugins (concept → `dev-core`, stack
  detail → the stack plugin), not into the project.

**Checkpoint 3:** `dev-core:architect` reads `AGENTS.md` → `PROJECT.md` and can plan the first
module without asking what the project is.

---

## Phase 4 — Repo, scaffold and CI baseline

1. **Repository** — private by default; `.gitignore` covers `.env*` (except `.env.example`) and
   any local bootstrap-secrets file; `.env.example` lists every variable with empty values.
2. **Scaffold** — the stack phase (e.g. `dev-patterns:bootstrap-project`) or the framework's
   generator. Follow the module layout recorded in `.claude/general-context.md`.
3. **CI baseline** on every pull request: lint, type-check (if the language has one), unit tests,
   build — for **every** app and package. In a monorepo task runner, **check the task count** in
   the CI log against the number of apps: an app without the script is skipped silently and
   looks green. Add a check that fails when an app lacks a required script.
4. **Branch protection** on the default branch: PR required, the CI check required, branch up to
   date, no force-push, no deletion. If the plan tier can't enforce it, write that down in
   `INFRA.md` instead of assuming it's on.
5. **Issue tracker and board** — issues for work items; a board with at least
   Todo / In Progress / Done. Agents move a card to In Progress when they start it.
6. Git conventions per `dev-core:git`; when Claude may commit, push or open PRs goes in the
   constitution's approval list.

**Checkpoint 4:** a trivial PR runs the full CI, the log shows one lint/type-check/test task per
app, and the merge is blocked until the check passes.

---

## Phase 5 — Infrastructure, in order

The human executes; the agent guides **one step at a time** (what, why, the exact command) and
waits for "done". Record each service in `INFRA.md` as it is created — names of env vars, never
values.

| # | Step | Notes |
|---|---|---|
| 1 | Environments | Local and **staging** now. **Production deferred** until there is a launch date: before that it is cost and process with no payoff. Write the deferral and the cutover steps in `INFRA.md`. |
| 2 | Database | Region chosen by the compliance criterion of ADR-001. Access policies reviewed with every table (`dev-core:migrations`). |
| 3 | Backups + restore runbook | Confirm the plan **actually** includes backups (read the dashboard, not the pricing page). Back up the database **and** stored files; encrypt backups of personal data. Write the restore runbook and **run a restore drill** into a fresh environment — a backup never restored is a hope. |
| 4 | Secrets | Stored per platform; an inventory in `INFRA.md` (where each lives, rotation bucket, last rotated). Rotation cadence per `dev-core:secrets-rotation`; a scheduled job that flags overdue secrets is cheap. |
| 5 | Hosting + deploy | Staging deploys on merge to the default branch, then health-checks the new version. |
| 6 | Error tracking | Privacy defaults from day one: no IPs, no request bodies, scrubbed user data, environment tag; prove the config reached the shipped artifact (`dev-core:logging-observability`). Alerts and uptime check. |
| 7 | DNS / edge | Once a domain exists. |
| 8 | Production (at the cutover) | Separate project/accounts and new secrets (never staging's), PITR or equivalent, deploy behind a **required-approval environment** restricted to the default branch, restore drill repeated, privacy go-live checklist (`dev-core:privacy-compliance`). |

**Checkpoint 5:** staging is reachable and healthy; a backup was restored successfully; the
secrets inventory is complete; an error thrown on purpose in staging reaches the tracker
without personal data.

---

## Phase 6 — Validate

- [ ] `docs/SPEC-INDEX.md` reviewed; no unanswered contradiction is silently "resolved" in code
- [ ] ADR-001 (stack) approved and recorded
- [ ] `AGENTS.md`, `CLAUDE.md`, `.claude/constitution.md`, `.claude/general-context.md` filled — no `<placeholder>` left
- [ ] `PROJECT.md` covers overview, modules, user model, permissions, business rules, enums
- [ ] `SESSION.md` and `ROADMAP.md` exist and are committed
- [ ] CI runs lint/type-check/tests for every app (task count checked); branch protection on
- [ ] Tracker and board exist; the first issue is In Progress
- [ ] Staging deployed and healthy; backup restore drill passed; secrets inventory in `INFRA.md`
- [ ] Error tracking receives a test error with privacy defaults on
- [ ] Production deferral (or cutover plan) written in `INFRA.md`
- [ ] `dev-core:architect` plans the first module from `PROJECT.md`; `dev-core:appsec` reads
      `.claude/agent-context/appsec.md` (if created) without "file not found"

**The bootstrap is done when every item is checked.**
