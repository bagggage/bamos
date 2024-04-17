#include "apic.h"

#include "logger.h"

#include "cpu/feature.h"
#include "cpu/regs.h"

#include "vm/vm.h"

#define MSR_APIC_ENABLE 0x800

typedef struct InterruptCommand {
    uint32_t vector             : 8;
    uint32_t delivery_mode      : 3;
    uint32_t dest_mode          : 1;
    uint32_t delivery_status    : 1;
    uint32_t reserved0          : 1;
    uint32_t level_init         : 1;
    uint32_t level_init_rvrs    : 1;
    uint32_t reserved1          : 2;
    uint32_t dest_type          : 2;
    uint32_t reserved2          : 12;
} ATTR_PACKED InterruptCommand;

static MADT* apic_madt = NULL;

static MADTEntry* get_madt_entry_at(const size_t idx) {
    MADTEntry* entry = &apic_madt->entries;

    for (size_t i = 0; i < idx; ++i) {
        entry = (MADTEntry*)((uint64_t)entry + entry->length);
    }

    return entry;
}

MADTEntry* madt_find_first_entry_of_type(const MADTEntryType type) {
    const uint64_t apic_madt_end = (uint64_t)apic_madt + apic_madt->header.length;

    MADTEntry* entry = &apic_madt->entries;

    while ((uint64_t)entry < apic_madt_end) {
        if (entry->type == (uint8_t)type) return entry;

        entry = (MADTEntry*)((uint64_t)entry + entry->length);
    }

    return NULL;
}

MADTEntry* madt_next_entry_of_type(MADTEntry* begin, const MADTEntryType type) {
    const uint64_t apic_madt_end = (uint64_t)apic_madt + apic_madt->header.length;

    MADTEntry* entry = (MADTEntry*)((uint64_t)begin + begin->length);

    while ((uint64_t)entry < apic_madt_end) {
        if (entry->type == (uint8_t)type) return entry;

        entry = (MADTEntry*)((uint64_t)entry + entry->length);
    }

    return NULL;
}

uint32_t lapic_read(const uint32_t reg) {
    return *(uint32_t*)(apic_madt->lapic_address + reg);
}

void lapic_write(const uint32_t reg, const uint32_t value) {
    *(uint32_t*)(apic_madt->lapic_address + reg) = value;
}

uint32_t lapic_get_cpu_idx() {
    return lapic_read(LAPIC_ID_REG);
}

static void apic_enable() {
    cpu_set_msr(MSR_APIC_BASE, cpu_get_msr(MSR_APIC_BASE) | MSR_APIC_ENABLE);
    lapic_write(LAPIC_SUPRIOR_INT_VEC_REG, 0x100);
    lapic_write(LAPIC_TPR_REG, 0x00);
}

bool_t is_apic_avail() {
    return cpu_is_feature_supported(CPUID_FEAT_EDX_APIC);
}

Status init_apic() {
    if (is_apic_avail() == FALSE) {
        error_str = "APIC Not supported";
        return KERNEL_ERROR;
    }

    apic_madt = (MADT*)acpi_find_entry("APIC");

    if (apic_madt == NULL) { 
        error_str = "MADT entry not found";
        return KERNEL_ERROR;
    }

    if (acpi_checksum((ACPISDTHeader*)apic_madt) == FALSE) {
        apic_madt = NULL;
        error_str = "MADT Checksum failed";
        return KERNEL_ERROR;
    }

    kernel_msg("APIC Local register base: %x\n", (uint64_t)apic_madt->lapic_address);

    if (vm_map_phys_to_virt((uint64_t)apic_madt->lapic_address,
            (uint64_t)apic_madt->lapic_address,
            1,
            VMMAP_WRITE | VMMAP_CACHE_DISABLED) != KERNEL_OK) {
        error_str = "APIC: Mapping failed";
        return KERNEL_ERROR;
    }

    apic_enable();

    //MADTEntry* entry = &apic_madt->entries;

    //while ((uint64_t)entry < (uint64_t)apic_madt + apic_madt->header.length) {
    //    kernel_msg("MADT Entry: type: %x: length: %u byte\n", (uint64_t)entry->type, (uint32_t)entry->length);
//
    //    switch (entry->type)
    //    {
    //    case MADT_ENTRY_TYPE_PROC_LAPIC:
    //        ProcLocalAPIC* plapic = (ProcLocalAPIC*)entry;
//
    //        kernel_warn("-LAPIC: %u: ID: %u\n",
    //            (uint32_t)plapic->acpi_proc_id,
    //            (uint32_t)plapic->apic_id);
    //        break;
    //    case MADT_ENTRY_TYPE_IOAPIC:
    //        IOAPIC* ioapic = (IOAPIC*)entry;
//
    //        kernel_warn("-IOAPIC: %x: ID: %u: BASE: %u\n",
    //            (uint64_t)ioapic->ioapic_address,
    //            (uint32_t)ioapic->ioapic_id,
    //            ioapic->global_sys_int_base);
    //        break;
    //    case MADT_ENTRY_TYPE_IOAPIC_INT_SRC_OVERR:
    //        IOAPICIntSourceOverride* ioapic_src_over = (IOAPICIntSourceOverride*)entry;
//
    //        kernel_warn("-IOAPIC INT SRC OVER: bus: %u: SYS INT: %x: IRQ: %u: FLAGS: %b\n",
    //            (uint32_t)ioapic_src_over->bus_source,
    //            (uint64_t)ioapic_src_over->global_sys_int,
    //            (uint32_t)ioapic_src_over->irq_source,
    //            ioapic_src_over->flags);
    //        break;
    //    case MADT_ENTRY_TYPE_IOAPIC_NONMASK_INT:
    //        break;
    //    default:
    //        break;
    //    }
//
    //    entry = (MADTEntry*)((uint64_t)entry + entry->length);
    //}

    return KERNEL_OK;
}