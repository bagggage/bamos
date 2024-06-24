#include "init.h"

#include <bootboot.h>
#include <stddef.h>

#include "assert.h"
#include "logger.h"
#include "mem.h"
#include "string.h"
#include "syscalls.h"

#include "cpu/feature.h"
#include "cpu/gdt.h"
#include "cpu/regs.h"

#include "dev/acpi_timer.h"
#include "dev/bootboot_display.h"
#include "dev/rtc.h"
#include "dev/hpet_timer.h"
#include "dev/keyboard.h"
#include "dev/lapic_timer.h"
#include "dev/ps2_keyboard.h"
#include "dev/stds/acpi.h"
#include "dev/stds/pci.h"
#include "dev/stds/usb.h"
#include "dev/storage.h"

#include "fs/vfs.h"

#include "intr/apic.h"
#include "intr/intr.h"
#include "intr/ioapic.h"

#include "proc/local.h"
#include "proc/task_scheduler.h"

#include "vm/vm.h"

#define RFLAGS_IF (1 << 9)

extern BOOTBOOT bootboot;
extern uint64_t initstack[];
extern const uint8_t _binary_font_psf_start;

static Spinlock cpus_init_lock = { 1 };
static Spinlock cpus_userspace_lock = { 1 };

static void wait_for_cpu_init() {
    spin_lock(&cpus_init_lock);

    vm_configure_cpu_page_table();
    cpu_set_idtr(intr_get_idtr(g_proc_local.idx));
    configure_lapic_timer();

    spin_release(&cpus_init_lock);
    spin_lock(&cpus_userspace_lock);

    init_user_space();

    spin_release(&cpus_userspace_lock);

    tsk_schedule();

    kassert(FALSE);
}

static Status split_logical_cores() {
    const uint32_t cpu_idx = cpu_get_idx();

    if (cpu_idx != 0) wait_for_cpu_init();
    if (init_kernel_logger_raw(&_binary_font_psf_start) != KERNEL_OK) return KERNEL_PANIC;

    kernel_msg("Kernel startup on CPU %u\n", cpu_idx);
    kernel_msg("CPUs detected: %u\n", bootboot.numcores);

    g_proc_local.idx = cpu_idx;
    g_proc_local.ioapic_idx = cpu_idx;
    g_proc_local.current_task = NULL;
    g_proc_local.kernel_stack = (uint64_t*)(UINT64_MAX - ((uint64_t)initstack * cpu_idx) - 8 + 1);
    g_proc_local.user_stack = NULL;
    g_proc_local.kernel_page_table = NULL;

    return KERNEL_OK;
}

extern uint32_t fb[];

static Status init_timer() {
    if (is_acpi_timer_avail() == FALSE) {
        error_str = "There is no supported timer device";
        return KERNEL_ERROR;
    }

    TimerDevice* acpi_timer = (TimerDevice*)dev_push(DEV_TIMER, sizeof(TimerDevice));
    TimerDevice* lapic_timer = (TimerDevice*)dev_push(DEV_TIMER, sizeof(TimerDevice));

    if (acpi_timer == NULL || lapic_timer == NULL) return KERNEL_ERROR;

    if (init_acpi_timer(acpi_timer) != KERNEL_OK) return KERNEL_ERROR;
    if (init_lapic_timer(lapic_timer) != KERNEL_OK) return KERNEL_ERROR;

    //if (is_hpet_timer_avail() == FALSE) {
    //    error_str = "There is no supported timer device";
    //    return KERNEL_ERROR;
    //}
    //
    //TimerDevice* timer;
    //
    //if (add_device(DEV_TIMER, &timer, sizeof(TimerDevice)) != KERNEL_OK) return KERNEL_ERROR;
    //if (init_hpet_timer(timer) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}

Status init_clock() {
    ClockDevice* rtc_clock = (ClockDevice*)dev_push(DEV_CLOCK, sizeof(ClockDevice));

    if (rtc_clock == NULL) return KERNEL_ERROR;

    if (init_rtc(rtc_clock) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}

Status init_pci() {
    PciBus* pci_bus = (PciBus*)dev_push(DEV_PCI_BUS, sizeof(PciBus));

    if (pci_bus == NULL) return KERNEL_ERROR;

    if (init_pci_bus(pci_bus) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}

TaskStateSegment* g_tss = NULL;
SegmentDescriptor* g_gdt = NULL;

Status init_user_space() {
    static uint32_t gdt_size = 0;
    static const uint32_t gdt_segs_count = 8;

    const uint32_t cpu_idx = g_proc_local.idx;
    const uint64_t proc_local_ptr = (uint64_t)_proc_get_local_ptr(cpu_idx);

    EFER efer = cpu_get_efer();

    // Enable syscalls
    efer.syscall_ext = 1;

    const uint64_t star = 
        ((3 * sizeof(SegmentDescriptor)) << 32) | // KERNEL
        (3ull << 48); // USER

    cpu_set_efer(efer);
    cpu_set_msr(MSR_STAR, star);
    cpu_set_msr(MSR_LSTAR, (uint64_t)&_syscall_handler);
    cpu_set_msr(MSR_CSTAR, 0x0);
    cpu_set_msr(MSR_SFMASK, RFLAGS_IF);
    cpu_set_msr(MSR_SWAPGS_BASE, proc_local_ptr);

    asm volatile("swapgs");

    intr_disable();
    lapic_mask_lvt(LAPIC_LVT_TIMER_REG, FALSE);

    if (cpu_idx != 0) {
        cpu_set_gdt(g_gdt, gdt_size - 1);
        cpu_set_ss(4, FALSE, 0);

        cpu_set_tss(
            (gdt_segs_count * sizeof(SegmentDescriptor)) +
            (cpu_idx * sizeof(SystemSegmentDescriptor))
        );

        g_proc_local.tss = g_tss + cpu_idx;
        return KERNEL_OK;
    }

    SegmentDescriptor* gdt = (SegmentDescriptor*)cpu_get_current_gdtr().base;

    {
    // Move kernel segments
        //SegmentDescriptor* const ker_code = gdt + 7;
        //ker_code->access_byte.access = 1;
        //ker_code->access_byte.read_write = 1;
        //ker_code->access_byte.dc = 0;
        //ker_code->access_byte.exec = 1;

        //ker_code->access_byte.present = 1;
        //ker_code->access_byte.privilage_level = 0;
        //ker_code->access_byte.descriptor_type = 1;
        //ker_code->base_1 = 0;
        //ker_code->base_2 = 0;
        //ker_code->base_3 = 0;
        //ker_code->limit_1 = 0xFFFF;
        //ker_code->limit_2 = 0xF;
        //ker_code->flags = 0b1010;
        gdt[3] = gdt[cpu_get_cs() / sizeof(SegmentDescriptor)]; // Code

        //gdt[4] = *ker_code; // Data
        //gdt[4].access_byte.exec = 0;
        gdt[4] = gdt[cpu_get_ss() / sizeof(SegmentDescriptor)]; // Data
        gdt[4].flags = 0b1100;
        gdt[4].access_byte.read_write = 1;
    }

    cpu_set_ss(4, FALSE, 0);

    // Initialize user segments
    SegmentDescriptor* const user_segs = gdt + 1;

    // [1]: Data: [2]: Code
    for (uint8_t i = 0; i < 2; ++i) {
        user_segs[i] = gdt[i == 0 ? 4 : 3];
        user_segs[i].access_byte.privilage_level = 3;
    }

    // Configure own GDT and per CPU TSS
    g_tss = kcalloc(sizeof(TaskStateSegment) * bootboot.numcores);

    gdt_size = (sizeof(SegmentDescriptor) * (gdt_segs_count + 1)) + (sizeof(SystemSegmentDescriptor) * bootboot.numcores);
    g_gdt = (SegmentDescriptor*)kcalloc(gdt_size);

    if (g_gdt == NULL || g_tss == NULL) {
        error_str = "Failed to allocate GDT/LDT/TSS";
        return KERNEL_ERROR;
    }

    memcpy((void*)gdt, (void*)g_gdt, (sizeof(SegmentDescriptor) * gdt_segs_count));

    SystemSegmentDescriptor* ssd = (SystemSegmentDescriptor*)(uint64_t)(g_gdt + gdt_segs_count);
    TaskStateSegment* tss = g_tss;

    for (uint32_t i = 0; i < bootboot.numcores; ++i) {
        const uint64_t base = (uint64_t)tss;
        tss->rsp0 = (uint64_t)_proc_get_local_data_by_idx(i)->kernel_stack;

        ssd->base_1 = (uint16_t)base;
        ssd->base_2 = (uint8_t)(base >> 16);
        ssd->base_3 = (uint8_t)(base >> 24);
        ssd->base_4 = (uint32_t)(base >> 32);
        ssd->flags = 0x0;
        ssd->access_byte_val = 0x89;
        ssd->limit_1 = sizeof(TaskStateSegment);
        ssd->limit_2 = 0;
        ssd->access_byte.privilage_level = 0;

        tss++;
        ssd++;
    }

    cpu_set_gdt(g_gdt, gdt_size - 1);
    cpu_set_tss(sizeof(SegmentDescriptor) * gdt_segs_count);

    g_proc_local.tss = g_tss + cpu_idx;

    return KERNEL_OK;
}

Status init_kernel() {
    if (split_logical_cores() != KERNEL_OK) return KERNEL_PANIC;

    if (intr_preinit_exceptions() != KERNEL_OK) return KERNEL_PANIC;

    if (init_memory()       != KERNEL_OK) return KERNEL_ERROR;
    if (init_intr()         != KERNEL_OK) return KERNEL_ERROR;

    if (init_acpi()         != KERNEL_OK) return KERNEL_ERROR;
    if (init_apic()         != KERNEL_OK) return KERNEL_ERROR;
    if (init_ioapic()       != KERNEL_OK) return KERNEL_ERROR;
    if (init_timer()        != KERNEL_OK) return KERNEL_ERROR;
    if (init_io_devices()   != KERNEL_OK) return KERNEL_ERROR;
    if (init_clock()        != KERNEL_OK) return KERNEL_ERROR;

    spin_release(&cpus_init_lock);

    if (init_usb()          != KERNEL_OK) return KERNEL_ERROR;
    if (init_pci()          != KERNEL_OK) return KERNEL_ERROR;

    init_syscalls();

    if (init_task_scheduler() != KERNEL_OK) return KERNEL_ERROR;
    if (init_user_space()     != KERNEL_OK) return KERNEL_ERROR;

    spin_release(&cpus_userspace_lock);

    if (init_vfs()          != KERNEL_OK) {
        char* str_buffer = (char*)kmalloc(sizeof(char[256]));
        sprintf(str_buffer, "VFS: %s", error_str);
        error_str = str_buffer;

        return KERNEL_ERROR;
    }

    return KERNEL_OK;
}

Status init_io_devices() {
    // TODO
    DisplayDevice* display = (DisplayDevice*)dev_push(DEV_DISPLAY, sizeof(DisplayDevice));
    KeyboardDevice* keyboard = (KeyboardDevice*)dev_push(DEV_KEYBOARD, sizeof(KeyboardDevice));

    if (display == NULL || keyboard == NULL) return KERNEL_ERROR;

    if (init_bootboot_display(display) != KERNEL_OK) return KERNEL_ERROR;
    if (init_ps2_keyboard(keyboard) != KERNEL_OK) {
        kernel_warn("Failed to init PS/2 keyboard: %s\n", error_str);
    }

    return KERNEL_OK;
}