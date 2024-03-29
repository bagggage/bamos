#pragma once

#include "definitions.h"

#define TRAP_GATE_FLAGS 0x8F
#define INTERRUPT_GATE_FLAGS 0x8E

typedef struct InterruptDescriptor64 {
    uint16_t offset_1;        // offset bits 0..15
    uint16_t selector;        // a code segment selector in GDT or LDT
    uint8_t  ist;             // bits 0..2 holds Interrupt Stack Table offset, rest of bits zero.
    uint8_t  type_attributes; // gate type, dpl, and p fields
    uint16_t offset_2;        // offset bits 16..31
    uint32_t offset_3;        // offset bits 32..63
    uint32_t reserved;
} ATTR_PACKED InterruptDescriptor64;

typedef struct IDTR64 {
    uint16_t limit;
    uint64_t base;
} ATTR_PACKED IDTR64;

typedef struct InterruptFrame64 {
    uint64_t rip;
    uint64_t cs;
    uint64_t eflags;
    uint64_t rsp;
    uint64_t ss;
} ATTR_PACKED InterruptFrame64;

Status init_intr();

void intr_set_idt_descriptor(const uint8_t idx, const void* isr, uint8_t flags);

void log_intr_frame(InterruptFrame64* frame);