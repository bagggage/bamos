#!/bin/bash

set -e
. ./env.sh

export FONT=${THIRD_PRT}/fonts/Uni2-VGA16.psf

mkdir -p ${BUILD_DIR}/kernel
cp ${FONT} ${BUILD_DIR}/kernel/font.psf
cd ${BUILD_DIR}/kernel
${TOOLCHAIN}/x86_64-elf-ld -r --format=binary -o font.o font.psf
rm -f font.psf

cd ../../src/kernel
make all
cd ../../