#!/bin/bash

set -e
. ./env.sh

export TARGET=${DIST_DIR}/bamos.iso
export MKBOOT=${BOOTBOOT}/mkbootimg

mkdir -p ${BOOT_SYS_DIR}
cp ${KERNEL_BIN} ${KERNEL_TAR}
cp ${CONFIG_DIR}/bootboot.cfg ${BOOT_SYS_DIR}/config
cp ${CONFIG_DIR}/bootboot.json ${DIST_DIR}
cp ${BUILD_DIR}/kernel/dbg.sym ${BOOT_SYS_DIR}/dbg.sym

${TOOLCHAIN}/x86_64-elf-strip --strip-all -K mmio -K fb -K bootboot -K environment -K initstack ${KERNEL_TAR}

cd ${DIST_DIR}
${MKBOOT} bootboot.json ${TARGET}
cd ../