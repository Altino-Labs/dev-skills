# Mutation Testing with Stryker
> Sub-file of `dev-patterns:test-patterns`. The policy — scope to domain + use cases, targets
> (domain ≥ 80%, use cases ≥ 60%), report-only first, where low scores cluster, fixing from the
> mutant list, equivalent mutants, unscored new code as expected lag — is in
> `dev-core:test-patterns` → "Mutation testing". This file is the Stryker implementation for a
> NestJS backend in a pnpm workspace.

---

## Setup

Use Stryker (`@stryker-mutator/core` + `@stryker-mutator/jest-runner`) on the backend app
(e.g. `apps/api/stryker.conf.json`), scoped to `src/**/domain/**` and `src/**/use-cases/**`
(Entities/VOs and Use Cases — the two layers a mutation-score bar should target).
Exclude repository interfaces (`**/repositories/**`), NestJS `*.module.ts` wiring, barrel
`index.ts` files and `*.spec.ts` — no real branches to mutate there. Enable the `html`, `json`
and `clear-text` reporters (the JSON report is what you mine for missing tests) and keep
`coverageAnalysis: "perTest"` — a full run over a mid-size API takes ~10 min.

```bash
cd apps/api
pnpm run mutation          # "mutation": "stryker run" — runs Stryker against the scoped glob
# report: reports/mutation/index.html + mutation-report.json (gitignore it, local only)
```

Add `reports/mutation/` to the app's `.gitignore` — the reports are local/CI artifacts only.

**Fixing low scores:** read the mutant list (location + mutator + replacement) straight from
`reports/mutation/mutation-report.json` to know exactly which test cases are missing.

## Report-only scheduled workflow

**Not a merge gate at first.** Run it in a scheduled CI workflow (e.g. weekly +
`workflow_dispatch`) that publishes the score to the job summary and the HTML/JSON report as
a build artifact, with **no `thresholds.break`** in `stryker.conf.json` — so a low score never
fails the workflow or blocks a PR.

## Checking whether a file has been scored yet

Before filing (or re-triaging) an issue like "X never ran mutation testing," check whether a
scheduled run has actually happened since the file merged:

```bash
gh run list --workflow mutation-testing.yml --limit 5          # confirm the schedule is firing
gh run view <run-id> --log | grep "your-use-case.ts  *|"        # per-file score table, if it ran since
```

If a run already covered the file, read its score off that table instead of re-running Stryker
locally or opening a new issue — only a score that's actually **below** the ≥80%/≥60% targets
is worth tracking as a finding; "hasn't run yet" self-resolves by the next scheduled run, so
don't keep issues open for it.

## Scope it to the backend only

A React Native app's Jest runs through a Babel/Metro preset that Stryker's jest-runner does not
support well (known ecosystem gap) — extending mutation testing to mobile is a separate
decision.

## Pitfall — pnpm workspaces

Stryker's default plugin auto-discovery (`plugins: ["@stryker-mutator/*"]`) silently fails to
find `@stryker-mutator/jest-runner` in a pnpm workspace (symlinked `node_modules`, not the flat
layout the glob-based loader expects) — the error is `Cannot find TestRunner plugin "jest"`
even though the package is installed and correctly symlinked. Fix: list the plugin explicitly —
`"plugins": ["@stryker-mutator/jest-runner"]` in `stryker.conf.json` — which bypasses the glob
and does a normal `require()`. Also set `"packageManager": "pnpm"`.
