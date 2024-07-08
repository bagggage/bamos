#include "intr.h"

#include "definitions.h"
#include "trace.h"
#include "logger.h"
#include "regs.h"

#define TRAP_GATE_FLAGS 0x8F
#define INTERRUPT_GATE_FLAGS 0x8E

#define INTR_ANY_CPU 0xFF

#define INTR_KERNEL_STACK 0
#define INTR_USER_STACK   2

Intr_x86_64::ExceptionHandler Intr_x86_64::except_handlers[] = {};
IntrDescTable Intr_x86_64::base_idt;

void IntrDescTable::set_isr(const uint32_t vector, void(*isr)(), const uint8_t stack_table, const uint32_t gate) {
    const uintptr_t isr_address = reinterpret_cast<uint64_t>(isr);

    Descriptor& desc = table[vector];

    desc.offset_1 = static_cast<uint16_t>(isr_address);
    desc.offset_2 = static_cast<uint16_t>(isr_address >> 16);
    desc.offset_3 = static_cast<uint32_t>(isr_address >> 32);
    desc.ist = stack_table;
    desc.type_attributes = gate;
    desc.selector = get_cs();
}

void IntrDescTable::use() {
    IDTR idtr = {
        .limit = sizeof(table) - 1,
        .base = reinterpret_cast<uintptr_t>(table)
    };

    set_idtr(idtr);
}

extern "C"
ATTR_NAKED void Intr_x86_64::except_handler_caller() {
    save_regs();

    asm volatile(
        "mov %rsp,%rdi \n"
        "mov -0x8(%rsp),%rdx \n"
        "mov -0x10(%rsp),%rsi"
    );

    register uint64_t except_num asm("rsi");

    asm volatile(
        "jmp *%0"
        ::
        "g"(except_handlers[except_num])
    );
}

template<unsigned int exception_num, bool has_error_code>
ATTR_NAKED void Intr_x86_64::intr_except_isr() {
    if constexpr (has_error_code) {
        asm volatile(
            "pop -%c0(%%rsp)"
            ::
            "i"(sizeof(CalleeRegs) + sizeof(ScratchRegs) + 8)
        );
    }
    else {
        asm volatile(
            "movq $0,-%c0(%%rsp)"
            ::
            "i"(sizeof(CalleeRegs) + sizeof(ScratchRegs) + sizeof(uint64_t))
        );
    }

    asm volatile(
        "movq %0,-%c1(%%rsp) \n"
        "jmp *%2"
        ::
        "i"(exception_num),
        "i"(sizeof(CalleeRegs) + sizeof(ScratchRegs) + sizeof(uint64_t[2])),
        "g"(Intr_x86_64::except_handler_caller)
    );
}

template<unsigned int N>
static constexpr bool is_excpt_has_error_code() {
    constexpr unsigned int vec_with_errors[] = { 8, 10, 11, 12, 13, 14, 17, 21 };

    for (uint32_t i = 0; i < sizeof(vec_with_errors) / sizeof(vec_with_errors[0]); i++) {
        if (N == vec_with_errors[i]) return true;
    }

    return false;
}

template<unsigned int exceptions_number, unsigned int N>
void Intr_x86_64::setup_exceptions() {
    if constexpr (N < exceptions_number) {
        base_idt.set_isr(N, &intr_except_isr<N, is_excpt_has_error_code<N>()>, INTR_KERNEL_STACK, INTERRUPT_GATE_FLAGS);

        setup_exceptions<exceptions_number, N + 1>();
    }
}

void Intr_x86_64::preinit() {
    trace_init();
    setup_exceptions<except_number>();
    init_except_handlers();

    base_idt.use();
}