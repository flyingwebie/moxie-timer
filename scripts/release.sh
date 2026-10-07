#!/bin/bash
# Publishes a release: ./scripts/release.sh 1.2.0
# Runs the Release workflow on GitHub, which builds the app, creates tag v<version> and the release.
# Installed apps pick it up through their built-in updater.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <major.minor.patch>" >&2
  exit 1
fi
if gh release view "v$VERSION" >/dev/null 2>&1; then
  echo "Release v$VERSION already exists." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes first." >&2
  exit 1
fi
git fetch -q origin main
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "Push main first: the release is built from origin/main." >&2
  exit 1
fi

gh workflow run release.yml --ref main -f version="$VERSION"
echo "Waiting for the workflow to start…"
until RUN_ID=$(gh run list --workflow release.yml --event workflow_dispatch --limit 1 \
  --json databaseId,status -q '.[] | select(.status != "completed") | .databaseId') && [[ -n "$RUN_ID" ]]; do
  sleep 2
done
gh run watch "$RUN_ID" --exit-status --interval 10
gh release view "v$VERSION" --json url -q .url
