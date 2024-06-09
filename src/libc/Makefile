CROSS_ENV:=-fpie -fomit-frame-pointer -ffreestanding -fno-stack-protector -mno-red-zone -nostdlib

AS:=${TOOLCHAIN}/x86_64-elf-as
AR:=${TOOLCHAIN}/x86_64-elf-ar
LD:=${TOOLCHAIN}/x86_64-elf-ld
CC:=${TOOLCHAIN}/x86_64-elf-gcc ${CROSS_ENV}

CC_FLAGS:=-Wall -Wextra -O2 -g

PP_DEF:=

OBJCOPY:=objcopy
MKDIR:=mkdir -p

BUILD_LIBC:=${BUILD_DIR}/libc
SRC_LIBC:=${SRC_DIR}/libc

CC_INCLUDE:=-I${SRC_LIBC}

SRCS:=$(shell find ${SRC_LIBC} -name '*.c')
OBJS:=$(patsubst ${SRC_LIBC}/%.c, ${BUILD_LIBC}/%.o, ${SRCS})
LINKLD:=${CONFIG_DIR}/kernel.ld

LIBC_BIN:=${BUILD_LIBC}/libc.a

${OBJS}: ${SRCS}
	@${MKDIR} ${@D}
	@${CC} ${CC_FLAGS} ${PP_DEF} ${CC_INCLUDE} -c $(patsubst ${BUILD_LIBC}/%.o, ${SRC_LIBC}/%.c, $@) -o $@

bin: ${OBJS}
	${AR} rcs -o ${LIBC_BIN} $(filter-out ${BUILD_LIBC}/crt0.o, ${OBJS})
	@${TOOLCHAIN}/x86_64-elf-readelf -Ws ${LIBC_BIN} > ${BUILD_LIBC}/elf-symbols.txt
#	@${THIRD_PRT}/elf-dbg/elf-dbg ${BUILD_LIBC}/elf-symbols.txt -o ${BUILD_LIBC}/dbg.sym
#	@${TOOLCHAIN}/x86_64-elf-strip --strip-all -K mmio -K fb -K bootboot -K environment -K initstack ${KERNEL_BIN}

all: bin
