#!/bin/bash

set -e
. ./env.sh

zig build kernel --prefix build --release=fast -Dexe-name=${KERNEL_BASENAME}

if [ $? -eq 0 ]; then
    ./iso.sh
    ./qemu.sh
fi