#!/bin/bash

export SRC_DIR=${PWD}/src
export UEFI_DIR=${PWD}/third-party/uefi
export DIST_DIR=${PWD}/dist
export BUILD_DIR=${PWD}/build
export CONFIG_DIR=${PWD}/config
export THIRD_PRT=${PWD}/third-party

export TOOLCHAIN=~/opt/cross/bin
export BOOTBOOT=~/opt/bootboot/dist

export BOOT_DIR=${DIST_DIR}/boot
export BOOT_SYS=bamos
export BOOT_SYS_DIR=${BOOT_DIR}/${BOOT_SYS}

export KERNEL_BASENAME=bamos.elf
export KERNEL_TAR=${BOOT_SYS_DIR}/${KERNEL_BASENAME}
export KERNEL_BIN=build/bin/${KERNEL_BASENAME}