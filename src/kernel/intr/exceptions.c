#include "exceptions.h"

#include "cpu/regs.h"
#include "cpu/feature.h"

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

typedef union PageFaultErrorCode {
    struct {
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
    };
    uint64_t value;
} ATTR_PACKED PageFaultErrorCode;

// #DE [0] Divide error
ATTR_INTRRUPT void intr_de_handler(InterruptFrame64* frame) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    raw_puts("#DE Divide error\n");
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #DB [1] Debug exception
ATTR_INTRRUPT void intr_db_handler(InterruptFrame64* frame) {

    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    raw_puts("#DB Debug exception\n");
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #NMI [2] NMI
ATTR_INTRRUPT void intr_nmi_handler(InterruptFrame64* frame) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    raw_puts("#NMI Non-maskable interrupt\n");
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #BP [3] Breakpoint exception
ATTR_INTRRUPT void intr_bp_handler(InterruptFrame64* frame) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    raw_puts("#BP Breakpoint exception\n");
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #OF [4] Overflow
ATTR_INTRRUPT void intr_of_handler(InterruptFrame64* frame) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    raw_puts("#OF Overflow\n");
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #DE [5] BOUND Range exception
ATTR_INTRRUPT void intr_br_handler(InterruptFrame64* frame) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    raw_puts("#BR BOUND Range exception\n");
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #UD [6] Invalid opcode
ATTR_INTRRUPT void intr_ud_handler(InterruptFrame64* frame) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    raw_puts("#UD Invalid opcode\n");
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #NM [7] Device not available
ATTR_INTRRUPT void intr_nm_handler(InterruptFrame64* frame) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    raw_puts("#NM Device not available\n");
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #DF [8] Double fault
ATTR_INTRRUPT void intr_df_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    kprintf("#DF Double fault: E: %b\n", error_code);
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #TS [10] Invalid TTS
ATTR_INTRRUPT void intr_ts_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    kprintf("#TS Invalid TSS: E: %b\n", error_code);
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #NP [11] Segment not present
ATTR_INTRRUPT void intr_np_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    kprintf("#NP Segment not present: E: %b\n", error_code);
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #SS [12] Segment fault
ATTR_INTRRUPT void intr_ss_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    kprintf("#SS Segment fault: E: %b\n", error_code);
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #GP [13] General protection fault
ATTR_INTRRUPT void intr_gp_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    kprintf("#GP General protection: E: %b\n", error_code);
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #PF [14] Page fault exception
ATTR_INTRRUPT void intr_pf_handler(InterruptFrame64* frame, uint64_t error_code) {
    //PageFaultErrorCode pf_error = *(PageFaultErrorCode*)&error_code;
    uint64_t virt_address = cpu_get_cr2();

    PageXEntry* pxe = (PageXEntry*)((uint64_t)get_pxe_of_virt_addr(virt_address).entry);

#ifdef KDEBUG
    kernel_logger_lock();
    kernel_logger_push_color(COLOR_LRED);
    kprintf("#PF Page fault: CPU: %u: E: %b CR2: %x\n", cpu_get_idx(), (uint32_t)error_code, virt_address);

    kernel_logger_push_color(COLOR_LYELLOW);

    if (pxe == NULL) {
        log_memory_page_tables(cpu_get_current_pml4());
    }
    else {
        kprintf("PXE: %x; (%x) %c%c%c%c%c%c%c\n",
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
            kprintf("Reserved bits is damaged\n");
        }
        //log_memory_page_tables(cpu_get_current_pml4());
    }

    kernel_logger_pop_color();

    log_intr_frame(frame);
    kernel_logger_release();
#endif

    _kernel_break();
    //if (pf_error.user == 0) _kernel_break();
}

// #AC [17] Alignment check
ATTR_INTRRUPT void intr_ac_handler(InterruptFrame64* frame, uint64_t error_code) {
    kernel_logger_lock();
    kprintf("#AC Alignment check: E: %b\n", error_code);
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

// #MC [18] Machine check
ATTR_INTRRUPT void intr_mc_handler(InterruptFrame64* frame) {
    kernel_logger_lock();
    raw_puts("#MC Machine check\n");
    log_intr_frame(frame);
    kernel_logger_release();

    _kernel_break();
}

Status init_intr_exceptions() {
    InterruptDescriptor64* const idt = intr_get_root_idt();

    intr_set_idt_entry(idt, DE_ISR, (void*)&intr_de_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, DB_ISR, (void*)&intr_db_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, NMI_ISR, (void*)&intr_nmi_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, BP_ISR, (void*)&intr_bp_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, OF_ISR, (void*)&intr_of_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, BR_ISR, (void*)&intr_br_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, UD_ISR, (void*)&intr_ud_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, NM_ISR, (void*)&intr_nm_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, DF_ISR, (void*)&intr_df_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, TS_ISR, (void*)&intr_ts_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, NP_ISR, (void*)&intr_np_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, SS_ISR, (void*)&intr_ss_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, GP_ISR, (void*)&intr_gp_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, PF_ISR, (void*)&intr_pf_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, AC_ISR, (void*)&intr_ac_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    intr_set_idt_entry(idt, MC_ISR, (void*)&intr_mc_handler, TRAP_GATE_FLAGS, INTR_KERNEL_STACK);
    return KERNEL_OK;
}