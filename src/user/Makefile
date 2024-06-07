CROSS_ENV:=-fpic -fomit-frame-pointer -ffreestanding -fno-stack-protector -mno-red-zone -nostdlib

AS:=${TOOLCHAIN}/x86_64-elf-as
AR:=${TOOLCHAIN}/x86_64-elf-ar
LD:=${TOOLCHAIN}/x86_64-elf-ld
CC:=${TOOLCHAIN}/x86_64-elf-gcc ${CROSS_ENV}

CC_FLAGS:=-Wall -Wextra -O2 -g

PP_DEF:=

OBJCOPY:=objcopy
MKDIR:=mkdir -p

BUILD_APP:=${BUILD_DIR}/user/${PROG_NAME}
SRC_APP:=${SRC_DIR}/user/${PROG_NAME}
OUT:=${BUILD_APP}/${PROG_NAME}

CC_INCLUDE:=-I${SRC_APP} -I${SRC_DIR}/libc

SRCS:=$(shell find ${SRC_APP} -name '*.c')
OBJS:=$(patsubst ${SRC_APP}/%.c, ${BUILD_APP}/%.o, ${SRCS})
LINKLD:=${CONFIG_DIR}/user.ld

SAVE_DEV:=${shell losetup | grep -oP "/dev/loop\d+(?=.*nvme\.img)"}
SAVE_DIR:=${shell lsblk -o MOUNTPOINT -nr ${SAVE_DEV}}/usr/bin

${OBJS}: ${SRCS}
	@${MKDIR} ${@D}
	@${CC} ${CC_FLAGS} ${PP_DEF} ${CC_INCLUDE} -c $(patsubst ${BUILD_APP}/%.o, ${SRC_APP}/%.c, $@) -o $@

bin: ${OBJS}
	@echo Linking: ${PROG_NAME}
	@${CC} -T ${LINKLD} -o ${OUT} ${OBJS} -L${BUILD_DIR}/libc -l:libc.a -Wl,--no-relax
	@cp ${OUT} ${SAVE_DIR} 
	@${TOOLCHAIN}/x86_64-elf-strip --strip-all ${SAVE_DIR}/${PROG_NAME}

PROGS_DIR:=${shell find -maxdepth 1 -type d -not -path . -printf '%f\n'}

all:
	@for dir in ${PROGS_DIR}; do make -s bin PROG_NAME=$${dir}; done
