#!/bin/bash

set -e
. ./env.sh

export TARGET=${DIST_DIR}/bamos.iso
export MKBOOT=${BOOTBOOT}/mkbootimg
export STRIP=strip

mkdir -p ${BOOT_SYS_DIR}
cp ${KERNEL_BIN} ${KERNEL_TAR}
cp ${CONFIG_DIR}/bootboot.json ${DIST_DIR}
cp ${CONFIG_DIR}/bootboot.cfg ${BOOT_SYS_DIR}/config

echo "kernel=${BOOT_SYS}/${KERNEL_BASENAME}" >> ${BOOT_SYS_DIR}/config

${STRIP} --discard-all ${KERNEL_TAR}

cd ${DIST_DIR}
${MKBOOT} bootboot.json ${TARGET}
cd ../