#!/usr/bin/env bash
# patch-revision.sh — identifier for koensayr patch sources baked into CI rom.zip output.
#
# Used to skip scheduled rebuilds only when upstream firmware and this revision
# already produced the current GitHub release.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git rev-parse HEAD
  exit 0
fi

# Fallback when .git is unavailable (local tarball builds).
{
  grep -E '^# Version:' apply.bash || true
  find apply.bash src/patches src/Y1Bridge src/su -type f 2>/dev/null | LC_ALL=C sort | while read -r f; do
    sha256sum "$f"
  done
} | sha256sum | awk '{print $1}'
