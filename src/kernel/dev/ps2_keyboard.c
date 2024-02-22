#include "ps2_keyboard.h"

#include "io/logger.h"
#include "keyboard.h"
#include "mem.h"

uint8_t inb(uint16_t port) {
    uint8_t ret;

    asm volatile("in %%dx, %%al" : "=a"(ret) : "d"(port));

    return ret;
}

void outb(uint16_t port, uint8_t value) {
    asm volatile("out %%al, %%dx" : : "a"(value), "d"(port));
}

void wait() {
    for (size_t i = 0; i < 0xFF000000; ++i) {
        asm volatile("");
    }
}

Status init_ps2_keyboard(KeyboardDevice* keyboard_device) {
    if (keyboard_device == NULL) return KERNEL_ERROR;

    outb(PS2_DATA_PORT, SET_DEFAULT_PARAMETERS);

    uint8_t result;

    if ((result = inb(PS2_DATA_PORT)) != ACK) {
        for (size_t i = 0; i < 10; ++i) {
            outb(PS2_DATA_PORT, SET_DEFAULT_PARAMETERS);

            wait();

            if (result = inb(PS2_DATA_PORT) == ACK) goto init_interface; 
        }

        if (result != ACK) {
            error_str = "PS/2 Keyboard uninitialized successfull";
            return result == RESEND ? KERNEL_ERROR : KERNEL_PANIC;
        }
    }

init_interface:
    keyboard_device->interface.get_scan_code = &ps2_get_scan_code;

    return KERNEL_OK;
}

uint8_t ignore_released = PS2_SCAN_CODE_NONE;

uint8_t ps2_get_scan_code() {
    PS2ScanCode scancode = PS2_SCAN_CODE_NONE;
    
    if (inb(PS2_STATUS_PORT) & 1) scancode = inb(PS2_DATA_PORT);

    return scancode == PS2_SCAN_CODE_NONE ? SCAN_CODE_NONE : scancode;
}
