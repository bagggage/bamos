#pragma once

#include "definitions.h"

#include "dev/device.h"
#include "intr/intr.h"

#include "acpi.h"

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
    STORAGE_OTHER_SUBCLASS = 0x80
} StorageControllerSubclass;

typedef enum NetworkControllerSubclass {
    ETHERNET_CONTROLLER = 0,
    NETWORK_OTHER_SUBCLASS = 0x80
} NetworkControllerSubclass;

typedef enum PciExtCapabityID {
    PCI_ECAP_NULL = 0,
    PCI_ECAP_AER = 1,
    PCI_ECAP_VIRT_CHANNEL = 2,
    PCI_ECAP_DEV_SERIAL_NUM = 3,
    PCI_ECAP_POWER_BUDGETING = 4,
    PCI_ECAP_ROOT_COMP_LINK_DECL = 5,
    PCI_ECAP_ROOT_COMP_INTER_LINK_CTRL = 6,
    PCI_ECAP_ROOT_COMP_EVENT_COLL_EP_AS = 7,
    PCI_ECAP_MULTI_FUNC_VIRT_CHANNEL = 8,
    PCI_ECAP_VIRT_CHANNEL_1 = 9,
    PCI_ECAP_ROOT_COMP_REG_BLOCK = 10,
    PCI_ECAP_VENDOR_SPEC_EXT_CAP = 11,
    PCI_ECAP_CONF_ACCESS_CORRELATION = 12,
    PCI_ECAP_ACCESS_CTRL_SERVICE = 13,
    PCI_ECAP_ALT_ROUTING_ID_INTERP = 14,
    PCI_ECAP_ADDR_TRANS_SERVICE = 15,
    PCI_ECAP_SINGLE_ROOT_IO_VIRT = 16,
    PCI_ECAP_MULTI_ROOT_IO_VIRT = 17,
    PCI_ECAP_MULTICAST = 18,
    PCI_ECAP_PAGE_REQ_INTERFACE = 19,

    PCI_ECAP_RESIZABLE_BAR = 21,
    PCI_ECAP_DYN_POWER_ALLOC = 22,
    PCI_ECAP_TPH_REQUESTTER = 23,
    PCI_ECAP_LATENCY_TOL_REP = 24,
    PCI_ECAP_SECONDARY_PCIE = 25,
    PCI_ECAP_PROT_MULTIPLEXING = 26,
    PCI_ECAP_PROC_ADDR_SPACE_ID = 27,
    PCI_ECAP_LN_REQUESTER = 28,
    PCI_ECAP_DOWNSTREAM_PORT_CONT = 29,
    PCI_ECAP_L1_PM_SUBSTATES = 30,
    PCI_ECAP_PERC_TIME_MEASUREMENT = 31,
    PCI_ECAP_PCIE_OVER_MPHY = 32,
    PCI_ECAP_FRS_QUEUEING = 33,
    PCI_ECAP_READINESS_TIME_REP = 34,
    PCI_ECAP_DESIG_VEND_SPEC_EXT_CAP = 35,
    PCI_ECAP_VF_RESIZABLE_BAR = 36,
    PCI_ECAP_DATA_LINK_FEATURE = 37,
    PCI_ECAP_PHYS_LAYER_16GT_S = 38,
    PCI_ECAP_LANE_MARG_RECEIVER = 39,
    PCI_ECAP_HIERARCHY_ID = 40,
    PCI_ECAP_NATIVE_PCIE_ENCLOSURE_MNGMT = 41,
    PCI_ECAP_PHYS_LAYER_32GT_S = 42,
    PCI_ECAP_ALTER_PROTOCOL = 43,
    PCI_ECAP_SYS_FIRMWARE_INTERM = 44,
} PciExtCapabilityID;

typedef enum PciCapabilityID {
    PCI_CAP_NULL = 0,
    PCI_CAP_PCI_POWER_MNGMT_INTERFACE = 1,
    PCI_CAP_AGP = 2,
    PCI_CAP_VPD = 3,
    PCI_CAP_SLOT_ID = 4,
    PCI_CAP_MSI = 5,
    PCI_CAP_COMP_PCI_HOT_SWAP = 6,
    PCI_CAP_PCI_X = 7,
    PCI_CAP_HYPER_TRANSPORT = 8,
    PCI_CAP_VENDOR_SPECIFIC = 9,
    PCI_CAP_DEBUG_PORT = 10,
    PCI_CAP_COMP_PCI_CENTRAL_RES_CTRL = 11,
    PCI_CAP_HOT_PLUG = 12,
    PCI_CAP_BRIDGE_SUBSYS_VENDOR_ID = 13,
    PCI_CAP_AGP_8X = 14,
    PCI_CAP_SECURE_DEVICE = 15,
    PCI_CAP_PCI_EXPRESS = 16,
    PCI_CAP_MSI_X = 17,
    PCI_CAP_SATA_DATA_IDX_CONF = 18,
    PCI_CAP_ADVANCED_FEATURES = 19,
    PCI_CAP_ENHANCED_ALLOC = 20,
    PCI_CAP_FLATTENING_PORTAL_BRIDGE = 21
} PciCapabilityID;

typedef union PciExtCapabilityHeader {
    struct {
        uint32_t id : 16;
        uint32_t version : 4;
        uint32_t next_cap_off : 12;
    };
    uint32_t value;
} ATTR_PACKED PciExtCapabilityHeader;

typedef union PciCapabilityHeader {
    struct {
        uint32_t id : 8;
        uint32_t next_cap_off : 8;
        uint32_t specific : 16;
    };
    uint32_t value;
} ATTR_PACKED PciCapabilityHeader;

typedef union MsiCtrlReg {
    struct {
        uint32_t reserved_1 : 16;

        uint32_t enable : 1;
        uint32_t multiple_cap : 3; // count = (1 << 'n')
        uint32_t multiple_enable : 3;
        uint32_t cap_64bit : 1;
        uint32_t vector_masking : 1;

        uint32_t reserved_2 : 7;
    };
    uint32_t value;
} ATTR_PACKED MsiCtrlReg;

typedef struct MsiCapability {
    MsiCtrlReg control;
    uint32_t msg_addr;

    union {
        struct {
            uint32_t msg_data;

            uint32_t mask_bits;
            uint32_t pend_bits;
        } x32;
        struct {
            uint32_t msg_addr_upper;
            uint32_t msg_data;

            uint32_t mask_bits;
            uint32_t pend_bits;
        } x64;

        struct {
            uint32_t dword_3;
            uint32_t dword_4;
            uint32_t dword_5;
        };
    };
} ATTR_PACKED MsiCapability;

typedef union MsiXCtrlReg {
    struct {
        uint32_t reserved_1 : 16;
        uint32_t table_size : 11;

        uint32_t reserved_2 : 3;

        uint32_t func_mask : 1;
        uint32_t enable : 1;
    };
    uint32_t value;
} ATTR_PACKED MsiXCtrlReg;

typedef struct MsiXTableEntry {
    uint64_32_t msg_addr;
    uint32_t msg_data;
    uint32_t ver_ctrl;
} ATTR_PACKED MsiXTableEntry;

typedef struct MsiXCapability {
    MsiXCtrlReg control;

    union {
        struct {
            uint32_t table_bar_indicator : 3;
            uint32_t : 29;
        };
        uint32_t table_offset;
        uint32_t dword_2;
    };
    union {
        struct {
            uint32_t pba_bar_indicator : 3;
            uint32_t : 29;
        };
        uint32_t pba_offset;
        uint32_t dword_3;
    };
} ATTR_PACKED MsiXCapability;

typedef union PciCommandReg {
    struct {
        uint16_t io_space : 1;
        uint16_t memory_space : 1;
        uint16_t bus_master : 1;
        uint16_t spec_cycles : 1;
        uint16_t mem_write_inval_enable : 1;
        uint16_t vga_palette_snoop : 1;
        uint16_t parity_err_response : 1;

        uint16_t reserved_1 : 1;

        uint16_t serr_enable : 1;
        uint16_t fast_b2b_enable : 1;
        uint16_t intr_disable : 1;

        uint16_t reserved_2 : 5;
    };
    uint16_t value;
} ATTR_PACKED PciCommandReg;

typedef union PciStatusReg {
    struct {
        uint16_t reserved_1 : 3;

        uint16_t intr_status : 1;
        uint16_t cap_list : 1;
        uint16_t cap_66mhz : 1;

        uint16_t reserved_2 : 1;

        uint16_t fast_b2b_cap : 1;
        uint16_t master_data_parity_err : 1;
        uint16_t devsel_timing : 2;
        uint16_t sig_target_abort : 1;
        uint16_t recv_target_abort : 1;
        uint16_t recv_master_abort : 1;
        uint16_t sig_sys_err : 1;
        uint16_t detected_parity_err : 1;
    };
    uint16_t value;
} ATTR_PACKED PciStatusReg;

/*
Structure identical in layout to the PCI configuration space.
*/
typedef struct PciConfigurationSpace {
    uint16_t vendor_id;
    uint16_t device_id;

    PciCommandReg command;
    PciStatusReg status;

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

    uint32_t expansion_rom_base;

    uint8_t cap_offset;
    uint8_t reserved_1[3];

    uint32_t reserved_2;

    uint8_t interrupt_line;
    uint8_t interrupt_pin;
    uint8_t min_grant;
    uint8_t max_latency;
} ATTR_PACKED ATTR_ALIGN(4) PciConfigurationSpace;

typedef enum PciIntrType {
    PCI_INTR_INTX = 0,
    PCI_INTR_MSI,
    PCI_INTR_MSIX
} PciIntrType;

typedef struct PciInterruptControl {
    uint8_t type;
    uint8_t bitmap[BYTE_SIZE];

    uint32_t cap_base;

    union {
        struct {
            MsiXCtrlReg control;

            volatile MsiXTableEntry* table;
            volatile uint64_t* pba;
        } msi_x;
        struct {
            MsiCtrlReg control;
        } msi;
    };
} PciInterruptControl;

typedef struct PciDevice {
    LIST_STRUCT_IMPL(PciDevice);

    uint16_t seg;
    uint8_t bus;
    uint8_t dev;
    uint8_t func;

    uint32_t config_base;

    const PciConfigurationSpace* config;
    uint64_t bar0;

    PciInterruptControl* intr_ctrl;
} PciDevice;

typedef struct MCFGConfigSpaceAllocEntry {
    uint64_t base;
    uint16_t segment;

    uint8_t start_bus;
    uint8_t end_bus;

    uint32_t reserved_1;
} ATTR_PACKED MCFGConfigSpaceAllocEntry;

typedef struct MCFG {
    ACPISDTHeader header;
    uint64_t reserved_1;

    MCFGConfigSpaceAllocEntry entries[];
} ATTR_PACKED MCFG;

typedef struct PciBus {
    BUS_STRUCT_IMPL;

    MCFG* mcfg;
} PciBus;

typedef uint8_t (*PciConfigReadB_t)(const PciDevice* pci_dev, const uint8_t offset);
typedef uint16_t(*PciConfigReadW_t)(const PciDevice* pci_dev, const uint8_t offset);
typedef uint32_t(*PciConfigReadL_t)(const PciDevice* pci_dev, const uint8_t offset);

typedef void (*PciConfigWriteW_t)(const PciDevice* pci_dev, const uint8_t offset, const uint16_t value);
typedef void (*PciConfigWriteL_t)(const PciDevice* pci_dev, const uint8_t offset, const uint32_t value);

typedef struct PciConfSpaceAccessMechanism {
    PciConfigReadB_t readb;
    PciConfigReadW_t readw;
    PciConfigReadL_t readl;

    PciConfigWriteW_t writew;
    PciConfigWriteL_t writel;
} PciConfSpaceAccessMechanism;

extern PciConfSpaceAccessMechanism _g_pci_conf_space_access_mechanism;

// Write to PCI devices registers on 32-bit bus
static inline void pci_write64(void* const address, const uint64_t value) {
    uint32_t* const ptr = (uint32_t*)address;

    ptr[0] = ((uint64_32_t)value).lo;
    ptr[1] = ((uint64_32_t)value).hi;
}

// Read from PCI devices registers on 32-bit bus
static inline uint64_t pci_read64(void* const address) {
    uint64_32_t result;
    const uint32_t* const ptr = (uint32_t*)address;

    result.lo = ptr[0];
    result.hi = ptr[1];

    return result.val;
}

uint32_t pci_get_capabilty(const PciDevice* const pci_dev, const uint8_t cap_id);
uint32_t pci_get_dev_base(const uint8_t bus, const uint8_t dev, const uint8_t func);
uint64_t pcie_get_dev_base(const uint64_t seg_base, const uint8_t bus, const uint8_t dev, const uint8_t func);

#define pci_config_readb(pci_dev, offset) \
    (_g_pci_conf_space_access_mechanism.readb((pci_dev),(offset)))
#define pci_config_readw(pci_dev, offset) \
    (_g_pci_conf_space_access_mechanism.readw((pci_dev),(offset)))
#define pci_config_readl(pci_dev, offset) \
    (_g_pci_conf_space_access_mechanism.readl((pci_dev),(offset)))

#define pci_config_writew(pci_dev, offset, value) \
    (_g_pci_conf_space_access_mechanism.writew((pci_dev),(offset),(value)))
#define pci_config_writel(pci_dev, offset, value) \
    (_g_pci_conf_space_access_mechanism.writel((pci_dev),(offset),(value)))

bool_t pci_init_msi_or_msi_x(PciDevice* const pci_dev);
void pci_enable_bus_master(PciDevice* const pci_dev);

bool_t pci_setup_precise_intr(PciDevice* const pci_dev, const InterruptLocation intr_location);

Status init_pci_bus(PciBus* const pci_bus);

void pci_log_device(const PciDevice* pci_dev);