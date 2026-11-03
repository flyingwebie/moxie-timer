#!/bin/bash
# Runs the unit tests in an isolated temp "home", so they never touch the real
# ~/Library/Application Support/MoxieTimer (shared with the installed app) or the real Keychain.
#   CFFIXED_USER_HOME / HOME / TMPDIR all point at a fresh mktemp directory for the run, then it's removed.
set -euo pipefail
cd "$(dirname "$0")/.."

TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT

CFFIXED_USER_HOME="$TMP_HOME" HOME="$TMP_HOME" TMPDIR="$TMP_HOME/" \
  swift test --scratch-path /tmp/moxie-test-build "$@"
