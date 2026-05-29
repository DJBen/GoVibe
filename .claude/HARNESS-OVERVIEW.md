# The Agent Harness — Overview & Rationale

This document explains what lives in `.claude/`, why each piece exists, and the
order to adopt them.

## What "the harness" is

The harness is a set of layers, all **plain files checked into the repo**, that
compose. From always-on to on-demand:

| Layer | Location | Loaded when | Purpose |
|---|---|---|---|
| **Instructions** | `CLAUDE.md` (root + `ios/CLAUDE.md`) | Always / on file proximity | Durable rules + a routing table |
| **Settings** | `.claude/settings.json` (shared) + `settings.local.json` (per-dev, gitignored) | Always | Permissions, hooks |
| **Hooks** | `.claude/hooks/*.{sh,js}` | On tool / prompt events | Deterministic guardrails |
| **Skills** | `.claude/skills/*/SKILL.md` | On-demand by description match | Guided workflows |
| **Learnings** | `.claude/learnings/*.md` (by domain) | Read at task start, appended at task end | Feed-forward institutional memory |

## The three tiers of enforcement

1. **Instructions** (`CLAUDE.md`) — the model *should* do this.
2. **Skills** — the model *follows a recipe* when a situation matches.
3. **Hooks / permissions** — the harness *guarantees* it, regardless of model.

Example: "don't read `.env`" is a tier-3 rule. It lives in `permissions.deny`
AND a Bash hook — not just a sentence in `CLAUDE.md`.

## Why each piece earns its place

- **Routing table** (in `CLAUDE.md`): turns "I have capabilities" into "given X,
  do Y, not naive Z." Cheapest thing to maintain, highest payoff.

- **Learnings system**: domain-partitioned files so each stays small enough to
  read at task start. Each entry is a debugging cost recovered.

- **Hooks as guardrails**: belt-and-suspenders. `permissions.deny` blocks the
  file tools; a Bash hook blocks `cat`/`grep`.

- **`writing-skills` meta-skill**: keeps the skill library consistent.

- **Split settings**: `settings.json` (committed team baseline) vs
  `settings.local.json` (gitignored, grows per-dev).
