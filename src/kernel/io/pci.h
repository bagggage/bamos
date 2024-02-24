#pragma once

#include "definitions.h"

#define PCI_CONFIG_ADDRESS_PORT 0xCF8
#define PCI_CONFIG_DATA_PORT 0xCFC

typedef struct PciConfigurationSpace {
    uint16_t vendor_id;
    uint16_t device_id;
} PciConfigurationSpace;

uint8_t pci_config_readb(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset);
uint16_t pci_config_readw(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset);
uint32_t pci_config_readl(uint8_t bus, uint8_t dev, uint8_t func, uint8_t offset);