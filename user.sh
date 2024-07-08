#!/bin/bash

set -e
. ./env.sh

mkdir -p ${BUILD_DIR}/user

cd ./src/user
make all
cd ../../