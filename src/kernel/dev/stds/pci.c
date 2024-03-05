#include "pci.h"

#include "logger.h"

#include "cpu/io.h"

#define PCI_INVALID_VENDOR_ID 0xFFFF

uint8_t pci_config_readb(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset) {
    uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    // (offset & 2) * 8) = 0 will choose the first word of the 32-bit register
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

    // (offset & 2) * 8) = 0 will choose the first word of the 32-bit register
    return inw(PCI_CONFIG_DATA_PORT);
}

void log_pci_devices() {
    for (uint8_t bus = 0; bus < 4; ++bus) {
        for (uint8_t dev = 0; dev < 32; ++dev) {
            for (uint8_t func = 0; func < 8; ++func) {
                uint16_t vendor_id = pci_config_readw(bus, dev, func, 0);

                if (vendor_id == 0xFFFF) break;

                kernel_msg("PCI bus: %u: dev: %u: func: %u: vendor id - %x\n",
                    (uint32_t)bus,
                    (uint32_t)dev,
                    (uint32_t)func,
                    (uint64_t)vendor_id);
            }
        }
    }
}