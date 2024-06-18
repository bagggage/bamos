#include "intr.h"

#include "assert.h"
#include "exceptions.h"
#include "logger.h"
#include "math.h"
#include "mem.h"

#include "cpu/feature.h"
#include "cpu/gdt.h"

#include "vm/bitmap.h"
#include "vm/buddy_page_alloc.h"

#define IDT_EXCEPTION_ENTRIES_COUNT 32
#define INTR_CTRL_MAX_CPUS (PAGE_BYTE_SIZE / sizeof(InterruptMap))
#define INTR_CTRL_INVAL_IRQ 255

extern uint64_t kernel_elf_start;
extern BOOTBOOT bootboot;

static InterruptDescriptor64 idt_root[IDT_ENTRIES_COUNT];
static InterruptControlBlock intr_ctrl = {
    .idts = NULL, .map = NULL, .cpu_count = 0
};

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

void intr_set_idt_entry(InterruptDescriptor64* const idt, const uint8_t idx, const void* isr, uint8_t flags) {
    idt[idx].offset_1 = (uint64_t)isr & 0xFFFF;
    idt[idx].offset_2 = ((uint64_t)isr >> 16) & 0xFFFF;
    idt[idx].offset_3 = (uint64_t)isr >> 32;
    idt[idx].ist = 0;
    idt[idx].selector = get_current_kernel_cs();
    idt[idx].type_attributes = flags;
    idt[idx].reserved = 0;
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
    raw_puts("Trace:\n");

    StackFrame* frame = (StackFrame*)__builtin_frame_address(0);

    for (unsigned int i = 0; i < 6 && is_virt_addr_mapped((uint64_t)frame); ++i) {
        if (frame->rbp == NULL) break;
        if (i < trace_start_depth || frame->rip == 0) {
            frame = frame->rbp;
            continue;
        }

        const DebugSymbol* dbg_symbol = get_debug_symbol(frame->rip);

        kprintf("%x: %s(...)+%x\n",
            frame->rip,
            dbg_symbol == NULL ? "UNKNOWN SYMBOL" : dbg_symbol->name,
            dbg_symbol == NULL ? 0 : frame->rip - dbg_symbol->virt_address);
        frame = frame->rbp;
    }
}
#endif

__attribute__((target("general-regs-only"))) void log_intr_frame(InterruptFrame64* frame) {
    if (is_virt_addr_mapped((uint64_t)frame) == FALSE) return;

    kernel_logger_push_color(COLOR_LYELLOW);

    const ProcessorLocal* const local = proc_get_local();

#ifdef KTRACE
    const DebugSymbol* dbg_symbol = get_debug_symbol(frame->rip);

    kprintf("-> %x: %s(...)+%x\n",
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

    kprintf(
        "CPU: %u: Interrupt Frame: (%x): Process: %u pid\n"
        "cr2: %x\ncr3: %x\n"
        "rax: %x; rdi: %x; rsi: %x; rcx: %x; rdx: %x; rbx: %x\n"
        "r10: %x r11: %x; r12: %x; r13: %x; r14: %x; r15: %x\n"
        "rip: %x:%x\n"
        "rsp: %x\nrflags: %b\ncs: %x\nss: %x\n",
        cpu_get_idx(),
        frame,
        (local->current_task) != NULL ? local->current_task->process->pid : 0,
        cpu_get_cr2(),
        cpu_get_cr3(),
        cpu_get_rax(), cpu_get_rdi(), cpu_get_rsi(), cpu_get_rcx(), cpu_get_rdx(), cpu_get_rbx(),
        r10, r11, r12, r13, r14, r15,
        frame->rip, get_phys_address((uint64_t)frame->rip),
        frame->rsp,
        frame->eflags,
        frame->cs,
        frame->ss);

    if (is_virt_addr_mapped(frame->rip)) raw_hexdump((void*)frame->rip, 16);

    raw_puts("Stack dump:\n");

    const uint64_t* stack = (void*)(frame + 1);

    for (uint32_t i = 0; i < 10; ++i) {
        kprintf(" [%u] %x\n", i, stack[i]);
    }
}

__attribute__((target("general-regs-only"))) void intr_excp_panic(InterruptFrame64* frame, uint32_t error_code) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    kprintf("[KERNEL PANIC] Unhandled interrupt exception: %x\n", error_code);
    log_intr_frame(frame);
    kernel_logger_release();
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
    kernel_logger_release();
    kernel_logger_push_color(COLOR_LRED);
    raw_puts("Unhandled interrupt:\n");
    log_intr_frame(frame);
    kernel_logger_release();
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

static uint8_t _intr_reserve_vector(const uint8_t cpu_idx) {
    InterruptMap* const map = intr_ctrl.map + cpu_idx;
    const uint8_t begin_vec = IDT_EXCEPTION_ENTRIES_COUNT;

    for (uint8_t i = (begin_vec / BYTE_SIZE);i < sizeof(InterruptMap); ++i) {
        if (map->bytes[i] == 0xFF) continue;

        uint8_t byte = map->bytes[i];

        for (uint8_t j = 0; j < BYTE_SIZE; ++j) {
            if ((byte & 1) == 0) {
                const uint8_t idx = (i * BYTE_SIZE) + j;

                _bitmap_set_bit(map->bytes, idx);

                return idx;
            }

            byte >>= 1;
        }
    }

    return 0;
}

InterruptLocation intr_reserve(const uint8_t cpu_idx) {
    InterruptLocation result = { .cpu_idx = cpu_idx, .vector = 0 };

    if (cpu_idx == INTR_ANY_CPU) {
        for (result.cpu_idx = 0; result.cpu_idx < intr_ctrl.cpu_count && result.vector == 0; ++result.cpu_idx) {
            result.vector = _intr_reserve_vector(result.cpu_idx);
        }

        if (result.vector != 0) result.cpu_idx--;
    }
    else {
        result.vector = _intr_reserve_vector(cpu_idx);
    }

    return result;
}

void intr_release(const InterruptLocation location) {
    kassert(location.cpu_idx < bootboot.numcores);

    InterruptMap* const map = intr_ctrl.map + location.cpu_idx;

    kassert(_bitmap_get_bit(map->bytes, location.vector) != 0);

    _bitmap_clear_bit(map->bytes, location.vector);
}

bool_t intr_setup_handler(InterruptLocation location, InterruptHandler_t handler) {
    if (location.cpu_idx >= bootboot.numcores || location.vector < 32) return FALSE;
    if (_bitmap_get_bit(
            intr_ctrl.map[location.cpu_idx].bytes,
            location.vector
        ) == 0) return FALSE;

    InterruptDescriptor64* idt = intr_get_idt(location.cpu_idx);

    intr_set_idt_entry(idt,location.vector, (void*)handler, INTERRUPT_GATE_FLAGS);

    return TRUE;
}

Status init_intr() {
    intr_ctrl.cpu_count = bootboot.numcores;

    if (intr_ctrl.cpu_count == 1) return KERNEL_OK;
    if (intr_ctrl.cpu_count > INTR_CTRL_MAX_CPUS) intr_ctrl.cpu_count = INTR_CTRL_MAX_CPUS;

    const uint64_t mem_block = bpa_allocate_pages(log2(intr_ctrl.cpu_count));

    if (mem_block == INVALID_ADDRESS) {
        error_str = "Intr: Failed to allocate interrupt control block";
        return KERNEL_ERROR;
    }

    intr_ctrl.idts = (InterruptDescriptorTable*)mem_block;
    intr_ctrl.map = (InterruptMap*)(mem_block + (sizeof(InterruptDescriptorTable) * intr_ctrl.cpu_count));

    for (uint32_t i = 0; i < intr_ctrl.cpu_count; ++i) {
        if (i > 0) memcpy((void*)idt_root, (void*)(intr_ctrl.idts + i), sizeof(InterruptDescriptorTable));

        memset((void*)(intr_ctrl.map + i), sizeof(InterruptMap), 0);
    }

    return KERNEL_OK;
}

Status intr_preinit_exceptions() {
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
            intr_set_idt_entry(idt_root, i, &intr_excp_error_code_handler, TRAP_GATE_FLAGS);
        }
        else {
            intr_set_idt_entry(idt_root, i, &intr_excp_handler, TRAP_GATE_FLAGS);
        }
    }

    if (init_intr_exceptions() != KERNEL_OK) return KERNEL_PANIC;

    // Setup regular interrupts
    for (uint16_t i = IDT_EXCEPTION_ENTRIES_COUNT; i < IDT_ENTRIES_COUNT; ++i) {
        intr_set_idt_entry(idt_root, i, &intr_handler, INTERRUPT_GATE_FLAGS);
    }

    cpu_set_idtr(intr_get_idtr(0));

    return KERNEL_OK;
}

InterruptDescriptor64* intr_get_root_idt() {
    return idt_root;
}

InterruptDescriptor64* intr_get_idt(const uint32_t cpu_idx) {
    kassert(cpu_idx < intr_ctrl.cpu_count);

    if (cpu_idx == 0) return idt_root;

    return (intr_ctrl.idts + cpu_idx)->descriptor;
}

IDTR64 intr_get_idtr(const uint32_t cpu_idx) {
    if (cpu_idx == 0) {
        return (IDTR64) {
            .base = (uint64_t)&idt_root,
            .limit = sizeof(idt_root) - 1
        };
    }

    IDTR64 idtr = {
        .base = (uint64_t)(intr_ctrl.idts + cpu_idx),
        .limit = sizeof(InterruptDescriptorTable) - 1
    };

    return idtr;
}