#include "task_scheduler.h"

#include "logger.h"
#include "math.h"
#include "mem.h"

#include "cpu/gdt.h"
#include "cpu/regs.h"

#include "intr/apic.h"

#include "vm/buddy_page_alloc.h"

static TaskScheduler* schedulers = NULL;

static void lapic_timer_intr_handler() {
    
}

Status init_task_scheduler() {
    //schedulers = (TaskScheduler*)kcalloc(sizeof(TaskScheduler) * bootboot.numcores);

    //if (schedulers == NULL) {
    //    error_str = "Scheduler: not enough memory";
    //    return KERNEL_ERROR;
    //}

    SegmentDescriptor* gdt = (SegmentDescriptor*)cpu_get_current_gdtr().base;

    if (is_virt_addr_mapped(gdt) == FALSE) {
        vm_map_phys_to_virt((uint64_t)gdt, (uint64_t)gdt, 1, VMMAP_WRITE);
    }

    kernel_msg("GDT: %x\n", gdt);

    uint64_t code_segment = cpu_get_cs();
    uint64_t data_segment = cpu_get_ds();
    uint64_t stack_segment = cpu_get_ss();
    uint64_t f_segment = cpu_get_fs();
    uint64_t general_segment = cpu_get_gs();

    kernel_msg("CS: %x: access byte: %b: flags: %b: base: %x: limit: %x\n", code_segment,
        gdt[((SegmentSelector*)&code_segment)->segment_idx].access_byte,
        gdt[((SegmentSelector*)&code_segment)->segment_idx].flags,
        gdt[((SegmentSelector*)&code_segment)->segment_idx].base_1,
        gdt[((SegmentSelector*)&code_segment)->segment_idx].limit_2);

    kernel_msg("DS: %x: access byte: %b: flags: %b: base: %x: limit: %x\n", data_segment,
        gdt[((SegmentSelector*)&data_segment)->segment_idx].access_byte,
        gdt[((SegmentSelector*)&data_segment)->segment_idx].flags,
        gdt[((SegmentSelector*)&data_segment)->segment_idx].base_1,
        gdt[((SegmentSelector*)&data_segment)->segment_idx].limit_2);

    return KERNEL_OK;
}

bool_t tsk_switch_to(Task* task) {
    
}