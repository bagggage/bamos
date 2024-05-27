ENTRY(_start)

SECTIONS
{
    . = 0xC00000000;
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