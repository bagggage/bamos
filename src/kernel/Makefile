CROSS_ENV:=-fpic -ffreestanding -fno-stack-protector -mno-red-zone -nostdlib

AS:=${TOOLCHAIN}/x86_64-elf-as
LD:=${TOOLCHAIN}/x86_64-elf-ld
CC:=${TOOLCHAIN}/x86_64-elf-gcc ${CROSS_ENV} -O2

PP_DEF:=-DMEM_RAW_PATCH

OBJCOPY:=objcopy
MKDIR:=mkdir -p

BUILD_KER:=${BUILD_DIR}/kernel
SRC_KER:=${SRC_DIR}/kernel

SRCS:=$(shell find ${SRC_KER} -name '*.c')
OBJS:=$(patsubst ${SRC_KER}/%.c, ${BUILD_KER}/%.o, ${SRCS})
LINKLD:=${CONFIG_DIR}/kernel.ld

${OBJS}: ${SRCS}
	${MKDIR} ${@D}
	${CC} ${PP_DEF} -I${BOOTBOOT} -I${SRC_KER} -c $(patsubst ${BUILD_KER}/%.o, ${SRC_KER}/%.c, $@) -o $@

bin: ${OBJS}
	${LD} -nostdlib -n -T ${LINKLD} -o ${KERNEL_BIN} ${BUILD_KER}/font.o ${OBJS}
	${TOOLCHAIN}/x86_64-elf-strip --strip-all -K mmio -K fb -K bootboot -K environment -K initstack ${KERNEL_BIN}
	${TOOLCHAIN}/x86_64-elf-readelf -hls ${KERNEL_BIN} > ${KERNEL_BIN}.txt

all: bin
