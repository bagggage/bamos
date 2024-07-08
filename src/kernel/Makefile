CROSS_ENV:=-fpic\
 -fstrict-volatile-bitfields\
 -ffreestanding\
 -fno-omit-frame-pointer\
 -fno-stack-protector\
 -fno-exceptions\
 -fno-unwind-tables\
 -fno-asynchronous-unwind-tables\
 -mincoming-stack-boundary=3\
 -mno-red-zone\
 -nostdlib

AS:=${TOOLCHAIN}/x86_64-elf-as
LD:=${TOOLCHAIN}/x86_64-elf-ld
CPP:=${TOOLCHAIN}/x86_64-elf-g++ ${CROSS_ENV}

CC_FLAGS:=-std=c++23 -Wall -Wextra -O2 -g

PP_DEF:=-DKDEBUG -DKTRACE -DKERNEL -DX86_64

OBJCOPY:=objcopy
MKDIR:=mkdir -p

BUILD_KER:=${BUILD_DIR}/kernel
SRC_KER:=${SRC_DIR}/kernel

CC_INCLUDE:=-I${BOOTBOOT} -I${SRC_KER} -I${SRC_DIR} -I${UEFI_DIR}/include

SRCS:=$(shell find ${SRC_KER} -name '*.cpp')
OBJS:=$(patsubst ${SRC_KER}/%.cpp, ${BUILD_KER}/%.o, ${SRCS})
LINKLD:=${CONFIG_DIR}/kernel.ld
DEPS:=$(shell find ${BUILD_KER} -name '*.d')

-include ${DEPS}

${OBJS}: ${SRCS}
	@${MKDIR} ${@D}
	@${CPP} ${CC_FLAGS} ${PP_DEF} ${CC_INCLUDE} -MMD -c $(patsubst ${BUILD_KER}/%.o, ${SRC_KER}/%.cpp, $@) -o $@

bin: ${OBJS}
	@${LD} -nostdlib -n -T ${LINKLD} -o ${KERNEL_BIN} ${BUILD_KER}/font.o ${OBJS}
	@${TOOLCHAIN}/x86_64-elf-readelf -Ws ${KERNEL_BIN} > ${BUILD_KER}/elf-symbols.txt
	@${THIRD_PRT}/elf-dbg/elf-dbg ${BUILD_KER}/elf-symbols.txt -o ${BUILD_KER}/dbg.sym
#	@${TOOLCHAIN}/x86_64-elf-strip --strip-all -K mmio -K fb -K bootboot -K environment -K initstack ${KERNEL_BIN}
	@${TOOLCHAIN}/x86_64-elf-readelf -hls ${KERNEL_BIN} > ${KERNEL_BIN}.txt

all: bin
