#include "pci.h"

#include "assert.h"
#include "logger.h"
#include "math.h"
#include "mem.h"
#include "xhci.h"

#include "cpu/io.h"
#include "dev/blk/nvme.h"
#include "intr/apic.h"
#include "vm/bitmap.h"

#define PCI_INVALID_VENDOR_ID 0xFFFF
#define PCI_BAR_STEP_OFFSET 0x4

#define PCI_STATUS_EXT_CAP (1 << 4)

#define PCI_INTR_INVAL_IDX 0xFF

typedef enum PciDevInitStatus {
    PCI_DEV_DRIVER_FAILED = -1,
    PCI_DEV_NO_DRIVER = 0,
    PCI_DEV_SUCCESS = 1
} PciDevInitStatus;

static ObjectMemoryAllocator* pci_dev_oma = NULL;

uint32_t pci_get_dev_base(const uint8_t bus, const uint8_t dev, const uint8_t func) {
    return ((uint32_t)bus << 16) | ((uint32_t)dev << 11) | ((uint32_t)func << 8) | 0x80000000u;
}

uint8_t pci_config_readb(const uint32_t base, const uint8_t offset) {
    outl(PCI_CONFIG_ADDRESS_PORT, base | (offset & 0xFC));

    // (offset & 3) * 8) = 0 will choose the first byte of the 32-bit register
    return inw(PCI_CONFIG_DATA_PORT + (offset & 3));
}

uint16_t pci_config_readw(const uint32_t base, const uint8_t offset) {
    outl(PCI_CONFIG_ADDRESS_PORT, base | (offset & 0xFC));

    // (offset & 2) * 8) = 0 will choose the first word of the 32-bit register
    return inw(PCI_CONFIG_DATA_PORT + (offset & 2));
}

uint32_t pci_config_readl(const uint32_t base, const uint8_t offset) {
    outl(PCI_CONFIG_ADDRESS_PORT, base | (offset & 0xFC));

    return inl(PCI_CONFIG_DATA_PORT);
}

void pci_config_writew(const uint32_t base, const uint8_t offset, const uint16_t value) {
    uint32_t ext_value = pci_config_readl(base, offset);

    if (offset % 2 == 0) {
        ext_value &= (~0xFFFF);
        ext_value |= value;
    }
    else {
        ext_value &= 0xFFFF;
        ext_value |= ((uint32_t)value << 16);
    }
    
    outl(PCI_CONFIG_ADDRESS_PORT, base | (offset & 0xFC));
    outl(PCI_CONFIG_DATA_PORT, ext_value);
}

void pci_config_writel(const uint32_t base, const uint8_t offset, const uint32_t value) {
    outl(PCI_CONFIG_ADDRESS_PORT, base | (offset & 0xFC));
    outl(PCI_CONFIG_DATA_PORT, value);
}

static uint64_t pci_read_bar(const uint32_t base, const uint8_t offset) {
    const uint32_t bar = pci_config_readl(base, (offset & 0xFC));

    if (bar == 0) return bar;

    if ((bar & 1) == 0) {  // bar is in memory space
        const uint32_t bar_type = (bar >> 1) & 0x3;

        //bar is in 32bit memory space
        if ((bar_type & 2) == 0) return (bar & 0xFFFFFFF0); // Clear flags

        //bar is in 64bit memory space
        return ((bar & 0xFFFFFFF0) + ((uint64_t)pci_config_readl(base, offset + 0x4) << 32));
    }
    else {  // bar is in i/o space 
        return (bar & 0xFFFFFFFC); // Clear flags
    } 

    return 0;
}

static void pci_config_write(const uint32_t base, const void* src, const uint32_t size) {
    kassert(size % sizeof(uint32_t) == 0);

    for (uint32_t i = 0; i < size; i += sizeof(uint32_t)) {
        outl(PCI_CONFIG_ADDRESS_PORT, base + i);
        outl(PCI_CONFIG_DATA_PORT, *(const uint32_t*)((uint64_t)src + i));
    }
}

static void pci_read_config_space(PciDevice* const pci_dev) {
    uint32_t* const config_ptr = (void*)&pci_dev->config;

    for (uint32_t i = 0; i < sizeof(PciConfigurationSpace) / sizeof(uint32_t); ++i) {
        config_ptr[i] = pci_config_readl(pci_dev->config_base, i * sizeof(uint32_t));
    }

    pci_dev->bar0 = pci_read_bar(pci_dev->config_base, PCI_BAR0_OFFSET);
    pci_dev->bar1 = pci_read_bar(pci_dev->config_base, PCI_BAR1_OFFSET);

    if (pci_dev->config.status.cap_list) {
        pci_dev->cap_base = pci_dev->config_base + pci_dev->config.cap_offset;
    }
    else {
        pci_dev->cap_base = 0;
    }
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

uint32_t pci_get_capabilty(const PciDevice* const pci_dev, const uint8_t cap_id) {
    if (pci_dev->cap_base == 0) return 0;

    uint32_t ext_base_off = pci_dev->cap_base;

    PciCapabilityHeader cap;

    do {
        cap.value = pci_config_readl(ext_base_off, 0);

        if (cap.id == cap_id) return ext_base_off;

        ext_base_off = pci_dev->config_base + (cap.next_cap_off & 0xFC);
    } while (cap.next_cap_off != 0);

    return 0;
};

static uint64_t pci_get_bar(const PciDevice* pci_dev, const uint8_t bar_idx) {
    const uint64_t bar = (
            bar_idx == 0 ?
            pci_dev->bar0 :
            *(&pci_dev->config.bar0 + bar_idx)
    );

    return bar;
}

bool_t pci_init_msi_or_msi_x(PciDevice* const pci_dev) {
    kassert(pci_dev != NULL && pci_dev->intr_ctrl == NULL);

    PciInterruptControl* const ctrl = (PciInterruptControl*)kmalloc(sizeof(PciInterruptControl));

    if (ctrl == NULL) return FALSE;

    memset(ctrl->bitmap, sizeof(ctrl->bitmap), 0);

    pci_dev->intr_ctrl = ctrl;

    uint64_t msi_base = 0;

    if ((msi_base = pci_get_capabilty(pci_dev, PCI_CAP_MSI_X)) == 0) {
        msi_base = pci_get_capabilty(pci_dev, PCI_CAP_MSI);

        if (msi_base == 0) {
            ctrl->type = PCI_INTR_INTX;
            return FALSE;
        }

        ctrl->type = PCI_INTR_MSI;
    }
    else {
        ctrl->type = PCI_INTR_MSIX;

        MsiXCapability cap = {
            .control.value = pci_config_readl(msi_base, 0x0),
            .dword_2 = pci_config_readl(msi_base, 0x4),
            .dword_3 = pci_config_readl(msi_base, 0x8)
        };

        // Enable MSI-X
        pci_dev->config.command.intr_disable = 1;
        pci_config_writew(
            pci_dev->config_base,
            offsetof(PciConfigurationSpace, command),
            pci_dev->config.command.value
        );

        cap.control.enable = 1;
        pci_config_writel(msi_base, 0, cap.control.value);

        ctrl->msi_x.control = cap.control;

        const uint64_t table_addr = pci_get_bar(pci_dev, cap.table_bar_indicator) + (cap.table_offset & (~0x7));
        const uint64_t pba_addr =   pci_get_bar(pci_dev, cap.pba_bar_indicator) + (cap.pba_offset & (~0x7));
        const uint32_t table_page_size = div_with_roundup(
            (uint32_t)ctrl->msi_x.control.table_size * sizeof(MsiXTableEntry),
            PAGE_BYTE_SIZE
        );

        ctrl->msi_x.table = (MsiXTableEntry*)vm_map_mmio(table_addr, table_page_size);
        ctrl->msi_x.pba   = (uint64_t*)vm_map_mmio(pba_addr, 1);

        if (ctrl->msi_x.table == NULL || ctrl->msi_x.pba == NULL) return FALSE;
    }

    ctrl->cap_base = msi_base;

    return TRUE;
}

static uint8_t pci_intr_alloc(PciInterruptControl* const ctrl) {
    kassert(ctrl != NULL);

    for (uint32_t i = 0; i < sizeof(ctrl->bitmap) * BYTE_SIZE; ++i) {
        if (_bitmap_get_bit(ctrl->bitmap, i) != 0) continue;

        _bitmap_set_bit(ctrl->bitmap, i);
        return i;
    }

    return PCI_INTR_INVAL_IDX;
}

static uint8_t pci_intr_free(PciInterruptControl* const ctrl, const uint8_t intr_idx) {
    kassert(ctrl != NULL);
    kassert(_bitmap_get_bit(ctrl->bitmap, intr_idx) != 0);

    _bitmap_clear_bit(ctrl->bitmap, intr_idx);
}

void pci_enable_bus_master(PciDevice* const pci_dev) {
    pci_dev->config.command.memory_space = 1;
    pci_dev->config.command.bus_master = 1;

    pci_config_writew(
        pci_dev->config_base,
        offsetof(PciConfigurationSpace, command),
        pci_dev->config.command.value
    );
}

bool_t pci_setup_precise_intr(PciDevice* const pci_dev, const InterruptLocation location) {
    if (pci_dev->intr_ctrl == NULL) {
        if (pci_init_msi_or_msi_x(pci_dev) == FALSE) return FALSE;
    }

    PciInterruptControl* const ctrl = pci_dev->intr_ctrl;

    if (ctrl->type == PCI_INTR_MSI) {
        kernel_msg("MSI Interrupt\n");
    }
    else if (ctrl->type == PCI_INTR_MSIX) {
        const uint8_t intr_idx = pci_intr_alloc(ctrl);

        kernel_msg("MSI-X Table: %x: size: %u: intr idx: %u\n",
            ctrl->msi_x.table,
            ctrl->msi_x.control.table_size,
            intr_idx
        );

        if (intr_idx == PCI_INTR_INVAL_IDX || intr_idx > ctrl->msi_x.control.table_size) return FALSE;

        const MsiMessage msg = apic_config_msi_message(location, APIC_DEST_PHYSICAL, APIC_DELV_MODE_FIXED, APIC_TRIGGER_EDGE);

        ctrl->msi_x.table[intr_idx].msg_addr.hi = 0;
        ctrl->msi_x.table[intr_idx].msg_addr.lo = msg.address.value;
        ctrl->msi_x.table[intr_idx].msg_data = msg.data.value;

        // Enable entry
        ctrl->msi_x.table[intr_idx].ver_ctrl = 0;
    }
    else {
        return FALSE;
    }

    return TRUE;
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
                const uint64_t base = pci_get_dev_base(bus, dev, func);
                const uint16_t vendor_id = pci_config_readw(base, 0x0);

                if (vendor_id == 0xFFFF || vendor_id == 0) continue;

                PciDevice* current_dev = (PciDevice*)oma_alloc(pci_dev_oma);

                if (current_dev == NULL) return KERNEL_ERROR;

                current_dev->bus = bus;
                current_dev->dev = dev;
                current_dev->func = func;
                current_dev->config_base = base;
                current_dev->intr_ctrl = NULL;

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
