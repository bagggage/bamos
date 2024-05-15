#!/bin/bash

set -e
. ./env.sh

export UEFI=${THIRD_PRT}/uefi/OVMF-efi.fd

unset GTK_PATH
#qemu-img create -f raw ${DIST_DIR}/nvme.img 512M
#mkfs -t ext2 ${DIST_DIR}/nvme.img
qemu-system-x86_64 -enable-kvm -bios ${UEFI} -smp cores=8 -nic none -m 512M -no-reboot \
-drive file=${DIST_DIR}/bamos.iso,media=cdrom \
-blockdev node-name=nvm,driver=file,filename=${DIST_DIR}/nvme.img \
-device nvme,id=nvme-ctrl-0,addr=06,serial=deadbeef,drive=nvm
# -device nvme,id=nvme-ctrl-0,serial=deadbeef \
# -drive file=${DIST_DIR}/nvme.img,if=none,id=nvm-1 \
# -device nvme-ns,drive=nvm-1