#!/bin/bash
set -e

mkdir -p "$OUT_DIR"

make -C "$KERNEL_DIR" O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 \
  KCFLAGS="$KERNEL_KCFLAGS" LDFLAGS="$KERNEL_LDFLAGS" konoha_defconfig

"$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
  -d CONFIG_VDSO32 -d CONFIG_COMPAT_VDSO

case "$VARIANT" in
  stock) "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -d CONFIG_KSU -d CONFIG_KSU_SUSFS -d CONFIG_KPM ;;
  root)  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -e CONFIG_KSU -d CONFIG_KSU_SUSFS ;;
  susfs) "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -e CONFIG_KSU -e CONFIG_KSU_SUSFS -e CONFIG_KSU_SUSFS_SUS_MAP ;;
esac

if [ "$ROOT" == "bakasu" ] && [ "$VARIANT" != "stock" ]; then
  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e CONFIG_KSU_MULTI_MANAGER_SUPPORT
fi

if [ "$ROOT" == "sukisu" ]; then
  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e CONFIG_KPM
else
  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d CONFIG_KPM
fi

case "$HZ_ID" in
  100)  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_500 -d CONFIG_HZ_1000 \
    -e CONFIG_HZ_100 --set-val CONFIG_HZ 100 -e CONFIG_RCU_LAZY ;;
  300)  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -d CONFIG_HZ_100 -d CONFIG_HZ_250 -d CONFIG_HZ_500 -d CONFIG_HZ_1000 \
    -e CONFIG_HZ_300 --set-val CONFIG_HZ 300 -d CONFIG_RCU_LAZY ;;
  500)  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_100 -d CONFIG_HZ_1000 \
    -e CONFIG_HZ_500 --set-val CONFIG_HZ 500 -d CONFIG_RCU_LAZY ;;
  1000) "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -d CONFIG_HZ_300 -d CONFIG_HZ_250 -d CONFIG_HZ_100 -d CONFIG_HZ_500 \
    -e CONFIG_HZ_1000 --set-val CONFIG_HZ 1000 -d CONFIG_RCU_LAZY ;;
  *)    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -d CONFIG_HZ_300 -d CONFIG_HZ_1000 -d CONFIG_HZ_100 -d CONFIG_HZ_500 \
    -e CONFIG_HZ_250 --set-val CONFIG_HZ 250 -d CONFIG_RCU_LAZY ;;
esac


if [ "$NOMOUNT" == "on" ]; then
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -e CONFIG_NOMOUNT
else
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" -d CONFIG_NOMOUNT
fi

case "$LTO_VAL" in
  full) "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -d CONFIG_LTO_NONE -d CONFIG_LTO_CLANG_THIN -e CONFIG_LTO_CLANG -e CONFIG_LTO_CLANG_FULL ;;
  none) "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -d CONFIG_LTO_CLANG -d CONFIG_LTO_CLANG_FULL -d CONFIG_LTO_CLANG_THIN -e CONFIG_LTO_NONE ;;
  *)    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -d CONFIG_LTO_NONE -d CONFIG_LTO_CLANG_FULL -e CONFIG_LTO_CLANG -e CONFIG_LTO_CLANG_THIN ;;
esac

"$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
  -e CONFIG_DEBUG_INFO_REDUCED \
  -d CONFIG_DEBUG_MISC -d CONFIG_BT_DEBUGFS \
  -d CONFIG_DEBUG_MEMORY_INIT -d CONFIG_PROFILING \
  -d CONFIG_PRINTK_CALLER -d CONFIG_RCU_TRACE \
  -d CONFIG_CMA_DEBUGFS \
  -d CONFIG_UBSAN -d CONFIG_UBSAN_BOUNDS \
  -d CONFIG_UBSAN_ARRAY_BOUNDS -d CONFIG_UBSAN_LOCAL_BOUNDS \
  -d CONFIG_UBSAN_SANITIZE_ALL -d CONFIG_UBSAN_TRAP \
  -d CONFIG_CLEANCACHE -d CONFIG_PRINTK_TIME

if [ -n "$VERSION_SPOOF" ]; then
  echo "[*] Spoofing kernel version: $VERSION_SPOOF"
  IFS='.' read -r V PL SL <<< "$VERSION_SPOOF"
  if [ -z "$V" ] || [ -z "$PL" ] || [ -z "$SL" ] || ! [[ "$V" =~ ^[0-9]+$ ]] || ! [[ "$PL" =~ ^[0-9]+$ ]] || ! [[ "$SL" =~ ^[0-9]+$ ]]; then
    echo "[!] Invalid VERSION_SPOOF format: '$VERSION_SPOOF' (expected x.x.x), skipping spoof."
  else
    sed -i "s/^VERSION = .*/VERSION = $V/" "$KERNEL_DIR/Makefile"
    sed -i "s/^PATCHLEVEL = .*/PATCHLEVEL = $PL/" "$KERNEL_DIR/Makefile"
    sed -i "s/^SUBLEVEL = .*/SUBLEVEL = $SL/" "$KERNEL_DIR/Makefile"
  fi
fi

CURRENT_CMDLINE=$(grep '^CONFIG_CMDLINE=' "$OUT_DIR/.config" | sed 's/^CONFIG_CMDLINE="//' | sed 's/"$//')
CMDLINE_APPEND=""
echo "$CURRENT_CMDLINE" | grep -q "kasan=off" || CMDLINE_APPEND="$CMDLINE_APPEND kasan=off"
echo "$CURRENT_CMDLINE" | grep -q "panic_on_rcu_stall" || CMDLINE_APPEND="$CMDLINE_APPEND kernel.panic_on_rcu_stall=0"
echo "$CURRENT_CMDLINE" | grep -q "init_on_alloc=" || CMDLINE_APPEND="$CMDLINE_APPEND init_on_alloc=0"
echo "$CURRENT_CMDLINE" | grep -q "page_alloc.shuffle=" || CMDLINE_APPEND="$CMDLINE_APPEND page_alloc.shuffle=0"
echo "$CURRENT_CMDLINE" | grep -q "randomize_kstack_offset=" || CMDLINE_APPEND="$CMDLINE_APPEND randomize_kstack_offset=0"
echo "$CURRENT_CMDLINE" | grep -q "loglevel=" || CMDLINE_APPEND="$CMDLINE_APPEND loglevel=0"
echo "$CURRENT_CMDLINE" | grep -q "mem_sleep_default=" || CMDLINE_APPEND="$CMDLINE_APPEND mem_sleep_default=s2idle"
if [ "$DEBUG_MODE" == "on" ]; then
  echo "$CURRENT_CMDLINE" | grep -q "nokaslr" || CMDLINE_APPEND="$CMDLINE_APPEND nokaslr"
fi
CMDLINE_APPEND="${CMDLINE_APPEND# }"
[ -n "$CMDLINE_APPEND" ] && \
  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
  --set-str CONFIG_CMDLINE "${CURRENT_CMDLINE:+$CURRENT_CMDLINE }$CMDLINE_APPEND"

[ "$DROIDSPACES" == "on" ] && \
  bash "$KERNEL_DIR/setup_droidspaces.sh" "$OUT_DIR"

make -C "$KERNEL_DIR" O="$OUT_DIR" CC=clang LLVM=1 LLVM_IAS=1 olddefconfig

if [ "$DROIDSPACES" == "on" ]; then
  "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
    -e CONFIG_SYSVIPC -e CONFIG_POSIX_MQUEUE -e CONFIG_IPC_NS -e CONFIG_PID_NS \
    -e CONFIG_DEVTMPFS -e CONFIG_NETFILTER_XT_MATCH_ADDRTYPE \
    -e CONFIG_NETFILTER_XT_TARGET_REJECT -e CONFIG_NETFILTER_XT_TARGET_LOG \
    -e CONFIG_NETFILTER_XT_MATCH_RECENT -e CONFIG_IP_SET \
    -e CONFIG_IP_SET_HASH_IP -e CONFIG_IP_SET_HASH_NET -e CONFIG_NETFILTER_XT_SET \
    -e CONFIG_TMPFS_POSIX_ACL -e CONFIG_TMPFS_XATTR
  echo "[+] Droidspaces configs re-forced after olddefconfig"
fi
