#!/bin/bash
# ==========================================================================
# SUSFS v2.1 Compatibility Fixup — Dynamic Multi-Manager Support
# ==========================================================================
# Surgically repairs SUSFS integration after 10_enable_susfs_for_ksu.patch
# which may partially fail on different KernelSU forks.
#
# Supported managers: KernelSU-Next, Sukisu-Ultra
# (BakaSU has native SUSFS — should be skipped upstream in build.sh)
#
# Usage: ksu_susfs_fixup.sh <path-to-ksu/kernel> [manager-name]
#   manager-name: ksu-next | sukisu (auto-detected if omitted)
# ==========================================================================
set -e

KSU_KERNEL="$1"
MANAGER_HINT="$2"

if [ -z "$KSU_KERNEL" ] || [ ! -d "$KSU_KERNEL" ]; then
    echo "Usage: $0 <path-to-ksu/kernel> [ksu-next|sukisu]"
    exit 1
fi

# ==========================================================================
# Manager Detection
# ==========================================================================
detect_manager() {
    local kdir="$1"
    local hint="$2"
    local parent
    parent=$(dirname "$kdir")

    if [ -n "$hint" ]; then
        case "$hint" in
            ksu)       echo "ksu" ;;
            ksu-next)  echo "ksu-next" ;;
            kowsu)     echo "kowsu" ;;
            sukisu)    echo "sukisu" ;;
            yukisu)    echo "yukisu" ;;
            bakasu)  echo "bakasu" ;;
            apatch)    echo "apatch" ;;
            folkpatch) echo "folkpatch" ;;
            *)         echo "unknown" ;;
        esac
        return
    fi

    if [ -f "$parent/.git/config" ]; then
        local url
        url=$(git -C "$parent" remote get-url origin 2>/dev/null || true)
        case "$url" in
            *KernelSU-Next*|*kernelsu-next*) echo "ksu-next"; return ;;
            *BakaSU*|*bakasu*|*Baka-SU*|*ReSukiSU*|*resukisu*) echo "bakasu"; return ;;
            *sukisu*|*SukiSU*|*Sukisu*)      echo "sukisu"; return ;;
            *YukiSU*|*yukisu*)               echo "yukisu"; return ;;
        esac
    fi

    if [ -f "$kdir/feature/adb_root.c" ]; then
        echo "sukisu"; return
    fi

    if [ -f "$kdir/hook/syscall_event_bridge.c" ] && \
       grep -q "KernelSU-Next" "$kdir/Kbuild" 2>/dev/null; then
        echo "ksu-next"; return
    fi

    echo "unknown"
}

MANAGER=$(detect_manager "$KSU_KERNEL" "$MANAGER_HINT")
echo "[SUSFS-Fixup] Manager: $MANAGER"

set -x
if [ "$MANAGER" = "sukisu" ]; then
    # Upstream selinux_hide.c on the current "builtin" branch itself is broken
    # (lsm_hook symbol resolution refactor not finished upstream — confirmed
    # via community issue + independently confirmed by another builder's own
    # canary system blacklisting this same commit). Excluding it from the
    # Kbuild object list entirely, rather than patching its contents, since
    # the file is broken even unmodified. Feature loss: selinux-policy
    # hiding (Duck Detector) disabled for sukisu; core SUSFS unaffected.
    for kbuild_candidate in "$KSU_KERNEL/Kbuild" "$KSU_KERNEL/Makefile"; do
        if [ -f "$kbuild_candidate" ] && grep -q "selinux_hide" "$kbuild_candidate" 2>/dev/null; then
            sed -i '/selinux_hide/s/^/#/' "$kbuild_candidate"
            echo "[SUSFS-Fixup] $(basename "$kbuild_candidate"): Excluded selinux_hide.o from build for sukisu (upstream builtin branch is broken)"
        fi
    done

    # [FIX] kernel_umount.c — upstream "builtin" tip (4.2.0) registers
    # .set_handler = kernel_umount_feature_set but never defines it (getter
    # only), so the driver fails to compile. Inject the missing setter.
    KSU_UMOUNT_C="$KSU_KERNEL/feature/kernel_umount.c"
    if [ -f "$KSU_UMOUNT_C" ] && ! grep -q "static int kernel_umount_feature_set" "$KSU_UMOUNT_C" 2>/dev/null; then
        sed -i '/static const struct ksu_feature_handler kernel_umount_handler = {/i\
static int kernel_umount_feature_set(u64 value)\
{\
    ksu_kernel_umount_enabled = value ? true : false;\
    return 0;\
}\
' "$KSU_UMOUNT_C"
        if ! grep -q "static int kernel_umount_feature_set" "$KSU_UMOUNT_C" 2>/dev/null; then
            echo "[SUSFS-Fixup] ERROR: failed to inject kernel_umount_feature_set (anchor moved upstream)" >&2
            exit 1
        fi
        echo "[SUSFS-Fixup] kernel_umount.c: injected missing kernel_umount_feature_set"
    fi

    # [FIX] supercall.h — declare EVENT_SERVICES (missing upstream)
    # dispatch.c (commit 70fa0e09, builtin HEAD) switches on EVENT_SERVICES
    # in do_report_event(), but supercall.h only DECLAREs up to
    # EVENT_MODULE_MOUNTED. Without the enum entry the switch case is an
    # undeclared identifier. Value 4 (next after EVENT_MODULE_MOUNTED=3).
    SUPERCALL_H_UAPI="$KSU_KERNEL/include/uapi/supercall.h"
    if [ -f "$SUPERCALL_H_UAPI" ] && ! grep -q "EVENT_SERVICES" "$SUPERCALL_H_UAPI" 2>/dev/null; then
        sed -i '/DECLARE(__u32, EVENT_MODULE_MOUNTED, 3);/a\DECLARE(__u32, EVENT_SERVICES, 4);' "$SUPERCALL_H_UAPI"
        echo "[SUSFS-Fixup] supercall.h: Added missing EVENT_SERVICES declare"
    fi

    # [FIX] selinux/rules.c — duplicate 'pol'/'old_pol' declaration
    # 70fa0e09: line 154 declares 'struct selinux_policy *pol, *old_pol;'
    # then the >=5.10 block (line 162) re-declares them with an initializer →
    # "redefinition of 'pol'". Comment only the outer plain declaration and
    # keep the assigning one (it is the ONLY declaration in known-good
    # b20dee70, so it must never be deleted — see note at end of this script).
    # Guard: only touch line 154 if it is exactly that declaration.
    RULES_C="$KSU_KERNEL/selinux/rules.c"
    if [ -f "$RULES_C" ] && grep -q "struct selinux_policy \*pol, \*old_pol;" "$RULES_C" 2>/dev/null \
        && grep -q "struct selinux_policy \*pol, \*old_pol = selinux_state.policy;" "$RULES_C" 2>/dev/null; then
        if [ "$(sed -n '154p' "$RULES_C" | tr -d '[:space:]')" = "structselinux_policy*pol,*old_pol;" ]; then
            sed -i '154s/struct selinux_policy \*pol, \*old_pol;/\/\/ struct selinux_policy *pol, *old_pol;/' "$RULES_C"
            echo "[SUSFS-Fixup] rules.c: Commented duplicate pol/old_pol declaration"
        else
            echo "[SUSFS-Fixup] rules.c: plain pol/old_pol decl not at expected line 154 — left untouched"
        fi
    fi

    # [FIX] include/arch.h — missing upstream, copied from KernelSU
    # kernel/kernel_includes.h includes "arch.h" but builtin branch
    # doesn't ship it. Copy from KernelSU (arm64/x86_64/riscv + pt_regs macros).
    ARCH_H="$KSU_KERNEL/include/arch.h"
    if [ ! -f "$ARCH_H" ]; then
        cat > "$ARCH_H" << 'ARCH_H_EOF'
#ifndef __KSU_H_ARCH
#define __KSU_H_ARCH

#include <linux/version.h>

#if defined(__aarch64__)

#define __PT_PARM1_REG regs[0]
#define __PT_PARM2_REG regs[1]
#define __PT_PARM3_REG regs[2]
#define __PT_SYSCALL_PARM4_REG regs[3]
#define __PT_CCALL_PARM4_REG regs[3]
#define __PT_PARM5_REG regs[4]
#define __PT_PARM6_REG regs[5]
#define __PT_RET_REG regs[30]
#define __PT_FP_REG regs[29] /* Works only with CONFIG_FRAME_POINTER */
#define __PT_RC_REG regs[0]
#define __PT_SP_REG sp
#define __PT_IP_REG pc
#define __PT_ORIG_SYSCALL_REG regs[8]

#define REBOOT_SYMBOL "__arm64_sys_reboot"
#define SYS_READ_SYMBOL "__arm64_sys_read"
#define SYS_EXECVE_SYMBOL "__arm64_sys_execve"
#define SYS_FSTAT_SYMBOL "__arm64_sys_newfstat"

#elif defined(__x86_64__)

#define __PT_PARM1_REG di
#define __PT_PARM2_REG si
#define __PT_PARM3_REG dx
/* syscall uses r10 for PARM4 */
#define __PT_SYSCALL_PARM4_REG r10
#define __PT_CCALL_PARM4_REG cx
#define __PT_PARM5_REG r8
#define __PT_PARM6_REG r9
#define __PT_RET_REG sp
#define __PT_FP_REG bp
#define __PT_RC_REG ax
#define __PT_SP_REG sp
#define __PT_IP_REG ip
#define __PT_ORIG_SYSCALL_REG orig_ax
#define REBOOT_SYMBOL "__x64_sys_reboot"
#define SYS_READ_SYMBOL "__x64_sys_read"
#define SYS_EXECVE_SYMBOL "__x64_sys_execve"
#define SYS_FSTAT_SYMBOL "__x64_sys_newfstat"

#elif defined(__riscv)

#define __PT_PARM1_REG a0
#define __PT_SYSCALL_PARM1_REG orig_a0
#define __PT_PARM2_REG a1
#define __PT_PARM3_REG a2
#define __PT_SYSCALL_PARM4_REG a3
#define __PT_CCALL_PARM4_REG a3
#define __PT_PARM5_REG a4
#define __PT_PARM6_REG a5
#define __PT_RET_REG ra
#define __PT_FP_REG s0
#define __PT_RC_REG a0
#define __PT_SP_REG sp
#define __PT_IP_REG epc
#define __PT_ORIG_SYSCALL_REG a7

#define REBOOT_SYMBOL "__riscv_sys_reboot"
#define SYS_READ_SYMBOL "__riscv_sys_read"
#define SYS_EXECVE_SYMBOL "__riscv_sys_execve"
#define SYS_FSTAT_SYMBOL "__riscv_sys_newfstat"

#else
#error "Unsupported arch"
#endif

/* allow some architectures to override \`struct pt_regs\` */
#ifndef __PT_REGS_CAST
#define __PT_REGS_CAST(x) (x)
#endif

#define PT_REGS_PARM1(x) (__PT_REGS_CAST(x)->__PT_PARM1_REG)
/* RISC-V saves syscall argument zero before using a0 as the return slot.
 * Kprobe C-call arguments (including PT_REAL_REGS) still use the live a0.
 */
#ifndef __PT_SYSCALL_PARM1_REG
#define __PT_SYSCALL_PARM1_REG __PT_PARM1_REG
#endif
#define PT_REGS_SYSCALL_PARM1(x) (__PT_REGS_CAST(x)->__PT_SYSCALL_PARM1_REG)
#define PT_REGS_PARM2(x) (__PT_REGS_CAST(x)->__PT_PARM2_REG)
#define PT_REGS_PARM3(x) (__PT_REGS_CAST(x)->__PT_PARM3_REG)
#define PT_REGS_SYSCALL_PARM4(x) (__PT_REGS_CAST(x)->__PT_SYSCALL_PARM4_REG)
#define PT_REGS_CCALL_PARM4(x) (__PT_REGS_CAST(x)->__PT_CCALL_PARM4_REG)
#define PT_REGS_PARM5(x) (__PT_REGS_CAST(x)->__PT_PARM5_REG)
#define PT_REGS_PARM6(x) (__PT_REGS_CAST(x)->__PT_PARM6_REG)
#define PT_REGS_RET(x) (__PT_REGS_CAST(x)->__PT_RET_REG)
#define PT_REGS_FP(x) (__PT_REGS_CAST(x)->__PT_FP_REG)
#define PT_REGS_RC(x) (__PT_REGS_CAST(x)->__PT_RC_REG)
#define PT_REGS_SP(x) (__PT_REGS_CAST(x)->__PT_SP_REG)
#define PT_REGS_IP(x) (__PT_REGS_CAST(x)->__PT_IP_REG)
#define PT_REGS_ORIG_SYSCALL(x) (__PT_REGS_CAST(x)->__PT_ORIG_SYSCALL_REG)

#define PT_REAL_REGS(regs) ((struct pt_regs *)PT_REGS_PARM1(regs))

#endif
ARCH_H_EOF
        echo "[SUSFS-Fixup] arch.h: Added missing arch.h from KernelSU"
    fi
fi

if [ "$MANAGER" = "bakasu" ]; then
    echo "[SUSFS-Fixup] BakaSU has native SUSFS — applying typo fix."
    if [ -f "$KSU_KERNEL/runtime/ksud_integration.c" ]; then
        sed -i 's/ksu_init_rc_hook_key_false/ksu_is_init_rc_hook_enabled/g' "$KSU_KERNEL/runtime/ksud_integration.c"
    fi
    # [GLOBAL] fs/susfs.c — make loop call non-static for compatibility
    if [ -f "$(dirname "$0")/fs/susfs.c" ]; then
        sed -i 's/static void susfs_run_sus_path_loop(void)/void susfs_run_sus_path_loop(void)/g' "$(dirname "$0")/fs/susfs.c"
        echo "[SUSFS-Fixup] fs/susfs.c: Made susfs_run_sus_path_loop non-static"
    fi
    # [FIX] selinux_hide.c — remove undefined context_struct_compute_av_fn extern
    # The kernel's context_struct_compute_av in security/selinux/ss/services.c is
    # static and not exported. selinux_hide.c has its own local copy, so remove
    # the extern reference and always use the local implementation.
    SELINUX_HIDE_C="$KSU_KERNEL/feature/selinux_hide.c"
    if [ -f "$SELINUX_HIDE_C" ] && grep -q "context_struct_compute_av_fn" "$SELINUX_HIDE_C" 2>/dev/null; then
        # Remove the extern declaration
        sed -i '/^extern void context_struct_compute_av_fn/,/struct extended_perms \*xperms);/d' "$SELINUX_HIDE_C"
        # Replace conditional call with direct call to local function
        sed -i '/if (context_struct_compute_av_fn) {/{
            N;N;N;N
            s/if (context_struct_compute_av_fn) {\n.*context_struct_compute_av_fn.*\n.*} else {\n.*context_struct_compute_av(.*\n.*}/context_struct_compute_av(policydb, scontext, tcontext, tclass, avd, NULL);/
        }' "$SELINUX_HIDE_C"
        echo "[SUSFS-Fixup] selinux_hide.c: Removed undefined context_struct_compute_av_fn"
    fi
    # [FIX] sucompat.c + kernel_umount.c — ksu_ vs susfs_ prefix mismatch
    # BakaSU uses ksu_is_current_proc_umounted / ksu_set_current_proc_umounted
    # but SUSFS v2.1 defines them as susfs_is_current_proc_umounted / susfs_set_current_proc_umounted
    for _f in "$KSU_KERNEL/feature/sucompat.c" "$KSU_KERNEL/feature/kernel_umount.c"; do
        if [ -f "$_f" ]; then
            if grep -q 'ksu_is_current_proc_umounted\|ksu_set_current_proc_umounted' "$_f" 2>/dev/null; then
                sed -i 's/ksu_is_current_proc_umounted/susfs_is_current_proc_umounted/g' "$_f"
                sed -i 's/ksu_set_current_proc_umounted/susfs_set_current_proc_umounted/g' "$_f"
                echo "[SUSFS-Fixup] $(basename "$_f"): Fixed ksu_ -> susfs_ proc umount prefix"
            fi
        fi
    done
fi

# ==========================================================================
# [GLOBAL] fs/susfs.c — make loop call non-static for compatibility
# ==========================================================================
if [ -f "$(dirname "$0")/fs/susfs.c" ]; then
    sed -i 's/static void susfs_run_sus_path_loop(void)/void susfs_run_sus_path_loop(void)/g' "$(dirname "$0")/fs/susfs.c"
    echo "[SUSFS-Fixup] fs/susfs.c: Made susfs_run_sus_path_loop non-static"
fi

# ==========================================================================
# Path Resolution (all supported managers use NEW layout with core/)
# ==========================================================================
KBUILD="$KSU_KERNEL/Kbuild"
MAKEFILE_KSU="$KSU_KERNEL/Makefile"
INIT_C="$KSU_KERNEL/core/init.c"
SUCOMPAT_C="$KSU_KERNEL/feature/sucompat.c"
SUCOMPAT_H="$KSU_KERNEL/feature/sucompat.h"
SETUID_HOOK_C="$KSU_KERNEL/hook/setuid_hook.c"
BRIDGE_C="$KSU_KERNEL/hook/syscall_event_bridge.c"
SUPERCALL_C="$KSU_KERNEL/supercall/supercall.c"
SUPERCALL_H="$KSU_KERNEL/supercall/supercall.h"
DISPATCH_C="$KSU_KERNEL/supercall/dispatch.c"
KSUD_H="$KSU_KERNEL/runtime/ksud.h"
KSUD_INT_C="$KSU_KERNEL/runtime/ksud_integration.c"
APP_PROFILE_C="$KSU_KERNEL/policy/app_profile.c"
KSU_H="$KSU_KERNEL/include/ksu.h"
RULES_C="$KSU_KERNEL/selinux/rules.c"
SELINUX_H="$KSU_KERNEL/selinux/selinux.h"
SULOG_EVENT_H="$KSU_KERNEL/sulog/event.h"
SULOG_EVENT_C="$KSU_KERNEL/sulog/event.c"
KERNEL_UMOUNT_C="$KSU_KERNEL/feature/kernel_umount.c"

# ==========================================================================
# [SHARED] supercall.c — ksu_install_su_fd stub (SUSFS v2.3.0 compat)
# ==========================================================================
# SUSFS v2.3.0 moved the su fd install out of 10_enable (which removed
# su_fd = ksu_install_su_fd() from the sucompat handler) and instead calls
# ksu_install_su_fd() directly from fs/exec.c after a successful su exec.
# Forks that do not implement the KSU_DRIVER_PERMISSION_SU_SESSION mechanism
# (e.g. BakaSU / SukiSU-Ultra) therefore fail to link with:
#   ld.lld: error: undefined symbol: ksu_install_su_fd
# Provide a no-op stub (returning success, no fd) only when the fork lacks it.
if [ -f "$SUPERCALL_C" ] && ! grep -q "ksu_install_su_fd" "$SUPERCALL_C" 2>/dev/null; then
    cat >> "$SUPERCALL_C" << 'SU_FD_STUB_EOF'

#ifdef CONFIG_KSU_SUSFS
/* SUSFS v2.3.0: fs/exec.c calls ksu_install_su_fd() after a su session exec.
 * Forks without the SU-session fd mechanism satisfy the link with a no-op. */
int ksu_install_su_fd(void)
{
    return 0;
}
#endif // #ifdef CONFIG_KSU_SUSFS
SU_FD_STUB_EOF
    echo "[SUSFS-Fixup] supercall.c: Added ksu_install_su_fd stub (SUSFS v2.3.0)"
fi

echo "[SUSFS-Fixup] Starting compatibility fixups..."

# ==========================================================================
# Helper: safely insert a line after a pattern (idempotent)
# ==========================================================================
insert_after() {
    local file="$1" pattern="$2" line="$3"
    [ -f "$file" ] || return 0
    grep -qF "$line" "$file" 2>/dev/null && return 0
    sed -i "/${pattern}/a\\${line}" "$file" 2>/dev/null || true
}

# ==========================================================================
# [SHARED] Makefile — SUSFS version detection
# ==========================================================================
if [ -f "$MAKEFILE_KSU" ] && ! grep -q "SUSFS_VERSION" "$MAKEFILE_KSU" 2>/dev/null; then
    cat >> "$MAKEFILE_KSU" << 'MKEOF'

## For susfs stuff ##
ifeq ($(shell test -e $(srctree)/fs/susfs.c; echo $$?),0)
$(eval SUSFS_VERSION=$(shell cat $(srctree)/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g'))
$(info )
$(info -- SUSFS_VERSION: $(SUSFS_VERSION))
else
$(info -- You have not integrated susfs in your kernel yet.)
endif
MKEOF
    echo "[SUSFS-Fixup] Makefile: Added SUSFS version detection"
fi

# ==========================================================================
# [SHARED] core/init.c — susfs include + init call
# ==========================================================================
if [ -f "$INIT_C" ]; then
    if ! grep -q "linux/susfs.h" "$INIT_C" 2>/dev/null; then
        # Try multiple anchor points for robustness
        sed -i '/#include <linux\/workqueue.h>/a #include <linux/susfs.h>' "$INIT_C" 2>/dev/null || \
        sed -i '/#include <linux\/moduleparam.h>/a #include <linux/susfs.h>' "$INIT_C" 2>/dev/null || \
        sed -i '0,/#include.*<linux\//{/#include.*<linux\//a #include <linux/susfs.h>
        }' "$INIT_C" 2>/dev/null || true
    fi
    if ! grep -q "susfs_init()" "$INIT_C" 2>/dev/null; then
        sed -i '/ksu_file_wrapper_init/a\\n\tsusfs_init();' "$INIT_C" 2>/dev/null || true
    fi
    echo "[SUSFS-Fixup] init.c: OK"
fi

# ==========================================================================
# [SHARED] selinux/rules.c — susfs SID init calls
# ==========================================================================
if [ "$MANAGER" != "bakasu" ] && [ -f "$RULES_C" ] && ! grep -q "susfs_set_zygote_sid" "$RULES_C" 2>/dev/null; then
    if grep -q "susfs_set_batch_sid" "$RULES_C" 2>/dev/null; then
        echo "[SUSFS-Fixup] selinux/rules.c: Using modern susfs_set_batch_sid"
    else
        if [ -f "$SELINUX_H" ]; then
            grep -q "susfs_set_batch_sid" "$SELINUX_H" 2>/dev/null || \
                sed -i "/^#endif/i void susfs_set_batch_sid(void);" "$SELINUX_H"
        fi
        if grep -q "reset_avc_cache();" "$RULES_C" 2>/dev/null; then
            sed -i 's/^[ \t]*reset_avc_cache();/\tsusfs_set_batch_sid();\n\treset_avc_cache();/' "$RULES_C"
        fi
        echo "[SUSFS-Fixup] selinux/rules.c: OK"
    fi
fi

# ==========================================================================
# [SHARED] setuid_hook.c — do_umount label
# ==========================================================================
if [ -f "$SETUID_HOOK_C" ] && grep -q "goto do_umount;" "$SETUID_HOOK_C" 2>/dev/null; then
    if ! grep -q "do_umount:" "$SETUID_HOOK_C" 2>/dev/null; then
        sed -i '/ksu_handle_umount/i\\ndo_umount:' "$SETUID_HOOK_C"
        echo "[SUSFS-Fixup] setuid_hook.c: Added do_umount label"
    fi
fi

# ==========================================================================
# [SHARED] Remove dead symbol references when objects are not compiled
# ==========================================================================
APP_PROFILE_C="$KSU_KERNEL/policy/app_profile.c"
if [ -f "$KBUILD" ] && [ -f "$APP_PROFILE_C" ]; then
    if ! grep -q "tp_marker.o" "$KBUILD" 2>/dev/null; then
        if grep -q "ksu_set_task_tracepoint_flag\|ksu_clear_task_tracepoint_flag" "$APP_PROFILE_C" 2>/dev/null; then
            sed -i '/ksu_set_task_tracepoint_flag/d' "$APP_PROFILE_C"
            sed -i '/ksu_clear_task_tracepoint_flag/d' "$APP_PROFILE_C"
            echo "[SUSFS-Fixup] app_profile.c: Removed tracepoint calls (tp_marker.o not compiled)"
        fi
    fi
fi

# ==========================================================================
# [SHARED] dispatch.c — ensure SUSFS includes are present
# ==========================================================================
# The SUSFS patch adds SUSFS_MAGIC/CMD_SUSFS_* usage to dispatch.c but may fail
# to add the #include <linux/susfs.h> (which transitively includes susfs_def.h)
# if the file's include block doesn't match the patch context (e.g., YukiSU).
if [ -f "$DISPATCH_C" ] && grep -q "SUSFS_MAGIC" "$DISPATCH_C" 2>/dev/null; then
    if ! grep -q "linux/susfs.h" "$DISPATCH_C" 2>/dev/null; then
        sed -i '/#include <linux\/version.h>/a #include <linux/susfs.h>' "$DISPATCH_C" 2>/dev/null || \
        sed -i '1,/#include/{/#include/a #include <linux/susfs.h>
        }' "$DISPATCH_C" 2>/dev/null || true
        echo "[SUSFS-Fixup] dispatch.c: Added missing #include <linux/susfs.h>"
    fi
fi

# ==========================================================================
# [SHARED] Kconfig — ensure CONFIG_KSU defaults to built-in (y), not module (m)
# ==========================================================================
# The SUSFS patch expects to modify Kconfig but may fail on some forks (e.g.,
# YukiSU has 'depends on m' + 'default m' instead of 'depends on KPROBES').
# This causes KernelSU to build as a module, leading to 47+ unresolved symbols.
KCONFIG="$KSU_KERNEL/Kconfig"
if [ -f "$KCONFIG" ]; then
    # Remove 'depends on m' which forces module-only build
    if grep -q "depends on m$" "$KCONFIG" 2>/dev/null; then
        sed -i '/^\s*depends on m$/d' "$KCONFIG"
        echo "[SUSFS-Fixup] Kconfig: Removed 'depends on m' (was forcing module build)"
    fi
    # Change 'default m' to 'default y' for built-in
    if grep -q "default m$" "$KCONFIG" 2>/dev/null; then
        sed -i 's/^\(\s*\)default m$/\1default y/' "$KCONFIG"
        echo "[SUSFS-Fixup] Kconfig: Changed 'default m' to 'default y' (built-in)"
    fi
fi

# ==========================================================================
# [SHARED] sucompat.h — Complete rebuild to clean state
# ==========================================================================
rebuild_sucompat_h() {
    [ -f "$SUCOMPAT_H" ] || return 0

    # Detect which functions exist in sucompat.c to declare them correctly
    local has_execve_sucompat=0 has_execveat_sucompat=0
    if [ -f "$SUCOMPAT_C" ]; then
        grep -q "ksu_handle_execve_sucompat" "$SUCOMPAT_C" 2>/dev/null && has_execve_sucompat=1
        grep -q "ksu_handle_execveat_sucompat" "$SUCOMPAT_C" 2>/dev/null && has_execveat_sucompat=1
    fi

    # Detect if sucompat.c uses DEFINE_STATIC_KEY_TRUE or plain bool
    local use_static_key=0
    if [ -f "$SUCOMPAT_C" ]; then
        grep -q 'DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled)' "$SUCOMPAT_C" 2>/dev/null && use_static_key=1
    fi

    if [ "$use_static_key" -eq 1 ]; then
        cat > "$SUCOMPAT_H" << 'SUCOMPAT_H_EOF'
#ifndef __KSU_H_SUCOMPAT
#define __KSU_H_SUCOMPAT
#include <asm/ptrace.h>
#include <linux/types.h>
#include <linux/version.h>
#include <linux/jump_label.h>

extern struct static_key_true ksu_su_compat_enabled;

void ksu_sucompat_init(void);
void ksu_sucompat_exit(void);

int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
int ksu_handle_stat_user(int *dfd, const char __user **filename_user, int *flags);
#else
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#define ksu_handle_stat_user ksu_handle_stat
#endif
SUCOMPAT_H_EOF
    else
        cat > "$SUCOMPAT_H" << 'SUCOMPAT_H_EOF'
#ifndef __KSU_H_SUCOMPAT
#define __KSU_H_SUCOMPAT
#include <asm/ptrace.h>
#include <linux/types.h>
#include <linux/version.h>

extern bool ksu_su_compat_enabled;

void ksu_sucompat_init(void);
void ksu_sucompat_exit(void);

int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *__unused_flags);

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags);
int ksu_handle_stat_user(int *dfd, const char __user **filename_user, int *flags);
#else
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);
#define ksu_handle_stat_user ksu_handle_stat
#endif
SUCOMPAT_H_EOF
    fi

    # Add the correct execve function declarations
    if [ "$has_execve_sucompat" -eq 1 ]; then
        cat >> "$SUCOMPAT_H" << 'EOF'

#ifndef CONFIG_KSU_SUSFS
long ksu_handle_execve_sucompat(const char __user **filename_user, int orig_nr, const struct pt_regs *regs);
#endif
EOF
    fi

    # Add SUSFS declarations
    cat >> "$SUCOMPAT_H" << 'EOF'

#ifdef CONFIG_KSU_SUSFS
#include <linux/fs.h>
struct user_arg_ptr;
EOF

    if grep -q "ksu_handle_execveat_init" "$SUCOMPAT_C" 2>/dev/null && \
       ! grep -qE "static[[:space:]]+(inline[[:space:]]+)?void[[:space:]]+ksu_handle_execveat_init" "$SUCOMPAT_C" 2>/dev/null; then
        cat >> "$SUCOMPAT_H" << 'EOF'
int ksu_handle_execveat_init(struct filename *filename,
    struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user);
EOF
    fi

    cat >> "$SUCOMPAT_H" << 'EOF'
int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
    void *argv_user, void *envp_user, int *__never_use_flags);
int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
    void *envp, int *flags);
#endif

#endif /* __KSU_H_SUCOMPAT */
EOF

    echo "[SUSFS-Fixup] sucompat.h: Rebuilt clean"
}

# ==========================================================================
# [SHARED] sucompat.c — ksu_handle_stat version gate + ksu_handle_execveat_init
# ==========================================================================
if [ -f "$SUCOMPAT_C" ]; then
    # Ensure susfs_def.h include
    if ! grep -q "linux/susfs_def.h" "$SUCOMPAT_C" 2>/dev/null; then
        sed -i '1,/#include/{/#include/a #include <linux/susfs_def.h>
        }' "$SUCOMPAT_C" 2>/dev/null || true
    fi

    # Fix ksu_handle_stat for kernel >= 6.1 if not already version-gated
    if grep -q "int ksu_handle_stat(int \*dfd, const char __user \*\*filename_user, int \*flags)" "$SUCOMPAT_C" 2>/dev/null && \
       ! grep -q "KERNEL_VERSION(6, 1, 0)" "$SUCOMPAT_C" 2>/dev/null; then
        sed -i '/^int ksu_handle_stat(int \*dfd, const char __user \*\*filename_user, int \*flags)/c\
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)\
{\
    if (unlikely(IS_ERR(*filename) || (*filename)->name == NULL)) return 0;\
    if (likely(memcmp((*filename)->name, "/system/bin/su", 15))) return 0;\
    pr_info("ksu_handle_stat: su->sh!\\n");\
    memcpy((void *)((*filename)->name), "/system/bin/sh", 15);\
    return 0;\
}\
int ksu_handle_stat_user(int *dfd, const char __user **filename_user, int *flags)\
#else\
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)\
#endif' "$SUCOMPAT_C"
        # We don't need the #endif at the end of the function anymore, because the #else/#endif wraps the function signature only.
        # However, the previous script might have already added #endif at the end of the function if it ran before.
        # But we are assuming a clean run of the script.
        echo "[SUSFS-Fixup] sucompat.c: Fixed ksu_handle_stat version gate"
    fi

    # Add ksu_handle_execveat_init if missing
    if ! grep -q "ksu_handle_execveat_init" "$SUCOMPAT_C" 2>/dev/null; then
        cat >> "$SUCOMPAT_C" << 'EXECVEAT_EOF'

#ifdef CONFIG_KSU_SUSFS
int ksu_handle_execveat_init(struct filename *filename,
    struct user_arg_ptr *argv_user, struct user_arg_ptr *envp_user)
{
    if (current->pid != 1 && is_init(get_current_cred())) {
        if (unlikely(strcmp(filename->name, KSUD_PATH) == 0)) {
            pr_info("hook_manager: escape to root for init executing ksud: %d\n", current->pid);
            escape_to_root_for_init();
            return 0;
        } else if (likely(strstr(filename->name, "/app_process") == NULL &&
                    strstr(filename->name, "/adbd") == NULL) &&
                    !susfs_is_current_proc_umounted())
        {
            pr_info("susfs: mark no sucompat checks for pid: '%d', exec: '%s'\n",
                current->pid, filename->name);
            susfs_set_current_proc_umounted();
            return 0;
        }
        return 0;
    }
    return -EINVAL;
}
#endif /* CONFIG_KSU_SUSFS */
EXECVEAT_EOF
        echo "[SUSFS-Fixup] sucompat.c: Added ksu_handle_execveat_init"
    fi
rebuild_sucompat_h
fi

# ==========================================================================
# [MANAGER-SPECIFIC] Fixes per kernel manager
# ==========================================================================

# --------------------------------------------------------------------------
# YukiSU: Fix adb_root and syscall_hook_manager signatures
# --------------------------------------------------------------------------
fix_yukisu_adb_root() {
    local adb_root_c="$KSU_KERNEL/feature/adb_root.c"
    local hook_mgr="$KSU_KERNEL/syscall_hook_manager.c"
    
    if [ -f "$adb_root_c" ]; then
        if grep -q "static long do_ksu_adb_root_handle_execve(struct pt_regs \*regs)" "$adb_root_c" 2>/dev/null; then
            sed -i 's|static long is_exec_adbd(struct pt_regs \*regs)|static long is_exec_adbd(const char \*filename)|' "$adb_root_c"
            sed -i 's|if (likely(is_exec_adbd(regs) != 1)) {|if (likely(is_exec_adbd(filename) != 1)) {|' "$adb_root_c"
            sed -i '1s/^/#include <linux\/susfs.h>\n/' "$adb_root_c"
            sed -i '/static long is_exec_adbd(const char \*filename)/,/^}/c\
static long is_exec_adbd(const char *filename)\
{\
    if (strstr(filename, "adbd"))\
        pr_info("is_exec_adbd() => filename: %s\\n", filename);\
    return (susfs_starts_with(filename, "/apex/") &&\
                susfs_ends_with(filename, "/adbd"));\
}' "$adb_root_c"
            
            sed -i 's|unsigned long stackp = user_stack_pointer(regs);|unsigned long stackp = current_user_stack_pointer();|' "$adb_root_c"
            sed -i 's|unsigned long \*envp_p = (unsigned long \*)&PT_REGS_PARM3(regs);|unsigned long \*envp_p = (unsigned long \*)envp_user_ptr;|' "$adb_root_c"
            sed -i 's|static long setup_ld_preload(struct pt_regs \*regs)|static long setup_ld_preload(void \*\*\*envp_user_ptr)|' "$adb_root_c"
            sed -i 's|long ret = setup_ld_preload(regs);|long ret = setup_ld_preload(envp_user_ptr);|' "$adb_root_c"
            sed -i 's|ret = setup_ld_preload(regs);|ret = setup_ld_preload(envp_user_ptr);|' "$adb_root_c"
            
            sed -i 's|static long do_ksu_adb_root_handle_execve(struct pt_regs \*regs)|static long do_ksu_adb_root_handle_execve(const char \*filename, void \*\*\*envp_user_ptr)|' "$adb_root_c"
            sed -i 's|long ksu_adb_root_handle_execve(struct pt_regs \*regs)|long ksu_adb_root_handle_execve(const char \*filename, void \*\*\*envp_user_ptr)|' "$adb_root_c"
            sed -i 's|return do_ksu_adb_root_handle_execve(regs);|return do_ksu_adb_root_handle_execve(filename, envp_user_ptr);|' "$adb_root_c"
            echo "[SUSFS-Fixup] adb_root.c: Fixed adb_root call signatures for YukiSU"
        fi
    fi
    
    if [ -f "$hook_mgr" ]; then
        if grep -q 'ksu_adb_root_handle_execve((struct pt_regs \*)regs)' "$hook_mgr" 2>/dev/null; then
            sed -i 's|ksu_adb_root_handle_execve((struct pt_regs \*)regs)|ksu_adb_root_handle_execve((const char \*)PT_REGS_PARM1(regs), (void \*\*\*)\&PT_REGS_PARM3(regs))|' "$hook_mgr"
            echo "[SUSFS-Fixup] syscall_hook_manager.c: Fixed adb_root call signature for YukiSU"
        fi
    fi

    # Inject missing static keys required by susfs patches if not present
    # YukiSU doesn't have ksu.c — use init.c or ksud_integration.c instead
    local target_c=""
    for candidate in "$KSU_KERNEL/ksu.c" "$KSU_KERNEL/core/init.c" "$KSU_KERNEL/runtime/ksud_integration.c"; do
        if [ -f "$candidate" ]; then
            target_c="$candidate"
            break
        fi
    done
    if [ -n "$target_c" ]; then
        if ! grep -q "ksu_is_init_rc_hook_enabled" "$target_c" 2>/dev/null; then
            # Find an anchor: #include <linux/module.h> or first #include <linux/
            if grep -q '#include <linux/module.h>' "$target_c" 2>/dev/null; then
                sed -i '/#include <linux\/module.h>/a \
#include <linux/jump_label.h>\
DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);\
EXPORT_SYMBOL_GPL(ksu_is_init_rc_hook_enabled);\
DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);\
EXPORT_SYMBOL_GPL(ksu_is_input_hook_enabled);' "$target_c"
            else
                # Insert after last #include block
                sed -i '0,/^#include.*$/{/^$/i \
#include <linux/jump_label.h>\
DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);\
EXPORT_SYMBOL_GPL(ksu_is_init_rc_hook_enabled);\
DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);\
EXPORT_SYMBOL_GPL(ksu_is_input_hook_enabled);
            }' "$target_c"
            fi
            echo "[SUSFS-Fixup] $(basename "$target_c"): Injected missing static keys"
        fi
    fi
}

# --------------------------------------------------------------------------
# YukiSU-specific: Fix SUSFS compatibility issues unique to YukiSU
# --------------------------------------------------------------------------
fix_yukisu_susfs_compat() {
    # Fix 1: sh_user_path duplication — the fixup's sucompat.c rebuild
    # may add sh_user_path but YukiSU already has it
    if [ -f "$SUCOMPAT_C" ]; then
        local count
        count=$(grep -c "^static char __user \*sh_user_path(void)" "$SUCOMPAT_C" 2>/dev/null || echo 0)
        if [ "$count" -gt 1 ]; then
            # Remove duplicate — keep only the first occurrence
            awk '/^static char __user \*sh_user_path\(void\)/{c++; if(c>1){skip=1}} skip && /^}/{skip=0; next} !skip' "$SUCOMPAT_C" > "${SUCOMPAT_C}.tmp" && mv "${SUCOMPAT_C}.tmp" "$SUCOMPAT_C"
            echo "[SUSFS-Fixup] sucompat.c: Removed duplicate sh_user_path"
        fi
    fi

    # Fix 2: ksu_handle_execveat_ksud — YukiSU uses 4 args (no fd), not 5
    # YukiSU signature: void ksu_handle_execveat_ksud(const char *filename, struct user_arg_ptr *argv,
    #                                                 struct user_arg_ptr *envp, int *flags);
    # Our injected ksu_handle_execveat calls it with 5 args (fd, filename_ptr, argv, envp, flags)
    if [ -f "$SUCOMPAT_C" ] && [ -f "$KSU_KERNEL/runtime/ksud.h" ]; then
        local ksud_sig
        ksud_sig=$(grep "ksu_handle_execveat_ksud" "$KSU_KERNEL/runtime/ksud.h" 2>/dev/null | head -1)
        if echo "$ksud_sig" | grep -q "const char \*filename," 2>/dev/null; then
            # YukiSU 4-arg form: void ksu_handle_execveat_ksud(filename, argv, envp, flags)
            # Replace 5-arg call. Since return is void, can't use in if(!...)
            sed -i 's|if (ksu_handle_execveat_ksud(fd, filename_ptr, argv, envp, flags))|ksu_handle_execveat_ksud((*filename_ptr)->name, (struct user_arg_ptr *)argv, (struct user_arg_ptr *)envp, flags); if (0)|' "$SUCOMPAT_C"
            echo "[SUSFS-Fixup] sucompat.c: Fixed ksu_handle_execveat_ksud to YukiSU 4-arg signature"
        fi
    fi

    # Fix 3: escape_to_root_for_init return type mismatch
    # YukiSU's app_profile.h declares: int escape_to_root_for_init(void);
    # YukiSU's app_profile.c defines:  void escape_to_root_for_init(void)
    # Fix: change .c definition to match .h declaration
    local APP_PROFILE_C_Y="$KSU_KERNEL/policy/app_profile.c"
    local APP_PROFILE_H_Y="$KSU_KERNEL/policy/app_profile.h"
    if [ -f "$APP_PROFILE_C_Y" ] && [ -f "$APP_PROFILE_H_Y" ]; then
        if grep -q "^int escape_to_root_for_init(void);" "$APP_PROFILE_H_Y" 2>/dev/null && \
           grep -q "^void escape_to_root_for_init(void)" "$APP_PROFILE_C_Y" 2>/dev/null; then
            sed -i 's/^void escape_to_root_for_init(void)/int escape_to_root_for_init(void)/' "$APP_PROFILE_C_Y"
            # Add return 0 before the closing brace of the function
            local funcstart
            funcstart=$(grep -n "^int escape_to_root_for_init(void)" "$APP_PROFILE_C_Y" | head -1 | cut -d: -f1)
            if [ -n "$funcstart" ]; then
                local funcend
                funcend=$(awk -v s="$funcstart" 'NR>s && /^}/{print NR; exit}' "$APP_PROFILE_C_Y")
                if [ -n "$funcend" ]; then
                    sed -i "${funcend}i\\\treturn 0;" "$APP_PROFILE_C_Y"
                fi
            fi
            echo "[SUSFS-Fixup] app_profile.c: Fixed escape_to_root_for_init return type (void -> int)"
        fi
    fi

    # Fix 4: ksu_handle_execve_sucompat — behind #ifndef CONFIG_KSU_SUSFS
    # bridge.c calls it unconditionally, so we need a stub outside the guard
    if [ -f "$SUCOMPAT_C" ]; then
        if grep -B2 "long ksu_handle_execve_sucompat" "$SUCOMPAT_C" 2>/dev/null | grep -q "#ifndef CONFIG_KSU_SUSFS"; then
            cat >> "$SUCOMPAT_C" << 'EXECVE_STUB_EOF'

/* SUSFS stub: bridge.c calls this unconditionally but upstream hides it behind #ifndef */
#ifdef CONFIG_KSU_SUSFS
long ksu_handle_execve_sucompat(const char __user **filename_user, int orig_nr, const struct pt_regs *regs)
{
    return 0;
}
#endif
EXECVE_STUB_EOF
            echo "[SUSFS-Fixup] sucompat.c: Added ksu_handle_execve_sucompat stub for SUSFS"
        fi
    fi
}


# --------------------------------------------------------------------------
# Sukisu-Ultra: kprobe-based reboot interception needs SUSFS forwarding
# --------------------------------------------------------------------------
fix_kprobe_supercall() {
    if [ ! -f "$SUPERCALL_C" ]; then return; fi

    # Only applies if supercall.c still has a kprobe handler
    if ! grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then return; fi

    # Check if dispatch.c has SUSFS handling (patch succeeded for dispatch.c)
    if ! grep -q "SUSFS_MAGIC" "$DISPATCH_C" 2>/dev/null; then
        echo "[SUSFS-Fixup] WARNING: dispatch.c missing SUSFS handler — cannot bridge"
        return
    fi

    # SUSFS supercalls are handled by kernel/reboot.c → dispatch.c's
    # ksu_handle_sys_reboot() in normal syscall context. No kprobe bridge needed.

    # NOTE: We do NOT add SUSFS dispatch to the kprobe handler.
    # kprobe pre-handlers run with preemption disabled (atomic context).
    # SUSFS dispatch calls mutex_lock/copy_from_user/kzalloc(GFP_KERNEL)
    # which sleep → BUG: scheduling while atomic.
    # Instead, kernel/reboot.c already has a direct call to
    # ksu_handle_sys_reboot() in normal syscall context which handles SUSFS.

    # Remove any previously-injected kprobe SUSFS bridge (from older fixup)
    if grep -q "ksu_susfs_dispatch_reboot" "$SUPERCALL_C" 2>/dev/null; then
        sed -i '/#ifdef CONFIG_KSU_SUSFS/{
            N;N;N;N;N;N
            /ksu_susfs_dispatch_reboot/d
        }' "$SUPERCALL_C"
        sed -i '/ksu_susfs_dispatch_reboot/d' "$SUPERCALL_C"
        sed -i '/^#ifdef CONFIG_KSU_SUSFS$/{N;/^#ifdef CONFIG_KSU_SUSFS\n#endif$/d}' "$SUPERCALL_C"
        echo "[SUSFS-Fixup] supercall.c: Removed kprobe SUSFS bridge (atomic context unsafe)"
    fi

    # Step 3: Add ksu_supercall_reboot_handler if missing (dispatch.c needs it)
    if ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_C" 2>/dev/null; then
        cat >> "$SUPERCALL_C" << 'REBOOT_HANDLER_EOF'

int ksu_supercall_reboot_handler(void __user **arg)
{
    struct ksu_install_fd_tw *tw;
    tw = kzalloc(sizeof(*tw), GFP_KERNEL);
    if (!tw) return 0;
    tw->outp = (int __user *)(*arg);
    tw->cb.func = ksu_install_fd_tw_func;
    if (task_work_add(current, &tw->cb, TWA_RESUME)) {
        kfree(tw);
        pr_warn("install fd add task_work failed\n");
    }
    return 0;
}
REBOOT_HANDLER_EOF
        echo "[SUSFS-Fixup] supercall.c: Added ksu_supercall_reboot_handler"
    fi

    if [ -f "$SUPERCALL_H" ] && ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_H" 2>/dev/null; then
        sed -i '/ksu_install_fd/a int ksu_supercall_reboot_handler(void __user **arg);' "$SUPERCALL_H" 2>/dev/null || \
        sed -i '/ksu_supercalls_init/i int ksu_supercall_reboot_handler(void __user **arg);' "$SUPERCALL_H" 2>/dev/null || true
    fi

    # Remove duplicate ksu_handle_sys_reboot from dispatch.c
    # The SUSFS patch adds it for non-kprobe architecture (KSU-Next style),
    # but kprobe-based managers already have it in supercall.c.
    if [ -f "$DISPATCH_C" ] && grep -q "^int ksu_handle_sys_reboot" "$DISPATCH_C" 2>/dev/null && \
       grep -q "^int ksu_handle_sys_reboot" "$SUPERCALL_C" 2>/dev/null; then
        # Remove the entire function from dispatch.c (from signature to closing brace)
        local start_line end_line
        start_line=$(grep -n "^int ksu_handle_sys_reboot" "$DISPATCH_C" | head -1 | cut -d: -f1)
        if [ -n "$start_line" ]; then
            # Find the matching closing brace at column 0
            end_line=$(awk -v s="$start_line" 'NR>s && /^}/{print NR; exit}' "$DISPATCH_C")
            if [ -n "$end_line" ]; then
                sed -i "${start_line},${end_line}d" "$DISPATCH_C"
                echo "[SUSFS-Fixup] dispatch.c: Removed duplicate ksu_handle_sys_reboot (already in supercall.c)"
            fi
        fi
    fi
}

# --------------------------------------------------------------------------
# Sukisu-Ultra: Fix sulog type mismatch in ksu_handle_execve_sucompat
# --------------------------------------------------------------------------
fix_sulog_type_mismatch() {
    if [ ! -f "$SUCOMPAT_C" ]; then return; fi

    # The SUSFS patch changes sulog/event.h to expect struct user_arg_ptr *
    # but the old ksu_handle_execve_sucompat passes raw const char __user *const __user *
    if [ -f "$SULOG_EVENT_H" ] && grep -q "struct user_arg_ptr \*argv_user" "$SULOG_EVENT_H" 2>/dev/null; then
        # Check if sucompat.c still has the old-style call
        if grep -q 'ksu_sulog_capture_sucompat(\*filename_user, argv_user' "$SUCOMPAT_C" 2>/dev/null; then
            # The function has: const char __user *const __user *argv_user = ...
            # We need to wrap it in struct user_arg_ptr before passing to ksu_sulog_capture_sucompat
            sed -i '/pending_sucompat = ksu_sulog_capture_sucompat(\*filename_user, argv_user/c\
    {\
        struct user_arg_ptr _argv_wrap = { .ptr.native = argv_user };\
        pending_sucompat = ksu_sulog_capture_sucompat(*filename_user, \&_argv_wrap, GFP_KERNEL);\
    }' "$SUCOMPAT_C"
            echo "[SUSFS-Fixup] sucompat.c: Fixed sulog argv_user type mismatch"
        fi
    fi
}

# --------------------------------------------------------------------------
# Sukisu-Ultra: Add ksu_handle_execveat_sucompat + ksu_handle_execveat
# and guard old ksu_handle_execve_sucompat from ksu_syscall_table dependency
# --------------------------------------------------------------------------
fix_execveat_handlers() {
    if [ ! -f "$SUCOMPAT_C" ]; then return; fi

    # Guard old ksu_handle_execve_sucompat with #ifndef CONFIG_KSU_SUSFS
    # (it uses ksu_syscall_table from syscall_hook_manager.c which is not compiled)
    if [ "$MANAGER" != "ksu-next" ] && [ "$MANAGER" != "sukisu" ] && grep -q "ksu_handle_execve_sucompat" "$SUCOMPAT_C" 2>/dev/null && \
       grep -q "ksu_syscall_table" "$SUCOMPAT_C" 2>/dev/null && \
       ! grep -q '#ifndef CONFIG_KSU_SUSFS' "$SUCOMPAT_C" 2>/dev/null; then

        sed -i '/^long ksu_handle_execve_sucompat/i\
#ifndef CONFIG_KSU_SUSFS' "$SUCOMPAT_C"

        # Find the closing brace of ksu_handle_execve_sucompat
        local funcstart
        funcstart=$(grep -n "^long ksu_handle_execve_sucompat" "$SUCOMPAT_C" | head -1 | cut -d: -f1)
        if [ -n "$funcstart" ]; then
            # Find the next line that has "^}" after the function start
            local funcend
            funcend=$(awk -v s="$funcstart" 'NR>s && /^}/{print NR; exit}' "$SUCOMPAT_C")
            if [ -n "$funcend" ]; then
                sed -i "${funcend}a\\#endif /* !CONFIG_KSU_SUSFS */" "$SUCOMPAT_C"
            fi
        fi
        echo "[SUSFS-Fixup] sucompat.c: Guarded old ksu_handle_execve_sucompat"
    fi

    # Add ksu_handle_execveat_sucompat + ksu_handle_execveat if missing
    if ! grep -q "ksu_handle_execveat_sucompat" "$SUCOMPAT_C" 2>/dev/null; then
        cat >> "$SUCOMPAT_C" << 'EXECVEAT_SUCOMPAT_EOF'

#ifdef CONFIG_KSU_SUSFS
static const char _su_path[] = "/system/bin/su";
static const char _sh_path[] = "/system/bin/sh";
static const char _ksud_path[] = KSUD_PATH;

int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,
                 void *argv_user, void *envp_user,
                 int *__never_use_flags)
{
    struct filename *filename;
    int ret;

    if (unlikely(!filename_ptr))
        return 0;

    filename = *filename_ptr;
    if (IS_ERR(filename))
        return 0;

    if (!ksu_handle_execveat_init(filename,
            (struct user_arg_ptr *)argv_user,
            (struct user_arg_ptr *)envp_user))
        return 0;

    if (likely(memcmp(filename->name, _su_path, sizeof(_su_path))))
        return 0;

    if (!ksu_is_allow_uid_for_current(current_uid().val))
        return 0;

    pr_info("ksu_handle_execveat_sucompat: su found\n");
    memcpy((void *)filename->name, _ksud_path, sizeof(_ksud_path));

    ret = escape_with_root_profile();
    if (ret)
        pr_err("escape_with_root_profile() failed: %d\n", ret);

    return 0;
}

int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,
            void *envp, int *flags)
{
    if (ksu_handle_execveat_ksud(fd, filename_ptr, argv, envp, flags))
        return 0;
    return ksu_handle_execveat_sucompat(fd, filename_ptr, argv, envp, flags);
}
#endif /* CONFIG_KSU_SUSFS */
EXECVEAT_SUCOMPAT_EOF
        echo "[SUSFS-Fixup] sucompat.c: Added ksu_handle_execveat_sucompat + ksu_handle_execveat"
    fi

    # Inject ksu_handle_stat_user for kernel 6.1+ if missing (required by tracepoint hook)
    if ! grep -q "ksu_handle_stat_user" "$SUCOMPAT_C" 2>/dev/null; then
        cat >> "$SUCOMPAT_C" << 'STAT_USER_EOF'

int ksu_handle_stat_user(int *dfd, const char __user **filename_user, int *flags)
{
    if (unlikely(!filename_user))
        return 0;
    char path[sizeof(su_path) + 1] = {0};
    strncpy_from_user(path, *filename_user, sizeof(path));
    if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
        pr_info("ksu_handle_stat_user: su->sh!\n");
        *filename_user = sh_user_path();
    }
    return 0;
}
STAT_USER_EOF
        echo "[SUSFS-Fixup] sucompat.c: Injected ksu_handle_stat_user"
    fi

    # Inject ksu_handle_execve_sucompat stub
    if ! grep -q "long ksu_handle_execve_sucompat" "$SUCOMPAT_C" 2>/dev/null; then
        cat >> "$SUCOMPAT_C" << 'SUCOMPAT_EOF'

long ksu_handle_execve_sucompat(const char __user **filename_user, int orig_nr, const struct pt_regs *regs)
{
    return 0;
}
SUCOMPAT_EOF
        echo "[SUSFS-Fixup] sucompat.c: Injected ksu_handle_execve_sucompat stub"
    fi
}

# --------------------------------------------------------------------------
# ksu_handle_faccessat → struct filename ** (SUSFS v2.3.0 signature)
# fs/open.c now passes a struct filename ** (getname_flags + filename_lookup).
# Managers that still ship the legacy const char __user ** variant (e.g.
# SukiSU-Ultra) conflict with the rebuilt sucompat.h. Guard the legacy
# definition off on kernel >= 6.1 and add the modern definition.
# --------------------------------------------------------------------------
fix_faccessat_signature() {
    if [ ! -f "$SUCOMPAT_C" ]; then return; fi

    # Already modernized
    if grep -q "int ksu_handle_faccessat(int \*dfd, struct filename \*\*filename" "$SUCOMPAT_C" 2>/dev/null; then
        return
    fi
    # No legacy variant to fix
    if ! grep -q "int ksu_handle_faccessat(int \*dfd, const char __user \*\*filename_user" "$SUCOMPAT_C" 2>/dev/null; then
        return
    fi
    # Idempotency: already guarded by a previous run
    if grep -q "ksu_handle_faccessat_modern" "$SUCOMPAT_C" 2>/dev/null; then
        return
    fi

    local funcstart funcend
    funcstart=$(grep -n "int ksu_handle_faccessat(int \*dfd, const char __user \*\*filename_user" "$SUCOMPAT_C" | head -1 | cut -d: -f1)
    if [ -z "$funcstart" ]; then return; fi

    funcend=$(awk -v s="$funcstart" 'NR>s && /^}/{print NR; exit}' "$SUCOMPAT_C")
    if [ -z "$funcend" ]; then return; fi

    # Guard the legacy definition off on kernel >= 6.1
    sed -i "${funcstart}i\\
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 1, 0)" "$SUCOMPAT_C"
    # funcend shifted by +1 due to the inserted guard above
    sed -i "$((funcend+1))a\\
#endif /* LINUX_VERSION_CODE < KERNEL_VERSION(6, 1, 0) */" "$SUCOMPAT_C"

    cat >> "$SUCOMPAT_C" << 'FACCESSAT_EOF'

/* SUSFS v2.3.0: fs/open.c calls ksu_handle_faccessat with a struct filename ** */
#ifdef CONFIG_KSU_SUSFS
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,
    int *__unused_flags)
{
    if (unlikely(IS_ERR(*filename) || (*filename)->name == NULL))
        return 0;
    if (likely(memcmp((*filename)->name, su_path, sizeof(su_path))))
        return 0;
    if (current_chrooted())
    {
        pr_err("ksu_handle_faccessat: su found but NOT allowed! Because current process is running in chrooted environment\n");
        return 0;
    }
    pr_info("ksu_handle_faccessat: su->sh!\n");
    memcpy((void *)((*filename)->name), sh_path, sizeof(sh_path));
    return 0;
}
#endif /* LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0) */
#endif /* CONFIG_KSU_SUSFS */
FACCESSAT_EOF

    echo "[SUSFS-Fixup] sucompat.c: ksu_handle_faccessat modernized to struct filename ** (v2.3.0)"
}
# --------------------------------------------------------------------------
fix_ksu_next_kbuild() {
    if [ ! -f "$KBUILD" ]; then return; fi

    # The SUSFS patch removes lsm_hook, syscall_event_bridge, tp_marker, etc.
    # KernelSU-Next needs them. Restore if missing.
    local need_restore=0

    for obj in "hook/lsm_hook.o" "hook/syscall_event_bridge.o" "hook/syscall_hook_manager.o" "hook/tp_marker.o" "infra/symbol_resolver.o"; do
        local src_file="$KSU_KERNEL/$(echo $obj | sed 's/\.o$/.c/')"
        if [ -f "$src_file" ] && ! grep -q "$obj" "$KBUILD" 2>/dev/null; then
            need_restore=1
            break
        fi
    done

    if [ "$need_restore" -eq 1 ]; then
        # Insert after hook/setuid_hook.o
        if ! grep -q "hook/lsm_hook.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/hook/lsm_hook.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/lsm_hook.o' "$KBUILD"
        fi
        if ! grep -q "hook/syscall_event_bridge.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/hook/syscall_event_bridge.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/syscall_event_bridge.o' "$KBUILD"
        fi
        if ! grep -q "hook/syscall_hook_manager.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/hook/syscall_hook_manager.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/syscall_hook_manager.o' "$KBUILD"
        fi
        if ! grep -q "hook/tp_marker.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/hook/tp_marker.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += hook/tp_marker.o' "$KBUILD"
        fi
        if ! grep -q "infra/symbol_resolver.o" "$KBUILD" 2>/dev/null && [ -f "$KSU_KERNEL/infra/symbol_resolver.c" ]; then
            sed -i '/hook\/setuid_hook.o/a kernelsu-objs += infra/symbol_resolver.o' "$KBUILD"
        fi
        echo "[SUSFS-Fixup] Kbuild: Restored hook objects for $MANAGER"
    fi

    # Arch-specific patch memory and syscall hook — checked independently of
    # need_restore, since SUSFS patch can strip just these entries while
    # leaving hook/syscall_event_bridge.o etc intact (seen on kowsu).
    if ! grep -q "hook/arm64/patch_memory.o" "$KBUILD" 2>/dev/null && [ -d "$KSU_KERNEL/hook/arm64" ]; then
        sed -i '/hook\/setuid_hook.o/a\
ifeq ($(CONFIG_ARM64),y)\
kernelsu-objs += hook/arm64/patch_memory.o\
kernelsu-objs += hook/arm64/syscall_hook.o\
else ifeq ($(CONFIG_X86_64),y)\
kernelsu-objs += hook/x86_64/patch_memory.o\
kernelsu-objs += hook/x86_64/syscall_hook.o\
endif' "$KBUILD"
        echo "[SUSFS-Fixup] Kbuild: Restored arch-specific syscall_hook.o"
    fi
}

# --------------------------------------------------------------------------
# KernelSU-Next: syscall_event_bridge.c setresuid fix
# --------------------------------------------------------------------------
fix_ksu_next_bridge() {
    if [ ! -f "$BRIDGE_C" ]; then return; fi

    if grep -q "ksu_handle_setresuid(old_uid, current_uid().val)" "$BRIDGE_C" 2>/dev/null; then
        # Check the ACTUAL definition in setuid_hook.c (not .h, which SUSFS strips)
        local SETUID_HOOK_C_LOCAL="$KSU_KERNEL/hook/setuid_hook.c"
        local has_3arg=0
        if [ -f "$SETUID_HOOK_C_LOCAL" ] && grep -q "ksu_handle_setresuid(uid_t ruid, uid_t euid, uid_t suid)" "$SETUID_HOOK_C_LOCAL" 2>/dev/null; then
            has_3arg=1
        elif [ -f "$SETUID_HOOK_C_LOCAL" ] && grep -q "ksu_handle_setresuid(uid_t old_uid, uid_t new_uid)" "$SETUID_HOOK_C_LOCAL" 2>/dev/null; then
            has_3arg=0
        else
            # Default: assume 3-arg (SUSFS standard transforms to 3-arg)
            has_3arg=1
        fi

        if [ "$has_3arg" -eq 1 ]; then
            sed -i 's/ksu_handle_setresuid(old_uid, current_uid()\.val);/{\
        uid_t ruid = PT_REGS_PARM1(regs);\
        uid_t euid = PT_REGS_PARM2(regs);\
        uid_t suid = PT_REGS_PARM3(regs);\
        ksu_handle_setresuid(ruid, euid, suid);\
    }/' "$BRIDGE_C"
            echo "[SUSFS-Fixup] syscall_event_bridge.c: Fixed setresuid 3-arg"
        else
            echo "[SUSFS-Fixup] syscall_event_bridge.c: Keeping setresuid 2-arg (manager definition uses 2-arg)"
        fi
    fi

    # Fix ksu_handle_stat call signature for KernelSU-Next tracepoints
    # We renamed it to ksu_handle_stat_user to avoid colliding with VFS hook signature.
    if grep -q "ksu_handle_stat(dfd, filename_user, flags);" "$BRIDGE_C" 2>/dev/null; then
        sed -i 's|ksu_handle_stat(dfd, filename_user, flags);|ksu_handle_stat_user(dfd, filename_user, flags);|' "$BRIDGE_C"
        echo "[SUSFS-Fixup] syscall_event_bridge.c: Renamed ksu_handle_stat to ksu_handle_stat_user"
    fi

    # tp_marker.h include
    if [ -f "$SETUID_HOOK_C" ] && grep -q "ksu_set_task_tracepoint_flag" "$SETUID_HOOK_C" 2>/dev/null; then
        if ! grep -q "hook/tp_marker.h" "$SETUID_HOOK_C" 2>/dev/null; then
            sed -i '/#include "hook\/setuid_hook.h"/a #include "hook/tp_marker.h"' "$SETUID_HOOK_C"
        fi
    fi

    # Fix ksu_su_compat_enabled static key usage (only if it is actually a static key)
    if grep -q 'DEFINE_STATIC_KEY_TRUE(ksu_su_compat_enabled)' "$SUCOMPAT_C" 2>/dev/null; then
        if grep -q "if (!ksu_su_compat_enabled)" "$BRIDGE_C" 2>/dev/null; then
            sed -i 's/if (!ksu_su_compat_enabled)/if (!static_branch_likely(\&ksu_su_compat_enabled))/g' "$BRIDGE_C"
            sed -i 's/else if (ksu_su_compat_enabled)/else if (static_branch_likely(\&ksu_su_compat_enabled))/g' "$BRIDGE_C"
            echo "[SUSFS-Fixup] syscall_event_bridge.c: Fixed ksu_su_compat_enabled static key access"
        fi
    fi
}

# --------------------------------------------------------------------------
# KernelSU-Next: supercall.c reboot handler (kprobe-free architecture)
# --------------------------------------------------------------------------
fix_ksu_next_supercall() {
    if [ ! -f "$SUPERCALL_C" ]; then return; fi

    # KernelSU-Next's SUSFS patch replaces kprobe with direct dispatch
    # If supercall.c still has kprobe, the patch failed — apply manually
    if grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then
        # kprobe still present = supercall.c patch failed
        # For KSU-Next, the bridge approach also works
        fix_kprobe_supercall
        return
    fi

    # Patch succeeded but ksu_supercall_reboot_handler may be missing
    if ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_C" 2>/dev/null; then
        cat >> "$SUPERCALL_C" << 'SUPERCALL_NEXT_EOF'

int ksu_supercall_reboot_handler(void __user **arg)
{
    struct ksu_install_fd_tw *tw;
    tw = kzalloc(sizeof(*tw), GFP_KERNEL);
    if (!tw) return 0;
    tw->outp = (int __user *)(*arg);
    tw->cb.func = ksu_install_fd_tw_func;
    if (task_work_add(current, &tw->cb, TWA_RESUME)) {
        kfree(tw);
        pr_warn("install fd add task_work failed\n");
    }
    return 0;
}
SUPERCALL_NEXT_EOF
        echo "[SUSFS-Fixup] supercall.c: Added ksu_supercall_reboot_handler"
    fi

    if [ -f "$SUPERCALL_H" ] && ! grep -q "ksu_supercall_reboot_handler" "$SUPERCALL_H" 2>/dev/null; then
        sed -i '/ksu_install_fd/a int ksu_supercall_reboot_handler(void __user **arg);' "$SUPERCALL_H" 2>/dev/null || true
    fi
}

# --------------------------------------------------------------------------
# KernelSU-Next: ksud compatibility wrappers
# --------------------------------------------------------------------------
fix_ksu_next_ksud() {
    if [ ! -f "$KSUD_INT_C" ]; then return; fi

    # Fix compilation errors in upstream ksud_integration.c
    if ! grep -q "static void stop_init_rc_hook(void);" "$KSUD_INT_C" 2>/dev/null; then
        sed -i '/DEFINE_STATIC_KEY_TRUE(ksu_is_input_hook_enabled);/a \
\
static void stop_init_rc_hook(void);\
static struct work_struct stop_input_hook_work;' "$KSUD_INT_C"
        echo "[SUSFS-Fixup] ksud_integration.c: Added missing declarations"
    fi

    if grep -q "ksu_handle_execveat_ksud(path, &argv);" "$KSUD_INT_C" 2>/dev/null; then
        sed -i 's/char path\[32\];/char path\[256\];\n    struct filename dummy_filename;\n    struct filename \*dummy_filename_ptr = \&dummy_filename;\n    int fd = AT_FDCWD;\n    int flags = 0;/' "$KSUD_INT_C"
        sed -i 's/strncpy_from_user(path, fn, 32);/strncpy_from_user(path, fn, sizeof(path));/' "$KSUD_INT_C"
        sed -i 's/ksu_handle_execveat_ksud(path, &argv);/dummy_filename.name = path;\n    ksu_handle_execveat(\&fd, \&dummy_filename_ptr, \&argv, NULL, \&flags);/' "$KSUD_INT_C"
        echo "[SUSFS-Fixup] ksud_integration.c: Fixed ksu_handle_execveat_ksud argument mismatch"
        # Ensure sucompat.h is included so ksu_handle_execveat() prototype is visible
        if ! grep -q 'feature/sucompat.h' "$KSUD_INT_C" 2>/dev/null; then
            if grep -q '#include "selinux/selinux.h"' "$KSUD_INT_C" 2>/dev/null; then
                sed -i '/#include "selinux\/selinux.h"/a #include "feature/sucompat.h"' "$KSUD_INT_C"
            else
                sed -i '1a #include "feature/sucompat.h"' "$KSUD_INT_C"
            fi
            echo "[SUSFS-Fixup] ksud_integration.c: Added feature/sucompat.h include for ksu_handle_execveat prototype"
        fi
    fi

    # Fix extern → include for ksu_handle_execveat_init
    if grep -q "extern int ksu_handle_execveat_init" "$KSUD_INT_C" 2>/dev/null; then
        if ! grep -q "feature/sucompat.h" "$KSUD_INT_C" 2>/dev/null; then
            sed -i '/#include "selinux\/selinux.h"/a #include "feature/sucompat.h"' "$KSUD_INT_C"
        fi
        sed -i '/^extern int ksu_handle_execveat_init/d' "$KSUD_INT_C"
    fi

    # Fix broken ksu_handle_vfs_fstat / ksu_sys_fstat / ksu_sys_read / kprobes
    if grep -q "void ksu_handle_vfs_fstat(int fd, loff_t \*kstat_size_ptr)" "$KSUD_INT_C" 2>/dev/null; then
        sed -i '/void ksu_handle_vfs_fstat(int fd, loff_t \*kstat_size_ptr)/,/^}/c\
static long (*orig_sys_fstat)(const struct pt_regs *regs);\
static long ksu_sys_fstat(const struct pt_regs *regs)\
{\
    unsigned int fd = PT_REGS_PARM1(regs);\
    void __user *statbuf = (void __user *)PT_REGS_PARM2(regs);\
    bool is_rc = false;\
    long ret;\
\
    struct file *file = fget(fd);\
    if (file) {\
        if (is_init_rc(file)) {\
            pr_info("stat init.rc\\n");\
            is_rc = true;\
        }\
        fput(file);\
    }\
\
    ret = orig_sys_fstat(regs);\
\
    if (is_rc) {\
        void __user *st_size_ptr = statbuf + offsetof(struct stat, st_size);\
        long size, new_size;\
        if (!copy_from_user_nofault(&size, st_size_ptr, sizeof(long))) {\
            new_size = size + ksu_rc_len;\
            pr_info("adding ksu_rc_len: %ld -> %ld", size, new_size);\
            if (!copy_to_user_nofault(st_size_ptr, &new_size, sizeof(long))) {\
                pr_info("added ksu_rc_len");\
            } else {\
                pr_err("add ksu_rc_len failed: statbuf 0x%lx", (unsigned long)st_size_ptr);\
            }\
        } else {\
            pr_err("read statbuf 0x%lx failed", (unsigned long)st_size_ptr);\
        }\
    }\
\
    return ret;\
}' "$KSUD_INT_C"
        echo "[SUSFS-Fixup] ksud_integration.c: Restored ksu_sys_fstat"
    fi

    if ! grep -q "ksu_sys_read(const struct pt_regs" "$KSUD_INT_C" 2>/dev/null; then
        sed -i '/^static unsigned int volumedown_pressed_count/i\
static long (*orig_sys_read)(const struct pt_regs *regs);\
static long ksu_sys_read(const struct pt_regs *regs)\
{\
    unsigned int fd = PT_REGS_PARM1(regs);\
    char __user **buf_ptr = (char __user **)&PT_REGS_PARM2(regs);\
    size_t *count_ptr = (size_t *)&PT_REGS_PARM3(regs);\
\
    ksu_handle_sys_read(fd, buf_ptr, count_ptr);\
    return orig_sys_read(regs);\
}\
' "$KSUD_INT_C"
        echo "[SUSFS-Fixup] ksud_integration.c: Restored ksu_sys_read"
    fi

    if ! grep -q "linux/kprobes.h" "$KSUD_INT_C" 2>/dev/null; then
        sed -i '1s/^/#include <linux\/kprobes.h>\n/' "$KSUD_INT_C"
        echo "[SUSFS-Fixup] ksud_integration.c: Restored linux/kprobes.h"
    fi

    # ksu_execve_hook_ksud wrapper (needed by syscall_event_bridge.c)
    if grep -q "syscall_event_bridge.o" "$KBUILD" 2>/dev/null && \
       ! grep -q "ksu_execve_hook_ksud" "$KSUD_INT_C" 2>/dev/null; then
        if [ -f "$KSUD_H" ] && ! grep -q "ksu_execve_hook_ksud" "$KSUD_H" 2>/dev/null; then
            if grep -q "ksu_handle_execveat_ksud" "$KSUD_H" 2>/dev/null; then
                sed -i '/ksu_handle_execveat_ksud/,/;/{/;/a\
\
void ksu_execve_hook_ksud(const struct pt_regs *regs);\
void ksu_stop_input_hook_runtime(void);
}' "$KSUD_H"
            fi
        fi

        cat >> "$KSUD_INT_C" << 'KSUD_COMPAT_EOF'

extern void ksu_stop_ksud_execve_hook(void);

void ksu_execve_hook_ksud(const struct pt_regs *regs)
{
    const char __user **filename_user_p = (const char __user **)&PT_REGS_PARM1(regs);
    const char __user *const __user *__argv = (const char __user *const __user *)PT_REGS_PARM2(regs);
    struct user_arg_ptr argv = { .ptr.native = __argv };
    char path[256];
    long ret;
    unsigned long addr;
    const char __user *fn;

    static const char app_process[] = "/system/bin/app_process";
    static bool first_zygote = true;
    static const char system_bin_init[] = "/system/bin/init";
    static bool init_second_stage_executed = false;

    if (!filename_user_p) return;
    addr = untagged_addr((unsigned long)*filename_user_p);
    fn = (const char __user *)addr;
    memset(path, 0, sizeof(path));
    ret = strncpy_from_user(path, fn, sizeof(path) - 1);
    if (ret <= 0) return;

    if (unlikely(!memcmp(path, system_bin_init, sizeof(system_bin_init) - 1) && __argv)) {
        char buf[16];
        if (!init_second_stage_executed &&
            check_argv(argv, 1, "second_stage", buf, sizeof(buf))) {
            pr_info("/system/bin/init second_stage executed\n");
            apply_kernelsu_rules();
            cache_sid();
            setup_ksu_cred();
            init_second_stage_executed = true;
        }
    }

    if (unlikely(first_zygote && !memcmp(path, app_process, sizeof(app_process) - 1) && __argv)) {
        char buf[16];
        if (check_argv(argv, 1, "-Xzygote", buf, sizeof(buf))) {
            pr_info("exec zygote, /data prepared, second_stage: %d\n", init_second_stage_executed);
            on_post_fs_data();
            first_zygote = false;
            ksu_stop_ksud_execve_hook();
        }
    }

#ifdef CONFIG_KSU_SUSFS
    {
        struct filename fname;
        fname.name = path;
        (void)ksu_handle_execveat_init(&fname, &argv, NULL);
    }
#endif
}
KSUD_COMPAT_EOF
        echo "[SUSFS-Fixup] ksud_integration.c: Added compat wrappers"
    fi

    # ksu_late_loaded restoration
    if grep -q "ksu_late_loaded" "$INIT_C" 2>/dev/null; then
        if ! grep -q "bool ksu_late_loaded" "$INIT_C" 2>/dev/null; then
            sed -i '/^struct cred \*ksu_cred;/a bool ksu_late_loaded;' "$INIT_C" 2>/dev/null || true
        fi
        if [ -f "$KSU_H" ] && ! grep -q "extern bool ksu_late_loaded" "$KSU_H" 2>/dev/null; then
            sed -i '/^extern struct cred \*ksu_cred;/a extern bool ksu_late_loaded;' "$KSU_H" 2>/dev/null || true
        fi
    fi

    # Remove dead symbol refs if corresponding .o not in Kbuild
    if [ -f "$KBUILD" ]; then
        if ! grep -q "tp_marker.o" "$KBUILD" 2>/dev/null && [ -f "$APP_PROFILE_C" ]; then
            sed -i '/ksu_set_task_tracepoint_flag/d' "$APP_PROFILE_C" 2>/dev/null || true
            sed -i '/ksu_clear_task_tracepoint_flag/d' "$APP_PROFILE_C" 2>/dev/null || true
        fi
        if ! grep -q "syscall_event_bridge.o" "$KBUILD" 2>/dev/null && [ -f "$KSUD_INT_C" ]; then
            sed -i '/extern void ksu_stop_ksud_execve_hook/d' "$KSUD_INT_C" 2>/dev/null || true
            sed -i '/ksu_stop_ksud_execve_hook/d' "$KSUD_INT_C" 2>/dev/null || true
        fi
    fi
}

fix_ksu_next_susfs_umount() {
    # Inject susfs_set_current_proc_umounted() into setuid_hook.c
    #
    # CRITICAL DESIGN: This flag MUST be set at the setuid_hook level, NOT inside
    # ksu_handle_umount(). The reason is ksu_handle_umount() has multiple early
    # returns (ksu_module_mounted, ksu_kernel_umount_enabled, ksu_cred) that
    # prevent the flag from being set when no modules are installed. But SUSFS
    # map hiding needs the flag regardless of module state.
    #
    # The flag must be CONDITIONAL (only for apps needing umount), matching
    # SukiSU's pattern. If set unconditionally, fs/exec.c's do_execveat_common
    # hook will skip su handling for ALL apps, breaking root.
    if [ -f "$SETUID_HOOK_C" ]; then
        # Ensure workqueue include
        if ! grep -q "linux/workqueue.h" "$SETUID_HOOK_C" 2>/dev/null; then
            sed -i '/#include <linux\/susfs_def.h>/a #include <linux/workqueue.h>' "$SETUID_HOOK_C"
        fi

        # Repair existing direct calls if found
        if grep -q "susfs_run_sus_path_loop()" "$SETUID_HOOK_C" 2>/dev/null; then
            echo "[SUSFS-Fixup] setuid_hook.c: Migrating direct loop call to deferred workqueue"
            # Delete the old-style loop call block completely
            sed -i '/#ifdef CONFIG_KSU_SUSFS_SUS_PATH/,/#endif/d' "$SETUID_HOOK_C"
            # Inject new deferred workqueue block before susfs_set_current_proc_umounted()
            sed -i '/susfs_set_current_proc_umounted/i #ifdef CONFIG_KSU_SUSFS_SUS_PATH\n\t\t{\n\t\t\textern struct work_struct susfs_extra_works;\n\t\t\tschedule_work(\&susfs_extra_works);\n\t\t\tflush_work(\&susfs_extra_works);\n\t\t}\n#endif' "$SETUID_HOOK_C"
        fi

        if ! grep -q "susfs_set_current_proc_umounted" "$SETUID_HOOK_C" 2>/dev/null; then
            sed -i '/ksu_handle_umount(old_uid, new_uid);/a \
\n#ifdef CONFIG_KSU_SUSFS\
\t/* Mark apps that need SUSFS hiding (map, mount, etc.).\
\t * This must be independent of ksu_module_mounted because SUSFS\
\t * map hiding needs this flag even when no modules are installed.\
\t * Only set for apps that should be umounted (not root-granted apps). */\
\tif (is_isolated_process(new_uid) ||\
\t    (is_appuid(new_uid) \&\& ksu_uid_should_umount(new_uid))) {\
#ifdef CONFIG_KSU_SUSFS_SUS_PATH\
\t\t{\
\t\t\textern struct work_struct susfs_extra_works;\
\t\t\tschedule_work(&susfs_extra_works);\
\t\t\tflush_work(&susfs_extra_works);\
\t\t}\
#endif\
\t\tsusfs_set_current_proc_umounted();\
\t}\
#endif' "$SETUID_HOOK_C"
            echo "[SUSFS-Fixup] setuid_hook.c: Added conditional susfs_set_current_proc_umounted (workqueue)"
        fi
    fi
}

fix_ksu_late_loaded() {
    local SELINUX_HIDE_C="$KSU_KERNEL/feature/selinux_hide.c"

    # Restore ksu_late_loaded removed by SUSFS patch.
    # The SUSFS patch completely strips ksu_late_loaded from init.c,
    # but fix_dirty_sepolicy restores upstream selinux_hide.c which uses it.
    # So we check selinux_hide.c (not init.c) for the reference.
    if [ -f "$SELINUX_HIDE_C" ] && grep -q "ksu_late_loaded" "$SELINUX_HIDE_C" 2>/dev/null && \
       [ -f "$INIT_C" ] && ! grep -q "bool ksu_late_loaded" "$INIT_C" 2>/dev/null; then
        # Find the right anchor — prefer ksu_cred, fallback to first struct/bool
        if grep -q "^struct cred \*ksu_cred;" "$INIT_C" 2>/dev/null; then
            sed -i '/^struct cred \*ksu_cred;/a bool ksu_late_loaded;' "$INIT_C"
        else
            # Insert after the last #include block
            sed -i '0,/^#include/{/^$/i bool ksu_late_loaded;
            }' "$INIT_C"
        fi
        # Restore #ifdef MODULE initialization block
        if grep -q "^int __init kernelsu_init(void)" "$INIT_C" 2>/dev/null; then
            sed -i '/^int __init kernelsu_init(void)/,/^{/{/^{/a\
#ifdef MODULE\n\tksu_late_loaded = (current->pid != 1);\n#else\n\tksu_late_loaded = false;\n#endif
}' "$INIT_C"
        fi
        echo "[SUSFS-Fixup] init.c: Restored ksu_late_loaded definition and init"
    fi
    if [ -f "$KSU_H" ] && [ -f "$SELINUX_HIDE_C" ] && \
       grep -q "ksu_late_loaded" "$SELINUX_HIDE_C" 2>/dev/null && \
       ! grep -q "ksu_late_loaded" "$KSU_H" 2>/dev/null; then
        if grep -q "^extern struct cred \*ksu_cred;" "$KSU_H" 2>/dev/null; then
            sed -i '/^extern struct cred \*ksu_cred;/a extern bool ksu_late_loaded;' "$KSU_H"
        else
            sed -i '/^#endif/i extern bool ksu_late_loaded;' "$KSU_H"
        fi
        echo "[SUSFS-Fixup] ksu.h: Restored extern ksu_late_loaded"
    fi
}

# ==========================================================================
# [SHARED] selinux_hide.c — remove undefined context_struct_compute_av_fn
# ==========================================================================
# The kernel's context_struct_compute_av in security/selinux/ss/services.c is
# static and not exported. selinux_hide.c has its own local copy, so remove
# the extern reference and always use the local implementation.
SELINUX_HIDE_C="$KSU_KERNEL/feature/selinux_hide.c"
if [ "$MANAGER" = "sukisu" ]; then
    # sukisu builds selinux_hide.c via ksu.c unity #include (the Kbuild/Makefile
    # exclusion above never matches), and fix_dirty_sepolicy is skipped for
    # sukisu, so the undefined *_fn references MUST be stripped here or the
    # link dies with "undefined symbol: context_struct_compute_av_fn".
    # sukisu uses the (void *)fn != NULL guard shape, so the sed below does
    # not match it — use python (same pattern as other fixups in this script).
    if [ -f "$SELINUX_HIDE_C" ] && grep -q "context_struct_compute_av_fn\|security_dump_masked_av_fn" "$SELINUX_HIDE_C" 2>/dev/null; then
        python3 -c "
import re, sys

path = '$SELINUX_HIDE_C'
with open(path, 'r') as f:
    src = f.read()

# Drop the multi-line extern declarations
src = re.sub(r'extern void context_struct_compute_av_fn\s*\(.*?\);', '', src, flags=re.S)
src = re.sub(r'extern void security_dump_masked_av_fn\s*\(.*?\);', '', src, flags=re.S)

# Collapse 'if ((void *)fn != NULL) { fn(...); } else { local(...); }'
# (and the plain 'if (fn) {' shape) into the direct local call
src = re.sub(
    r'if\s*\(\s*(?:\(void\s*\*\)\s*)?context_struct_compute_av_fn\s*(?:!=\s*NULL)?\s*\)\s*\{\s*'
    r'context_struct_compute_av_fn\s*\(.*?\);\s*\}\s*else\s*\{\s*'
    r'(context_struct_compute_av\s*\(.*?\);)\s*\}',
    r'\1', src, flags=re.S)

# Drop the security_dump_masked_av_fn conditional call (debug audit only).
# Two shapes: braceless 'if (c) fn(...);' and braced 'if (c) { fn(...); }'.
src = re.sub(
    r'if\s*\(\s*(?:\(void\s*\*\)\s*)?security_dump_masked_av_fn\s*(?:!=\s*NULL)?\s*\)\s*\{[^{}]*security_dump_masked_av_fn\s*\([^{}]*\);\s*\}',
    '', src, flags=re.S)
src = re.sub(
    r'if\s*\(\s*(?:\(void\s*\*\)\s*)?security_dump_masked_av_fn\s*(?:!=\s*NULL)?\s*\)[^{};]*security_dump_masked_av_fn\s*\([^{}]*\);',
    '', src, flags=re.S)

with open(path, 'w') as f:
    f.write(src)
"
        if grep -q "context_struct_compute_av_fn\|security_dump_masked_av_fn" "$SELINUX_HIDE_C" 2>/dev/null; then
            echo "[SUSFS-Fixup] ERROR: undefined *_fn references remain in selinux_hide.c after fixup" >&2
            exit 1
        fi
        echo "[SUSFS-Fixup] selinux_hide.c: Removed undefined context_struct_compute_av_fn and security_dump_masked_av_fn (sukisu)"
    fi
elif [ -f "$SELINUX_HIDE_C" ] && grep -q "context_struct_compute_av_fn\|security_dump_masked_av_fn" "$SELINUX_HIDE_C" 2>/dev/null; then
    # Remove the extern declarations (multi-line)
    sed -i '/^extern void context_struct_compute_av_fn/,/struct extended_perms \*xperms);/d' "$SELINUX_HIDE_C"
    sed -i '/^extern void security_dump_masked_av_fn/,/const char \*reason);/d' "$SELINUX_HIDE_C"
    sed -i '/if (context_struct_compute_av_fn) {/{
        N;N;N;N
        s/if (context_struct_compute_av_fn) {\n.*context_struct_compute_av_fn.*\n.*} else {\n.*context_struct_compute_av(.*\n.*}/context_struct_compute_av(policydb, scontext, tcontext, tclass, avd, NULL);/
    }' "$SELINUX_HIDE_C"
    # Remove security_dump_masked_av_fn conditional call (debug audit, safe to drop)
    sed -i '/if (security_dump_masked_av_fn)/,/masked, "bounds");/d' "$SELINUX_HIDE_C"
    echo "[SUSFS-Fixup] selinux_hide.c: Removed undefined context_struct_compute_av_fn and security_dump_masked_av_fn"
fi

# --------------------------------------------------------------------------
# fix_dirty_sepolicy — restore full selinux_hide hooks (DirtySepolicy counter)
# The SUSFS patch strips ALL THREE selinux_hide hooks from selinux_hide.c:
#   1. my_write_context  — intercepts /sys/fs/selinux/context (check_context)
#   2. my_write_access   — intercepts /sys/fs/selinux/access (compute_av)
#   3. my_setprocattr    — intercepts /proc/self/attr/current (setcurrent)
#
# Duck Detector / DirtySepolicy uses all three vectors to detect root.
# This function restores the upstream selinux_hide.c and applies only
# the minimal SUSFS compatibility changes needed.
# --------------------------------------------------------------------------
fix_dirty_sepolicy() {
    if [ ! -f "$SELINUX_HIDE_C" ]; then return; fi

    # Skip if all three hooks are already present
    if grep -q "my_write_context" "$SELINUX_HIDE_C" 2>/dev/null && \
       grep -q "my_write_access" "$SELINUX_HIDE_C" 2>/dev/null && \
       grep -q "my_setprocattr" "$SELINUX_HIDE_C" 2>/dev/null; then
        echo "[SUSFS-Fixup] selinux_hide.c: All DirtySepolicy hooks already present"
        return
    fi

    # Determine the KSU-Next source git repo
    KSU_GIT_DIR=""
    for candidate in \
        "$(dirname "$0")/.root_modules/KernelSU-Next" \
        "$(dirname "$0")/.root_modules/sukisu-ultra" \
        "$(dirname "$0")/.root_modules/BakaSU"; do
        if [ -d "$candidate/.git" ] && [ -f "$candidate/kernel/feature/selinux_hide.c" ]; then
            KSU_GIT_DIR="$candidate"
            break
        fi
    done
    if [ -z "$KSU_GIT_DIR" ]; then
        echo "[SUSFS-Fixup] selinux_hide.c: Cannot find KSU git repo, skipping DirtySepolicy fix"
        return
    fi

    # Step 1: Restore upstream selinux_hide.c from git HEAD
    echo "[SUSFS-Fixup] selinux_hide.c: Restoring upstream file from $(basename "$KSU_GIT_DIR")"
    (cd "$KSU_GIT_DIR" && git show HEAD:kernel/feature/selinux_hide.c) > "$SELINUX_HIDE_C"

    # Step 2: Make ksu_selinux_hide_running non-static (SUSFS needs it exported)
    sed -i 's/^static bool ksu_selinux_hide_running/bool ksu_selinux_hide_running/' "$SELINUX_HIDE_C"

    # Step 3: Remove undefined context_struct_compute_av_fn extern (it's static in kernel)
    # The upstream file uses it conditionally; replace with direct call
    if grep -q "context_struct_compute_av_fn" "$SELINUX_HIDE_C" 2>/dev/null; then
        sed -i '/^extern void context_struct_compute_av_fn/,/struct extended_perms \*xperms);/d' "$SELINUX_HIDE_C"
        sed -i '/if (context_struct_compute_av_fn) {/{
            N;N;N;N
            s/if (context_struct_compute_av_fn) {\n.*context_struct_compute_av_fn.*\n.*} else {\n.*context_struct_compute_av(.*\n.*}/context_struct_compute_av(policydb, scontext, tcontext, tclass, avd, NULL);/
        }' "$SELINUX_HIDE_C"
    fi

    # Step 4: Remove undefined security_dump_masked_av_fn extern (debug-only, safe to drop)
    if grep -q "security_dump_masked_av_fn" "$SELINUX_HIDE_C" 2>/dev/null; then
        sed -i '/^extern void security_dump_masked_av_fn/,/const char \*reason);/d' "$SELINUX_HIDE_C"
        sed -i '/if (security_dump_masked_av_fn)/,/masked, "bounds");/d' "$SELINUX_HIDE_C"
        # Remove the find_kernel_symbol_exact line for security_dump_masked_av
        sed -i '/security_dump_masked_av_fn = find_kernel_symbol_exact/,+3d' "$SELINUX_HIDE_C"
    fi

    # Step 5: Remove find_kernel_symbol_exact for context_struct_compute_av since we removed the fn ptr
    if grep -q "context_struct_compute_av_fn = find_kernel_symbol_exact" "$SELINUX_HIDE_C" 2>/dev/null; then
        sed -i '/context_struct_compute_av_fn = find_kernel_symbol_exact/,+3d' "$SELINUX_HIDE_C"
    fi

    echo "[SUSFS-Fixup] selinux_hide.c: Restored ALL DirtySepolicy hooks (write_context + write_access + setprocattr)"
}

# ==========================================================================
# Dispatch per manager
# ==========================================================================
# --------------------------------------------------------------------------
# fix_backup_sepolicy_leak — prevent backup_sepolicy from being overwritten
# --------------------------------------------------------------------------
fix_backup_sepolicy_leak() {
    local RULES_C="$KSU_KERNEL/selinux/rules.c"
    [ ! -f "$RULES_C" ] && RULES_C=".root_modules/KernelSU-Next/kernel/selinux/rules.c"
    if [ ! -f "$RULES_C" ]; then return; fi

    if grep -q "if (!backup_sepolicy) {" "$RULES_C" 2>/dev/null; then
        echo "[SUSFS-Fixup] rules.c: backup_sepolicy already guarded"
        return
    fi

    echo "[SUSFS-Fixup] rules.c: Guarding backup_sepolicy against dirty overwrites"

    python3 -c "
import sys
import re

with open('$RULES_C', 'r') as f:
    content = f.read()

pattern = r'(backup_sepolicy =\s+ksu_dup_sepolicy\(rcu_dereference_protected\(old_pol, lockdep_is_held\(&selinux_state\.policy_mutex\)\)\);.*?(?:pr_info\(\"backup sepolicy success!\\\\n\"\);|pr_info\(\"backup sepolicy success! latest_granting=%d\\\\n\", backup_sepolicy->latest_granting\);).*?\}\s*\n\s*\})'

def repl(m):
    block = m.group(1)
    indented = '\n'.join('    ' + line if line.strip() else line for line in block.split('\n'))
    return 'if (!backup_sepolicy) {\n' + indented + '\n    }'

new_content = re.sub(pattern, repl, content, flags=re.DOTALL)
with open('$RULES_C', 'w') as f:
    f.write(new_content)
"
}

# --------------------------------------------------------------------------
# fix_dirty_sepolicy_seqno — fix Seqno split in DirtySepolicy (Duck Detector)
# --------------------------------------------------------------------------
fix_dirty_sepolicy_seqno() {
    local RULES_C="$KSU_KERNEL/selinux/rules.c"
    local HIDE_C="$KSU_KERNEL/feature/selinux_hide.c"

    [ ! -f "$RULES_C" ] && RULES_C=".root_modules/KernelSU-Next/kernel/selinux/rules.c"
    [ ! -f "$HIDE_C" ] && HIDE_C=".root_modules/KernelSU-Next/kernel/feature/selinux_hide.c"

    if [ ! -f "$RULES_C" ] || [ ! -f "$HIDE_C" ]; then return; fi

    if grep -q "status->policyload" "$HIDE_C" 2>/dev/null && grep -q "status->policyload" "$RULES_C" 2>/dev/null; then
        echo "[SUSFS-Fixup] selinux_hide.c and rules.c: seqno split already fixed"
        return
    fi

    echo "[SUSFS-Fixup] Guarding against DirtySepolicy Seqno Split (Duck Detector)"

    python3 -c "
import sys
import re

def fix_rules_c(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # Comment out selinux_status_update_policyload to prevent sequence increment and status page allocation
    content = re.sub(r'(selinux_status_update_policyload\([^)]*\);)', r'// \g<1>', content)

    with open(filepath, 'w') as f:
        f.write(content)

def fix_hide_c(filepath):
    with open(filepath, 'r') as f:
        content = f.read()
    
    if 'status->policyload' in content:
        return

    pattern = r'(length = scnprintf\(buf, SIMPLE_TRANSACTION_LIMIT, \"%x %x %x %x %u %x\", avd\.allowed, 0xffffffff, avd\.auditallow,\s*avd\.auditdeny, avd\.seqno, avd\.flags\);)'

    def repl(m):
        return \"\"\"
    {
        struct page *spage = selinux_kernel_status_page();
        if (spage) {
            struct selinux_kernel_status *status = page_address(spage);
            if (status->policyload > 0) {
                avd.seqno = status->policyload;
            }
        }
    }
    \"\"\" + m.group(1)

    content = re.sub(pattern, repl, content)
    with open(filepath, 'w') as f:
        f.write(content)

fix_rules_c('$RULES_C')
fix_hide_c('$HIDE_C')
"
}

# ==========================================================================
# [SHARED] fix_app_zygote_bypass — Allow app_zygote in KernelSU
# ==========================================================================
fix_app_zygote_bypass() {
    local SELINUX_C="$KSU_KERNEL/selinux/selinux.c"
    local SELINUX_H="$KSU_KERNEL/selinux/selinux.h"
    local ALLOWLIST_H="$KSU_KERNEL/policy/allowlist.h"
    
    # Patch allowlist.h to support app_zygote isolated UIDs
    if [ -f "$ALLOWLIST_H" ]; then
        if ! grep -q "FIRST_APP_ZYGOTE_ISOLATED_UID" "$ALLOWLIST_H" 2>/dev/null; then
            echo "[SUSFS-Fixup] Patching allowlist.h to support app_zygote isolated UIDs"
            sed -i '/#define FIRST_ISOLATED_UID/i #define FIRST_APP_ZYGOTE_ISOLATED_UID 90000\n#define LAST_APP_ZYGOTE_ISOLATED_UID 98999' "$ALLOWLIST_H"
            sed -i 's/return appid >= FIRST_ISOLATED_UID && appid <= LAST_ISOLATED_UID;/return (appid >= FIRST_ISOLATED_UID \&\& appid <= LAST_ISOLATED_UID) || (appid >= FIRST_APP_ZYGOTE_ISOLATED_UID \&\& appid <= LAST_APP_ZYGOTE_ISOLATED_UID);/g' "$ALLOWLIST_H"
        else
            echo "[SUSFS-Fixup] allowlist.h: app_zygote isolated UID range already fixed"
        fi
    fi

    if [ ! -f "$SELINUX_C" ] || [ ! -f "$SELINUX_H" ]; then return; fi

    if grep -q "APP_ZYGOTE_CONTEXT" "$SELINUX_H" 2>/dev/null; then
        echo "[SUSFS-Fixup] selinux.c: app_zygote bypass already fixed"
        return
    fi

    echo "[SUSFS-Fixup] Patching selinux to support app_zygote for isolated services"

    # Add APP_ZYGOTE_CONTEXT to selinux.h
    sed -i '/#define ZYGOTE_CONTEXT/a #define APP_ZYGOTE_CONTEXT "u:r:app_zygote:s0"' "$SELINUX_H"

    # Add cached_app_zygote_sid to selinux.c
    sed -i '/static u32 cached_zygote_sid/a static u32 cached_app_zygote_sid __read_mostly = 0;' "$SELINUX_C"

    # Cache the sid
    sed -i '/err = security_secctx_to_secid(ZYGOTE_CONTEXT/i \
\terr = security_secctx_to_secid(APP_ZYGOTE_CONTEXT, strlen(APP_ZYGOTE_CONTEXT), \&cached_app_zygote_sid);\
\tif (err) {\
\t\tpr_warn("Failed to cache app_zygote SID: %d\\n", err);\
\t\tcached_app_zygote_sid = 0;\
\t} else {\
\t\tpr_info("Cached app_zygote SID: %u\\n", cached_app_zygote_sid);\
\t}\
' "$SELINUX_C"

    # Modify is_zygote to also return true for app_zygote
    sed -i 's/return is_sid_match(cred, cached_zygote_sid, ZYGOTE_CONTEXT);/return is_sid_match(cred, cached_zygote_sid, ZYGOTE_CONTEXT) || is_sid_match(cred, cached_app_zygote_sid, APP_ZYGOTE_CONTEXT);/g' "$SELINUX_C"
}

fix_context_struct_compute_av_link() {
    # NOTE: sed-based replacement for context_struct_compute_av conditional
    # was causing "sh: 1: Syntax error: word unexpected (expecting )" errors.
    # The fixup is deferred to manual review; core SUSFS path unaffected.
    return 0
}
# fix_context_struct_compute_av_link  # disabled - sed replacement causes bash syntax errors

case "$MANAGER" in
    bakasu|sukisu|yukisu)
        fix_sulog_type_mismatch
        fix_execveat_handlers
        fix_faccessat_signature
        if [ "$MANAGER" = "yukisu" ]; then
            fix_yukisu_adb_root
        fi
        # All use KernelSU-Next hooking architecture
        fix_ksu_next_kbuild
        fix_ksu_next_bridge
        fix_ksu_next_ksud
        # If it still has kprobe supercall, fix it, otherwise use next's
        if [ -f "$SUPERCALL_C" ] && grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then
            fix_kprobe_supercall
        else
            fix_ksu_next_supercall
        fi
        # Fix adb_root call signature mismatch in syscall_event_bridge.c
        if [ -f "$BRIDGE_C" ] && grep -q 'ksu_adb_root_handle_execve((struct pt_regs \*)regs)' "$BRIDGE_C" 2>/dev/null; then
            ADB_ROOT_C="$KSU_KERNEL/feature/adb_root.c"
            if [ -f "$ADB_ROOT_C" ] && grep -q 'ksu_adb_root_handle_execve(const char' "$ADB_ROOT_C" 2>/dev/null; then
                sed -i 's|ksu_adb_root_handle_execve((struct pt_regs \*)regs)|ksu_adb_root_handle_execve((const char *)PT_REGS_PARM1(regs), (void __user ***)\&PT_REGS_PARM3(regs))|' "$BRIDGE_C"
                echo "[SUSFS-Fixup] syscall_event_bridge.c: Fixed adb_root call signature"
            else
                echo "[SUSFS-Fixup] syscall_event_bridge.c: Skipping adb_root fix (1-arg signature)"
            fi
        fi
        # Restore ksu_sulog_capture_root_execve in event.c if missing
        if [ -f "$SULOG_EVENT_C" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_C" 2>/dev/null; then
            cat >> "$SULOG_EVENT_C" << 'SULOG_EXECVE_EOF'

struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user,
                                                              const char __user *const __user *argv_user, gfp_t gfp)
{
    struct user_arg_ptr _argv_wrap = { .ptr.native = argv_user };
    return ksu_sulog_capture(KSU_SULOG_EVENT_ROOT_EXECVE, filename_user, &_argv_wrap, gfp);
}
SULOG_EXECVE_EOF
            echo "[SUSFS-Fixup] sulog/event.c: Restored ksu_sulog_capture_root_execve"
        fi
        if [ -f "$SULOG_EVENT_H" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_H" 2>/dev/null; then
            sed -i '/ksu_sulog_capture_sucompat/i struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user, const char __user *const __user *argv_user, gfp_t gfp);' "$SULOG_EVENT_H"
        fi
        if [ "$MANAGER" != "sukisu" ]; then
            fix_dirty_sepolicy
        else
            echo "[SUSFS-Fixup] selinux_hide.c: Skipping DirtySepolicy hook restore for sukisu (known link/compile incompatibility with current SukiSU-Ultra builtin — see upstream v4.1.3 selinux_hide changes). Core SUSFS path/mount hiding unaffected; /sys/fs/selinux hiding layer reduced for this variant."
        fi
        fix_ksu_late_loaded
        fix_dirty_sepolicy_seqno
        fix_backup_sepolicy_leak
        fix_app_zygote_bypass
        # YukiSU-specific compat fixes (sh_user_path dup, execveat_ksud 4-arg, escape_to_root type)
        if [ "$MANAGER" = "yukisu" ]; then
            fix_yukisu_susfs_compat
        fi
        ;;
    ksu-next|kowsu)
        fix_sulog_type_mismatch
        fix_faccessat_signature
        fix_ksu_next_kbuild
        fix_ksu_next_bridge
        fix_ksu_next_supercall
        fix_ksu_next_ksud
        fix_execveat_handlers
        fix_ksu_next_susfs_umount
        # KSU-Next's sucompat.c uses _sucompat suffix for VFS hooks.
        # The SUSFS patch + kernel hooks in fs/open.c, fs/stat.c call
        # ksu_handle_faccessat / ksu_handle_stat (without _sucompat).
        # sucompat.h declares them but sucompat.c doesn't define them.
        # Add stubs that delegate to the version-gated implementations.
        if [ -f "$SUCOMPAT_C" ] && ! grep -q "^int ksu_handle_faccessat" "$SUCOMPAT_C" 2>/dev/null; then
            cat >> "$SUCOMPAT_C" << 'VFS_STUBS_EOF'

/* VFS hook stubs — fs/open.c and fs/stat.c call these names */
int ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode,
    int *__unused_flags)
{
    if (unlikely(!filename_user))
        return 0;
    char path[sizeof(su_path) + 1] = {0};
    strncpy_from_user(path, *filename_user, sizeof(path));
    if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
        *filename_user = sh_user_path();
    }
    return 0;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
int ksu_handle_stat(int *dfd, struct filename **filename, int *flags)
{
    static const char su[] = SU_PATH;
    static const char sh[] = "/system/bin/sh";
    if (unlikely(IS_ERR(*filename) || (*filename)->name == NULL))
        return 0;
    if (likely(memcmp((*filename)->name, su, sizeof(su))))
        return 0;
    memcpy((void *)((*filename)->name), sh, sizeof(sh));
    return 0;
}
#else
int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags)
{
    if (unlikely(!filename_user))
        return 0;
    char path[sizeof(su_path) + 1] = {0};
    strncpy_from_user(path, *filename_user, sizeof(path));
    if (unlikely(!memcmp(path, su_path, sizeof(su_path)))) {
        *filename_user = sh_user_path();
    }
    return 0;
}
#endif
VFS_STUBS_EOF
            echo "[SUSFS-Fixup] sucompat.c: Added ksu_handle_faccessat + ksu_handle_stat VFS stubs"
        fi
        # Fix adb_root call signature mismatch in syscall_event_bridge.c
        if [ -f "$BRIDGE_C" ] && grep -q 'ksu_adb_root_handle_execve((struct pt_regs \*)regs)' "$BRIDGE_C" 2>/dev/null; then
            ADB_ROOT_C="$KSU_KERNEL/feature/adb_root.c"
            if [ -f "$ADB_ROOT_C" ] && grep -q 'ksu_adb_root_handle_execve(const char' "$ADB_ROOT_C" 2>/dev/null; then
                sed -i 's|ksu_adb_root_handle_execve((struct pt_regs \*)regs)|ksu_adb_root_handle_execve((const char *)PT_REGS_PARM1(regs), (void __user ***)\&PT_REGS_PARM3(regs))|' "$BRIDGE_C"
                echo "[SUSFS-Fixup] syscall_event_bridge.c: Fixed adb_root call signature"
            else
                echo "[SUSFS-Fixup] syscall_event_bridge.c: Skipping adb_root fix (1-arg signature)"
            fi
        fi
        # Restore ksu_sulog_capture_root_execve in event.c if missing
        if [ -f "$SULOG_EVENT_C" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_C" 2>/dev/null; then
            cat >> "$SULOG_EVENT_C" << 'SULOG_EXECVE_EOF'

struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user,
                                                              const char __user *const __user *argv_user, gfp_t gfp)
{
    struct user_arg_ptr _argv_wrap = { .ptr.native = argv_user };
    return ksu_sulog_capture(KSU_SULOG_EVENT_ROOT_EXECVE, filename_user, &_argv_wrap, gfp);
}
SULOG_EXECVE_EOF
            echo "[SUSFS-Fixup] sulog/event.c: Restored ksu_sulog_capture_root_execve"
        fi
        if [ -f "$SULOG_EVENT_H" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_H" 2>/dev/null; then
            sed -i '/ksu_sulog_capture_sucompat/i struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user, const char __user *const __user *argv_user, gfp_t gfp);' "$SULOG_EVENT_H"
        fi
        fix_dirty_sepolicy
        fix_ksu_late_loaded
        fix_dirty_sepolicy_seqno
        fix_backup_sepolicy_leak
        fix_app_zygote_bypass
        ;;
    ksu)
        echo "[SUSFS-Fixup] Applying fixes for standard KernelSU ($MANAGER)..."
        fix_sulog_type_mismatch
        fix_execveat_handlers
        # Standard KSU uses the same Next-style hooking now
        fix_ksu_next_kbuild
        fix_ksu_next_bridge
        fix_ksu_next_ksud
        # Supercall fix
        if [ -f "$SUPERCALL_C" ] && grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then
            fix_kprobe_supercall
        else
            fix_ksu_next_supercall
        fi
        # Fix adb_root call signature mismatch
        if [ -f "$BRIDGE_C" ] && grep -q 'ksu_adb_root_handle_execve((struct pt_regs \*)regs)' "$BRIDGE_C" 2>/dev/null; then
            ADB_ROOT_C="$KSU_KERNEL/feature/adb_root.c"
            if [ -f "$ADB_ROOT_C" ] && grep -q 'ksu_adb_root_handle_execve(const char' "$ADB_ROOT_C" 2>/dev/null; then
                sed -i 's|ksu_adb_root_handle_execve((struct pt_regs \*)regs)|ksu_adb_root_handle_execve((const char *)PT_REGS_PARM1(regs), (void __user ***)\&PT_REGS_PARM3(regs))|' "$BRIDGE_C"
                echo "[SUSFS-Fixup] syscall_event_bridge.c: Fixed adb_root call signature"
            else
                echo "[SUSFS-Fixup] syscall_event_bridge.c: Skipping adb_root fix (1-arg signature)"
            fi
        fi
        # Restore ksu_sulog_capture_root_execve if missing
        if [ -f "$SULOG_EVENT_C" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_C" 2>/dev/null; then
            cat >> "$SULOG_EVENT_C" << 'SULOG_EXECVE_EOF'

struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user,
                                                              const char __user *const __user *argv_user, gfp_t gfp)
{
    struct user_arg_ptr _argv_wrap = { .ptr.native = argv_user };
    return ksu_sulog_capture(KSU_SULOG_EVENT_ROOT_EXECVE, filename_user, &_argv_wrap, gfp);
}
SULOG_EXECVE_EOF
            echo "[SUSFS-Fixup] sulog/event.c: Restored ksu_sulog_capture_root_execve"
        fi
        if [ -f "$SULOG_EVENT_H" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_H" 2>/dev/null; then
            sed -i '/ksu_sulog_capture_sucompat/i struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user, const char __user *const __user *argv_user, gfp_t gfp);' "$SULOG_EVENT_H"
        fi
        fix_dirty_sepolicy
        fix_ksu_late_loaded
        fix_dirty_sepolicy_seqno
        fix_backup_sepolicy_leak
        fix_app_zygote_bypass
        ;;
    *)
        echo "[SUSFS-Fixup] Unknown manager '$MANAGER' — applying best-effort fixes"
        fix_sulog_type_mismatch
        fix_execveat_handlers
        # If kprobe-based, fix it; if not, try ksu-next fixes
        if [ -f "$SUPERCALL_C" ] && grep -q "reboot_handler_pre" "$SUPERCALL_C" 2>/dev/null; then
            fix_kprobe_supercall
        else
            fix_ksu_next_kbuild
            fix_ksu_next_bridge
            fix_ksu_next_supercall
            fix_ksu_next_ksud
        fi
        # Fix adb_root call signature mismatch
        if [ -f "$BRIDGE_C" ] && grep -q 'ksu_adb_root_handle_execve((struct pt_regs \*)regs)' "$BRIDGE_C" 2>/dev/null; then
            ADB_ROOT_C="$KSU_KERNEL/feature/adb_root.c"
            if [ -f "$ADB_ROOT_C" ] && grep -q 'ksu_adb_root_handle_execve(const char' "$ADB_ROOT_C" 2>/dev/null; then
                sed -i 's|ksu_adb_root_handle_execve((struct pt_regs \*)regs)|ksu_adb_root_handle_execve((const char *)PT_REGS_PARM1(regs), (void __user ***)\&PT_REGS_PARM3(regs))|' "$BRIDGE_C"
                echo "[SUSFS-Fixup] syscall_event_bridge.c: Fixed adb_root call signature"
            else
                echo "[SUSFS-Fixup] syscall_event_bridge.c: Skipping adb_root fix (1-arg signature)"
            fi
        fi
        # Restore ksu_sulog_capture_root_execve if missing
        if [ -f "$SULOG_EVENT_C" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_C" 2>/dev/null; then
            cat >> "$SULOG_EVENT_C" << 'SULOG_EXECVE_EOF'

struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user,
                                                              const char __user *const __user *argv_user, gfp_t gfp)
{
    struct user_arg_ptr _argv_wrap = { .ptr.native = argv_user };
    return ksu_sulog_capture(KSU_SULOG_EVENT_ROOT_EXECVE, filename_user, &_argv_wrap, gfp);
}
SULOG_EXECVE_EOF
            echo "[SUSFS-Fixup] sulog/event.c: Restored ksu_sulog_capture_root_execve"
        fi
        if [ -f "$SULOG_EVENT_H" ] && ! grep -q "ksu_sulog_capture_root_execve" "$SULOG_EVENT_H" 2>/dev/null; then
            sed -i '/ksu_sulog_capture_sucompat/i struct ksu_sulog_pending_event *ksu_sulog_capture_root_execve(const char __user *filename_user, const char __user *const __user *argv_user, gfp_t gfp);' "$SULOG_EVENT_H"
        fi
        fix_dirty_sepolicy
        fix_ksu_late_loaded
        fix_dirty_sepolicy_seqno
        fix_backup_sepolicy_leak
        fix_app_zygote_bypass
        ;;
esac

echo "[SUSFS-Fixup] All compatibility fixups applied for $MANAGER!"

# --------------------------------------------------------------------------
# fix_backup_sepolicy_leak — prevent backup_sepolicy from being overwritten
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
# Guard call site of ksu_handle_execve_sucompat in syscall_event_bridge.c
# The definition in sucompat.c is guarded behind #ifndef CONFIG_KSU_SUSFS,
# but this call site was unconditional -> "undefined symbol" at link time
# when SUSFS is enabled.
# --------------------------------------------------------------------------
if [ -f "$BRIDGE_C" ] && grep -q "} else if (ksu_su_compat_enabled) {" "$BRIDGE_C" 2>/dev/null; then
    sed -i '/} else if (ksu_su_compat_enabled) {/,/^    }$/c\
    }\
#ifndef CONFIG_KSU_SUSFS\
    else if (ksu_su_compat_enabled) {\
        ret = ksu_handle_execve_sucompat(filename_user, orig_nr, regs);\
        ksu_sulog_emit_pending(pending_root_execve, ret, GFP_KERNEL);\
        return ret;\
    }\
#endif' "$BRIDGE_C"
    echo "[SUSFS-Fixup] syscall_event_bridge.c: Guarded ksu_handle_execve_sucompat call site for SUSFS"
fi

# NOTE: do NOT add a second fixup here that deletes the
# `struct selinux_policy *pol, *old_pol = selinux_state.policy;` line.
# The sukisu-scoped fixup at the top of this script already comments out the
# outer plain declaration (line ~154) for 70fa0e09, and in known-good
# b20dee70 that assigning line is the ONLY declaration — deleting it (as a
# previous version of this block did) strips pol/old_pol entirely and the
# build dies with "use of undeclared identifier".
