#!/bin/bash

set -e
. ./env.sh

export UEFI=${THIRD_PRT}/uefi/OVMF-efi.fd

unset GTK_PATH
qemu-img create -f raw ${DIST_DIR}/nvme.img 512K
qemu-system-x86_64 -enable-kvm -bios ${UEFI} -smp cores=8 -nic none -m 128M -no-reboot \
-drive file=${DIST_DIR}/bamos.iso,media=cdrom \
-drive format=raw,file=${DIST_DIR}/nvme.img,if=none,id=nvme \
-device nvme,drive=nvme,serial=1234