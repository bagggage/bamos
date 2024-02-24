#pragma once

#include "definitions.h"

uint8_t inb(uint16_t port);
void outb(uint16_t port, uint8_t data);

uint16_t inw(uint32_t port);
void outw(uint32_t port, uint16_t data);

uint32_t inl(uint32_t port);
void outl(uint32_t port, uint32_t data);
