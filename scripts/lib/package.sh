#!/bin/bash
set -e

IMAGE_FOUND=0
for img in Image.gz-dtb Image.gz Image; do
  [ -f "$ZIMAGE_DIR/$img" ] && { IMAGE_FOUND=1; break; }
done
[ "$IMAGE_FOUND" == "0" ] && { warn "No kernel image found!"; return 1; }

: "${BUILD_START:?BUILD_START not set — check sourcing order}"
TEMP_DIR="${GITHUB_WORKSPACE}/anykernel_temp"
rm -rf "$TEMP_DIR"
cp -r "$ANYKERNEL_DIR" "$TEMP_DIR"

for img in Image.gz-dtb Image.gz Image; do
  [ -f "$ZIMAGE_DIR/$img" ] && { cp -v "$ZIMAGE_DIR/$img" "$TEMP_DIR/"; break; }
done


KVER=$(grep '^VERSION = ' "$KERNEL_DIR/Makefile" | awk '{print $3}')
KPL=$(grep '^PATCHLEVEL = ' "$KERNEL_DIR/Makefile" | awk '{print $3}')
KSL=$(grep '^SUBLEVEL = ' "$KERNEL_DIR/Makefile" | awk '{print $3}')
KERNEL_VER="${KVER}.${KPL}.${KSL}"
echo "KERNEL_VER=$KERNEL_VER" >> "$GITHUB_ENV"

case "$VARIANT" in
  stock)
    BUILD_LABEL="Vanilla"
    ;;
  susfs)
    case "$ROOT" in
      sukisu)   BUILD_LABEL="SUKISU-SUSFS" ;;
      bakasu) BUILD_LABEL="BAKASU-SUSFS" ;;
      ksu-next) BUILD_LABEL="KSUN-SUSFS" ;;
      *)        BUILD_LABEL="$(tr '[:lower:]' '[:upper:]' <<< "${ROOT}")-SUSFS" ;;
    esac
    ;;
  *)
    BUILD_LABEL="$(tr '[:lower:]' '[:upper:]' <<< "${VARIANT}")"
    ;;
esac
ZIP_NAME="DumpC2J-${BUILD_LABEL}.zip"
echo "VARIANT_LABEL=$BUILD_LABEL" >> "$GITHUB_ENV"
cd "$TEMP_DIR" && zip -r9 "${GITHUB_WORKSPACE}/$ZIP_NAME" . \
  -x '.git*' -x 'README.md' -x '*placeholder' > /dev/null
cd "$GITHUB_WORKSPACE"
rm -rf "$TEMP_DIR"

mkdir -p "$KERNEL_DIR/DumpC2J-Release"
cp "$ZIP_NAME" "$KERNEL_DIR/DumpC2J-Release/"


echo "ZIP_NAME=$ZIP_NAME" >> "$GITHUB_ENV"
echo "INPUT_VARIANT=$VARIANT" >> "$GITHUB_ENV"
echo "INPUT_ROOT=$ROOT" >> "$GITHUB_ENV"
echo "INPUT_BYPASS=$BYPASSCHARGING" >> "$GITHUB_ENV"
echo "INPUT_NOMOUNT=$NOMOUNT" >> "$GITHUB_ENV"
echo "INPUT_DROIDSPACES=$DROIDSPACES" >> "$GITHUB_ENV"
echo "INPUT_DEBUG=$DEBUG_MODE" >> "$GITHUB_ENV"

BUILD_END=$(date +"%s")
DIFF=$((BUILD_END - BUILD_START))
echo "BUILD_DURATION_SEC=$DIFF" >> "$GITHUB_ENV"
echo ""
echo "=========================================="
echo "Build done in $((DIFF / 60))m $((DIFF % 60))s"
echo "Output: $ZIP_NAME"
echo "=========================================="
