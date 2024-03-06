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

Status init_ahci() {
    for (uint8_t bus = 0; bus < 4; ++bus) {
        for (uint8_t dev = 0; dev < 32; ++dev) {
            for (uint8_t func = 0; func < 8; ++func) {
                uint16_t vendor_id = pci_config_readw(bus, dev, func, 0x0);

                uint8_t prog_if = pci_config_readb(bus, dev, func, 0x9);
                uint8_t subclass = pci_config_readb(bus, dev, func, 0xA);

                if (vendor_id == 0xffff) continue;

                if (is_ahci(prog_if, subclass)) {
                    init_HBA_memory(bus, dev, func);
                    detect_ahci_devices_type();
                }
            }
        }
    }

    return KERNEL_OK;
}

Status init_HBA_memory(uint8_t bus, uint8_t dev, uint8_t func) {
    uint64_t bar5 = pci_config_readl(bus, dev, func, 0x24);
    uint64_t bar5_type;

    if (bar5 == 0) {
        kernel_error("bar5 is 0\n");

        return KERNEL_ERROR;
    } else {
        if ((bar5 & 1) == 0) {  // bar5 is in memory space
            bar5_type = (bar5 >> 1) & 0x3;

            if ((bar5_type & 2) == 0 ) {    //bar5 is in 32bit memory space
 				kernel_msg("bar5 is in 32bit on bus: %u, dev: %u, func: %u\n", bus, dev, func);

                HBA_memory = bar5 & 0xFFFFFFF0; // Clear flags
            } else {
                kernel_msg("bar5 is in 64bit on bus: %u, dev: %u, func: %u\n", bus, dev, func);

                HBA_memory = bar5 & 0xFFFFFFFFFFFFFFF0; // Clear flags
            }
        } else {    // bar5 is in i/o space 
            kernel_msg("bar5 is in I/O space on bus: %u, dev: %u, func: %u\n", bus, dev, func);

            HBA_memory = bar5 & 0xFFFFFFFC; // Clear flags
        } 
    }
				
    return KERNEL_OK;
}

bool_t is_ahci(uint8_t prog_if, uint8_t subclass) {
    if (prog_if == PCI_PROGIF_AHCI && subclass == PCI_SUBCLASS_SATA_CONTROLLER) {
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
				kernel_msg("No drive found at port %d\n", i);
                break;
            }
            }
        }

        port_implemented >>= 1;
    }
}