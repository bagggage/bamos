#include "ioapic.h"

#include "assert.h"
#include "logger.h"

#include "intr/apic.h"

#include "vm/vm.h"

typedef struct IOAPICDev {
    uint64_t base;
    uint32_t id;
    uint32_t version;
    uint32_t redirections_count;
} IOAPICDev;

static IOAPIC* ioapic_madt = NULL;
static IOAPICDev ioapic;

uint64_t ioapic_base = 0;

bool_t is_ioapic_avail() {
    if (ioapic_madt == NULL) ioapic_madt = (IOAPIC*)madt_find_first_entry_of_type(MADT_ENTRY_TYPE_IOAPIC);

    return ioapic_madt != NULL;
}

void ioapic_redirect_irq(const uint8_t irq_idx, const uint8_t vector) {
    kassert(irq_idx < 24 && vector >= 0x10 && vector <= 0xFE);
}

void ioapic_mask_irq(const uint8_t irq_idx, const bool_t is_masked) {
    const uint8_t redirection_entry_reg_offset = IOAPIC_REDTBL_OFFSET + (irq_idx * IOAPIC_REDIR_ENTRY_LENGTH);
    const uint64_t temp_entry = ioapic_read64(ioapic.base, redirection_entry_reg_offset);

    ((IRQRedirectionEntry*)&temp_entry)->mask = is_masked ? 1 : 0;

    ioapic_write64(ioapic.base, redirection_entry_reg_offset, temp_entry);
}

Status init_ioapic() {
    if (is_ioapic_avail() == FALSE) {
        error_str = "IOAPIC Not available";
        return KERNEL_ERROR;
    }

    ioapic_base = (uint64_t)ioapic_madt->ioapic_address;

    if (vm_map_phys_to_virt(ioapic_base, ioapic_base, 1, VMMAP_WRITE | VMMAP_CACHE_DISABLED) != KERNEL_OK) {
        error_str = "IOAPIC: Mapping failed";
        return KERNEL_ERROR;
    }

    const uint32_t ver_reg = ioapic_read32(ioapic_base, IOAPIC_VER_REG);

    ioapic.base = ioapic_base;
    ioapic.id = ioapic_madt->ioapic_id;
    ioapic.version = (ver_reg & 0xff);
    ioapic.redirections_count = (ver_reg >> 16) + 1;

    kernel_msg("IOAPIC: %x: id: %u: ver: %u.%u: redirections count: %u\n",
        (uint64_t)ioapic_madt->ioapic_address,
        (uint32_t)ioapic_madt->ioapic_id,
        ioapic.version >> 4, ioapic.version & 0x0f,
        ioapic.redirections_count);

    for (uint8_t i = 0; i < ioapic.redirections_count; ++i) {
        ioapic_mask_irq(i, TRUE);
    }

    return KERNEL_OK;
}