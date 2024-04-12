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
    uint32_t acq_admin_tail_doorbell;
    uint32_t asq_io1_tail_doorbell;
    uint32_t acq_io1_tail_doorbell;
} ATTR_PACKED NvmeBar0;

typedef struct Command {
    uint8_t opcode;             // Bits 0-7: Opcode
    uint8_t fused_op    : 2;    // Bits 8-9: Fused operation
    uint8_t reserved_1  : 4;    // Bits 10-13: Reserved
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
    unsigned int cint0;
    unsigned int rsvd;

    union{
        struct{
            unsigned short sub_queue_idx;
            unsigned short sub_queue_id;
        };
        unsigned int cint2_raw;
    };

    volatile union{
        struct{
            unsigned short cmd_id;
            unsigned short phase : 1;
            unsigned short stat : 15;
        } ATTR_PACKED;

        unsigned int cint3_raw;
    };

} ATTR_PACKED NvmeComplQueueEntry;

typedef struct lba_format{
    unsigned short meta_sz;
    unsigned short lba_data_sz:8;
    unsigned short rel_perf : 2;
    unsigned short rsvd : 6;
}__attribute__((packed))lba_format;

typedef struct nvme_disk_info{
    unsigned long sz_in_sects;
    unsigned long cap_in_sects;
    unsigned long used_in_sects;
    unsigned char features;
    unsigned char no_of_formats;
    unsigned char lba_format_sz;
    unsigned char meta_caps;
    unsigned char prot_caps;
    unsigned char prot_types;
    unsigned char nmic_caps;
    unsigned char res_caps;
    char rsvd[88];
    unsigned long euid;
    lba_format lba_format_supports[15];
    char rsvd2 [202];
}__attribute__((packed)) nvme_disk_info;

typedef struct NvmeController {
    NvmeBar0* bar0;
    NvmeSubmissionQueueEntry* asq;
    NvmeComplQueueEntry* acq;
    NvmeSubmissionQueueEntry* iosq;
    NvmeComplQueueEntry* iocq;
    uint32_t* namespace_list;

} NvmeController;

typedef struct NvmeInterface {
} NvmeInterface;

typedef struct NvmeDevice {
    STORAGE_DEVICE_STRUCT_IMPL(Nvme);
    NvmeController controller;
    nvme_disk_info* disk_info;
    uint64_t namespace_id;
} NvmeDevice;

bool_t init_nvme_device(NvmeDevice* nvme_device, const PciDeviceNode* pci_device);

bool_t is_nvme(const uint8_t class_code, const uint8_t subclass);
