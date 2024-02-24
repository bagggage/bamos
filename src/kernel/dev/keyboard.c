#include "keyboard.h"

uint8_t keyboard_scan_code_to_kernel_scan_code() {
    // TODO: convert keyboard scan code to kernel scan code
    return 0;
}

unsigned char scan_code_to_ascii(KernelScancode scan_code) {
    //TODO: upper case
    static const char asciiTable[] = {
        0, 0, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\b', '\t',   // 0x00-0x0F
        'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', '\n', 0, 'a', 's',  // 0x10-0x1F
        'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0, '\\', 'z', 'x', 'c', 'v', // 0x20-0x2F
        'b', 'n', 'm', ',', '.', '/', 0, '*', 0, ' ', 0, 0, 0, 0, 0, 0,                 // 0x30-0x3F
        0, 0, 0, 0, 0, 0, 0, '7', '8', '9', '-', '4', '5', '6', '+', '1',               // 0x40-0x4F
        '2', '3', '0', '.', 0, 0, 0, '=', 0, 0, 0, 0, 0, 0, 0, 0,                       // 0x50-0x5F
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,                                 // 0x60-0x6F
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,                                 // 0x70-0x7F
    };

    if (scan_code < sizeof(asciiTable)) {
        return asciiTable[scan_code];
    }
    
    return 0;
}