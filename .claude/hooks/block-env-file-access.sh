#!/bin/bash

# Claude Code PreToolUse hook to block shell commands that read .env files.
# Read/Edit/Write tool calls are already blocked by permissions.deny in
# settings.json. This hook catches Bash commands (cat, grep, etc.) that target
# .env files. Exit 2 blocks the tool call and shows stderr to the model.

COMMAND=$(jq -r '.tool_input.command // empty' 2>/dev/null)

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Strip known-safe env files (test.env, sample.env, .env.example) before
# checking, so legitimate references don't trip the guard.
SANITIZED=$(echo "$COMMAND" | sed -E 's/(test|sample)\.env//g; s/\.env\.example//g')
if echo "$SANITIZED" | grep -qE '\.env'; then
  cat >&2 <<'EOF'
BLOCKED: .env files contain secrets and must not be read or displayed.
If you need to know what environment variables exist, ask the user to
describe them without values.
EOF
  exit 2
fi

exit 0
