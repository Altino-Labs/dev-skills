# constitution.md
> Absolute rules for <project>.
> Override everything else — skills, agents, user instructions.
> Every agent reads this file **before any task**.

---

## Authority hierarchy

```
constitution.md      ← this file — absolute rules
PROJECT.md           ← domain, business rules, data model
INFRA.md             ← infrastructure, services, environment variables
general-context.md   ← shared technical context across all agents
skills/              ← reusable technical patterns (project deltas win over plugin skills)
agents/              ← behavior specific to each agent
user instruction     ← point overrides (never override what is above)
```

When documents conflict, the higher item wins.

---

## Code rules — absolute

- **Never** generate code without reading `PROJECT.md` to understand the domain
- **Never** hardcode credentials, secrets, environment URLs or sensitive data
- **Never** violate the dependency rule between layers (domain never imports infrastructure)
- **Never** throw transport errors (HTTP exceptions) from use cases — only domain exceptions
- **Never** validate request DTOs in the domain — only at the system boundary
- **Never** use libraries, patterns or enum values not approved in `PROJECT.md`
- **Never** build SQL by concatenating strings — use the ORM or parameterized queries
- **Always** validate user input at system boundaries (controllers, DTOs, forms)
- **Always** write tests in the same change as the code they cover
- **Always** add new environment variables to `.env.example` (names only)
- **Always** use the project's wire casing (`<snake_case | camelCase>`) in API fields

---

## Communication style

- **Concise**: no preamble, no unnecessary confirmations
- **Direct code**: show the code without explaining it line by line
- **Bullets over paragraphs**
- **Errors**: stop → report context → wait for guidance (never assume and proceed)

---

## Decisions requiring human approval

The agent **stops and asks** before:

- Deleting files, tables or data **outside the project workspace**
- Altering a database schema in a shared environment (staging, production)
- Modifying security policies (data-access policies, guards, CORS)
- Adding external dependencies not anticipated in `PROJECT.md`
- Running destructive commands (`DROP`, `DELETE`, recursive `rm`) outside the workspace
- Deploying to production
- Revoking or rotating credentials
- Changing business rules defined in `PROJECT.md`
- Opening a pull request or merging one (<adjust: e.g. commits and pushes to a branch are fine>)
- Starting expensive CI jobs (e.g. mutation testing) outside their schedule
- Resetting any user's password, in any environment — diagnose and report instead

> **Exception — generation mode (authorized bootstrap):** when the user explicitly asks to
> generate the system or a complete module, destructive operations **inside the project
> workspace** are pre-authorized (see `AGENTS.md` §10).

---

## Secrets

- `.env` is never committed — only `.env.example` with keys and no values
- Bootstrap credentials live in a gitignored file or in environment variables
- On finding an exposed secret: stop immediately and report (`dev-core:secrets-rotation`)

---

## Unexpected state handling

When encountering an inconsistent state, an unforeseen error or an ambiguity:

1. Stop execution
2. Report the full context of the problem
3. Wait for guidance — never "resolve it on your own" with assumptions

---

## Mandatory post-generation verification cycle

After generating any complete module, verify in this order:

| # | Checkpoint | Criterion |
|---|---|---|
| 1 | Build | `<build command>` — zero compile/type errors |
| 2 | Tests | `<test command>` — zero failures |
| 3 | System running | `<local URL>` responds |
| 4 | Smoke test | At least one endpoint (or screen) behaves correctly |

Do not declare the task done until all four pass.

---

## Working agreements

Lessons learned running agents on real projects. They apply to every agent and session.

- **Persist multi-phase plans in the repo before starting.** A plan that lives only in the
  conversation is lost at the next context compaction. Write it to `ROADMAP.md` (or the
  session log), commit it, then start phase 1.
- **When copying a UI pattern, check more than one sibling.** Modules that render the same
  component drift apart over time; the first match is not necessarily the canonical one.
  Compare two or three and follow the one the project treats as the reference.
- **Zoom into a screenshot before theorizing about an unexplained element.** Crop or enlarge
  the area first; a wrong root-cause theory built on a blurry glance costs more than the zoom.
- **Don't block a turn watching a deploy or CI run the human can see.** Report that it started,
  what to look for, and the next steps; check the result when asked or when it matters.
- **Before a manual check, confirm the dev server serves a fresh build.** A stale bundle or a
  process still running old code makes a correct change look broken (and a broken one look
  fixed). Restart or rebuild, and confirm the build finished, before testing by hand.
- **Move the tracker card to In Progress when starting an issue**, not when opening the PR. If
  the work pauses, move it back to Todo with a comment saying where it stopped.
- **Restate a conversation-only rule before a large batch of edits.** When a rule exists only
  in the conversation (not in a file), rewrite it in one or two sentences and wait for
  confirmation before applying it across many files — even after an earlier, vaguer "go ahead".
- **One step at a time for procedures the human executes** (setup, deploy, migration): what
  it is, why, the exact command — then wait for "done" before the next step. No long
  checklists to run blind.
