#!/usr/bin/env bash
# Builds llama.cpp for Snapdragon Android using the toolchain Docker image.
# Produces pkg-snapdragon/llama.cpp for deployment to the device.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUARTZ_SRC_ROOT="${QUARTZ_SRC_ROOT:-${QUARTZ_SOURCE:-}}"
QUARTZ_SDK_ROOT="${QUARTZ_SDK_ROOT:-${QUARTZ_SDK:-}}"
QUARTZ_INPUT=""
CMAKE_ARGS=()

usage() {
    echo "Usage: $0 [--quartz-source PATH | --quartz-sdk PATH] [cmake arguments...]"
    echo "       -DBUILD_WITH_QUARTZ=ON enables llama-quartz-bench."
    echo "       -DQUARTZ_SRC_ROOT=PATH or -DQUARTZ_SDK_ROOT=PATH selects the dependency."
    echo "       Matching environment variables can supply the paths instead."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quartz-source|--quartz-sdk|--quartz-source=*|--quartz-sdk=*|-DQUARTZ_SRC_ROOT=*|-DQUARTZ_SRC_ROOT:PATH=*|-DQUARTZ_SDK_ROOT=*|-DQUARTZ_SDK_ROOT:PATH=*)
            option="${1%%=*}"
            case "$option" in
                -DQUARTZ_SRC_ROOT*) option=--quartz-source ;;
                -DQUARTZ_SDK_ROOT*) option=--quartz-sdk ;;
            esac
            if [[ -n "$QUARTZ_INPUT" && "$QUARTZ_INPUT" != "$option" ]]; then
                echo "error: choose either --quartz-source or --quartz-sdk." >&2
                exit 2
            fi
            QUARTZ_INPUT="$option"
            if [[ "$1" == *=* ]]; then
                value="${1#*=}"
                shift
            else
                [[ $# -ge 2 ]] || { echo "error: $option requires a path." >&2; exit 2; }
                value="$2"
                shift 2
            fi
            [[ -n "$value" && "$value" != -* ]] || { echo "error: $option requires a path." >&2; exit 2; }
            if [[ "$option" == "--quartz-source" ]]; then
                QUARTZ_SRC_ROOT="$value"
                QUARTZ_SDK_ROOT=""
            else
                QUARTZ_SDK_ROOT="$value"
                QUARTZ_SRC_ROOT=""
            fi
            ;;
        -h|--help) usage; exit 0 ;;
        *) CMAKE_ARGS+=("$1"); shift ;;
    esac
done

DOCKER_VOLUMES=(--volume "${SCRIPT_DIR}:/workspace")
# Clear the previous dependency selection when reusing a build directory.
QUARTZ_ARGS=(-DQUARTZ_SRC_ROOT= -DQUARTZ_SDK_ROOT=)
if [[ -n "$QUARTZ_SRC_ROOT" && -n "$QUARTZ_SDK_ROOT" ]]; then
    echo "error: set only one of QUARTZ_SRC_ROOT or QUARTZ_SDK_ROOT." >&2
    exit 2
elif [[ -n "$QUARTZ_SDK_ROOT" ]]; then
    [[ -d "$QUARTZ_SDK_ROOT" ]] || { echo "error: Quartz SDK directory not found: $QUARTZ_SDK_ROOT" >&2; exit 2; }
    QUARTZ_SDK_ROOT="$(cd "$QUARTZ_SDK_ROOT" && pwd)"
    DOCKER_VOLUMES+=(--volume "${QUARTZ_SDK_ROOT}:/quartz-sdk:ro")
    QUARTZ_ARGS+=(-DQUARTZ_SDK_ROOT=/quartz-sdk)
elif [[ -n "$QUARTZ_SRC_ROOT" ]]; then
    [[ -f "$QUARTZ_SRC_ROOT/CMakeLists.txt" ]] || { echo "error: Quartz source not found: $QUARTZ_SRC_ROOT" >&2; exit 2; }
    QUARTZ_SRC_ROOT="$(cd "$QUARTZ_SRC_ROOT" && pwd)"
    DOCKER_VOLUMES+=(--volume "${QUARTZ_SRC_ROOT}:/quartz:ro")
    QUARTZ_ARGS+=(-DQUARTZ_SRC_ROOT=/quartz)
fi

echo "==> Starting Snapdragon Android build in ${SCRIPT_DIR}"
# Pass each CMake argument separately so spaces and wildcard characters survive Docker.
docker run --rm \
    -u "$(id -u):$(id -g)" \
    "${DOCKER_VOLUMES[@]}" \
    --platform linux/amd64 \
    ghcr.io/snapdragon-toolchain/arm64-android:v0.7 \
    bash -c '
        set -euo pipefail
        cd /workspace
        cp docs/backend/snapdragon/CMakeUserPresets.json .
        cmake --preset arm64-android-snapdragon-release -B build-snapdragon "$@"
        cmake --build build-snapdragon
        cmake --install build-snapdragon --prefix pkg-snapdragon/llama.cpp
    ' bash "${QUARTZ_ARGS[@]}" "${CMAKE_ARGS[@]}"

echo "==> Build complete: ${SCRIPT_DIR}/pkg-snapdragon/llama.cpp"
echo "    Run ./deploy-snapdragon.sh to push it to the device."
