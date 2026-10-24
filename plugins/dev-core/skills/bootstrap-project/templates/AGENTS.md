# AGENTS.md
> Universal entry point for all AI agents in <project>.
> Read by any tool (Claude Code, Cursor, Windsurf, Copilot, etc.).
> If you are an agent: **read this entire file before any action**.

---

## 1. Mandatory loading sequence

Execute in this order before any task:

```
1. .claude/constitution.md    ← absolute rules
2. .claude/general-context.md ← shared technical context (stack, layout, vocabulary)
3. PROJECT.md                 ← domain, ADRs, data model, business rules
4. INFRA.md                   ← if the task involves infrastructure, services or deploy
5. SESSION.md                 ← latest entry: where the last session stopped
6. .claude/me.md              ← developer context on this machine (optional, gitignored)
7. relevant sub-agent / skill ← per the tables below
```

Never skip step 1. Never skip step 3 when the domain is relevant.

---

## 2. Conflict hierarchy

When documents contradict each other, the higher item wins:

```
1. .claude/constitution.md       ← absolute rules
2. PROJECT.md                    ← domain, ADRs, business rules
3. INFRA.md                      ← infrastructure and services
4. .claude/general-context.md    ← shared technical context
5. .claude/skills/<project>-*    ← project complements to the plugin skills
   plugin skills (dev-core, stack plugin) ← reusable patterns
6. .claude/agent-context/<agent>.md ← project rules for each sub-agent
   plugin agents (dev-core)      ← sub-agent behavior
7. user instruction              ← point overrides; never override 1–4
```

---

## 3. Sub-agent selection

All sub-agents come from the shared `dev-core` plugin. Each reads the project's rules from
`.claude/agent-context/<agent>.md` when it exists (that file wins on conflict).

| Task | Sub-agent |
|---|---|
| Plan a new module before implementing | `dev-core:architect` |
| Implement backend use cases, handlers, repositories | `dev-core:backend-developer` |
| Create screens, components, client state | `dev-core:frontend-developer` |
| Create or review migrations and data-access policies | `dev-core:dba` |
| Write unit, integration and contract tests | `dev-core:qa` |
| Review architecture, cohesion, pattern consistency | `dev-core:tech-lead` |
| Review security (auth, access policies, CORS, sensitive data) | `dev-core:appsec` |
| Deploy, CI/CD, infrastructure | `dev-core:devops` |

When a task spans roles, pick the most specialized one.

---

## 4. Skill selection

Each `<name>` below means: load `dev-core:<name>`, plus the stack plugin's `<stack>:<name>`
when it exists, plus `.claude/skills/<project>-<name>/` when it exists (it holds what is
specific to <project> and wins on conflict). Tools without plugin support read the generic
skill from `plugins/<plugin>/skills/<name>/` in the plugin repository.

| Situation | Skill |
|---|---|
| Create entity, use case, repository or controller | `clean-architecture` |
| Create or review an API endpoint | `api-contracts` |
| Create or alter a database schema | `migrations` |
| Login, tokens, guards, permission checks | `auth-security` |
| Error handling | `error-handling` |
| Tests of any kind | `test-patterns` |
| Publish or subscribe to domain events | `domain-events` |
| Logging, correlation IDs, error tracking, health checks | `logging-observability` |
| External services that can fail | `resilience-patterns` |
| Dates, times, time zones, scheduled jobs | `date-time` |
| New personal-data field, consent, legal pages, go-live privacy | `privacy-compliance` |
| Rotate secrets or handle an exposed secret | `secrets-rotation` |
| Commits, branches, PRs | `git` |
| Before merging a branch | `pre-merge` |
| Full-repository health check (human-triggered) | `audit` |
| <stack-specific situation> | `<stack>:<skill>` |

---

## 5. Domain references

| When you need | Consult |
|---|---|
| Business rules, permissions, data model | `PROJECT.md` |
| Canonical enum values | `PROJECT.md` — enum table |
| Why a technical decision was made | `PROJECT.md` ADRs (or `project/ADR.md`) |
| Services, environments, env vars, runbooks | `INFRA.md` |
| Multi-phase plans | `ROADMAP.md` |

---

## 6. Communication guidelines

- **Concise**: the minimum needed to be clear and actionable
- **Direct code**: show the code without explaining it line by line
- **Bullets over paragraphs**
- **No unnecessary confirmations** for explicit tasks
- **Unexpected state**: stop and report the context — never assume and proceed

---

## 7. Local development

```bash
# <how to start every service locally, one block per app>
# <URLs and ports>
# <how to reset and seed the local database>
```

---

## 8. Session log

At the end of each significant session, add an entry on top of `SESSION.md`
(format in the file: what was done · decisions made · pending items · requires human
attention). Plans that span more than one session go to `ROADMAP.md` before the work starts.

---

## 9. Mandatory post-generation verification cycle

After generating any complete module, the agent **cannot** declare the task done until the
four checkpoints pass, in this order:

| # | Checkpoint | Criterion |
|---|---|---|
| 1 | **Build** | `<build command>` — zero compile/type errors in every app |
| 2 | **Tests** | `<test command>` — zero failures |
| 3 | **System running** | `<local URL>` responds (e.g. the health or docs endpoint) |
| 4 | **Smoke test** | At least one endpoint (or screen) of the module behaves as expected |

If a checkpoint fails: fix it and repeat from the failing step. For UI changes, also check the
running app and say what was checked by hand.

---

## 10. Generation mode (authorized bootstrap)

When the user explicitly asks to generate the system or a complete module, destructive
operations **inside the project workspace** are pre-authorized: clearing build outputs and
caches, resetting the **local** database, recreating unreleased dev migrations. The agent runs
them without asking at each step. Everything outside the workspace, and every shared
environment, still follows the approval list in `.claude/constitution.md`.
