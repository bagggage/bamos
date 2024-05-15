#pragma once

#include "definitions.h"

#include "dev/device.h"

#define PCI_CONFIG_ADDRESS_PORT 0xCF8
#define PCI_CONFIG_DATA_PORT 0xCFC

typedef enum PciBarOffset {
    PCI_BAR0_OFFSET = 0x10,
    PCI_BAR1_OFFSET = 0x14,
    PCI_BAR2_OFFSET = 0x18,
    PCI_BAR3_OFFSET = 0x1C,
    PCI_BAR4_OFFSET = 0x20,
    PCI_BAR5_OFFSET = 0x24
} PciBarOffset;

typedef enum PciClassCode {
    PCI_UNDEFINED = 0,
    PCI_STORAGE_CONTROLLER,
    PCI_NETWORK_CONTROLLER,
    PCI_DISPLAY_CONTROLLER,
    PCI_MULTIMEDIA_CONTROLLER,
    PCI_MEMORY_CONTROLLER,
    PCI_BRIDGE,
    PCI_COMMUNICATION_CONTROLLER,
    PCI_SYSTEM_PERIPHERAL,
    PCI_INPUT_DEVICE_CONTROLLER,
    PCI_DOCKING_STATION,
    PCI_PROCESSOR,
    PCI_SERIAL_BUS_CONTROLLER,
    PCI_WIRELESS_CONTROLLER,
    PCI_INTELLIGENT_CONTROLLER,
    PCI_SATELLITE_CONTROLLER,
    PCI_ENCRYPTION_CONTROLLER,
    PCI_SIGNAL_PROCESSING_CONTROLLER,
    PCI_PROCESSING_ACCELERATOR
} PciClassCode;

typedef enum StorageControllerSubclass {
    SCIS_BUS_CONTROLLER = 0,
    IDE_CONTROLLER,
    FLOPPY_DISK_CONTROLLER,
    IPI_BUS_CONTROLLER,
    RAID_CONTROLLER,
    ATA_CONTROLLER,
    SATA_CONTROLLER,
    SERIAL_ATTACHED_SCSI_CONTROLLER,
    NVME_CONTROLLER,
    OTHER_SUBCLASS = 0x80
} StorageControllerSubclass;

typedef struct PciConfigurationSpace {
    uint16_t vendor_id;
    uint16_t device_id;
    uint16_t command;
    uint16_t status;
    uint8_t revision_id;
    uint8_t prog_if;
    uint8_t subclass;
    uint8_t class_code;
    uint8_t cache_line_size;
    uint8_t latency_timer;
    uint8_t header_type;
    uint8_t bist;
    uint64_t bar0;
    uint64_t bar1;
    uint32_t bar2;
    uint32_t bar3;
    uint32_t bar4;
    uint32_t bar5;
    uint32_t cardbus_cis_pointer;
    uint16_t subsystem_vendor_id;
    uint16_t subsystem_id;
    uint32_t expansion_rom_base_address;
    uint8_t capabilities_pointer;
    uint8_t reserved1;
    uint16_t reserved2;
    uint32_t reserved3;
    uint8_t interrupt_line;
    uint8_t interrupt_pin;
    uint8_t min_grant;
    uint8_t max_latency;
} ATTR_PACKED PciConfigurationSpace;

typedef struct PciDevice {
    LIST_STRUCT_IMPL(PciDevice);

    uint8_t bus;
    uint8_t dev;
    uint8_t func;

    PciConfigurationSpace config;
} PciDevice;

typedef struct PciBus {
    BUS_STRCUT_IMPL;
} PciBus;

uint8_t pci_config_readb(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset);
uint16_t pci_config_readw(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset);
uint32_t pci_config_readl(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset);

void pci_config_writel(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset, const uint32_t value);

Status init_pci_bus(PciBus* const pci_bus);

bool_t is_pci_bus(const Device* const device);