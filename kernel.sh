#!/bin/bash

set -e
. ./env.sh

export FONT=${THIRD_PRT}/fonts/Uni2-VGA16.psf

cd src/kernel
make all
cd ../../