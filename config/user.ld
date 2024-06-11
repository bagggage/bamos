ENTRY(_start)
STARTUP(crt0.o)

. = 0x1000;

SECTIONS
{
    .text : {
        *(.text .text.*)                       /* code */
        *(.rodata .rodata.*)                   /* data */
    }
    .data : {
        . = ALIGN(16);
        *(.data .data.*)
    }
    .bss (NOLOAD) : {                          /* bss */
        . = ALIGN(16);
        *(.bss .bss.*)
        *(COMMON)
    }

    /DISCARD/ : { *(.eh_frame) *(.comment) }
}