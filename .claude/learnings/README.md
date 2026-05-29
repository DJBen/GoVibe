# Learnings

Feed-forward institutional memory. Each file covers one **problem domain** so it
stays small enough to read at the start of a task. Recording learnings is part
of the definition of done — like writing tests.

## How to use

- **Before** working in a domain, skim that file's recent entries.
- **After** solving a non-obvious problem, add a dated entry. Don't wait to be asked.
- Keep entries concise (3–6 lines). One entry = one debugging cost recovered.
- When a pattern proves stable and reusable, promote it into the relevant skill.

## Files (partition by domain — create as you go)

- `general.md` — anything that doesn't yet have a home
- `ios.md` — iOS / macOS Swift & SwiftUI gotchas
- `relay.md` — WebSocket relay and Cloud Run infrastructure

## Entry format

Newest entries at the top. Use a dated heading plus these fields:

```markdown
### Short, specific title (YYYY-MM-DD)

**Context**: What were you doing? What surfaced the problem?
**Pattern**: The fix / the convention to follow next time.
**Key insight**: The non-obvious thing — why it bites, what to watch for.
**Key files**: path/to/file.ext, path/to/other.ext
```

Write titles a future agent would *search for*. "Developer ID signing requires
manual profile in xcconfig" beats "fixed a signing bug".
