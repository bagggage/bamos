/*
  BOOTBOOT linker script, gcc -T 
  Specification [ https://gitlab.com/bztsrc/bootboot/-/blob/master/bootboot_spec_1st_ed.pdf ]
 */

fb =   0xfffffffffc000000;  /* linear frame buffer */
mmio = 0xfffffffff8000000;  /* Memory-Mapped Input/Output area */
initstack = 1024;           /* starts at adress 0, grows downwards */

PHDRS {
    boot PT_LOAD;
}

SECTIONS {
    . = 0xffffffffffe00000;
    bootboot = .;     /* bootboot structure */
    . += 4096;
    environment = .;  /* '\n' separated, zero terminated UTF-8 string with "key=value" pairs */
    . += 4096;

    .text : {
        KEEP(*(.text.boot)) *(.text .text.*)
        *(.rodata .rodata.*)
        *(.data .data.*)

    } : boot

    .bss (NOLOAD) : {
        . = ALIGN(16);
        *(.bss .bss.*)
        *(COMMON)       /* everything else */
    } : boot

    /DISCARD/ : {
        *(.comment)
        *(.eh_frame)
    }
}

/* Kernel entry point is in ELF at Elf64_Ehdr.e_entry */