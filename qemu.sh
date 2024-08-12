#!/bin/bash

set -e
. ./env.sh

export UEFI=${THIRD_PRT}/uefi/OVMF-efi.fd
export DRIVE_IMG=nvme.img

echo $(losetup -j $DRIVE_IMG | grep -o "/dev/loop[0-9]*")

if [ -z $(echo $(losetup -j $DRIVE_IMG | grep -o "/dev/loop[0-9]*")) ]; then
    sudo losetup -f $DRIVE_IMG && \
    dev_loop=$(losetup -j $DRIVE_IMG | grep -o "/dev/loop[0-9]*") && \
    sudo partprobe $dev_loop
fi

unset GTK_PATH
#qemu-img create -f raw ${DIST_DIR}/nvme.img 512M
#mkfs -t ext2 ${DIST_DIR}/nvme.img
qemu-system-x86_64 -enable-kvm -cpu host -bios ${UEFI} -smp cores=4 -nic none -m 64M -no-reboot \
 -drive file=${DIST_DIR}/bamos.iso,media=cdrom \
 -drive file=${DRIVE_IMG},if=none,id=nvm \
 -device nvme,id=nvme-ctrl-0,addr=06,serial=deadbeef,drive=nvm \

# -device usb-ehci,id=ehci \

# -device nvme,id=nvme-ctrl-0,serial=deadbeef \
# -drive file=${DIST_DIR}/nvme.img,if=none,id=nvm-1 \
# -device nvme-ns,drive=nvm-1