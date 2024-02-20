#!/bin/bash

set -e
. ./env.sh

export UEFI=${THIRD_PRT}/uefi/OVMF-efi.fd

unset GTK_PATH
qemu-system-x86_64 -bios ${UEFI} -smp cores=1 ${DIST_DIR}/bamos.iso