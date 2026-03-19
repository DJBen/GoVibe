#!/usr/bin/env bash
# set-github-secrets.sh — Push Apple release secrets from .env.release to GitHub
# Usage: ./scripts/set-github-secrets.sh [repo]
# Default repo: DJBen/GoVibe

set -euo pipefail

REPO="${1:-DJBen/GoVibe}"
ENV_FILE="$(cd "$(dirname "$0")/.." && pwd)/.env.release"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: $ENV_FILE not found. Copy .env.release.template to .env.release and fill in values."
  exit 1
fi

echo "==> Setting secrets on $REPO"

# Parse key=value lines manually to handle base64 values that contain '=' characters
while IFS= read -r line; do
  # Skip comments and blank lines
  [[ "$line" =~ ^\s*# ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue

  # Split on first '=' only
  key="${line%%=*}"
  value="${line#*=}"

  [[ -z "$key" ]] && continue

  if [[ -z "$value" ]]; then
    echo "  SKIP  $key (empty)"
  else
    gh secret set "$key" --repo "$REPO" --body "$value"
    echo "  OK    $key"
  fi
done < "$ENV_FILE"

echo "==> Done"
