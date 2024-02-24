#include "pci.h"
#include "io/tty.h"

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