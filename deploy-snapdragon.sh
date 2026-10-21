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

#vm-04
DEVICE="3130214d"
HOST="morph-awusb-vm-04"
#----

#vm-03
#DEVICE="128b7864"
#HOST="morph-awusb-vm-03"
#----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="${SCRIPT_DIR}/pkg-snapdragon/llama.cpp"
DEVICE_DEST="/data/local/tmp"

if [ ! -d "${PKG_DIR}" ]; then
	    echo "ERROR: Package directory not found: ${PKG_DIR}"
	        echo "       Run ./build-snapdragon.sh first."
		    exit 1
fi
clear


echo "==> Deploying to device ${DEVICE}"
echo "    Source : ${PKG_DIR}"
echo "    Dest   : ${DEVICE_DEST}/llama.cpp"

echo "==> Pushing package via adb"
adb -H $HOST -s $DEVICE push "${PKG_DIR}" "${DEVICE_DEST}/"

echo "==> Setting permissions on binaries"
adb -H $HOST -s $DEVICE shell "chmod 777 ${DEVICE_DEST}/llama.cpp/bin/*"

echo "==> Pushing sample-prompt.txt"
adb -H $HOST -s $DEVICE push sample-prompt.txt "${DEVICE_DEST}/llama.cpp/"

echo ""
echo "==> Deployment complete."
echo "    Binaries are at ${DEVICE_DEST}/llama.cpp/bin/ on device ${DEVICE}"

