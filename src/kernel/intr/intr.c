#include "intr.h"

#include "logger.h"
#include "mem.h"

#include "cpu/gdt.h"

#define IDT_ENTRIES_COUNT 256
#define IDT_EXCEPTION_ENTRIES_COUNT 32

InterruptDescriptor64 idt_64[IDT_ENTRIES_COUNT];
IDTR64 idtr_64;

uint16_t get_current_kernel_cs() {
    uint16_t cs;

    asm volatile("mov %%cs,%0":"=a"(cs));

    return cs;
}

typedef struct OffsetAddress {
    uint16_t offset_1;
    uint16_t offset_2;
    uint32_t offset_3;
} ATTR_PACKED OffsetAddress;

void set_idt_descriptor(uint8_t idx, void* isr, uint8_t flags) {
    idt_64[idx].offset_1 = (uint64_t)isr & 0xFFFF;
    idt_64[idx].offset_2 = ((uint64_t)isr >> 16) & 0xFFFF;
    idt_64[idx].offset_3 = (uint64_t)isr >> 32;
    idt_64[idx].ist = 0;
    idt_64[idx].selector = get_current_kernel_cs();
    idt_64[idx].type_attributes = flags;
    idt_64[idx].reserved = 0;
}

__attribute__((target("general-regs-only"))) void log_intr_frame(InterruptFrame64* frame) {
    kernel_warn("Interrupt Frame:\nrip: %x\nrsp: %x\neflags: %b\ncs: %x\nss: %x\n", 
    frame->rip,
    frame->rsp,
    frame->eflags,
    frame->cs,
    frame->ss);
}

__attribute__((target("general-regs-only"))) void intr_excp_panic(InterruptFrame64* frame, uint32_t error_code) {
    kernel_error("[KERNEL PANIC] Unhandled interrupt exception: %x\n", error_code);
    log_intr_frame(frame);
    // Halt
    while (1);
}

// Default interrupt exception handler
ATTR_INTRRUPT void intr_excp_handler(InterruptFrame64* frame) {
    intr_excp_panic(frame, 0);
}

// Default interrupt exception handler with error code
ATTR_INTRRUPT void intr_excp_error_code_handler(InterruptFrame64* frame, uint64_t error_code) {
    intr_excp_panic(frame, error_code);
}

// Default interrupt handler
ATTR_INTRRUPT void intr_handler(InterruptFrame64* frame) {
    kernel_warn("Unhandled interrupt:\n");
    log_intr_frame(frame);
}

Status init_intr() {
    idtr_64.limit = sizeof(idt_64) - 1;
    idtr_64.base = (uint64_t)&idt_64;

    // Setup interrupt descriptors

    // Setup exception heandlers
    for (uint8_t i = 0; i < IDT_EXCEPTION_ENTRIES_COUNT; ++i) {
        if (i == 8 || i == 10 || i == 11 || i == 12 ||
            i == 13 || i == 14 || i == 17 || i == 21) {
            set_idt_descriptor(i, &intr_excp_error_code_handler, TRAP_GATE_FLAGS);
        }
        else {
            set_idt_descriptor(i, &intr_excp_handler, TRAP_GATE_FLAGS);
        }
    }

    // Setup regular interrupts
    for (uint16_t i = IDT_EXCEPTION_ENTRIES_COUNT; i < IDT_ENTRIES_COUNT; ++i) {
        set_idt_descriptor(i, &intr_handler, INTERRUPT_GATE_FLAGS);
    }

    asm volatile("lidt %0"::"memory"(idtr_64));

    return KERNEL_OK;
}