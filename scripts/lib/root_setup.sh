#!/bin/bash
set -e

case "$ROOT" in
  sukisu)   ROOT_REPO="https://github.com/sukisu-ultra/sukisu-ultra.git"; REPO_NAME="sukisu-ultra"
            if [ "$VARIANT" == "susfs" ]; then BRANCH="builtin"; PIN_KEY="sukisu_susfs"; PIN_PREFIX="SUKISU_SUSFS"
            else BRANCH="main"; PIN_KEY="sukisu_root"; PIN_PREFIX="SUKISU_ROOT"; fi ;;
  bakasu) ROOT_REPO="https://github.com/Baka-SU/BakaSU.git"; REPO_NAME="BakaSU"; BRANCH="main"
            if [ "$VARIANT" == "susfs" ]; then PIN_KEY="bakasu_susfs"; PIN_PREFIX="BAKASU_SUSFS"
            else PIN_KEY="bakasu_root"; PIN_PREFIX="BAKASU_ROOT"; fi ;;
  ksu-next)
    if [ "$VARIANT" == "susfs" ]; then
      ROOT_REPO="https://github.com/pershoot/KernelSU-Next.git"; REPO_NAME="KernelSU-Next"; BRANCH="dev-susfs"
      PIN_KEY="ksunext_susfs"; PIN_PREFIX="KSUNEXT_SUSFS"
    else
      ROOT_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"; REPO_NAME="KernelSU-Next"; BRANCH="dev"
      PIN_KEY="ksunext_root"; PIN_PREFIX="KSUNEXT_ROOT"
    fi ;;
  *)        REPO_NAME="none" ;;
esac

echo "PIN_KEY=${PIN_KEY:-}" >> "$GITHUB_ENV"
echo "PIN_PREFIX=${PIN_PREFIX:-}" >> "$GITHUB_ENV"

echo "REPO_NAME=$REPO_NAME" >> "$GITHUB_ENV"

THREAD_INFO_H="$KERNEL_DIR/arch/arm64/include/asm/thread_info.h"
if [ -f "$THREAD_INFO_H" ] && ! grep -q "TIF_PROC_IN_KSU_EXECVE" "$THREAD_INFO_H"; then
  echo "[+] Patching thread_info.h: adding TIF_PROC_IN_KSU_EXECVE define"
  sed -i '/^#define TIF_SYSCALL_TRACE/a#define TIF_PROC_IN_KSU_EXECVE 29' "$THREAD_INFO_H"
fi

rm -rf "$KERNEL_DIR/drivers/kernelsu"

if [ "$VARIANT" == "stock" ]; then
  mkdir -p "$KERNEL_DIR/drivers/kernelsu"
  touch "$KERNEL_DIR/drivers/kernelsu/Kconfig"
  touch "$KERNEL_DIR/drivers/kernelsu/Makefile"
else
  mkdir -p "$MODULES_DIR"

  REF_VAR="${PIN_PREFIX}_REF"
  RESOLVED_SHA="${!REF_VAR}"
  [ -z "$RESOLVED_SHA" ] && { warn "${REF_VAR} is empty — scout.sh not run or failed to resolve."; return 1; }

  if [ ! -d "$MODULES_DIR/$REPO_NAME" ]; then
    echo "[+] Cloning $REPO_NAME (full history, for fallback)..."
    timeout 90 git clone -b "$BRANCH" "$ROOT_REPO" "$MODULES_DIR/$REPO_NAME" || { echo "[-] Root method clone failed/timed out"; return 1; }
  else
    echo "[+] Fetching $REPO_NAME..."
    (cd "$MODULES_DIR/$REPO_NAME" && timeout 60 git fetch origin "$BRANCH") || { echo "[-] Root method fetch failed/timed out"; return 1; }
  fi

  echo "[+] Checkout ${PIN_KEY} @ ${RESOLVED_SHA:0:8} (from scout.sh)"
  (cd "$MODULES_DIR/$REPO_NAME" && git checkout -B "$BRANCH" --quiet "$RESOLVED_SHA")

  echo "MANAGER_ROOT_NAME=${ROOT}" >> "$GITHUB_ENV"
  echo "MANAGER_REPO_DIR=${MODULES_DIR}/${REPO_NAME}" >> "$GITHUB_ENV"
  cd "$GITHUB_WORKSPACE"

  if [ "$VARIANT" == "susfs" ]; then
    SUSFS_REPO_URL="https://gitlab.com/simonpunk/susfs4ksu.git"
    SUSFS_REF_VAR="SUSFS4KSU_REF"

    SUSFS_DIR="$MODULES_DIR/susfs4ksu"
    SUSFS_BRANCH="gki-android15-6.6"
    SUSFS_TARGET_SHA="${!SUSFS_REF_VAR:-}"
    [ -z "$SUSFS_TARGET_SHA" ] && { warn "${SUSFS_REF_VAR} is empty — scout.sh not run or failed to resolve."; return 1; }

    if [ ! -d "$SUSFS_DIR" ]; then
      local clone_ok=0
      for attempt in 1 2 3; do
        timeout 120 git clone "$SUSFS_REPO_URL" -b "$SUSFS_BRANCH" "$SUSFS_DIR" && { clone_ok=1; break; }
        echo "[!] SUSFS clone failed (attempt ${attempt}/3), retrying in 30s..."
        rm -rf "$SUSFS_DIR" 2>/dev/null
        sleep 30
      done
      [ "$clone_ok" -eq 0 ] && { echo "[-] SUSFS clone failed after 3 attempts"; return 1; }
    else
      local fetch_ok=0
      for attempt in 1 2 3; do
        (cd "$SUSFS_DIR" && git remote set-url origin "$SUSFS_REPO_URL" && timeout 90 git fetch origin "$SUSFS_BRANCH") && { fetch_ok=1; break; }
        echo "[!] SUSFS fetch failed (attempt ${attempt}/3), retrying in 30s..."
        sleep 30
      done
      [ "$fetch_ok" -eq 0 ] && { echo "[-] SUSFS fetch failed after 3 attempts"; return 1; }
    fi

    echo "[+] Checkout susfs4ksu @ ${SUSFS_TARGET_SHA:0:8} (from scout.sh)"
    (cd "$SUSFS_DIR" && git checkout --quiet "$SUSFS_TARGET_SHA")
    echo "SUSFS_USED_SHA=${SUSFS_TARGET_SHA}" >> "$GITHUB_ENV"

    echo "[+] Injecting SUSFS kernel sources..."
    cp "$SUSFS_DIR/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/susfs.c"
    cp "$SUSFS_DIR/kernel_patches/include/linux/susfs.h" "$KERNEL_DIR/include/linux/susfs.h"
    [ -f "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" ] && \
      cp "$SUSFS_DIR/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"

    SUSFS_DEF_H="$KERNEL_DIR/include/linux/susfs_def.h"
    if [ -f "$SUSFS_DEF_H" ] && ! grep -q "linux/sched.h" "$SUSFS_DEF_H" 2>/dev/null; then
      sed -i '/#include <linux\/bits.h>/a\
#include <linux\/sched.h>\
#include <linux\/thread_info.h>\
#include <linux\/cred.h>\
#include <asm\/current.h>' "$SUSFS_DEF_H"
    fi

    if grep -q "KSU_SUSFS" "$MODULES_DIR/$REPO_NAME/kernel/Kconfig" 2>/dev/null || [ "$ROOT" == "sukisu" ] || [ "$ROOT" == "bakasu" ]; then
      echo "[+] $REPO_NAME already has native SUSFS integration. Skipping patch..."
    else
      echo "[+] Patching $REPO_NAME for SUSFS..."
      if ! (cd "$MODULES_DIR/$REPO_NAME" && \
        patch -p1 --forward -f --reject-file=- \
        < "$SUSFS_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"); then
        warn "SUSFS patch failed to apply to $REPO_NAME (hunk mismatch or missing target) — aborting build instead of continuing without the patch."
        return 1
      fi
    fi
  fi

  if [ ! -d "$MODULES_DIR/$REPO_NAME/kernel/uapi" ] && [ -d "$MODULES_DIR/$REPO_NAME/uapi" ]; then
    ln -sfn ../uapi "$MODULES_DIR/$REPO_NAME/kernel/uapi"
  fi

  echo "[+] Symlinking $REPO_NAME to drivers/kernelsu..."
  ln -sf "$MODULES_DIR/$REPO_NAME/kernel" "$KERNEL_DIR/drivers/kernelsu"
fi

if [ "$VARIANT" == "susfs" ]; then
  echo "[+] Installing fixed ksu_susfs_fixup.sh..."
  cp "$BUILDER_DIR/scripts/ksu_susfs_fixup.sh" "$KERNEL_DIR/ksu_susfs_fixup.sh"
  chmod +x "$KERNEL_DIR/ksu_susfs_fixup.sh"
  echo "[+] Running SUSFS fixup..."
  bash "$KERNEL_DIR/ksu_susfs_fixup.sh" "$KERNEL_DIR/drivers/kernelsu" "$ROOT"
fi
