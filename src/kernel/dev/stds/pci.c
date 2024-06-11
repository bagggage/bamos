#include "pci.h"

#include "assert.h"
#include "logger.h"
#include "mem.h"
#include "xhci.h"

#include "dev/blk/nvme.h"

#include "cpu/io.h"

#define PCI_INVALID_VENDOR_ID 0xFFFF
#define PCI_BAR_STEP_OFFSET 0x4

typedef enum PciDevInitStatus {
    PCI_DEV_DRIVER_FAILED = -1,
    PCI_DEV_NO_DRIVER = 0,
    PCI_DEV_SUCCESS = 1
} PciDevInitStatus;

static ObjectMemoryAllocator* pci_dev_oma = NULL;

uint8_t pci_config_readb(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset) {
    const uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    // (offset & 3) * 8) = 0 will choose the first byte of the 32-bit register
    return inw(PCI_CONFIG_DATA_PORT + (offset & 3));
}

uint16_t pci_config_readw(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset) {
    const uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    // (offset & 2) * 8) = 0 will choose the first word of the 32-bit register
    return inw(PCI_CONFIG_DATA_PORT + (offset & 2));
}

uint32_t pci_config_readl(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset) {
    const uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    return inl(PCI_CONFIG_DATA_PORT);
}

void pci_config_writel(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset, const uint32_t value) {
    const uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);
    outl(PCI_CONFIG_DATA_PORT, value);
}

static uint64_t pci_read_bar(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset) {
    const uint32_t bar = pci_config_readl(bus, dev, func, offset);

    if (bar == 0) return bar;

    if ((bar & 1) == 0) {  // bar is in memory space
        const uint32_t bar_type = (bar >> 1) & 0x3;

        //bar is in 32bit memory space
        if ((bar_type & 2) == 0) return (bar & 0xFFFFFFF0); // Clear flags

        //bar is in 64bit memory space
        return ((bar & 0xFFFFFFF0) + ((uint64_t)pci_config_readl(bus, dev, func, offset + 0x4) << 32));
    }
    else {  // bar is in i/o space 
        return (bar & 0xFFFFFFFC); // Clear flags
    } 

    return 0;
}

static void pci_read_config_space(PciDevice* const pci_dev) {
    const uint32_t bus = pci_dev->bus;
    const uint32_t dev = pci_dev->dev;
    const uint32_t func = pci_dev->func;

    pci_dev->config.device_id = pci_config_readw(bus, dev, func, 2);
    pci_dev->config.prog_if = pci_config_readb(bus, dev, func, 0x9);
    pci_dev->config.subclass = pci_config_readb(bus, dev, func, 0xA);
    pci_dev->config.class_code = (pci_config_readw(bus, dev, func, 0xB) >> 8);  // for no reason readbyte on 0xB we always get 0xFF
    pci_dev->config.bar0 = pci_read_bar(bus, dev, func, PCI_BAR0_OFFSET);
    pci_dev->config.bar1 = pci_read_bar(bus, dev, func, PCI_BAR1_OFFSET);
    pci_dev->config.bar2 = pci_read_bar(bus, dev, func, PCI_BAR2_OFFSET);
    pci_dev->config.bar3 = pci_read_bar(bus, dev, func, PCI_BAR3_OFFSET);
    pci_dev->config.bar4 = pci_read_bar(bus, dev, func, PCI_BAR4_OFFSET);
    pci_dev->config.bar5 = pci_read_bar(bus, dev, func, PCI_BAR5_OFFSET);
}

static void pci_bus_push(PciBus* const bus, PciDevice* const dev) {
    dev->next = NULL;

    if (bus->nodes.next == NULL) {
        bus->nodes.next = (void*)dev;
        bus->nodes.prev = (void*)dev;
    }
    else {
        dev->prev = (void*)bus->nodes.prev;

        bus->nodes.prev->next = (void*)dev;
        bus->nodes.prev = (void*)dev;
    }

    bus->size++;
}

static PciDevInitStatus pci_find_and_load_driver(PciDevice* const pci_device) {
    Status status = KERNEL_OK;

    switch (pci_device->config.class_code)
    {
    case PCI_STORAGE_CONTROLLER:
        if (is_nvme_controller(pci_device)) status = init_nvme_controller(pci_device);
        break;
    case PCI_SERIAL_BUS_CONTROLLER:
        if (is_xhci_controller(pci_device)) status = init_xhci_controller(pci_device);
        break;
    default:
        return PCI_DEV_NO_DRIVER;
        break;
    }

    return (status == KERNEL_OK) ? PCI_DEV_SUCCESS : PCI_DEV_DRIVER_FAILED;
}

Status init_pci_bus(PciBus* const pci_bus) {
    kassert(pci_bus != NULL);

    pci_bus->nodes.next = NULL;
    pci_bus->nodes.prev = NULL;
    pci_bus->size = 0;

    pci_dev_oma = _oma_new(sizeof(PciDevice), 1);

    if (pci_dev_oma == NULL) return KERNEL_ERROR;

    for (uint8_t bus = 0; bus < 4; ++bus) {
        for (uint8_t dev = 0; dev < 32; ++dev) {
            for (uint8_t func = 0; func < 8; ++func) {
                uint16_t vendor_id = pci_config_readw(bus, dev, func, 0);

                if (vendor_id == 0xFFFF || vendor_id == 0) continue;

                PciDevice* current_dev = (PciDevice*)oma_alloc(pci_dev_oma);

                if (current_dev == NULL) return KERNEL_ERROR;

                current_dev->bus = bus;
                current_dev->dev = dev;
                current_dev->func = func;
                current_dev->config.vendor_id = vendor_id;

                pci_read_config_space(current_dev);
                pci_bus_push(pci_bus, current_dev);

                const PciDevInitStatus status = pci_find_and_load_driver(current_dev);

                if (status == PCI_DEV_DRIVER_FAILED) {
                    kernel_warn("Failed to load driver for device: PCI %u:%u.%u: %s\n",
                        bus, dev, func, error_str
                    );
                }
            }
        }
    }

    return KERNEL_OK;
}

void pci_log_device(const PciDevice* pci_dev) {
    kernel_msg("PCI: %u:%u.%u: vendor: %x: device: %x: class: %x: sub: %x: interface: %x\n",
        pci_dev->bus, pci_dev->dev, pci_dev->func,
        pci_dev->config.vendor_id,
        pci_dev->config.device_id,
        pci_dev->config.class_code,
        pci_dev->config.subclass,
        pci_dev->config.prog_if
    );
}
