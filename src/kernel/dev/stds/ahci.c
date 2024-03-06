#include "ahci.h"

#include "logger.h"
#include "pci.h"

#define	SATA_SIG_ATA	0x00000101	// SATA drive
#define	SATA_SIG_ATAPI	0xEB140101	// SATAPI drive
#define	SATA_SIG_SEMB	0xC33C0101	// Enclosure management bridge
#define	SATA_SIG_PM	    0x96690101	// Port multiplier
 
#define AHCI_DEV_NULL   0
#define AHCI_DEV_SATA   1
#define AHCI_DEV_SEMB   2
#define AHCI_DEV_PM     3
#define AHCI_DEV_SATAPI 4
 
#define HBA_PORT_IPM_ACTIVE     1
#define HBA_PORT_DET_PRESENT    3

#define MAX_IMPLEMENTED_PORTS   32

HBAMemory* HBA_memory = NULL;

bool_t is_ahci(uint8_t class_code, uint8_t prog_if, uint8_t subclass) {
    if (class_code == PCI_CLASS_CODE_STORAGE_CONTROLLER &&
        prog_if == PCI_PROGIF_AHCI &&
        subclass == PCI_SUBCLASS_SATA_CONTROLLER) {
        return TRUE;
    }

    return FALSE;
}

static uint8_t check_device_type(HBAPort* port) {
    uint32_t sata_status = port->sata_status;

    uint8_t ipm = (sata_status >> 8) & 0x0F;
    uint8_t det = sata_status & 0x0F;

    if (det != HBA_PORT_DET_PRESENT)	// Check drive status
        return AHCI_DEV_NULL;
    if (ipm != HBA_PORT_IPM_ACTIVE)
        return AHCI_DEV_NULL;

    switch (port->signature) {
        case SATA_SIG_ATAPI:
            return AHCI_DEV_SATAPI;
        case SATA_SIG_SEMB:
            return AHCI_DEV_SEMB;
        case SATA_SIG_PM:
            return AHCI_DEV_PM;
        default:
            return AHCI_DEV_SATA;
        }
}

void detect_ahci_devices_type() {
	uint32_t port_implemented = HBA_memory->port_implemented;

    for (size_t i = 0; i < MAX_IMPLEMENTED_PORTS; ++i) {
        if (port_implemented & 1) {
            uint8_t device_type = check_device_type(&HBA_memory->ports[i]);

            switch (device_type) {
            case AHCI_DEV_SATA: {
				kernel_msg("SATA drive found at port %d\n", i);
                break;
            }
            case AHCI_DEV_SATAPI: {
                kernel_msg("SATAPI drive found at port %d\n", i);
                break;
            }
            case AHCI_DEV_SEMB: {
                kernel_msg("SEMB drive found at port %d\n", i);
                break;
            }
            case AHCI_DEV_PM: {
                kernel_msg("PM drive found at port %d\n", i);
                break;
            }
            default: {
				//kernel_msg("No drive found at port %d\n", i);
                break;
            }
            }
        }

        port_implemented >>= 1;
    }
}