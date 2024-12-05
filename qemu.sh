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
 -chardev stdio,id=char0 \
 -serial chardev:char0 \
 -bios ${UEFI} -nic none -no-reboot \
 -drive file=${DIST_DIR}/bamos.iso,format=raw,if=none,id=boot \
 -drive file=/dev/nvme0n1,format=raw,if=none,id=img \
 -device ide-hd,drive=boot,bootindex=0 \
 -device nvme,serial=deadbeef,drive=img \
 -machine q35 -smp cores=4 -m 64M \
 -enable-kvm -cpu host \
# ^^^^^^^^^^^^^^^^^^^^^^
# comment line above when running on Windows!