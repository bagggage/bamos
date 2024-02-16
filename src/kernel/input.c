#include "input.h"


unsigned char inb(unsigned short port) {

    unsigned char ret;

    asm volatile("in %%dx, %%al" : "=a"(ret) : "d"(port));

    return ret;
}

void outb(unsigned char value, unsigned short port) {

    asm volatile("out %%al, %%dx" : : "a"(value), "d"(port));
}

uint8_t init_keyboard() {

    outb(PS2_PORT, SET_DEFAULT_PARAMETERS);       
    uint8_t status = 0;

    status = inb(PS2_PORT); 

    if(status != ACK)
    {
        return 1;
    }

    return 0;
}   

uint32_t get_scan_code() {

    return inb(PS2_PORT);    
}