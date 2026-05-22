#!/usr/bin/env bash
# repack-rom.sh — replace system.img inside an extracted rom.zip tree with a
# patched raw (or re-sparsified) system image, then produce rom.zip.
#
# Usage:
#   ./tools/ci/repack-rom.sh <rom-extract-dir> <patched-system.img> <output-rom.zip>
#
# Writes <rom-extract-dir>/.koensayr-system-sparse (0 or 1) on first extract if
# missing; pass the same extract dir used when the flag was recorded.

set -euo pipefail

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: ./tools/ci/repack-rom.sh <rom-extract-dir> <patched-system.img> <output-rom.zip>

Expects <rom-extract-dir> to contain the contents of upstream rom.zip (including
system.img). Replaces system.img with <patched-system.img> (raw ext4 from
apply.bash). If .koensayr-system-sparse in the extract dir is 1, runs img2simg
before zipping.

Create .koensayr-system-sparse when extracting upstream rom.zip:
  echo 1 > dir/.koensayr-system-sparse   # if system.img inside zip was sparse
  echo 0 > dir/.koensayr-system-sparse   # raw
EOF
    exit 0
    ;;
esac

if [[ $# -ne 3 ]]; then
  echo "usage: $0 <rom-extract-dir> <patched-system.img> <output-rom.zip>" >&2
  echo "  see: $0 --help" >&2
  exit 1
fi

EXTRACT_DIR="$1"
PATCHED_RAW="$2"
OUTPUT_ZIP="$3"
TARGET="${EXTRACT_DIR}/system.img"
SPARSE_FLAG="${EXTRACT_DIR}/.koensayr-system-sparse"

if [[ ! -d "$EXTRACT_DIR" ]]; then
  echo "ERROR: extract dir not found: ${EXTRACT_DIR}" >&2
  exit 1
fi
if [[ ! -f "$PATCHED_RAW" ]]; then
  echo "ERROR: patched system image not found: ${PATCHED_RAW}" >&2
  exit 1
fi

was_sparse=0
if [[ -f "$SPARSE_FLAG" ]]; then
  read -r was_sparse < "$SPARSE_FLAG" || was_sparse=0
fi

if [[ "$was_sparse" == "1" ]]; then
  if ! command -v img2simg >/dev/null 2>&1; then
    echo "ERROR: img2simg required to re-sparsify system.img (install android-tools)" >&2
    exit 1
  fi
  echo "[repack] Converting patched raw system.img → sparse.."
  img2simg "$PATCHED_RAW" "$TARGET"
else
  echo "[repack] Installing patched raw system.img.."
  cp -f "$PATCHED_RAW" "$TARGET"
fi

echo "[repack] Building ${OUTPUT_ZIP}.."
rm -f "$OUTPUT_ZIP"
(
  cd "$EXTRACT_DIR"
  # Zip root entries only (exclude marker file from archive).
  zip -r -9 "$OUTPUT_ZIP" . -x '.koensayr-system-sparse'
)

echo "[repack] Done: ${OUTPUT_ZIP} ($(wc -c < "$OUTPUT_ZIP") bytes)"
