ENTRY(_start)

mmio        = 0xfffffffff8000000;
fb          = 0xfffffffffc000000;
bootboot    = 0xffffffffff000000; /* default = 0xffffffffffe00000 */
environment = 0xffffffffff001000; /* default = 0xffffffffffe01000 */
initstack   = 0x4000;

PHDRS
{
    boot PT_LOAD;
}

SECTIONS
{
    . = 0xffffffffff002000; /* default = 0xffffffffffe02000 */

    kernel_elf_start = .;

    .text : {
        KEEP(*(.text.boot)) *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)
    } :boot

    .bss (NOLOAD) : {
        . = ALIGN(16);
        *(.bss .bss.*)
        *(COMMON)
    } :boot

    kernel_elf_end = .;

    /DISCARD/ : { *(.eh_frame) *(.comment) }
}
