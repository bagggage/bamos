#!/bin/bash

zig build kernel --prefix build --release=fast

if [ $? -eq 0 ]; then
    ./iso.sh
    ./qemu.sh
fi