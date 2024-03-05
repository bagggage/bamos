#include "apic.h"

#include "logger.h"

MADT* apic_madt = NULL;

static MADTEntry* get_madt_entry_at(size_t idx) {
    MADTEntry* entry = &apic_madt->entries;

    for (size_t i = 0; i < idx; ++i) {
        entry = (MADTEntry*)((uint64_t)entry + entry->length);
    }

    return entry;
}

MADTEntry* madt_find_fist_entry_of_type(MADTEntryType type) {
    MADTEntry* entry = &apic_madt->entries;

    while ((uint64_t)entry < ((uint64_t)apic_madt + apic_madt->header.length)) {
        if (entry->type == (uint8_t)type) return entry;

        entry = (MADTEntry*)((uint64_t)entry + entry->length);
    }

    return NULL;
}

// TODO: Implement
bool_t is_apic_avail() {
    return TRUE;
}

Status init_apic() {
    if (is_apic_avail() == FALSE) return KERNEL_ERROR;

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

    //MADTEntry* entry = &apic_madt->entries;

    //while ((uint64_t)entry < (uint64_t)apic_madt + apic_madt->header.length) {
    //    kernel_msg("MADT Entry:\ntype: %x\nlength: %u byte\n\n", (uint64_t)entry->type, (uint32_t)entry->length);
    //    entry = (MADTEntry*)((uint64_t)entry + entry->length);
    //}

    return KERNEL_OK;
}