#pragma once

#include "definitions.h"

#include "cpu/regs.h"

#define IDT_ENTRIES_COUNT 256

#define TRAP_GATE_FLAGS 0x8F
#define INTERRUPT_GATE_FLAGS 0x8E

#define INTR_ANY_CPU 0xFF

typedef struct InterruptDescriptor64 {
    uint16_t offset_1;        // offset bits 0..15
    uint16_t selector;        // a code segment selector in GDT or LDT
    uint8_t  ist;             // bits 0..2 holds Interrupt Stack Table offset, rest of bits zero.
    uint8_t  type_attributes; // gate type, dpl, and p fields
    uint16_t offset_2;        // offset bits 16..31
    uint32_t offset_3;        // offset bits 32..63
    uint32_t reserved;
} ATTR_PACKED InterruptDescriptor64;

typedef struct InterruptDescriptorTable {
    InterruptDescriptor64 descriptor[IDT_ENTRIES_COUNT];
} ATTR_PACKED InterruptDescriptorTable;

typedef struct InterruptFrame64 {
    uint64_t rip;
    uint64_t cs;
    uint64_t eflags;
    uint64_t rsp;
    uint64_t ss;
} ATTR_PACKED InterruptFrame64;

typedef void (*InterruptHandler_t)();

typedef struct InterruptMap {
    uint8_t bytes[IDT_ENTRIES_COUNT / BYTE_SIZE];
} InterruptMap;

typedef struct InterruptLocation {
    uint8_t vector;
    uint8_t cpu_idx;
} InterruptLocation;

typedef struct InterruptControlBlock {
    InterruptDescriptorTable* idts;
    InterruptMap* map;

    uint16_t cpu_count;
    uint16_t next_cpu;
} InterruptControlBlock;

static inline void intr_enable() {
    asm volatile("sti");
}

static inline void intr_disable() {
    asm volatile("cli");
}

void intr_set_idt_entry(InterruptDescriptor64* const idt, const uint8_t idx, const void* isr, uint8_t flags);

/*
Reserve available interrupt vector in IDT and returns it.
The parameter `cpu_idx` can be equal `INTR_ANY_CPU`, then any first avail cpu would be choosen.
If all vectors are busy returns struct with field `vector` equals 0.
*/
InterruptLocation intr_reserve(const uint8_t cpu_idx);

/*
Release previously reserved interrupt vector for specific cpu.
*/
void intr_release(const InterruptLocation location);

/*
Setup handler on location in IDT.
If required location is invalid or not reserved, than returns `FALSE`.
*/
bool_t intr_setup_handler(const InterruptLocation location, InterruptHandler_t const handler);

Status init_intr();
Status intr_preinit_exceptions();

InterruptDescriptor64* intr_get_root_idt();
InterruptDescriptor64* intr_get_idt(const uint32_t cpu_idx);

/*
Returns kernel IDTR for specific cpu.
*/
IDTR64 intr_get_idtr(const uint32_t cpu_idx);

#ifdef KTRACE
void log_trace(const uint32_t trace_start_depth);
#endif

void log_intr_frame(InterruptFrame64* frame);