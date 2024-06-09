#include "intr.h"

#include "exceptions.h"

#include "logger.h"
#include "mem.h"

#include "cpu/feature.h"
#include "cpu/gdt.h"

#define IDT_ENTRIES_COUNT 256
#define IDT_EXCEPTION_ENTRIES_COUNT 32

static InterruptDescriptor64 idt_64[IDT_ENTRIES_COUNT];
static IDTR64 idtr_64;

extern uint64_t kernel_elf_start;

uint16_t get_current_kernel_cs() {
    uint16_t cs;

    asm volatile("mov %%cs,%0":"=a"(cs));

    return cs;
}

#ifdef KTRACE
typedef struct DebugSymbol {
    uint64_t virt_address;
    uint32_t size;
    const char name[32];
} ATTR_PACKED DebugSymbol;

typedef struct DebugSymbolTable {
    uint64_t magic;
    uint64_t count;
    
    DebugSymbol symbols[];
} ATTR_PACKED DebugSymbolTable;

typedef struct StackFrame { 
    struct StackFrame* rbp;
    uint64_t rip;
} StackFrame;

extern BOOTBOOT bootboot;

static const DebugSymbolTable* sym_table = NULL;
static const unsigned char sym_table_magic[] = { 0xAC, 'D', 'B', 'G' };
#endif

typedef struct OffsetAddress {
    uint16_t offset_1;
    uint16_t offset_2;
    uint32_t offset_3;
} ATTR_PACKED OffsetAddress;

void intr_set_idt_descriptor(const uint8_t idx, const void* isr, uint8_t flags) {
    idt_64[idx].offset_1 = (uint64_t)isr & 0xFFFF;
    idt_64[idx].offset_2 = ((uint64_t)isr >> 16) & 0xFFFF;
    idt_64[idx].offset_3 = (uint64_t)isr >> 32;
    idt_64[idx].ist = 0;
    idt_64[idx].selector = get_current_kernel_cs();
    idt_64[idx].type_attributes = flags;
    idt_64[idx].reserved = 0;
}

#ifdef KTRACE
const DebugSymbol* get_debug_symbol(const uint64_t symbol_virt_address) {
    for (uint32_t i = 0; i < sym_table->count; ++i) {
        const uint64_t end_address = sym_table->symbols[i].virt_address + sym_table->symbols[i].size;

        if (sym_table->symbols[i].virt_address <= symbol_virt_address &&
            symbol_virt_address < end_address) {
            return sym_table->symbols + i;
        }
    }

    return NULL;
}

#define TRACE_INTERRUPT_DEPTH 2

void log_trace(const uint32_t trace_start_depth) {
    kernel_warn("Trace:\n");

    StackFrame* frame = (StackFrame*)__builtin_frame_address(0);

    for (unsigned int i = 0; i < 6; ++i) {
        if (frame->rbp == NULL) break;
        if (i < trace_start_depth || frame->rip == 0) {
            frame = frame->rbp;
            continue;
        }

        const DebugSymbol* dbg_symbol = get_debug_symbol(frame->rip);

        kernel_warn("%x: %s(...)+%x\n",
            frame->rip,
            dbg_symbol == NULL ? "UNKNOWN SYMBOL" : dbg_symbol->name,
            dbg_symbol == NULL ? 0 : frame->rip - dbg_symbol->virt_address);
        frame = frame->rbp;
    }
}
#endif

__attribute__((target("general-regs-only"))) void log_intr_frame(InterruptFrame64* frame) {
#ifdef KTRACE
    const DebugSymbol* dbg_symbol = get_debug_symbol(frame->rip);

    kernel_warn("-> %x: %s(...)+%x\n",
        frame->rip,
        dbg_symbol == NULL ? "UNKNOWN SYMBOL" : dbg_symbol->name,
        dbg_symbol == NULL ? 0 : frame->rip - dbg_symbol->virt_address);
    log_trace(TRACE_INTERRUPT_DEPTH);
#endif
    register uint64_t r10 asm("r10");
    register uint64_t r11 asm("r11");
    register uint64_t r12 asm("r12");
    register uint64_t r13 asm("r13");
    register uint64_t r14 asm("r14");
    register uint64_t r15 asm("r15");

    kernel_warn(
        "CPU: %u: Interrupt Frame:\n"
        "cr2: %x\ncr3: %x\n"
        "rax: %x; rdi: %x; rsi: %x; rcx: %x; rdx: %x; rbx: %x\n"
        "r10: %x r11: %x; r12: %x; r13: %x; r14: %x; r15: %x\n"
        "rip: %x:%x\n"
        "rsp: %x\nrflags: %b\ncs: %x\nss: %x\n",
        cpu_get_idx(),
        cpu_get_cr2(),
        cpu_get_cr3(),
        cpu_get_rax(), cpu_get_rdi(), cpu_get_rsi(), cpu_get_rcx(), cpu_get_rdx(), cpu_get_rbx(),
        r10, r11, r12, r13, r14, r15,
        frame->rip, get_phys_address((uint64_t)frame->rip),
        frame->rsp,
        frame->eflags,
        frame->cs,
        frame->ss);

    raw_hexdump((void*)frame->rip, 16);
}

__attribute__((target("general-regs-only"))) void intr_excp_panic(InterruptFrame64* frame, uint32_t error_code) {
    kernel_error("[KERNEL PANIC] Unhandled interrupt exception: %x\n", error_code);
    log_intr_frame(frame);
    // Halt
    _kernel_break();
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

#ifdef KTRACE
static bool_t find_debug_sym_table(const uint8_t* initrd, const uint64_t initrd_size) {
    // Magic is divided into 2 parts to prevent finding kernel code in initrd
    const uint32_t second_part_magic = 0xFE015223;
    const uint8_t* ptr = initrd; 

    while (ptr < initrd + initrd_size) {
        if (*(const uint32_t*)ptr == *(const uint32_t*)sym_table_magic) {
            if (*(const uint32_t*)(ptr + sizeof(uint32_t)) == second_part_magic) {
                sym_table = (const DebugSymbolTable*)ptr;
                return TRUE;
            }
        }

        ptr++;
    }

    return FALSE;
}
#endif

Status init_intr() {
    idtr_64.limit = sizeof(idt_64) - 1;
    idtr_64.base = (uint64_t)&idt_64;

#ifdef KTRACE
    if (find_debug_sym_table((const uint8_t*)bootboot.initrd_ptr, bootboot.initrd_size) == FALSE) {
        draw_kpanic_screen();
        kernel_error("Kernel debug information for trace('KTRACE') is not located");
        _kernel_break();
    }
#endif

    // Setup exception heandlers
    for (uint8_t i = 0; i < IDT_EXCEPTION_ENTRIES_COUNT; ++i) {
        if (i == 8 || i == 10 || i == 11 || i == 12 ||
            i == 13 || i == 14 || i == 17 || i == 21) {
            intr_set_idt_descriptor(i, &intr_excp_error_code_handler, TRAP_GATE_FLAGS);
        }
        else {
            intr_set_idt_descriptor(i, &intr_excp_handler, TRAP_GATE_FLAGS);
        }
    }

    if (init_intr_exceptions() != KERNEL_OK) return KERNEL_PANIC;

    // Setup regular interrupts
    for (uint16_t i = IDT_EXCEPTION_ENTRIES_COUNT; i < IDT_ENTRIES_COUNT; ++i) {
        intr_set_idt_descriptor(i, &intr_handler, INTERRUPT_GATE_FLAGS);
    }

    cpu_set_idtr(idtr_64);
    intr_enable();

    return KERNEL_OK;
}

IDTR64 intr_get_kernel_idtr() {
    return idtr_64;
}