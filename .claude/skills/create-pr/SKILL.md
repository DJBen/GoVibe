---
name: create-pr
description: Use when creating a pull request — generates a human-sounding PR description from the diff and opens the PR via the gh CLI.
user-invocable: true
argument-hint: [base branch]
---

# Create PR

## When to Use

- The user asks to open a PR, raise a PR, or "ship this branch"
- Invoked via `/create-pr`

## When NOT to Use

- The user only wants a local commit (just commit; don't open a PR)
- Work is incomplete or tests are failing (finish first)

## Learnings

Before starting, skim `.claude/learnings/general.md` for repo-specific PR
gotchas. After finishing, add a dated entry if you hit something non-obvious.

## Core Workflow

1. **Determine the base branch.** Use the `[base branch]` argument if given,
   else `main`.
2. **Confirm you're not on the base branch.** If you are, create a feature
   branch first — never commit straight to `main`.
3. **Gather context.** Run `git diff <base>...HEAD` and the commit messages to
   understand intent. Summarize what changed and *why*.
4. **Draft the description.** Write like a human author: a tight summary, the
   reasoning, and a test plan. No filler.
5. **PAUSE — show the user the title and body and wait for approval.** Opening a
   PR is outward-facing; do not run `gh pr create` until they confirm.
6. **Open it.** `gh pr create --base <base> --title "..." --body "..."` and
   return the URL.

## Common Pitfalls

- Committing to `main` instead of a feature branch.
- Pasting the raw diff into the body instead of explaining the change.
- Opening the PR before the user has seen the description.
