#include "trace.h"

#include "boot.h"
#include "logger.h"

#include "vm/vm.h"

static const DebugSymbolTable* sym_table = nullptr;

void trace_init() {
    sym_table = VM::get_virt_dma(Boot::get_dbg_table());
}

const DebugSymbol* trace_symbol(const uintptr_t func_ptr) {
    for (uint32_t i = 0; i < sym_table->count; ++i) {
        const uint64_t end_address = sym_table->symbols[i].address + sym_table->symbols[i].size;

        if (sym_table->symbols[i].address <= func_ptr && func_ptr < end_address) {
            return sym_table->symbols + i;
        }
    }

    return nullptr;
}

static bool trace_func(const uintptr_t func_ptr, const bool force = false) {
    const DebugSymbol* symbol = trace_symbol(func_ptr);

    if (symbol == nullptr) {
        if (force == false) return false;

        warn(func_ptr, ": UNKNOWN SYMBOL(...)");
        return false;
    }

    warn(func_ptr, force ? ": -> " : ": ", symbol->name, '+', func_ptr - symbol->address);

    return true;
}

void trace() {
    const Arch::StackFrame* frame = reinterpret_cast<Arch::StackFrame*>(__builtin_frame_address(0));

    trace(frame->ret_ptr, frame->next, 8);
}

void trace(const uintptr_t ip, const Arch::StackFrame* frame, const uint8_t depth) {
    if (ip != 0) trace_func(ip, true);

    for (uint32_t i = 0; i < depth && frame != nullptr; ++i) {
        if (reinterpret_cast<uintptr_t>(frame) >= UINTPTR_MAX - sizeof(uintptr_t)) break;

        if (trace_func(frame->ret_ptr) == false) break;
        frame = frame->next;
    }
}