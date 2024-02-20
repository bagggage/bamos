#include "ps2_keyboard.h"

#include "keyboard.h"
#include "mem.h"

uint8_t inb(unsigned short port) {
    unsigned char ret;

    asm volatile("in %%dx, %%al" : "=a"(ret) : "d"(port));

    return ret;
}

void outb(unsigned char value, unsigned short port) {
    asm volatile("out %%al, %%dx" : : "a"(value), "d"(port));
}

Status init_ps2_keyboard(KeyboardDevice* keyboard_device) {
    if (keyboard_device == NULL) {
        return KERNEL_ERROR;
    }
    
    outb(PS2_PORT, SET_DEFAULT_PARAMETERS); 

    if (inb(PS2_PORT) != ACK) {
        return KERNEL_ERROR;
    } 

    keyboard_device->interface.get_scan_code = &ps2_get_scan_code;

    return KERNEL_OK;
}   

uint8_t ps2_get_scan_code() {
    return inb(PS2_PORT);    
}
