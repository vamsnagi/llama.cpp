#!/usr/bin/env bash
# build-snapdragon.sh
# Builds llama.cpp for Snapdragon-based Android devices using the toolchain Docker image.
# Produces a pkg-snapdragon/llama.cpp package ready to be pushed to the device.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Usage:
#   ./run-build.sh [--quartz-source PATH] [cmake arguments...]
#
# QUARTZ_SOURCE remains supported as an environment-variable override.
QUARTZ_SOURCE="${QUARTZ_SOURCE:-${SCRIPT_DIR}/../quartz}"
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quartz-source)
            [[ $# -ge 2 ]] || { echo "error: --quartz-source requires a path" >&2; exit 2; }
            QUARTZ_SOURCE="$2"
            shift 2
            ;;
        --quartz-source=*)
            QUARTZ_SOURCE="${1#*=}"
            [[ -n "${QUARTZ_SOURCE}" ]] || { echo "error: --quartz-source requires a path" >&2; exit 2; }
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--quartz-source PATH] [cmake arguments...]"
            echo "       QUARTZ_SOURCE=PATH $0 [cmake arguments...]"
            exit 0
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

# Extra cmake args forwarded to the configure step (e.g. -DHEXAGON_HTP_DEBUG=ON)
CMAKE_EXTRA_ARGS="${POSITIONAL_ARGS[*]-}"

QUARTZ_CONTAINER_ROOT="/quartz"
DOCKER_VOLUMES=(--volume "${SCRIPT_DIR}:/workspace")
if [[ -f "${QUARTZ_SOURCE}/CMakeLists.txt" ]]; then
    DOCKER_VOLUMES+=(--volume "${QUARTZ_SOURCE}:${QUARTZ_CONTAINER_ROOT}:ro")
    CMAKE_EXTRA_ARGS="${CMAKE_EXTRA_ARGS} -DQUARTZ_ROOT=${QUARTZ_CONTAINER_ROOT}"
else
    echo "==> Quartz source not found at ${QUARTZ_SOURCE}"
    echo "    Pass --quartz-source /path/to/quartz or set QUARTZ_SOURCE."
fi

echo "==> Starting Snapdragon Android build"
echo "    Working directory: ${SCRIPT_DIR}"

echo $CMAKE_EXTRA_ARGS

docker run --rm \
	    -u "$(id -u):$(id -g)" \
	        "${DOCKER_VOLUMES[@]}" \
	    --platform linux/amd64 \
	        -e CMAKE_EXTRA_ARGS="${CMAKE_EXTRA_ARGS}" \
	    ghcr.io/snapdragon-toolchain/arm64-android:v0.7 \
			        bash -c '
        set -euo pipefail
	        cd /workspace

		        echo "==> Copying CMakeUserPresets.json"
			        cp docs/backend/snapdragon/CMakeUserPresets.json .

				        echo "==> Configuring build (arm64-android-snapdragon-release)"
					        cmake --preset arm64-android-snapdragon-release -B build-snapdragon ${CMAKE_EXTRA_ARGS}

						        echo "==> Building"
							        cmake --build build-snapdragon

								        echo "==> Installing to pkg-snapdragon/llama.cpp"
									        cmake --install build-snapdragon --prefix pkg-snapdragon/llama.cpp
										    '

										    echo ""
										    echo "==> Build complete. Package is ready at: ${SCRIPT_DIR}/pkg-snapdragon/llama.cpp"
										    echo "    Run ./deploy-snapdragon.sh to push it to the device."
