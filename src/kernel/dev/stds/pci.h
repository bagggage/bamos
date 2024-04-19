#pragma once

#include "definitions.h"

#include "dev/device.h"

#define PCI_CONFIG_ADDRESS_PORT 0xCF8
#define PCI_CONFIG_DATA_PORT 0xCFC

#define PCI_BAR0_OFFSET 0x10
#define PCI_BAR1_OFFSET 0x14
#define PCI_BAR2_OFFSET 0x18
#define PCI_BAR3_OFFSET 0x1C
#define PCI_BAR4_OFFSET 0x20
#define PCI_BAR5_OFFSET 0x24

#define PCI_PROGIF_AHCI 0x1

typedef enum PciClassCode {
    UNDEFINED = 0,
    STORAGE_CONTROLLER,
    NETWORK_CONTROLLER,
    DISPLAY_CONTROLLER,
    MULTIMEDIA_CONTROLLER,
    MEMORY_CONTROLLER,
    BRIDGE,
    COMMUNICATION_CONTROLLER,
    SYSTEM_PERIPHERAL,
    INPUT_DEVICE_CONTROLLER,
    DOCKING_STATION,
    PROCESSOR,
    SERIAL_BUS_CONTROLLER,
    WIRELESS_CONTROLLER,
    INTELLIGENT_CONTROLLER,
    SATELLITE_CONTROLLER,
    ENCRYPTION_CONTROLLER,
    SIGNAL_PROCESSING_CONTROLLER,
    PROCESSING_ACCELERATOR
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
    OTHER = 0x80
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
    uint32_t bar0;
    uint32_t bar1;
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

typedef struct PciDeviceNode {
    uint8_t bus;
    uint8_t dev;
    uint8_t func;
    PciConfigurationSpace pci_header;
    struct PciDeviceNode* next;
} PciDeviceNode;

typedef struct PciInterface {
} PciInterface;

typedef struct PciDevice {
    DEVICE_STRUCT_IMPL(Pci);
    PciDeviceNode* head;
} PciDevice;

uint8_t pci_config_readb(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset);
uint16_t pci_config_readw(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset);
uint32_t pci_config_readl(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset);

void pci_config_writel(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset, const uint32_t value);

Status init_pci_device(PciDevice* pci_device);
bool_t add_new_pci_device(const PciDeviceNode* new_pci_device);
void remove_pci_device(PciDevice* pci_device, const size_t index);