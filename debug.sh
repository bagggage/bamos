#!/bin/bash

zig build kernel --prefix build
./iso.sh
./qemu.sh