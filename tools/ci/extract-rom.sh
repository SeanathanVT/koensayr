#!/usr/bin/env bash
# extract-rom.sh — unzip rom.zip and record whether system.img was sparse.
#
# Usage: ./tools/ci/extract-rom.sh <rom.zip> <extract-dir>

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <rom.zip> <extract-dir>" >&2
  exit 1
fi

ROM_ZIP="$1"
EXTRACT_DIR="$2"

mkdir -p "$EXTRACT_DIR"
unzip -q -o "$ROM_ZIP" -d "$EXTRACT_DIR"

SYS="${EXTRACT_DIR}/system.img"
if [[ ! -f "$SYS" ]]; then
  echo "ERROR: ${ROM_ZIP} has no system.img at zip root" >&2
  exit 1
fi

is_sparse=0
if command -v file >/dev/null 2>&1 && file "$SYS" | grep -q "Android sparse image"; then
  is_sparse=1
else
  magic=$(head -c 4 "$SYS" 2>/dev/null | od -An -v -t x1 | tr -d ' \n')
  [[ "$magic" == "3aff26ed" ]] && is_sparse=1
fi

echo "$is_sparse" > "${EXTRACT_DIR}/.koensayr-system-sparse"
echo "[extract] ${ROM_ZIP} → ${EXTRACT_DIR} (system.img sparse=${is_sparse})"
