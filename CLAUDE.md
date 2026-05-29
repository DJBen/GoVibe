# CLAUDE.md

Shared guidance for coding agents working in this repository.

## Security: .env Files

NEVER read, display, or modify `.env` files. They contain secrets and
credentials. This is enforced two ways: `permissions.deny` in
`.claude/settings.json` blocks the Read/Edit/Write tools, and a PreToolUse hook
(`.claude/hooks/block-env-file-access.sh`) blocks Bash commands (`cat`, `grep`,
…) that target them. If you need to know what env vars exist, ask the user to
describe them without values.

## Repository Overview

GoVibe is a mobile-first coding companion that connects an **iOS client app** to
**macOS host sessions** (terminal, Xcode Simulator) via a **WebSocket relay**.
The host watches AI coding tools (Claude Code, Codex CLI, Gemini CLI) and
streams session data to the iOS app in real time.

```
GoVibe/
├── ios/                          # All Apple platform code
│   ├── GoVibe.xcodeproj/        # Xcode project (all targets + SPM deps)
│   ├── GoVibe/                  # iOS app target — thin entry point
│   ├── GoVibeFeaturePackage/    # iOS feature module (SwiftUI views, stores)
│   ├── GoVibeHostCorePackage/   # Shared host core (sessions, relay, log watchers)
│   ├── GoVibeHostApp/           # macOS host app (menu bar UI, onboarding)
│   ├── GoVibeHostCli/           # macOS host CLI target
│   ├── Config/                  # XCConfig build settings
│   └── GoVibeUITests/           # UI automation tests
├── infra/cloud-run-relay/       # Node.js WebSocket relay (Cloud Run)
├── backend/                     # Firebase backend (Firestore rules, Cloud Functions)
├── scripts/                     # Build, release, and E2E test scripts
├── shared/protocol/             # Shared protocol definitions
└── web/                         # Firebase Hosting landing pages
```

**Important:** All iOS/macOS development happens in the SPM packages
(`GoVibeFeaturePackage`, `GoVibeHostCorePackage`), not in the app targets
directly. The app targets are thin wrappers.

## Build & Run

Use `xcodebuildmcp` for all Xcode builds. See `AGENTS.md` for full command
reference.

- **iOS app:** scheme `GoVibe`, project `ios/GoVibe.xcodeproj`
- **macOS host:** scheme `GoVibeHost`, project `ios/GoVibe.xcodeproj`
- **Relay server:** `cd infra/cloud-run-relay && npm install && npm start`
- **SPM package tests:** `xcodebuildmcp` or `swift test` in the package dir
- **Lint/format:** Swift — follow existing style; JS — no separate linter configured

## Branch Strategy

- **Main branch**: `main`
- **PRs**: Create feature branches, open PRs to `main`.
- Commit/push only when the user asks.

## Skills

This repo uses Claude skills (`.claude/skills/`) for guided workflows. Skills
load on-demand by their `description`, so they don't dilute context at session
start. Use `/writing-skills` when creating or editing a skill.

### Skill Priority (routing table)

When multiple approaches could apply, **prefer the repo-specific skill** — it
encodes project tools and conventions a generic approach lacks.

| Scenario | Use this | Not this |
|----------|----------|----------|
| Opening a pull request | `create-pr` | ad-hoc `gh pr create` |
| Creating or editing a skill | `writing-skills` | generic templates |

## Learnings System (REQUIRED)

Institutional knowledge lives in `.claude/learnings/`, partitioned by problem
domain. Recording learnings is part of the definition of done — like tests.

- **Before complex work**: skim the relevant learnings file for recent gotchas.
- **Before finishing any task**: if you discovered a non-obvious insight, add a
  dated entry to the appropriate learnings file. Don't wait to be asked.

See `.claude/learnings/README.md` for the entry format.

## Code Comments

Comments describe the **current** state of the code, not the diff that produced
it. Don't write `// added for TICKET-123`, `// per review feedback`, or
`// no longer does X`. That context belongs in the commit message. Only comment
when the *why* is non-obvious from the code itself.

## GitHub Interaction

Prefer the GitHub CLI (`gh`) over guessing. Use read-only commands by default
(`gh pr view`, `gh pr diff`, `gh issue view`). Only perform write actions when
the user explicitly asks. Check `gh auth status` if authentication is unclear.

## Per-Package Instructions

Detailed Swift/SwiftUI conventions, architecture, testing, and API references
live in `ios/CLAUDE.md`. That file is loaded automatically when working in the
`ios/` tree.
