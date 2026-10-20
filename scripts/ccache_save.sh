#!/bin/bash
set -e

if [ -z "${CCACHE_ASSET:-}" ] || [ ! -d "${GITHUB_WORKSPACE}/.ccache" ]; then
  echo "[!] ccache was never set up this run (an earlier step likely failed first) — nothing to save, skipping."
  exit 0
fi

# Never publish an (almost) empty cache: a failed build that never compiled
# anything would --clobber the good cache stored in the release.
CCACHE_FILES=$(find "${GITHUB_WORKSPACE}/.ccache" -type f 2>/dev/null | wc -l)
if [ "$CCACHE_FILES" -lt 100 ]; then
  echo "[!] ccache has only ${CCACHE_FILES} files — build likely failed before compiling. Skipping save so the stored cache is not overwritten."
  exit 0
fi

echo "[+] ccache stats after build:"
ccache -s -v

CCACHE_OUT_DIR="${GITHUB_WORKSPACE}/ccache-out"
mkdir -p "$CCACHE_OUT_DIR"
TAR_PATH="${CCACHE_OUT_DIR}/${CCACHE_ASSET}"
tar --use-compress-program=zstdmt -cf "$TAR_PATH" -C "${GITHUB_WORKSPACE}" .ccache

SIZE_MB=$(du -m "$TAR_PATH" | cut -f1)
echo "[+] Local ccache tar size: ${SIZE_MB} MB"

echo "CCACHE_TAR_PATH=${TAR_PATH}" >> "$GITHUB_ENV"
echo "CCACHE_OUT_DIR=${CCACHE_OUT_DIR}" >> "$GITHUB_ENV"
echo "[+] ccache tar ready at ${TAR_PATH} — publish directly (single build) or via the merge_ccache job (matrix build)."
