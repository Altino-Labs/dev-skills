---
name: git
description: >
  Git conventions: commits, branches, PRs, and workflow.
  Invoke when creating commits, branches, PRs, or reviewing history.
---

# Git Conventions

## Commit format (Conventional Commits)

```
<type>(<scope>): <description>

[optional body — the "why", not the "what"]
```

### Required types

| Type | When to use |
|---|---|
| `feat` | New feature visible to users |
| `fix` | Bug fix |
| `refactor` | Code change without altering behavior |
| `test` | Add or fix tests |
| `chore` | Maintenance: deps, config, build, CI |
| `docs` | Documentation |
| `perf` | Performance improvement |

**Never use:** `wip`, `temp`, `fix stuff`, `updates`, `misc`, `adjustments`.

### Scope (optional but recommended)

Use the module or area name:
```
feat(orders): add order status tracking UI
fix(auth): handle expired refresh token silently
chore(deps): upgrade http-client to 5.1.11
```

---

## Branch names

```
feat/<description-kebab-case>      ← new feature
fix/<description-kebab-case>       ← bug fix
chore/<description-kebab-case>     ← maintenance
hotfix/<description-kebab-case>    ← urgent production fix
```

Examples:
```
feat/order-status-tracking
fix/auth-token-refresh
chore/upgrade-framework-10-4
```

Never: `test-branch`, `my-branch`, `fix-2`, `<person-name>-feature`.

---

## Standard workflow

```bash
# 1. Create branch from main/develop
git checkout -b feat/feature-name

# 2. Atomic commits during development
git add <specific files>    # never "git add ." blindly
git commit -m "feat(module): clear description"

# 3. Before PR — update with base
git fetch origin
git rebase origin/main

# 4. Push and open PR — only per the project's policy (see "Pull Request" below)
git push origin feat/feature-name
```

---

## Commit rules

- **Atomic commits**: each commit does ONE thing. Do not mix feat + refactor.
- **Imperative message**: "add", "fix", "update" — not "added", "fixed", "updated"
- **Never commit**: `.env` and other local secret files (e.g. `.bootstrap-secrets`), build output and
  installed dependencies (e.g. `dist/`, `node_modules/`, `target/`, `.venv/`)
- **Never `--no-verify`**: if the hook fails, investigate the cause — do not bypass

---

## Pull Request

**Follow the project's policy on when to push and when to open PRs.** Pushing and opening a PR
can trigger CI (every workflow wired to `push`/`pull_request`) and consume a shared quota such as
GitHub Actions minutes. Many teams require asking the human first; the project's delta skill or
`CLAUDE.md` states the policy. **Default when nothing is stated: ask before opening a PR.** Local
commits on a branch are always fine.

Title follows the same commit pattern: `feat(module): description`.

Minimum body:
```markdown
## What it does
[1-3 bullets describing the change]

## Why
[Context — ticket, ADR, or decision that motivated the change]

## How to test
[Steps to validate manually]
```

---

## Protected branches

| Branch | Protection |
|---|---|
| `main` | Required PR, CI must pass, never force-push |
| `develop` | Required PR, CI must pass |

Never push directly to `main` or `develop`.

---

## Pushing more commits to a branch — verify the PR is still open first

`git push` to a branch that already has an open PR normally updates that PR's diff automatically — but only while the PR is still open. Once a PR is merged, GitHub has already created the merge commit from the state at merge time; anything pushed to the source branch afterward just sits on an orphaned branch and never reaches the target branch, with no error or warning from `git push` itself.

**Symptom:** a fix is committed, pushed, and reported as "done" — but a later audit finds it missing from `main`. Typical case: a fix is pushed to a branch minutes *after* its PR was merged (someone merged it while the branch was still checked out locally). The push succeeds silently and the fix never lands until someone notices and reapplies it in a new PR.

**Rule:** before pushing a follow-up commit to a branch with an existing PR — especially after any gap where the user could have acted (a question was asked, time passed, control returned to the user) — check `gh pr view <n> --json state,mergedAt` first (GitHub CLI; on GitLab `glab mr view <n>`, on Azure DevOps `az repos pr show --id <n>` — or the PR/MR page). If merged, branch off `main` (or cherry-pick the commit onto a fresh branch) instead of assuming the push lands anywhere.
