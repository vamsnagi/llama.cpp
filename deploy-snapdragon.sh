#!/usr/bin/env bash
# deploy-snapdragon.sh
# Pushes the pkg-snapdragon/llama.cpp package to the Android test device
# and sets executable permissions on all binaries.

set -euo pipefail

# vm7
# DEVICE="cd756a6b"
# HOST="morph-drental-vm-7"
#-----

#vm-02
# DEVICE="8faa30c1"
# HOST="morph-awusb-vm-02"
#----

# Defaults may be overridden by a positional serial or --serial.  Leave HOST
# empty to use the local adb server (the normal case on this VM).
DEVICE="bc7689c"
HOST=""

#vm-03
#DEVICE="128b7864"
#HOST="morph-awusb-vm-03"
#----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/pkg-snapdragon/llama.cpp"
DEVICE_DEST="/data/local/tmp"
QUARTZ_ROOT="${SCRIPT_DIR}/../quartz"
NSP_SKEL="${QUARTZ_ROOT}/hexagon/build-v81/libnsp_freq_skel.so"
QUARTZ_TOOLS_DIR="${QUARTZ_ROOT}/build/android-arm64/tools"

usage() {
    echo "usage: $0 [SERIAL] [--serial SERIAL] [--host ADB_HOST]"
    echo "  SERIAL defaults to ${DEVICE}; omit --host to use local adb."
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --serial)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            DEVICE="$2"
            shift 2
            ;;
        --host)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            HOST="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            DEVICE="$1"
            shift
            ;;
    esac
done

ADB=(adb -s "${DEVICE}")
if [ -n "${HOST}" ]; then
    ADB=(adb -H "${HOST}" -s "${DEVICE}")
fi

if [ ! -d "${PKG_DIR}" ]; then
	    echo "ERROR: Package directory not found: ${PKG_DIR}"
	        echo "       Run ./build-snapdragon.sh first."
		    exit 1
fi
QUARTZ_TOOLS=()
if [ -d "${QUARTZ_TOOLS_DIR}" ]; then
    for tool_dir in "${QUARTZ_TOOLS_DIR}"/quartz-*; do
        tool="${tool_dir}/${tool_dir##*/}"
        if [ -f "${tool}" ]; then
            QUARTZ_TOOLS+=("${tool}")
        fi
    done
fi
clear


echo "==> Deploying to device ${DEVICE}"
echo "    Source : ${PKG_DIR}"
echo "    Dest   : ${DEVICE_DEST}/llama.cpp"

echo "==> Pushing package via adb"
"${ADB[@]}" push "${PKG_DIR}" "${DEVICE_DEST}/"

if [ -f "${NSP_SKEL}" ]; then
    echo "==> Pushing v81 NSP FastRPC skeleton"
    "${ADB[@]}" shell "mkdir -p ${DEVICE_DEST}/llama.cpp/lib"
    "${ADB[@]}" push "${NSP_SKEL}" "${DEVICE_DEST}/llama.cpp/lib/libnsp_freq_skel.so"
else
    echo "==> WARNING: NSP FastRPC skeleton not found; skipping: ${NSP_SKEL}" >&2
fi

if [ "${#QUARTZ_TOOLS[@]}" -gt 0 ]; then
    echo "==> Pushing Quartz tools (${#QUARTZ_TOOLS[@]} executables)"
    "${ADB[@]}" shell "mkdir -p ${DEVICE_DEST}/llama.cpp/tools"
    for tool in "${QUARTZ_TOOLS[@]}"; do
        tool_name="$(basename "${tool}")"
        tool_dest="${DEVICE_DEST}/llama.cpp/tools/${tool_name}"
        # Preserve the nested layout from earlier build-tree deployments.
        if "${ADB[@]}" shell "test -d '${tool_dest}'"; then
            tool_dest="${tool_dest}/${tool_name}"
        fi
        "${ADB[@]}" push "${tool}" "${tool_dest}"
        "${ADB[@]}" shell "chmod 755 '${tool_dest}'"
    done
else
    echo "==> WARNING: no built Quartz tools found; skipping: ${QUARTZ_TOOLS_DIR}" >&2
fi

echo "==> Setting permissions on binaries"
"${ADB[@]}" shell "find '${DEVICE_DEST}/llama.cpp/bin' -type f -exec chmod 755 {} +"
"${ADB[@]}" shell "find '${DEVICE_DEST}/llama.cpp/lib' -type f -name '*.so*' -exec chmod 755 {} +"

if [ -f "${SCRIPT_DIR}/sample-prompt.txt" ]; then
    echo "==> Pushing sample-prompt.txt"
    "${ADB[@]}" push "${SCRIPT_DIR}/sample-prompt.txt" "${DEVICE_DEST}/llama.cpp/"
else
    echo "==> WARNING: sample-prompt.txt not found; skipping" >&2
fi

echo ""
echo "==> Deployment complete."
echo "    Binaries are at ${DEVICE_DEST}/llama.cpp/bin/ on device ${DEVICE}"
echo "    Quartz tools are at ${DEVICE_DEST}/llama.cpp/tools/"

