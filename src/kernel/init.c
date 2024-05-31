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
#include "dev/storage.h"

#include "fs/vfs.h"

#include "intr/apic.h"
#include "intr/intr.h"
#include "intr/ioapic.h"

#include "proc/local.h"
#include "proc/task_scheduler.h"

#include "rawtsk/task.h"

#include "vm/vm.h"

extern BOOTBOOT bootboot;
extern uint64_t initstack[];
extern const uint8_t _binary_font_psf_start;

static Spinlock cpus_init_lock = { 1 };

static void wait_for_cpu_init() {
    spin_lock(&cpus_init_lock);

    vm_configure_cpu_page_table();
    cpu_set_idtr(intr_get_kernel_idtr());
    configure_lapic_timer();
    init_user_space();

    spin_release(&cpus_init_lock);

    while (TRUE) {
        tsk_exec();
    }

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
    g_proc_local.kernel_stack = (uint64_t*)(UINT64_MAX - ((uint64_t)initstack * (cpu_idx + 1)) + 1);
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

Status init_storage() {
    if (init_storage_devices() != KERNEL_OK) return KERNEL_ERROR;
    
    return KERNEL_OK;
}

Status init_user_space() {
    EFER efer = cpu_get_efer();

    // Enable syscalls
    efer.syscall_ext = 1;

    cpu_set_efer(efer);
    cpu_set_msr(MSR_STAR, 0x0);
    cpu_set_msr(MSR_LSTAR, (uint64_t)&_syscall_handler);
    cpu_set_msr(MSR_CSTAR, 0x0);
    cpu_set_msr(MSR_SWAPGS_BASE, 0x0);

    if (lapic_get_cpu_idx() != 0) return KERNEL_OK;

    SegmentDescriptor* gdt = (SegmentDescriptor*)cpu_get_current_gdtr().base;

    // Move kernel segments
    gdt[3] = gdt[7];
    gdt[4] = gdt[6];

    // Initialize user segments
    SegmentDescriptor* user_segs = gdt + 1;

    for (uint8_t i = 0; i < 2; ++i) {
        user_segs[i].base_1 = 0;
        user_segs[i].base_2 = 0;
        user_segs[i].base_3 = 0;
        user_segs[i].limit_1 = 0xFFFF;
        user_segs[i].limit_2 = 0xF;
        user_segs[i].flags = (i == 0 ? 0b1010 : 0b1100);

        SegmentAccessByte* access_byte = (SegmentAccessByte*)&user_segs[i].access_byte;

        access_byte->present = 1;
        access_byte->privilage_level = USER_PRIVILAGE_LEVEL;
        access_byte->descriptor_type = 1;
        access_byte->exec = i;
        access_byte->dc = 0;
        access_byte->read_write = 1;
    }

    init_syscalls();

    return init_task_scheduler();
}

Status init_kernel() {
    if (split_logical_cores() != KERNEL_OK) return KERNEL_PANIC;

    if (init_intr()         != KERNEL_OK) return KERNEL_PANIC;
    if (init_memory()       != KERNEL_OK) return KERNEL_ERROR;

    if (init_acpi()         != KERNEL_OK) return KERNEL_ERROR;
    if (init_apic()         != KERNEL_OK) return KERNEL_ERROR;
    if (init_ioapic()       != KERNEL_OK) return KERNEL_ERROR;
    if (init_timer()        != KERNEL_OK) return KERNEL_ERROR;
    if (init_io_devices()   != KERNEL_OK) return KERNEL_ERROR;
    if (init_timer()        != KERNEL_OK) return KERNEL_ERROR;
    if (init_clock()        != KERNEL_OK) return KERNEL_ERROR;

    spin_release(&cpus_init_lock);

    if (init_pci()          != KERNEL_OK) return KERNEL_ERROR;
    if (init_storage()      != KERNEL_OK) {
        kernel_error("Storage devices initialization failed: %s\n", error_str);
    }

    if (init_user_space()   != KERNEL_OK) return KERNEL_ERROR;

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
    //if (init_ps2_keyboard(keyboard) != KERNEL_OK) return KERNEL_ERROR;

    return KERNEL_OK;
}