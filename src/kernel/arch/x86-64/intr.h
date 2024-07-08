#pragma once

#include "definitions.h"
#include "regs.h"

class IntrDescTable {
public:
    static constexpr uint32_t table_size = 256;
private:
    struct ATTR_PACKED Descriptor {
        uint16_t offset_1;        // offset bits 0..15
        uint16_t selector;        // a code segment selector in GDT or LDT
        uint8_t  ist;             // bits 0..2 holds Interrupt Stack Table offset, rest of bits zero.
        uint8_t  type_attributes; // gate type, dpl, and p fields
        uint16_t offset_2;        // offset bits 16..31
        uint32_t offset_3;        // offset bits 32..63
        uint32_t reserved;
    };

    Descriptor table[table_size];
public:
    void set_isr(const uint32_t vector, void(*isr)(), const uint8_t stack_table, const uint32_t gate);

    void use();
};

class Intr_x86_64 {
private:
    using ExceptionHandler = void(*)(Regs* const regs, const uint32_t vec, const uint32_t error_code);

    static constexpr uint32_t except_number = 22;
    static ExceptionHandler except_handlers[except_number];

    static IntrDescTable base_idt;

    static void except_handler_caller();

    template<unsigned int exception_num, bool has_error_code>
    static void intr_except_isr();

    template<unsigned int exceptions_number, unsigned int N = 0>
    static void setup_exceptions();

    static void init_except_handlers();
public:
    static void preinit();
};

static ATTR_INLINE_ASM void iret() {
    asm volatile("iret");
}

static ATTR_INLINE_ASM void intr_ret() {
    restore_regs();
    iret();
}