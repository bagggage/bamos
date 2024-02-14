CROSS_ENV:=-fpic -ffreestanding -fno-stack-protector -mno-red-zone -nostdlib

AS:=${TOOLCHAIN}/x86_64-elf-as
LD:=${TOOLCHAIN}/x86_64-elf-ld
CC:=${TOOLCHAIN}/x86_64-elf-gcc ${CROSS_ENV} -O2

OBJCOPY:=objcopy
MKDIR:=mkdir -p

BUILD_KER:=${BUILD_DIR}/kernel
SRC_KER:=${SRC_DIR}/kernel

SRCS:=$(shell find ${SRC_KER} -name '*.c')
OBJS:=$(patsubst ${SRC_KER}/%.c, ${BUILD_KER}/%.o, ${SRCS})
LINKLD:=${CONFIG_DIR}/kernel.ld

${OBJS}: ${SRCS}
	${MKDIR} ${@D}
	${CC} -I${BOOTBOOT} -c $(patsubst ${BUILD_KER}/%.o, ${SRC_KER}/%.c, $@) -o $@

${BUILD_KER}/font.o: ${FONT}
	${LD} --relocatable --format=binary -o $@ ${FONT}

bin: ${OBJS} ${BUILD_KER}/font.o
	${CC} -T ${LINKLD} -o ${KERNEL_BIN} ${OBJS} ${BUILD_KER}/font.o
	${TOOLCHAIN}/x86_64-elf-strip --strip-all -K mmio -K fb -K bootboot -K environment -K initstack ${KERNEL_BIN}
	${TOOLCHAIN}/x86_64-elf-readelf -hls ${KERNEL_BIN} > ${KERNEL_BIN}.txt

all: bin
