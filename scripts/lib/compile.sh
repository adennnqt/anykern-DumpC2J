#!/bin/bash
set -e

CPUS=$(nproc --all)
echo "[+] Building with ${CPUS} threads..."

BUILD_LOG="$(mktemp)"

run_make() {
  make -C "$KERNEL_DIR" \
    "-j${CPUS}" O="$OUT_DIR" \
    CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm \
    OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
    LLVM=1 LLVM_IAS=1 KALLSYMS_EXTRA_PASS=1 \
    KCFLAGS="$KERNEL_KCFLAGS" LDFLAGS="$1" 2>&1 | tee "$BUILD_LOG"
  return "${PIPESTATUS[0]}"
}

if ! run_make "$KERNEL_LDFLAGS"; then
  if grep -q "Inconsistent kallsyms data" "$BUILD_LOG" && [[ "$KERNEL_LDFLAGS" == *"--icf=all"* ]]; then
    echo "[!] Inconsistent kallsyms data with --icf=all, retrying once with --icf=safe"
    if ! run_make "${KERNEL_LDFLAGS//--icf=all/--icf=safe}"; then
      rm -f "$BUILD_LOG"
      warn "Build failed!"
      return 1
    fi
  else
    rm -f "$BUILD_LOG"
    warn "Build failed!"
    return 1
  fi
fi

rm -f "$BUILD_LOG"
