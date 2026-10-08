#!/bin/bash
set -eo pipefail

CLANG_VARIANT="${1:-neutron}"
TOOLCHAIN_DIR="${HOME}/toolchains/${CLANG_VARIANT}-clang"

if [ "${CLANG_VARIANT}" != "neutron" ] && [ -x "${TOOLCHAIN_DIR}/bin/clang" ]; then
  CLANG_BIN="${TOOLCHAIN_DIR}/bin"
  VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "cached")
  case "${CLANG_VARIANT}" in
    cirrus) COMPILER_STRING="Cirrus Clang ${VER}" ;;
    aosp)   COMPILER_STRING="AOSP Clang ${VER}" ;;
    weebx)  COMPILER_STRING="WeebX Clang ${VER}" ;;
    zyc)    COMPILER_STRING="ZyC Clang ${VER}" ;;
    *)      COMPILER_STRING="${CLANG_VARIANT} Clang ${VER}" ;;
  esac
  echo "CLANG_VARIANT=${CLANG_VARIANT}" >> "${GITHUB_ENV}"
  echo "CLANG_PATH=${CLANG_BIN}" >> "${GITHUB_ENV}"
  echo "${CLANG_BIN}" >> "${GITHUB_PATH}"
  echo "KBUILD_COMPILER_STRING=${COMPILER_STRING}" >> "${GITHUB_ENV}"
  echo "[+] Clang ready (cached): ${CLANG_BIN}"
  "${CLANG_BIN}/clang" --version
  exit 0
fi

echo "[*] Setting up Clang: ${CLANG_VARIANT}"

case "${CLANG_VARIANT}" in
  neutron)
    mkdir -p "${HOME}/toolchains/neutron-clang"
    cd "${HOME}/toolchains/neutron-clang"
    # antman uses `wget -q` with no retries; a single 403/dead-mirror response
    # from archlinux.org kills it instantly. Force wget-level retries globally.
    cat > "${HOME}/.wgetrc" << 'WGETRC_EOF'
tries = 5
waitretry = 10
timeout = 30
WGETRC_EOF
    curl --max-time 60 --retry 3 -Lo antman https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman
    chmod +x antman
    for i in 1 2 3 4 5; do
      ./antman -S 2>&1 | tee antman-s.log && break
      echo "[!] antman -S failed (attempt ${i}/5), retrying in 15s..."
      sleep 15
      [ "${i}" -eq 5 ] && { echo "[!] antman -S failed after 5 attempts"; exit 1; }
    done
    for i in 1 2 3 4 5; do
      ./antman --patch=glibc 2>&1 | tee antman-glibc.log && break
      echo "[!] antman --patch=glibc failed (attempt ${i}/5), retrying in 15s..."
      sleep 15
      [ "${i}" -eq 5 ] && { echo "[!] antman --patch=glibc failed after 5 attempts"; exit 1; }
    done
    CLANG_BIN="${HOME}/toolchains/neutron-clang/bin"
    NEUTRON_VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "latest")
    COMPILER_STRING="Neutron Clang ${NEUTRON_VER}"
    ;;
  cirrus)
    CIRRUS_URL=$(curl -s --max-time 30 https://api.github.com/repos/greenforce-project/greenforce_clang/releases/latest \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(next((x['browser_download_url'] for x in d.get('assets',[]) if x['name'].endswith('.tar.gz')), ''))")
    if [ -z "${CIRRUS_URL}" ]; then
      echo "[!] Cirrus release not found"
      exit 1
    fi
    echo "[*] Cirrus URL: ${CIRRUS_URL}"
    mkdir -p "${HOME}/toolchains/cirrus-clang"
    curl -fL --retry 5 --retry-delay 15 --retry-all-errors -C - --max-time 300 -o /tmp/cirrus-clang.tar.gz "${CIRRUS_URL}" || { echo "[!] Cirrus clang download failed/timed out"; exit 1; }
    tar -xf /tmp/cirrus-clang.tar.gz -C "${HOME}/toolchains/cirrus-clang" --strip-components=1
    rm /tmp/cirrus-clang.tar.gz
    CLANG_BIN="${HOME}/toolchains/cirrus-clang/bin"
    GF_VERSION=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "23.0.0")
    COMPILER_STRING="Cirrus Clang ${GF_VERSION}"
    ;;
  aosp)
    CLANG_VER="r596125"
    AOSP_TAG="android-17.0.0_r1"
    AOSP_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/${AOSP_TAG}/clang-${CLANG_VER}.tar.gz"
    echo "[*] AOSP clang latest: ${CLANG_VER} (tag: ${AOSP_TAG})"
    mkdir -p "${HOME}/toolchains/aosp-clang"
    curl -fL --retry 8 --retry-delay 15 --retry-all-errors --retry-connrefused -C - --max-time 300 -o /tmp/aosp-clang.tar.gz "${AOSP_URL}" || { echo "[!] Failed to download AOSP clang ${CLANG_VER} from tag ${AOSP_TAG} after retries (server may be down for an extended period)"; exit 1; }
    tar -xf /tmp/aosp-clang.tar.gz -C "${HOME}/toolchains/aosp-clang"
    rm /tmp/aosp-clang.tar.gz
    CLANG_BIN="${HOME}/toolchains/aosp-clang/bin"
    AOSP_VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "${CLANG_VER}")
    COMPILER_STRING="AOSP Clang ${AOSP_VER} (${CLANG_VER})"
    ;;
  weebx)
    WEEBX_URL=$(curl -s --max-time 30 https://raw.githubusercontent.com/XSans0/WeebX-Clang/main/main/link.txt)
    [ -z "${WEEBX_URL}" ] && { echo "[!] WeebX URL not found"; exit 1; }
    mkdir -p "${HOME}/toolchains/weebx-clang"
    curl -fL --retry 5 --retry-delay 15 --retry-all-errors -C - --max-time 300 -o /tmp/weebx-clang.tar.gz "${WEEBX_URL}" || { echo "[!] WeebX clang download failed/timed out"; exit 1; }
    tar -xf /tmp/weebx-clang.tar.gz -C "${HOME}/toolchains/weebx-clang" --strip-components=1
    rm /tmp/weebx-clang.tar.gz
    CLANG_BIN="${HOME}/toolchains/weebx-clang/bin"
    WX_VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "latest")
    COMPILER_STRING="WeebX Clang ${WX_VER}"
    ;;
  zyc)
    ZYC_URL=$(curl -sL --max-time 30 https://raw.githubusercontent.com/ZyCromerZ/Clang/main/Clang-main-link.txt | tr -d '[:space:]')
    echo "[*] ZyC URL: ${ZYC_URL}"
    mkdir -p "${HOME}/toolchains/zyc-clang"
    if [ -z "$ZYC_URL" ]; then
      echo "[-] ZyC: Clang-main-link.txt is empty or unreachable. ZyC may be down."
      echo "[-] Please choose a different toolchain (neutron/cirrus/weebx)."
      exit 1
    fi
    curl -L --fail --retry 5 --retry-delay 15 --retry-all-errors -C - --max-time 300 -o /tmp/zyc-clang.tar.gz "${ZYC_URL}" || {
      echo "[-] ZyC: download failed. Server may be down."
      echo "[-] Please choose a different toolchain (neutron/cirrus/weebx)."
      exit 1
    }
    echo "[*] Building ZyC tar index..."
    tar -tf /tmp/zyc-clang.tar.gz > /tmp/zyc-index.txt 2>/dev/null
    echo "[*] ZyC tar structure (first 10):"
    head -10 /tmp/zyc-index.txt
    echo "[*] ZyC bin location:"
    grep -m3 'bin/clang' /tmp/zyc-index.txt
    STRIP=0
    BIN_PATH=$(grep -m1 'bin/clang$' /tmp/zyc-index.txt)
    [ -z "$BIN_PATH" ] && { echo "[!] bin/clang not found in ZyC tarball"; exit 1; }
    DEPTH=$(echo "$BIN_PATH" | tr '/' '\n' | wc -l)
    STRIP=$(( DEPTH - 2 ))
    [ "$STRIP" -lt 0 ] && STRIP=0
    echo "[*] bin/clang found at: ${BIN_PATH} -> strip-components=${STRIP}"
    tar -xf /tmp/zyc-clang.tar.gz -C "${HOME}/toolchains/zyc-clang" --strip-components=${STRIP}
    rm /tmp/zyc-clang.tar.gz
    CLANG_BIN="${HOME}/toolchains/zyc-clang/bin"
    ZYC_VER=$("${CLANG_BIN}/clang" --version | head -n1 | grep -oP 'clang version \K[0-9.]+' || echo "latest")
    COMPILER_STRING="ZyC Clang ${ZYC_VER}"
    ;;
  *)
    echo "[!] Unknown clang variant: ${CLANG_VARIANT}"
    exit 1
    ;;
esac

echo "CLANG_VARIANT=${CLANG_VARIANT}" >> "${GITHUB_ENV}"
echo "CLANG_PATH=${CLANG_BIN}" >> "${GITHUB_ENV}"
echo "${CLANG_BIN}" >> "${GITHUB_PATH}"
echo "KBUILD_COMPILER_STRING=${COMPILER_STRING}" >> "${GITHUB_ENV}"
echo "[+] Clang ready: ${CLANG_BIN}"
"${CLANG_BIN}/clang" --version
