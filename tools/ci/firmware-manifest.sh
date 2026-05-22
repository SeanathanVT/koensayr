#!/usr/bin/env bash
# firmware-manifest.sh — read KNOWN_FIRMWARES rows from apply.bash (single source of truth).
#
# Usage (sourced):
#   firmware_manifest_row 3.0.2
#   firmware_manifest_field 3.0.2 rom_md5

set -euo pipefail

FIRMWARE_MANIFEST_APPLY_BASH="${FIRMWARE_MANIFEST_APPLY_BASH:-}"

firmware_manifest_apply_bash() {
  if [[ -n "$FIRMWARE_MANIFEST_APPLY_BASH" && -f "$FIRMWARE_MANIFEST_APPLY_BASH" ]]; then
    echo "$FIRMWARE_MANIFEST_APPLY_BASH"
    return 0
  fi
  local root="${REPO_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  fi
  echo "${root}/apply.bash"
}

firmware_manifest_row() {
  local version="$1"
  local apply
  apply="$(firmware_manifest_apply_bash)"
  grep -E "^[[:space:]]+\"${version}\|" "$apply" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//'
}

firmware_manifest_field() {
  local version="$1" field="$2"
  local row idx
  row="$(firmware_manifest_row "$version")"
  if [[ -z "$row" ]]; then
    return 1
  fi
  case "$field" in
    system_md5) idx=2 ;;
    boot_md5)   idx=3 ;;
    rom_md5)    idx=4 ;;
    music_apk)  idx=5 ;;
    *) echo "ERROR: unknown firmware_manifest_field ${field}" >&2; return 2 ;;
  esac
  echo "$row" | cut -d'|' -f"$idx"
}

# firmware_md5_matches_field <manifest-field-value> <actual-md5>
firmware_md5_matches_field() {
  local field_value="$1" actual="$2" alt
  IFS=',' read -ra alts <<< "$field_value"
  for alt in "${alts[@]}"; do
    alt="${alt//[[:space:]]/}"
    if [[ "$actual" == "$alt" ]]; then
      return 0
    fi
  done
  return 1
}

firmware_version_from_slug() {
  local slug="$1"
  if [[ "$slug" =~ ^y1-stock-rom-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}
