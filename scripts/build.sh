#!/bin/bash
set -eE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/functions.sh"

ENGINE_REPORTED=""
report_failure_once() {
  [ -n "${PIN_KEY:-}" ] || return 0
  [ -z "$ENGINE_REPORTED" ] || return 0
  ENGINE_REPORTED=1
  local stage="${CURRENT_BUILD_STAGE:-unknown}"
  local root_candidate_var="CANDIDATE_${PIN_PREFIX}"
  local root_is_candidate="${!root_candidate_var:-false}"
  local susfs_key="susfs4ksu" susfs_prefix="SUSFS4KSU"
  local susfs_candidate_var="CANDIDATE_${susfs_prefix}"
  local susfs_is_candidate="${!susfs_candidate_var:-false}"
  echo "[!] Build failed during stage: ${stage}"
  if [ "$root_is_candidate" == "true" ] && [ "$susfs_is_candidate" == "true" ]; then
    echo "[!] Ambiguous failure (unguarded error): $PIN_KEY and susfs4ksu are both new candidates — skip auto-blacklist. Check manually."
  else
    [ "$root_is_candidate" == "true" ] && bash "${SCRIPT_DIR}/engine.sh" failure "$PIN_KEY" "$PIN_PREFIX" "$stage"
    [ "$susfs_is_candidate" == "true" ] && bash "${SCRIPT_DIR}/engine.sh" failure "$susfs_key" "$susfs_prefix" "$stage"
    true
  fi
}
trap report_failure_once ERR

LIB_ORDER=(
  defaults.sh
  adjust_inputs.sh
  root_setup.sh
  branding.sh
  baseband_guard.sh
  rekernel.sh
  bakasu_fixes.sh
  clang_flags.sh
  kconfig.sh
  compile.sh
  package.sh
)

run_all_libs() {
  for name in "${LIB_ORDER[@]}"; do
    f="$SCRIPT_DIR/lib/$name"
    CURRENT_BUILD_STAGE="$name"
    echo "[orchestrator] sourcing $(basename "$f")"
    source "$f"
  done
}

run_all_libs

if [ -n "${PIN_KEY:-}" ]; then
  bash "${SCRIPT_DIR}/engine.sh" success "$PIN_KEY" "$PIN_PREFIX"
  susfs_key="susfs4ksu" susfs_prefix="SUSFS4KSU"
  bash "${SCRIPT_DIR}/engine.sh" success "$susfs_key" "$susfs_prefix"
fi

echo "[+] Build succeeded."
