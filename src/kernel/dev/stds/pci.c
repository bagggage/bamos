#include "pci.h"

#include "logger.h"

#include "cpu/io.h"

#include "ahci.h"

#define PCI_INVALID_VENDOR_ID 0xFFFF

extern HBAMemory* HBA_memory;

uint8_t pci_config_readb(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset) {
    uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    // (offset & 3) * 8) = 0 will choose the first byte of the 32-bit register
    return inw(PCI_CONFIG_DATA_PORT + (offset & 3));
}

uint16_t pci_config_readw(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset) {
    uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    // (offset & 2) * 8) = 0 will choose the first word of the 32-bit register
    return inw(PCI_CONFIG_DATA_PORT + (offset & 2));
}

uint32_t pci_config_readl(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset) {
    uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    return inl(PCI_CONFIG_DATA_PORT);
}

uint64_t read_BAR(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset) {
    uint64_t bar = pci_config_readl(bus, dev, func, offset);
    uint64_t bar_type;

    if (bar == 0) {
        kernel_error("Bar with offset %x is 0\n", offset);

        return NULL;
    } else {
        if ((bar & 1) == 0) {  // bar is in memory space
            bar_type = (bar >> 1) & 0x3;

            if ((bar_type & 2) == 0 ) {    //bar is in 32bit memory space
 				kernel_msg("Bar with offset %x is in 32bit on bus: %u, dev: %u, func: %u\n", offset, bus, dev, func);

                return (bar & 0xFFFFFFF0); // Clear flags
            } else {
                kernel_msg("Bar with offset %x is in 64bit on bus: %u, dev: %u, func: %u\n", offset, bus, dev, func);

                return (bar & 0xFFFFFFFFFFFFFFF0); // Clear flags
            }
        } else {    // bar is in i/o space 
            kernel_msg("Bar with offset %x is in I/O space on bus: %u, dev: %u, func: %u\n", offset, bus, dev, func);

            return (bar & 0xFFFFFFFC); // Clear flags
        } 
    }
  
    return NULL;
}

Status init_pci_devices() {
    for (uint8_t bus = 0; bus < 4; ++bus) {
        for (uint8_t dev = 0; dev < 32; ++dev) {
            for (uint8_t func = 0; func < 8; ++func) {
                uint16_t vendor_id = pci_config_readw(bus, dev, func, 0);

                if (vendor_id == 0xFFFF) break;

                uint8_t prog_if = pci_config_readb(bus, dev, func, 0x9);
                uint8_t subclass = pci_config_readb(bus, dev, func, 0xA);
                uint8_t class_code = (pci_config_readw(bus, dev, func, 0xB) >> 8);  // for no reason readbyte on 0xB we always get 0xFF
                

                if (is_ahci(class_code, prog_if, subclass)) {
                    HBA_memory = read_BAR(bus, dev, func, PCI_BAR5_OFFSET);
                    detect_ahci_devices_type();
                }


                kernel_msg("PCI bus: %u: dev: %u: func: %u: vendor id - %x\n",
                    (uint32_t)bus,
                    (uint32_t)dev,
                    (uint32_t)func,
                    (uint64_t)vendor_id);
            }
        }
    }

    return KERNEL_OK;
}