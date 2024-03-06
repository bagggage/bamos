#pragma once

#include "definitions.h"

#define PCI_CONFIG_ADDRESS_PORT 0xCF8
#define PCI_CONFIG_DATA_PORT 0xCFC

#define PCI_BAR0_OFFSET 0x10
#define PCI_BAR1_OFFSET 0x14
#define PCI_BAR2_OFFSET 0x18
#define PCI_BAR3_OFFSET 0x1C
#define PCI_BAR4_OFFSET 0x20
#define PCI_BAR5_OFFSET 0x24

#define PCI_CLASS_CODE_STORAGE_CONTROLLER 0x1
#define PCI_SUBCLASS_SATA_CONTROLLER 0X6
#define PCI_PROGIF_AHCI 0X1

typedef struct PciConfigurationSpace {
    uint16_t vendor_id;
    uint16_t device_id;
} PciConfigurationSpace;

uint8_t pci_config_readb(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset);
uint16_t pci_config_readw(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset);
uint32_t pci_config_readl(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset);

uint64_t read_BAR(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset);

Status init_pci_devices();