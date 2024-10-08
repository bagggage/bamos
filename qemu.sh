#!/bin/bash

set -e
. ./env.sh

export UEFI=${THIRD_PRT}/uefi/OVMF-efi.fd

DBG=""

if [ -n "$QEMU_GDB" ]; then
    DBG+="-s -S"
fi

unset GTK_PATH
qemu-system-x86_64 \
 ${DBG} \
 -bios ${UEFI} -nic none -no-reboot \
 -drive file=${DIST_DIR}/bamos.iso,media=cdrom \
 -machine q35 -smp cores=4 -m 64M \
 -enable-kvm -cpu host \
# ^^^^^^^^^^^^^^^^^^^^^^
# comment line above when running on Windows!