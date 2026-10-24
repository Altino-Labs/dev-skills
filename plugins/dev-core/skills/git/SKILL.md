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
gh pr view --json state,mergedAt   # branch already has a PR? stop if it is merged (see below)
git add <specific files>    # never "git add ." blindly
git status --short          # right before EVERY commit — confirm exactly what is staged
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
- **`git status --short` immediately before each commit**, not only when files were deleted.
  An unstaged change — typically a plain `rm` that was never `git rm`'d — is silently undone by
  a `git checkout` to another branch and back, and the commit goes out without it.

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

### Linking issues

- **One closing keyword per issue:** `Closes #12, Closes #13, Closes #14`. GitHub reads
  `Closes #12, #13, #14` as closing only `#12`. After the merge, confirm each issue's state
  (`gh issue view <n> --json state`) instead of trusting the PR body.
- **Never put `fix` / `close` / `resolve` (any tense) right before an issue number that is not
  resolved.** GitHub ignores negation: "this does not fix #42" still closes #42 on merge. Write
  "related to #42" / "see #42" / "#42 stays open".

### Batching — one PR per natural delivery point

Every PR runs CI and, on merge, often a deploy. Accumulate related work on one branch and open
one PR per natural checkpoint (a feature slice, an audit batch, a release) — not one PR per
item.

- **No docs-only PR.** A doc update (status note, changelog line, runbook tweak) rides along
  with the next substantive PR, unless the human asks for it on its own.
- **Never open a PR just to record that another PR merged** (a "mark X as done" note with no
  effect on the code). Fold that note into the next real PR, or leave it on the merged branch.

---

## Protected branches

| Branch | Protection |
|---|---|
| `main` | Required PR, CI must pass, never force-push |
| `develop` | Required PR, CI must pass |

Never push directly to `main` or `develop`.

---

## Committing more to a branch — verify the PR is still open first

`git push` to a branch that already has an open PR normally updates that PR's diff automatically — but only while the PR is still open. Once a PR is merged, GitHub has already created the merge commit from the state at merge time; anything pushed to the source branch afterward just sits on an orphaned branch and never reaches the target branch, with no error or warning from `git push` itself.

**Symptom:** a fix is committed, pushed, and reported as "done" — but a later audit finds it missing from `main`. Typical case: a fix is pushed to a branch minutes *after* its PR was merged (someone merged it while the branch was still checked out locally). The push succeeds silently and the fix never lands until someone notices and reapplies it in a new PR.

**Rule:** before **every commit** on a branch with an existing PR — not only before pushing, and not only after an obvious gap — check `gh pr view <n> --json state,mergedAt` (GitHub CLI; on GitLab `glab mr view <n>`, on Azure DevOps `az repos pr show --id <n>` — or the PR/MR page). The PR can be merged at any moment the human has control, and checking only at push time means the work is already built on a dead branch. If it is merged, **stop**: update `main` (`git fetch && git checkout main && git merge --ff-only origin/main` — a plain `checkout` can leave a stale local `main`), branch off it (or cherry-pick the commit onto a fresh branch), and only then commit — never assume the push lands anywhere.
