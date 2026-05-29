#!/usr/bin/env node
// Cross-platform shim so Python hooks work on Windows (py) and macOS/Linux
// (python3). Use in settings.json as:
//   node "$CLAUDE_PROJECT_DIR"/.claude/hooks/run-python.js "$CLAUDE_PROJECT_DIR"/.claude/hooks/my-hook.py
const { spawnSync } = require('node:child_process');
const cmd = process.platform === 'win32' ? 'py' : 'python3';
const result = spawnSync(cmd, process.argv.slice(2), { stdio: 'inherit' });
process.exit(result.status ?? 1);
