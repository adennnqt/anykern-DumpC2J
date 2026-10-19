#!/bin/bash
set -e

IMAGE_FOUND=0
for img in Image.gz-dtb Image.gz Image; do
  [ -f "$ZIMAGE_DIR/$img" ] && { IMAGE_FOUND=1; break; }
done
[ "$IMAGE_FOUND" == "0" ] && { warn "No kernel image found!"; return 1; }

# --- KPM: patch the raw Image with KernelPatch (SukiSU stubs get hooked at boot) ---
if [ "$ROOT" == "sukisu" ] && [ "$VARIANT" != "stock" ]; then
  if [ -z "$KPM_SUPERKEY" ]; then
    KPM_SUPERKEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    echo "[!] KPM_SUPERKEY secret not set, using a random one (not shown in log)"
  fi
  echo "::add-mask::$KPM_SUPERKEY"
  KPM_DIR="${GITHUB_WORKSPACE}/kpm_tools"; mkdir -p "$KPM_DIR"
  KPM_BASE="https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/latest/download"
  curl -fLSs -o "$KPM_DIR/kptools-linux" "$KPM_BASE/kptools-linux" || { warn "kptools download failed"; return 1; }
  curl -fLSs -o "$KPM_DIR/kpimg" "$KPM_BASE/kpimg" || { warn "kpimg download failed"; return 1; }
  chmod +x "$KPM_DIR/kptools-linux"

  KPM_RAW="$ZIMAGE_DIR/Image"
  [ -f "$KPM_RAW" ] || gzip -dk "$ZIMAGE_DIR/Image.gz" || { warn "No Image for KPM patch"; return 1; }
  cp "$KPM_RAW" "$KPM_RAW.orig"
  "$KPM_DIR/kptools-linux" -p -i "$KPM_RAW.orig" -S "$KPM_SUPERKEY" -k "$KPM_DIR/kpimg" -o "$KPM_RAW" \
    || { warn "KPM patching failed"; return 1; }
  rm -f "$KPM_RAW.orig"
  # package loop prefers Image.gz-dtb / Image.gz, so refresh them from the patched Image
  [ -f "$ZIMAGE_DIR/Image.gz" ] && gzip -nkf "$KPM_RAW"
  rm -f "$ZIMAGE_DIR/Image.gz-dtb"
  echo "[+] KPM patch applied"
fi

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
