#include "pci.h"

#include "assert.h"
#include "logger.h"
#include "mem.h"

#include "cpu/io.h"

#define PCI_INVALID_VENDOR_ID 0xFFFF

uint8_t pci_config_readb(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset) {
    uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    // (offset & 3) * 8) = 0 will choose the first byte of the 32-bit register
    return inw(PCI_CONFIG_DATA_PORT + (offset & 3));
}

uint16_t pci_config_readw(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset) {
    uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    // (offset & 2) * 8) = 0 will choose the first word of the 32-bit register
    return inw(PCI_CONFIG_DATA_PORT + (offset & 2));
}

uint32_t pci_config_readl(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset) {
    uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);

    return inl(PCI_CONFIG_DATA_PORT);
}

void pci_config_writel(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset, const uint32_t value) {
    uint32_t address = (bus << 16) | (dev << 11) | (func << 8) | (offset & 0xFC) | 0x80000000;

    outl(PCI_CONFIG_ADDRESS_PORT, address);
    outl(PCI_CONFIG_DATA_PORT, value);
}

static uint32_t pci_read_bar(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset) {
    const uint32_t bar = pci_config_readl(bus, dev, func, offset);

    if (bar == 0) {
        //kernel_error("Bar with offset %x is 0\n", offset);
        return bar;
    }
    else if ((bar & 1) == 0) {  // bar is in memory space
        const uint32_t bar_type = (bar >> 1) & 0x3;

        if ((bar_type & 2) == 0) {    //bar is in 32bit memory space
 			//kernel_msg("Bar %x with offset %x is in 32bit on bus: %u, dev: %u, func: %u\n", bar, offset, bus, dev, func);
            return (bar & 0xFFFFFFF0); // Clear flags
        }
        else {  //bar is in 64bit memory space
            //kernel_msg("Bar %x with offset %x is in 64bit on bus: %u, dev: %u, func: %u\n", bar, offset, bus, dev, func);
            return (bar & 0xFFFFFFFFFFFFFFF0); // Clear flags
        }
    }
    else {  // bar is in i/o space 
        //kernel_msg("Bar %x with offset %x is in I/O space on bus: %u, dev: %u, func: %u\n", bar, offset, bus, dev, func);
        return (bar & 0xFFFFFFFC); // Clear flags
    } 

    return NULL;
}

Status init_pci_bus(PciBus* pci_bus) {
    if (pci_bus == NULL) return KERNEL_INVALID_ARGS;
    
    pci_bus->nodes.next = NULL;
    pci_bus->nodes.prev = NULL;

    for (uint8_t bus = 0; bus < 4; ++bus) {
        for (uint8_t dev = 0; dev < 32; ++dev) {
            for (uint8_t func = 0; func < 8; ++func) {
                uint16_t vendor_id = pci_config_readw(bus, dev, func, 0);

                if (vendor_id == 0xFFFF || vendor_id == 0) continue;

                PciDevice* current_dev = (PciDevice*)kmalloc(sizeof(PciDevice));
                current_dev->next = NULL;

                current_dev->bus = bus;
                current_dev->dev = dev;
                current_dev->func = func;
                current_dev->config.vendor_id = vendor_id;
                current_dev->config.device_id = pci_config_readw(bus, dev, func, 2);
                current_dev->config.prog_if = pci_config_readb(bus, dev, func, 0x9);
                current_dev->config.subclass = pci_config_readb(bus, dev, func, 0xA);
                current_dev->config.class_code = (pci_config_readw(bus, dev, func, 0xB) >> 8);  // for no reason readbyte on 0xB we always get 0xFF
                current_dev->config.bar0 = pci_read_bar(bus, dev, func, PCI_BAR0_OFFSET);
                current_dev->config.bar1 = pci_read_bar(bus, dev, func, PCI_BAR1_OFFSET);
                current_dev->config.bar2 = pci_read_bar(bus, dev, func, PCI_BAR2_OFFSET);
                current_dev->config.bar3 = pci_read_bar(bus, dev, func, PCI_BAR3_OFFSET);
                current_dev->config.bar4 = pci_read_bar(bus, dev, func, PCI_BAR4_OFFSET);
                current_dev->config.bar5 = pci_read_bar(bus, dev, func, PCI_BAR5_OFFSET);

                // kernel_msg("PCI bus: %u: dev: %u: func: %u: vendor id: %x: class: %x: subclass: %x\n",
                //     (uint32_t)bus,
                //     (uint32_t)dev,
                //     (uint32_t)func,
                //     (uint64_t)vendor_id,
                //     (uint64_t)current_node->pci_header.class_code,
                //     (uint64_t)current_node->pci_header.subclass);

                if (pci_bus->nodes.next == NULL) {
                    pci_bus->nodes.next = (void*)current_dev;
                    pci_bus->nodes.prev = (void*)current_dev;
                }
                else {
                    current_dev->prev = (PciDevice*)pci_bus->nodes.prev;

                    pci_bus->nodes.prev->next = (void*)current_dev;
                    pci_bus->nodes.prev = (void*)current_dev;
                }
            }
        }
    }

    return KERNEL_OK;
}

bool_t is_pci_bus(Device* device) {
    return device->type == DEV_PCI_BUS;
}
