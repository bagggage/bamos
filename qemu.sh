#!/bin/bash

set -e
. ./env.sh

export UEFI=${THIRD_PRT}/uefi/OVMF-efi.fd

unset GTK_PATH
# qemu-img create -f raw ${DIST_DIR}/nvme.img 512K
qemu-system-x86_64 -enable-kvm -bios ${UEFI} -smp cores=8 -nic none -m 512M -no-reboot \
-drive file=${DIST_DIR}/bamos.iso,media=cdrom \
# -device nvme,id=nvme-ctrl-0,serial=deadbeef \
# -drive file=${DIST_DIR}/nvme.img,if=none,id=nvm-1 \
# -device nvme-ns,drive=nvm-1