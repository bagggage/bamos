#include "acpi.h"

#include <bootboot.h>

#include "mem.h"
#include "io/logger.h"
#include "io/tty.h"

extern BOOTBOOT bootboot;

XSDT* acpi_xsdt = NULL;
RSDT* acpi_rsdt = NULL;

// Size of XSDT entries array
size_t acpi_xsdt_size = 0;
// Size of RSDT entries array
size_t acpi_rsdt_size = 0;

bool_t acpi_checksum(ACPISDTHeader* header) {
    unsigned char sum = 0;

    for (int i = 0; i < header->length; i++) {
        sum += ((char*)header)[i];
    }
 
    return sum == 0;
}

static bool_t is_acpi_enabled(FADT* fadt) {
    return fadt->smi_command_port == 0 ||
        (fadt->acpi_enable == 0 && fadt->acpi_disable == 0) ||
        (fadt->x_pm1a_control_block.address & 1);
}

ACPISDTHeader* acpi_find_entry(const char signature[4]) {
    for (size_t i = 0; i < acpi_xsdt_size; ++i) {
        ACPISDTHeader* entry = (ACPISDTHeader*)acpi_xsdt->other_sdt[i];
        const char* sign = entry->signature;

        if (*(uint32_t*)signature == *(uint32_t*)sign) return entry;
    }

    return NULL;
}

Status init_acpi() {
    acpi_xsdt = bootboot.arch.x86_64.acpi_ptr;
    acpi_rsdt = bootboot.arch.x86_64.acpi_ptr;
    acpi_xsdt_size = (acpi_xsdt->header.length - sizeof(acpi_xsdt->header)) >> 3; // divide by 8
    acpi_rsdt_size = (acpi_rsdt->header.length - sizeof(acpi_rsdt->header)) >> 2; // divide by 4

    kernel_msg("ACPI v%u.0\n", (uint32_t)acpi_xsdt->header.revision + 1);

    if (acpi_checksum(&acpi_xsdt->header) == FALSE) {
        error_str = "XSDT Checksum failed";
        return KERNEL_ERROR;
    }

    kernel_msg("XSDT Entries count: %u\n", acpi_xsdt_size);

    FADT* fadt = (FADT*)acpi_find_entry("FACP");

    if (fadt == NULL) {
        error_str = "FADT Not found";
        return KERNEL_ERROR;
    }

    if (acpi_checksum(fadt) == FALSE) {
        error_str = "FADT checksum failed";
        return KERNEL_ERROR;
    }

    kernel_msg("FADT Located at: %x\n", fadt);

    if (is_acpi_enabled(fadt) == FALSE) {
        kernel_msg("Enable ACPI...\n");

        // TODO: Implement code to enable ACPI
        //outw(fadt->smi_command_port, fadt->acpi_enable);

        //while (inw(fadt->pm1a_control_block) & 1 == 0);
    }

    return KERNEL_OK;
}