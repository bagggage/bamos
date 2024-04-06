#include "exceptions.h"

#include "cpu/regs.h"

#include "mem.h"
#include "logger.h"
#include "vm/vm.h"

#define DE_ISR 0
#define DB_ISR 1
#define NMI_ISR 2
#define BP_ISR 3
#define OF_ISR 4
#define BR_ISR 5
#define UD_ISR 6
#define NM_ISR 7
#define DF_ISR 8
#define TS_ISR 10
#define NP_ISR 11
#define SS_ISR 12
#define GP_ISR 13
#define PF_ISR 14
#define MF_ISR 16
#define AC_ISR 17
#define MC_ISR 18
#define XM_ISR 19
#define VE_ISR 20
#define CP_ISR 21

typedef struct PageFaultErrorCode {
    uint64_t present : 1;       // 0 - non-present page, 1 - page-level protection violation
    uint64_t write : 1;         // 0 - read access, 1 - write access
    uint64_t user : 1;          // 0 - superviros-mode, 1 - user-mode
    uint64_t rsvd : 1;          // 1 - reserved bit set to 1 in pxe structure
    uint64_t instr : 1;         // 1 - instruction fetch fault
    uint64_t protection : 1;    // 1 - protection-key violation
    uint64_t shadow_stack : 1;  // 1 - shadow-stack access
    uint64_t hlat : 1;          // 1 - during HLAT paging
    uint64_t reserved_0 : 7;
    uint64_t sgx : 1;           // 1 - violation of SGX-specific access-controll requirements
    uint64_t reserved_1 : 48;
} PageFaultErrorCode;

// #DE [0] Divide error
ATTR_INTRRUPT void intr_de_handler(InterruptFrame64* frame) {
    kernel_error("#DE Divide error\n");
    log_intr_frame(frame);
    _kernel_break();
}

// #OF [4] Overflow
ATTR_INTRRUPT void intr_of_handler(InterruptFrame64* frame) {
    kernel_error("#OF Overflow\n");
    log_intr_frame(frame);
    _kernel_break();
}

// #DE [5] BOUND Range exception
ATTR_INTRRUPT void intr_br_handler(InterruptFrame64* frame) {
    kernel_error("#BR BOUND Range exception\n");
    log_intr_frame(frame);
    _kernel_break();
}

// #UD [6] Invalid opcode
ATTR_INTRRUPT void intr_ud_handler(InterruptFrame64* frame) {
    kernel_error("#UD Invalid opcode\n");
    log_intr_frame(frame);
    _kernel_break();
}

// #NM [7] Device not available
ATTR_INTRRUPT void intr_nm_handler(InterruptFrame64* frame) {
    kernel_error("#NM Device not available\n");
    log_intr_frame(frame);
    _kernel_break();
}

// #DF [8] Double fault
ATTR_INTRRUPT void intr_df_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_error("#DF Double fault: E: %b\n", error_code);
    log_intr_frame(frame);
    _kernel_break();
}

// #TS [10] Invalid TTS
ATTR_INTRRUPT void intr_ts_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_error("#TS Invalid TSS: E: %b\n", error_code);
    log_intr_frame(frame);
    _kernel_break();
}

// #NP [11] Segment not present
ATTR_INTRRUPT void intr_np_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_error("#NP Segment not present: E: %b\n", error_code);
    log_intr_frame(frame);
    _kernel_break();
}

// #SS [12] Segment fault
ATTR_INTRRUPT void intr_ss_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_error("#SS Segment fault: E: %b\n", error_code);
    log_intr_frame(frame);
    _kernel_break();
}

// #GP [13] General protection
ATTR_INTRRUPT void intr_gp_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_error("#GP General protection: E: %b\n", error_code);
    log_intr_frame(frame);
    _kernel_break();
}

// #PF [14] Page fault exception
ATTR_INTRRUPT void intr_pf_handler(InterruptFrame64* frame, uint64_t error_code) {
    PageFaultErrorCode pf_error = *(PageFaultErrorCode*)&error_code;
    uint64_t virt_address = cpu_get_cr2();

    PageXEntry* pxe = (PageXEntry*)get_pxe_of_virt_addr(virt_address).entry;

#ifdef KDEBUG
    kernel_error("#PF Page fault: E: %b CR2: %x\n", (uint32_t)error_code, virt_address);

    if (pxe == NULL) { 
        log_memory_page_tables(cpu_get_current_pml4());
    }
    else {
        kernel_warn("PXE: %x; (%x) %c%c%c%c%c%c%c\n",
            (uint64_t)pxe,
            (uint64_t)pxe->page_ppn,
            pxe->present ?              'P' : '-',
            pxe->writeable ?            'W' : '-',
            pxe->user_access ?          'U' : '-',
            pxe->size ?                 'S' : '-',
            pxe->write_through ?        'T' : '-',
            pxe->cache_disabled ?       '-' : 'C',
            pxe->execution_disabled ?   '-' : 'X');

        if (pxe->ignored_1 != 0 || pxe->ignored_2 != 0 || pxe->reserved_1 != 0 || (pxe->size == 1 && (pxe->page_ppn & 0x1FF) != 0)) {
            kernel_error("Reserved bits is damaged\n");
        }
    }

    log_intr_frame(frame);
#endif

    if (pf_error.user == 0) _kernel_break();
}

// #AC [17] Alignment check
ATTR_INTRRUPT void intr_ac_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_error("#AC Alignment check: E: %b\n", error_code);
    log_intr_frame(frame);
    _kernel_break();
}

// #MC [18] Machine check
ATTR_INTRRUPT void intr_mc_handler(InterruptFrame64* frame) {
    kernel_error("#MC Machine check\n");
    log_intr_frame(frame);
    _kernel_break();
}

Status init_intr_exceptions() {
    intr_set_idt_descriptor(DE_ISR, (void*)&intr_de_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(OF_ISR, (void*)&intr_of_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(BR_ISR, (void*)&intr_br_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(UD_ISR, (void*)&intr_ud_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(NM_ISR, (void*)&intr_nm_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(DF_ISR, (void*)&intr_df_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(TS_ISR, (void*)&intr_ts_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(NP_ISR, (void*)&intr_np_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(SS_ISR, (void*)&intr_ss_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(GP_ISR, (void*)&intr_gp_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(PF_ISR, (void*)&intr_pf_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(AC_ISR, (void*)&intr_ac_handler, TRAP_GATE_FLAGS);
    intr_set_idt_descriptor(MC_ISR, (void*)&intr_mc_handler, TRAP_GATE_FLAGS);

    return KERNEL_OK;
}