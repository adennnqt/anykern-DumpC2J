#!/bin/bash
log()   { echo "[+] $*"; }
warn()  { echo "[!] $*" >&2; }
error() { echo "[-] $*" >&2; exit 1; }
run_quiet() { "$@" > /dev/null 2>&1 || true; }

# Shared upstream source registry — single source of truth for scout.sh + upstream_check.sh
declare -A DUMPC2J_SOURCES=(
  [sukisu_root]="SukiSU-Ultra (root)|https://api.github.com/repos/SukiSU-Ultra/SukiSU-Ultra/commits/main|.sha"
  [sukisu_susfs]="SukiSU-Ultra (susfs)|https://api.github.com/repos/SukiSU-Ultra/SukiSU-Ultra/commits/builtin|.sha"
  [bakasu_root]="BakaSU (root)|https://api.github.com/repos/Baka-SU/BakaSU/commits/main|.sha"
  [bakasu_susfs]="BakaSU (susfs)|https://api.github.com/repos/Baka-SU/BakaSU/commits/main|.sha"
  [ksunext_root]="KernelSU-Next (root)|https://api.github.com/repos/KernelSU-Next/KernelSU-Next/commits/dev|.sha"
  [ksunext_susfs]="KernelSU-Next-susfs (pershoot)|https://api.github.com/repos/pershoot/KernelSU-Next/commits/dev-susfs|.sha"
  [susfs4ksu]="SUSFS4KSU (simon)|https://gitlab.com/api/v4/projects/simonpunk%2Fsusfs4ksu/repository/commits/gki-android15-6.6|.id"
)

source_label()  { local IFS='|'; local parts=(${DUMPC2J_SOURCES[$1]}); echo "${parts[0]}"; }
source_url()    { local IFS='|'; local parts=(${DUMPC2J_SOURCES[$1]}); echo "${parts[1]}"; }
source_filter() { local IFS='|'; local parts=(${DUMPC2J_SOURCES[$1]}); echo "${parts[2]}"; }
