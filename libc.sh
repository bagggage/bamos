#!/bin/bash

set -e
. ./env.sh

mkdir -p ${BUILD_DIR}/libc

cd ./src/libc
make all
cd ../../