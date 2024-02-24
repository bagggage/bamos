#include "tty.h"

uint16_t inw(uint32_t port) {
    uint16_t data;

    asm volatile("inw %w1,%0":"=a" (data):"Nd" (port));

    return data;
}

void outw(uint32_t port, uint16_t data) {
    asm volatile("outw %w0,%w1": :"a" (data), "Nd" (port));
}

uint8_t inb(uint16_t port) {
    uint8_t ret;

    asm volatile("in %%dx, %%al" : "=a"(ret) : "d"(port));

    return ret;
}

void outb(uint16_t port, uint8_t data) {
    asm volatile("out %%al, %%dx" : : "a"(data), "d"(port));
}

uint32_t inl(uint32_t port) {
    uint32_t data;

    asm volatile("inl %w1,%0":"=a" (data):"Nd" (port));

    return data;
}

void outl(uint32_t port, uint32_t data) {
    asm volatile("outl %0,%w1": :"a" (data), "Nd" (port));
}