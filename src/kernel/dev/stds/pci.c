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

static uint32_t read_bar(const uint8_t bus, const uint8_t dev, const uint8_t func, const uint8_t offset) {
    uint32_t bar = pci_config_readl(bus, dev, func, offset);
    uint32_t bar_type;

    if (bar == 0) {
        //kernel_error("Bar with offset %x is 0\n", offset);

        return bar;
    } else {
        if ((bar & 1) == 0) {  // bar is in memory space
            bar_type = (bar >> 1) & 0x3;

            if ((bar_type & 2) == 0) {    //bar is in 32bit memory space
 				//kernel_msg("Bar %x with offset %x is in 32bit on bus: %u, dev: %u, func: %u\n", bar, offset, bus, dev, func);

                return (bar & 0xFFFFFFF0); // Clear flags
            } else {     //bar is in 64bit memory space
                //kernel_msg("Bar %x with offset %x is in 64bit on bus: %u, dev: %u, func: %u\n", bar, offset, bus, dev, func);

                return (bar & 0xFFFFFFFFFFFFFFF0); // Clear flags
            }
        } else {  // bar is in i/o space 
            //kernel_msg("Bar %x with offset %x is in I/O space on bus: %u, dev: %u, func: %u\n", bar, offset, bus, dev, func);

            return (bar & 0xFFFFFFFC); // Clear flags
        } 
    }
  
    return NULL;
}

Status init_pci_device(PciDevice* pci_device) {
    if (pci_device == NULL) return KERNEL_INVALID_ARGS;
    
    pci_device->head = NULL;

    PciDeviceNode* device_list = NULL;

    for (uint8_t bus = 0; bus < 4; ++bus) {
        for (uint8_t dev = 0; dev < 32; ++dev) {
            for (uint8_t func = 0; func < 8; ++func) {
                uint16_t vendor_id = pci_config_readw(bus, dev, func, 0);

                if (vendor_id == 0xFFFF || vendor_id == 0) continue;

                PciDeviceNode* current_node = (PciDeviceNode*)kmalloc(sizeof(PciDeviceNode));
                current_node->next = NULL;

                current_node->bus = bus;
                current_node->dev = dev;
                current_node->func = func;
                current_node->pci_header.vendor_id = vendor_id;
                current_node->pci_header.device_id = pci_config_readw(bus, dev, func, 2);
                current_node->pci_header.prog_if = pci_config_readb(bus, dev, func, 0x9);
                current_node->pci_header.subclass = pci_config_readb(bus, dev, func, 0xA);
                current_node->pci_header.class_code = (pci_config_readw(bus, dev, func, 0xB) >> 8);  // for no reason readbyte on 0xB we always get 0xFF
                current_node->pci_header.bar0 = read_bar(bus, dev, func, PCI_BAR0_OFFSET);
                current_node->pci_header.bar1 = read_bar(bus, dev, func, PCI_BAR1_OFFSET);
                current_node->pci_header.bar2 = read_bar(bus, dev, func, PCI_BAR2_OFFSET);
                current_node->pci_header.bar3 = read_bar(bus, dev, func, PCI_BAR3_OFFSET);
                current_node->pci_header.bar4 = read_bar(bus, dev, func, PCI_BAR4_OFFSET);
                current_node->pci_header.bar5 = read_bar(bus, dev, func, PCI_BAR5_OFFSET);

                kernel_msg("PCI bus: %u: dev: %u: func: %u: vendor id: %x: class: %x: subclass: %x\n",
                    (uint32_t)bus,
                    (uint32_t)dev,
                    (uint32_t)func,
                    (uint64_t)vendor_id,
                    (uint64_t)current_node->pci_header.class_code,
                    (uint64_t)current_node->pci_header.subclass);
                
                if (pci_device->head == NULL) {
                    device_list = current_node;
                    pci_device->head = device_list;
                } else {
                    device_list->next = current_node;
                    device_list = device_list->next;
                }
            }
        }
    }

    return KERNEL_OK;
}

static bool_t is_pci_device(Device* device) {
    return device->type == DEV_PCI_BUS;
}

bool_t add_new_pci_device(const PciDeviceNode* new_pci_device) {
    if (new_pci_device == NULL) return FALSE;
    
    PciDevice* pci_device = NULL;

    if  (!(pci_device = dev_find(pci_device, &is_pci_device))) return FALSE;

    PciDeviceNode* device_list = pci_device->head;

    while (device_list->next != NULL) {
        device_list = device_list->next;
    }

    device_list->next = new_pci_device;
    device_list->next->next = NULL;

    return TRUE;
}

void remove_pci_device(PciDevice* pci_device, const size_t index) {
    if (index < 0) return;

    PciDeviceNode* current = pci_device->head;
    PciDeviceNode* previous = NULL;

    if (index == 0) {
        pci_device->head = current->next;

        kfree(current);

        return;
    }

    size_t i = 0;
    while (current->next != NULL) { 
        previous = current;
        current = current->next;

        ++i;
    }

    if (i < index) {
        kernel_msg("Node with index was %u not found\n", index);
        return;
    }

    if (current == NULL) return;

    previous->next = current->next;
    
    kfree(current);
}
