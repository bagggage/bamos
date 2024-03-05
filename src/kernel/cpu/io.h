#pragma once

#include "definitions.h"

static inline uint16_t inw(uint32_t port) {
    uint16_t ret;

    asm volatile("inw %w1,%0":"=a"(ret):"Nd"(port));

    return ret;
}

static inline void outw(uint32_t port, uint16_t data) {
    asm volatile("outw %w0,%w1": :"a"(data),"Nd"(port));
}

static inline uint8_t inb(uint16_t port) {
    uint8_t ret;

    asm volatile("in %%dx,%%al":"=a"(ret):"d"(port));

    return ret;
}

static inline void outb(uint16_t port, uint8_t data) {
    asm volatile("out %%al,%%dx"::"a"(data),"d"(port));
}

static inline uint32_t inl(uint32_t port) {
    uint32_t ret;

    asm volatile("inl %w1,%0":"=a"(ret):"Nd"(port));

    return ret;
}

static inline void outl(uint32_t port, uint32_t data) {
    asm volatile("outl %0,%w1": :"a"(data),"Nd"(port));
}

static inline void sys_write64(uint64_t data, uint64_t address) {
	asm volatile("movq %0,%1"::"r"(data),"m"(*(volatile uint64_t*)(uintptr_t)address):"memory");
}

static inline uint64_t sys_read64(uint64_t address) {
	uint64_t ret;

	asm volatile("movq %1,%0":"=r"(ret):"m"(*(volatile uint64_t*)(uintptr_t)address):"memory");

	return ret;
}
