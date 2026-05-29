---
name: writing-skills
description: Use when creating new Claude skills, editing existing skills, or reviewing skill quality. Provides the canonical template and conventions for this repo.
---

# Writing Claude Skills

Guide for creating and maintaining skills (`.claude/skills/`) in this repo.

## When to Use

- Creating a new skill from scratch
- Reviewing or improving an existing skill
- Helping someone understand how skills work here

## When NOT to Use

- Performing the actual workflow (invoke that skill instead)
- One-off tasks that won't recur (not everything needs a skill)

## Skill Anatomy

A skill is a directory under `.claude/skills/` with at minimum a `SKILL.md`:

```
.claude/skills/
  my-skill/
    SKILL.md          # Required — skill definition
    references/       # Optional — detailed reference docs the skill links to
    scripts/          # Optional — automation the skill calls
```

## SKILL.md Structure

```markdown
---
name: my-skill
description: Use when [trigger condition]. [One sentence on what it does.]
---

# Skill Title

## When to Use
- [Specific trigger 1]
- [Specific trigger 2]

## When NOT to Use
- [Anti-pattern that should NOT activate this skill]

## Learnings
Before starting, check `.claude/learnings/{domain}.md` for recent gotchas.
After finishing, add a dated entry there if you solved something non-obvious.

## Core Workflow
1. [Concrete, imperative step]
2. [Step] — **PAUSE here and confirm with the user** before destructive/outward actions
...

## Common Pitfalls
- [Pitfall 1]
```

## Required Elements

### 1. Frontmatter

```yaml
---
name: kebab-case-name        # matches the directory name
description: Use when ...     # see below — the most important line
---
```

- **`description`** starts with **"Use when"** and is the ONLY thing the model
  reads at session start. It must encode the *trigger*, not just the topic.
  Keep it under ~200 chars. This is what makes on-demand loading work.
- Optional: `user-invocable: true` (enables `/my-skill`), `argument-hint`.

### 2. "When to Use" AND "When NOT to Use"

The negative space prevents over-triggering. Be explicit about scope.

### 3. Learnings integration

Every non-trivial skill links the relevant learnings file (read before, append
after). Purely mechanical skills (a version checker) may omit it.

### 4. Workflow as numbered imperatives

Each step concrete and actionable. **Bold the mandatory pause points** where the
user must confirm — especially before anything hard to reverse or outward-facing.

## Review Checklist

- [ ] `description` starts with "Use when" and names the trigger
- [ ] Has both "When to Use" and "When NOT to Use"
- [ ] Steps are concrete imperatives, not vague advice
- [ ] Pause points are bolded before risky actions
- [ ] Links learnings (unless purely mechanical)
- [ ] Added to the routing table in `CLAUDE.md` if it competes with a default
