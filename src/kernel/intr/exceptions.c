#include "exceptions.h"

#include "cpu/regs.h"

#include "mem.h"
#include "logger.h"

#define PF_ISR 14

// #NP [11] Segment not present exception

typedef struct PageFaultErrorCode {
    uint64_t present : 1;       // 0 - non-present page, 1 - page-level protection violation
    uint64_t write : 1;         // 0 - read access, 1 - write access
    uint64_t user : 1;          // 0 - superviros-mode, 1 - user-mode
    uint64_t rsvd : 1;          // 1 - reserved bit set to 1 in pxe structure
    uint64_t instr : 1;         // 1 - instruction fentch fault
    uint64_t protection : 1;    // 1 - protection-key violation
    uint64_t shadow_stack : 1;  // 1 - shadow-stack access
    uint64_t hlat : 1;          // 1 - during HLAT paging
    uint64_t reserved_0 : 7;
    uint64_t sgx : 1;           // 1 - violation of SGX-specific access-controll requirements
    uint64_t reserved_1 : 48;
} PageFaultErrorCode;

// #PF [14] Page fault exception
ATTR_INTRRUPT void intr_pf_handler(InterruptFrame64* frame, uint64_t error_code) {
    PageFaultErrorCode pf_error = *(PageFaultErrorCode*)&error_code;
    uint64_t virt_address = cpu_get_cr2();
    
#ifdef KDEBUG
    kernel_warn("#PF Page fault: E: %b CR2: %x\n", (uint32_t)error_code, virt_address);
    log_intr_frame(frame);
#endif

    if (pf_error.user == 0) _kernel_break();
}

Status init_intr_exceptions() {
    intr_set_idt_descriptor(PF_ISR, (void*)get_phys_address((uint64_t)&intr_pf_handler), TRAP_GATE_FLAGS);

    return KERNEL_OK;
}