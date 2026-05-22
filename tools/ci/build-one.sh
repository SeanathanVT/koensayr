#!/usr/bin/env bash
# build-one.sh — download one upstream rom.zip, patch with koensayr --all, repack,
# and publish (or skip) a GitHub release on the current repo.
#
# Usage:
#   ./tools/ci/build-one.sh \
#     --source-repo y1-community/y1-stock-rom \
#     --source-tag 3.0.2 \
#     [--release-tag 2.4.0-koensayr-3.0.2]  # optional; derived as VERSION-koensayr-FW if omitted
#     --download-url <url> \
#     --digest <sha256> \
#     --slug y1-stock-rom-3.0.2 \
#     [--force]

set -euo pipefail

SOURCE_REPO=""
SOURCE_TAG=""
RELEASE_TAG=""
RELEASE_TAG_ARG=""
DOWNLOAD_URL=""
DIGEST=""
SLUG=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
    --source-tag) SOURCE_TAG="$2"; shift 2 ;;
    --release-tag) RELEASE_TAG_ARG="$2"; shift 2 ;;
    --download-url) DOWNLOAD_URL="$2"; shift 2 ;;
    --digest) DIGEST="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: ./tools/ci/build-one.sh --source-repo REPO --source-tag TAG \
  --release-tag TAG --download-url URL --digest SHA256 --slug SLUG [--force]

Environment:
  KOENSAYR_SKIP_PUBLISH=1   Build only; do not create/upload GitHub release.
  GITHUB_REPOSITORY          Target repo for releases (defaults from gh).
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown arg $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$SOURCE_REPO" || -z "$SOURCE_TAG" || -z "$DOWNLOAD_URL" || -z "$SLUG" ]]; then
  echo "ERROR: --source-repo, --source-tag, --download-url, and --slug are required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CI_DIR="${REPO_ROOT}/tools/ci"
# shellcheck source=firmware-manifest.sh
source "${CI_DIR}/firmware-manifest.sh"
WORKDIR="$(mktemp -d -t koensayr-ci.XXXXXX)"
trap 'rm -rf "$WORKDIR"' EXIT

STAGING="${WORKDIR}/staging"
EXTRACT="${WORKDIR}/rom-extract"
mkdir -p "$STAGING" "$EXTRACT"

KOENSAYR_VERSION="$(grep -E '^# Version:' apply.bash | awk '{print $3}')"
PATCH_REVISION="$("${CI_DIR}/patch-revision.sh")"
RELEASE_INTRO_FILE="${REPO_ROOT}/.github/workflows/workflow.md"

if ! FW_VERSION="$(firmware_version_from_slug "$SLUG")"; then
  echo "ERROR: slug ${SLUG} is not a known y1-stock-rom firmware id" >&2
  exit 1
fi
RELEASE_TAG="${KOENSAYR_VERSION}-koensayr-${FW_VERSION}"
RELEASE_TITLE="${KOENSAYR_VERSION}-koensayr-${FW_VERSION}"
if [[ -n "$RELEASE_TAG_ARG" && "$RELEASE_TAG_ARG" != "$RELEASE_TAG" ]]; then
  echo "[build-one] NOTE: matrix release-tag ${RELEASE_TAG_ARG} ignored; using ${RELEASE_TAG}"
fi

# True when the commit being built was authored by SeanathanVT (GitHub / git display name).
commit_author_is_seanathanvt() {
  local author email
  author="$(git log -1 --format='%an')"
  email="$(git log -1 --format='%ae')"
  shopt -s nocasematch
  [[ "$author" == *seanathanvt* || "$email" == *seanathanvt* ]]
  local rc=$?
  shopt -u nocasematch
  return $rc
}

# Idempotency: skip only when an existing release was built from the same upstream
# rom.zip *and* the same koensayr git revision (patches / apply.bash / Y1Bridge / su).
# Push workflows pass --force to always republish after commits to main.
release_already_current() {
  local tag="$1" manifest_dir published_rev published_digest
  if ! gh release view "$tag" >/dev/null 2>&1; then
    return 1
  fi
  manifest_dir="$(mktemp -d)"
  if ! gh release download "$tag" -p "build-manifest.json" -D "$manifest_dir" >/dev/null 2>&1; then
    rm -rf "$manifest_dir"
    return 1
  fi
  if [[ ! -f "${manifest_dir}/build-manifest.json" ]]; then
    rm -rf "$manifest_dir"
    return 1
  fi
  read -r published_rev published_digest < <(
    python3 - "${manifest_dir}/build-manifest.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("koensayr_git_sha", ""), data.get("upstream_digest_sha256", ""))
PY
  )
  rm -rf "$manifest_dir"
  if [[ -z "$published_rev" || "$published_rev" != "$PATCH_REVISION" ]]; then
    return 1
  fi
  if [[ -n "$DIGEST" && "$published_digest" != "$DIGEST" ]]; then
    return 1
  fi
  return 0
}

if [[ "$FORCE" != true && "${KOENSAYR_SKIP_PUBLISH:-}" != "1" ]]; then
  if release_already_current "$RELEASE_TAG"; then
    echo "[build-one] Release ${RELEASE_TAG} already matches upstream digest and patch revision ${PATCH_REVISION:0:12}; skipping."
    exit 0
  fi
fi

echo "[build-one] Downloading upstream rom.zip.."
curl -fsSL -o "${STAGING}/rom.zip" "$DOWNLOAD_URL"

if [[ -n "$DIGEST" ]]; then
  actual_digest="$(sha256sum "${STAGING}/rom.zip" | awk '{print $1}')"
  if [[ "$actual_digest" != "$DIGEST" ]]; then
    echo "ERROR: downloaded rom.zip sha256 ${actual_digest} != expected ${DIGEST}" >&2
    exit 1
  fi
  echo "[build-one] Upstream rom.zip sha256 verified (${DIGEST:0:16}…)"
fi

rom_md5="$(md5sum "${STAGING}/rom.zip" | awk '{print $1}')"
expected_rom_md5="$(firmware_manifest_field "$FW_VERSION" rom_md5)"
if ! firmware_md5_matches_field "$expected_rom_md5" "$rom_md5"; then
  echo "ERROR: rom.zip md5 ${rom_md5} does not match KNOWN_FIRMWARES v${FW_VERSION} (expected one of: ${expected_rom_md5})" >&2
  echo "       Refusing to patch — update apply.bash manifest or fix the upstream download URL." >&2
  exit 1
fi
echo "[build-one] rom.zip md5 matches KNOWN_FIRMWARES v${FW_VERSION}"

echo "[build-one] Extracting upstream layout.."
"${CI_DIR}/extract-rom.sh" "${STAGING}/rom.zip" "$EXTRACT"

echo "[build-one] Patching (koensayr ${KOENSAYR_VERSION}).."
./apply.bash --all --no-flash --artifacts-dir "$STAGING"

# apply.bash names the loop-mounted image system-${VERSION_FIRMWARE}-devel.img
# (manifest version e.g. 3.0.2 / 3.0.7 when rom.zip matches KNOWN_FIRMWARES).
resolve_devel_img() {
  local staging="$1" fw_version="$2" slug="$3" source_tag="$4"
  local p
  for p in \
    "${staging}/system-${fw_version}-devel.img" \
    "${staging}/system-${slug}-devel.img" \
    "${staging}/system-${source_tag}-devel.img"; do
    if [[ -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  for p in "${staging}"/system-*-devel.img; do
    if [[ -f "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

DEVEL_IMG="$(resolve_devel_img "$STAGING" "$FW_VERSION" "$SLUG" "$SOURCE_TAG" || true)"
if [[ -z "$DEVEL_IMG" || ! -f "$DEVEL_IMG" ]]; then
  echo "ERROR: expected patched system image under ${STAGING}/" >&2
  echo "       (tried system-${FW_VERSION}-devel.img, system-${SLUG}-devel.img, system-${SOURCE_TAG}-devel.img)" >&2
  exit 1
fi
echo "[build-one] Using patched system image: ${DEVEL_IMG}"

OUTPUT_ROM="${WORKDIR}/rom-koensayr.zip"
"${CI_DIR}/repack-rom.sh" "$EXTRACT" "$DEVEL_IMG" "$OUTPUT_ROM"

# Fail closed if we accidentally repacked an unmodified upstream image.
upstream_sha="$(sha256sum "${STAGING}/rom.zip" | awk '{print $1}')"
output_sha="$(sha256sum "$OUTPUT_ROM" | awk '{print $1}')"
if [[ "$upstream_sha" == "$output_sha" ]]; then
  echo "ERROR: patched rom.zip is byte-identical to upstream — refusing to publish." >&2
  exit 1
fi
if [[ "$(wc -c < "${STAGING}/rom.zip")" -ge "$(wc -c < "$OUTPUT_ROM")" ]]; then
  echo "ERROR: patched rom.zip is not larger than upstream (expected system.img changes)." >&2
  exit 1
fi

# Copy staging rom for convenience
cp -f "$OUTPUT_ROM" "${STAGING}/rom-koensayr.zip"

MANIFEST="${WORKDIR}/build-manifest.json"
python3 - "$MANIFEST" <<PY
import json, hashlib, pathlib, sys
out = pathlib.Path(sys.argv[1])
rom = pathlib.Path("${OUTPUT_ROM}")
h = hashlib.sha256()
with rom.open("rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
data = {
    "koensayr_version": "${KOENSAYR_VERSION}",
    "koensayr_git_sha": "${PATCH_REVISION}",
    "source_repo": "${SOURCE_REPO}",
    "source_tag": "${SOURCE_TAG}",
    "release_tag": "${RELEASE_TAG}",
    "release_title": "${RELEASE_TITLE}",
    "firmware_version": "${FW_VERSION}",
    "slug": "${SLUG}",
    "upstream_digest_sha256": "${DIGEST}",
    "output_rom_sha256": h.hexdigest(),
    "output_rom_bytes": rom.stat().st_size,
}
out.write_text(json.dumps(data, indent=2) + "\n")
print(json.dumps(data, indent=2))
PY

if [[ "${KOENSAYR_SKIP_PUBLISH:-}" == "1" ]]; then
  echo "[build-one] KOENSAYR_SKIP_PUBLISH=1 — artifacts in ${WORKDIR}"
  cp -f "$OUTPUT_ROM" "${REPO_ROOT}/rom-koensayr-${SLUG}.zip" 2>/dev/null || true
  exit 0
fi

NOTES="${WORKDIR}/release-notes.md"
{
  echo "# ${RELEASE_TITLE}"
  echo ""
  if [[ -f "$RELEASE_INTRO_FILE" ]]; then
    grep -v '^Devs:' "$RELEASE_INTRO_FILE" || true
  else
    echo "Koensayr patched firmware for the Innioasis Y1."
  fi
  echo ""
  if commit_author_is_seanathanvt; then
    echo "Detailed notes:"
    echo ""
    git log -1 --format='%B'
    echo ""
  fi
  echo "---"
  echo ""
  cat <<EOF
## Build metadata

Patched **rom.zip** built from stock **${FW_VERSION}** by [koensayr-auto](https://github.com/${GITHUB_REPOSITORY:-ryan-specter/koensayr-auto}) v${KOENSAYR_VERSION}.

## Upstream
EOF
} > "$NOTES"
cat >> "$NOTES" <<EOF

- Repository: [\`${SOURCE_REPO}\`](https://github.com/${SOURCE_REPO})
- Release tag: \`${SOURCE_TAG}\`
- Asset: \`rom.zip\`
- Upstream SHA256: \`${DIGEST}\`

## Koensayr build

- Version: \`${KOENSAYR_VERSION}\`
- Git revision: \`${PATCH_REVISION}\` (includes \`com.innioasis.y1\` APK patches under \`src/patches/\`)

## Build output

- Patched \`rom.zip\` SHA256: \`${output_sha}\` (see \`build-manifest.json\` on this release)
- Upstream \`rom.zip\` was re-hashed at build time; output must differ (CI enforces this).

## Patches (\`--all\`)

- Music-player UX (Artist→Album navigation)
- Bluetooth pairing (\`audio.conf\` / \`auto_pairing.conf\` / \`blacklist.conf\` / \`build.prop\`)
- System config (ADB debugging, bloatware removal)
- Root (\`/system/xbin/su\`, mode 06755)
- AVRCP 1.3 metadata + control + Y1Bridge

Diagnostic scripts (\`tools/dual-capture.sh\`, gdb attach, \`btlog-dump\`) are **not** included in the ROM — see the repo [Diagnostics](https://github.com/${GITHUB_REPOSITORY:-ryan-specter/koensayr-auto}#diagnostics).

## After flash

If AVRCP / MultiDex classes fail to load after upgrading from a prior koensayr build:

\`\`\`bash
adb shell rm -rf /data/data/com.innioasis.y1/code_cache/secondary-dexes/
\`\`\`

EOF

# Flash tools expect the outer archive to be named rom.zip.
RELEASE_ASSET="${WORKDIR}/rom.zip"
cp -f "$OUTPUT_ROM" "$RELEASE_ASSET"

for LEGACY_RELEASE_TAG in \
  "y1-stock-rom@${FW_VERSION}" \
  "${FW_VERSION}-koensayr-${KOENSAYR_VERSION}"; do
  if [[ "$LEGACY_RELEASE_TAG" != "$RELEASE_TAG" ]] && gh release view "$LEGACY_RELEASE_TAG" >/dev/null 2>&1; then
    echo "[build-one] Removing legacy release tag ${LEGACY_RELEASE_TAG}.."
    gh release delete "$LEGACY_RELEASE_TAG" --yes
  fi
done

echo "[build-one] Publishing GitHub release ${RELEASE_TAG} (${RELEASE_TITLE}).."
echo "[build-one]   upstream sha256: ${upstream_sha}"
echo "[build-one]   output sha256:   ${output_sha}"
if gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
  echo "[build-one] Removing prior release ${RELEASE_TAG} (replace with fresh build).."
  gh release delete "$RELEASE_TAG" --yes
fi
gh release create "$RELEASE_TAG" "$RELEASE_ASSET" "$MANIFEST" \
  --title "${RELEASE_TITLE}" \
  --notes-file "$NOTES"

echo "[build-one] Published ${RELEASE_TAG} (rom.zip + build-manifest.json)"
