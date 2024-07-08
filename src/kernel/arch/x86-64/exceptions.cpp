#include "intr.h"

#include "logger.h"
#include "regs.h"
#include "intr.h"
#include "trace.h"

static ATTR_NAKED void common_handler(Regs* const regs, const uint32_t vec, const uint32_t error_code) {
    error("Exception: #", vec, " - error code: ", error_code);
    trace(regs->intr.rip, reinterpret_cast<Arch::StackFrame*>(regs->callee.rbp), 6);
    warn("Regs:\n",
        "rax: ", regs->scratch.rax, ", ",
        "rcx: ", regs->scratch.rcx, ", ",
        "rdx: ", regs->scratch.rdx, ", ",
        "rbx: ", regs->callee.rbx, '\n',
        "rip: ", regs->intr.rip,    ", ",
        "rsp: ", regs->intr.rsp,    ", ",
        "rbp: ", regs->callee.rbp,  ", ",
        "rflags: ", regs->intr.eflags, '\n',
        "r8: ", regs->scratch.r8,   ", ",
        "r9: ", regs->scratch.r9,   ", ",
        "r10: ", regs->scratch.r10, ", ",
        "r11: ", regs->scratch.r11, '\n',
        "r12: ", regs->callee.r12,  ", ",
        "r13: ", regs->callee.r13,  ", ",
        "r14: ", regs->callee.r14,  ", ",
        "r15: ", regs->callee.r15
    );

    _kernel_break();
}

void Intr_x86_64::init_except_handlers() {
    for (uint32_t i = 0; i < except_number; ++i) {
        except_handlers[i] = &common_handler;
    }
}