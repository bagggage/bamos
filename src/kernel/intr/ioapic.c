#include "ioapic.h"

#include "logger.h"

#include "intr/apic.h"

IOAPIC* ioapic = NULL;

bool_t is_ioapic_avail() {
    if (ioapic == NULL) ioapic = (IOAPIC*)madt_find_fist_entry_of_type(MADT_ENTRY_TYPE_IOAPIC);

    return ioapic != NULL;
}

Status init_ioapic() {
    if (is_apic_avail() == FALSE) return KERNEL_ERROR;

    kernel_msg("IOAPIC Address: %x\n", (uint64_t)ioapic->ioapic_address);

    return KERNEL_OK;
}