CROSS_ENV:=-fpic -ffreestanding -fno-omit-frame-pointer -fno-stack-protector -mno-red-zone -nostdlib

AS:=${TOOLCHAIN}/x86_64-elf-as
AR:=${TOOLCHAIN}/x86_64-elf-ar
LD:=${TOOLCHAIN}/x86_64-elf-ld
CC:=${TOOLCHAIN}/x86_64-elf-gcc ${CROSS_ENV}

CC_FLAGS:=-Wall -Wextra -O2 -g

PP_DEF:=

OBJCOPY:=objcopy
MKDIR:=mkdir -p

BUILD_APP:=${BUILD_DIR}/user
SRC_APP:=${SRC_DIR}/user

CC_INCLUDE:=-I${SRC_APP} -I${SRC_DIR}/libc

SRCS:=$(shell find ${SRC_APP} -name '*.c')
OBJS:=$(patsubst ${SRC_APP}/%.c, ${BUILD_APP}/%.o, ${SRCS})
LINKLD:=${CONFIG_DIR}/kernel.ld

OUT:=${BUILD_APP}/test.app
SAVE_DEV:=${shell losetup | grep -oP "/dev/loop\d+(?=.*nvme\.img)"}
SAVE_DIR:=${shell lsblk -o MOUNTPOINT -nr ${SAVE_DEV}}/usr/bin

${OBJS}: ${SRCS}
	@${MKDIR} ${@D}
	@${CC} ${CC_FLAGS} ${PP_DEF} ${CC_INCLUDE} -c $(patsubst ${BUILD_APP}/%.o, ${SRC_APP}/%.c, $@) -o $@

bin: ${OBJS}
	${CC} -T link.ld -o ${OUT} ${OBJS} -L${BUILD_DIR}/libc -l:libc.a -Wl,--no-relax
#	@${THIRD_PRT}/elf-dbg/elf-dbg ${BUILD_LIBC}/elf-symbols.txt -o ${BUILD_LIBC}/dbg.sym
#	@${TOOLCHAIN}/x86_64-elf-strip --strip-all ${OUT}
	@cp ${OUT} ${SAVE_DIR} 

all: bin
