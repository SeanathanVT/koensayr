#!/usr/bin/env bash
# discover-inputs.sh — build matrix for allowed y1-stock-rom rom.zip releases.
#
# Only these upstream tags are considered:
#   y1-community/y1-stock-rom  → 3.0.2, Latest-3.0.7 (published as VERSION-koensayr-3.0.2 / VERSION-koensayr-3.0.7)
#
# Usage:
#   ./tools/ci/discover-inputs.sh [--source-repo OWNER/NAME] [--force]

set -euo pipefail

SOURCE_FILTER=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-repo)
      SOURCE_FILTER="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: ./tools/ci/discover-inputs.sh [--source-repo OWNER/NAME] [--force]

Emits a JSON array of matrix objects:
  source_repo, source_tag, release_tag, download_url, digest, slug

Upstream allowlist (rom.zip only):
  y1-community/y1-stock-rom: 3.0.2, Latest-3.0.7 (→ koensayr release VERSION-koensayr-3.0.2 / VERSION-koensayr-3.0.7)
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: gh CLI required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 required" >&2
  exit 1
fi

REPOS=(
  "y1-community/y1-stock-rom"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KOENSAYR_VERSION="$(grep -E '^# Version:' "${REPO_ROOT}/apply.bash" | awk '{print $3}')"

python3 - "$SOURCE_FILTER" "$FORCE" "$KOENSAYR_VERSION" "${REPOS[@]}" <<'PY'
import json
import subprocess
import sys

source_filter = sys.argv[1]
force = sys.argv[2] == "true"
koensayr_version = sys.argv[3]
repos = sys.argv[4:]

Y1_REPO = "y1-community/y1-stock-rom"
# Upstream GitHub release tag → firmware version for koensayr release naming.
Y1_UPSTREAM_TAGS = {
    "3.0.2": "3.0.2",
    "Latest-3.0.7": "3.0.7",
}


def release_has_rom_zip(repo: str, tag: str) -> dict | None:
    out = subprocess.run(
        [
            "gh",
            "api",
            f"repos/{repo}/releases/tags/{tag}",
            "--jq",
            '[.assets[] | select(.name == "rom.zip")][0]',
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0 or not out.stdout.strip() or out.stdout.strip() == "null":
        return None
    try:
        asset = json.loads(out.stdout)
    except json.JSONDecodeError:
        return None
    digest = asset.get("digest") or ""
    if digest.startswith("sha256:"):
        digest = digest[7:]
    return {
        "browser_download_url": asset["browser_download_url"],
        "digest": digest,
    }


entries: list[dict] = []

for repo in repos:
    if source_filter and repo != source_filter:
        continue
    for upstream_tag in sorted(
        Y1_UPSTREAM_TAGS.keys(),
        key=lambda t: Y1_UPSTREAM_TAGS[t],
    ):
        asset = release_has_rom_zip(repo, upstream_tag)
        if asset is None:
            continue
        fw_version = Y1_UPSTREAM_TAGS[upstream_tag]
        release_tag = f"{koensayr_version}-koensayr-{fw_version}"
        slug = f"y1-stock-rom-{fw_version}"
        entries.append(
            {
                "source_repo": repo,
                "source_tag": upstream_tag,
                "release_tag": release_tag,
                "download_url": asset["browser_download_url"],
                "digest": asset["digest"],
                "slug": slug,
                "force": force,
            }
        )

print(json.dumps(entries))
PY
