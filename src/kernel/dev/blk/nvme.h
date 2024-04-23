#pragma once

#include "definitions.h"

#include "dev/storage.h"

#include "dev/stds/pci.h"

typedef struct NvmeBar0 {
    uint64_t cap;               // Controller Capabilities
    uint32_t version;           // Version
    uint32_t intms;             // Interrupt Mask Set
    uint32_t intmc;             // Interrupt Mask Clear
    uint32_t cc;                // Controller Configuration
    uint32_t reserved;          // Reserved
    uint32_t csts;              // Controller Status
    uint32_t nssr;              // NVM Subsystem Reset
    uint32_t aqa;               // Admin Queue Attributes
    uint64_t asq;               // Admin Submission Queue Base Address
    uint64_t acq;               // Admin Completion Queue Base Address
    // uint32_t cmbloc;            // Controller Memory Buffer Location
    // uint32_t cmbsz;             // Controller Memory Buffer Size
    // uint32_t bpinfo;            // Boot Partition Information
    // uint32_t bprsel;            // Boot Partition Read Select
    // uint64_t bpmbloc;           // Boot Partition Memory Buffer Location
    // uint64_t cmbmsc;            // Controller Memory Buffer Memory Space Control
    // uint32_t cmbsts;            // Controller Memory Buffer Status
    // uint32_t cmbebs;            // Controller Memory Buffer Elasticity Buffer Size
    // uint32_t cmbswtp;           // Controller Memory Buffer Sustained Write Throughput
    // uint32_t nssd;              // NVM Subsystem Shutdown
    // uint32_t crto;              // Controller Ready Timeouts
    // uint32_t reserved2[5];      // Reserved
    // uint32_t pmrcap;            // Persistent Memory Capabilities
    // uint32_t pmrctl;            // Persistent Memory Region Control
    // uint32_t pmrsts;            // Persistent Memory Region Status
    // uint32_t pmrebs;            // Persistent Memory Region Elasticity Buffer Size
    // uint32_t pmrswtp;           // Persistent Memory Region Sustained Write Throughput
    // uint32_t pmrcmscl;          // Persistent Memory Region Controller Memory Space Control Lower
    // uint32_t pmrcmscu;          // Persistent Memory Region Controller Memory Space Control Upper
    uint8_t reserved1[0xFC8];
    uint32_t asq_admin_tail_doorbell;
    uint32_t acq_admin_head_doorbell;
    uint32_t asq_io1_tail_doorbell;
    uint32_t acq_io1_head_doorbell;
} ATTR_PACKED NvmeBar0;

typedef struct Command {
    uint8_t opcode;             // Bits 0-7: Opcode
    uint8_t fused_op    : 2;    // Bits 8-9: Fused operation
    uint8_t reserved    : 4;    // Bits 10-13: Reserved
    uint8_t prp_sgl     : 2;    // Bits 14-15: PRP or SGL selection
    uint16_t command_id;        // Bits 16-31: Command identifier
} Command;

typedef struct NvmeSubmissionQueueEntry {
    Command command;
    uint32_t nsid;
    uint64_t reserved;
    uint64_t metadata;
    uint64_t prp1;
    uint64_t prp2;
    uint32_t command_dword[6];
} ATTR_PACKED NvmeSubmissionQueueEntry;

typedef struct NvmeComplQueueEntry {
    uint32_t command_specific;
    uint32_t reserved;
    uint16_t sq_idx;
    uint16_t sq_id;
    volatile union {
        struct {
            uint16_t cmd_id;
            uint16_t phase : 1;
            uint16_t status : 15;
        } ATTR_PACKED;
        uint32_t command_raw;
    };
} ATTR_PACKED NvmeComplQueueEntry;

typedef struct LbaFormat {
    uint16_t metadata_size;
    uint16_t lba_data_size  : 8;
    uint16_t rel_perf       : 2;
    uint16_t reserved       : 6;
} ATTR_PACKED LbaFormat;

typedef struct NvmeNamespaceInfo {
    uint64_t size_in_sects;
    uint64_t cap_in_sects;
    uint64_t used_in_sects;
    uint8_t features;
    uint8_t no_of_formats;
    uint8_t lba_format_size;
    uint8_t meta_caps;
    uint8_t prot_caps;
    uint8_t prot_types;
    uint8_t nmic_caps;
    uint8_t res_caps;
    uint8_t reserved1[88];
    uint64_t euid;
    LbaFormat lba_format_supports[15];
    uint8_t reserved2[202];
} ATTR_PACKED NvmeNamespaceInfo;

typedef struct NvmeController {
    NvmeBar0* bar0;
    NvmeSubmissionQueueEntry* asq;
    NvmeComplQueueEntry* acq;
    NvmeSubmissionQueueEntry* iosq;
    NvmeComplQueueEntry* iocq;
    uint64_t page_size;
    PciInfo* pci_device;
} NvmeController;

typedef struct NvmeDevice {
    STORAGE_DEVICE_STRUCT_IMPL;
    NvmeController controller;
    NvmeNamespaceInfo* namespace_info;
    uint32_t nsid;
} NvmeDevice;

NvmeController create_nvme_controller(const PciInfo* const pci_device);

// Create  new nvme device and push it to the storage device list 
bool_t init_nvme_devices_for_controller(const NvmeController* const nvme_controller);

bool_t is_nvme(const uint8_t class_code, const uint8_t subclass);
