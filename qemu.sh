#!/bin/bash

set -e
. ./env.sh

export UEFI=/usr/share/OVMF/OVMF-mouse-efi.fd

unset GTK_PATH
qemu-system-x86_64 -bios ${UEFI} -smp cores=4 ${DIST_DIR}/bamos.iso