#pragma once

#include "definitions.h"

#include "dev/storage.h"

#include "dev/stds/pci.h"

typedef struct NvmeCapRegister {
    uint16_t reserved1 : 2;     // Bits 63:61 - Reserved
    uint16_t crms : 2;          // Bit 60:59 - Controller Ready With Media Support
    uint16_t nsss : 1;          // Bit 58 - NVM Subsystem Shutdown Supported
    uint16_t cmbs : 1;          // Bit 57 - Controller Memory Buffer Supported
    uint16_t pmrs : 1;          // Bit 56 - Persistent Memory Region Supported
    uint16_t mpsmax : 4;        // Bits 55:52 - Memory Page Size Maximum
    uint16_t mpsmin : 4;        // Bits 51:48 - Memory Page Size Minimum
    uint16_t cps : 2;           // Bits 47:46 - Controller Power Scope
    uint16_t bps : 1;           // Bit 45 - Boot Partition Support
    uint16_t css : 8;           // Bits 44:37 - Command Sets Supported
    uint16_t nssrs : 1;         // Bit 36 - NVM Subsystem Reset Supported
    uint16_t dstrd : 4;         // Bits 35:32 - Doorbell Stride
    uint16_t to : 8;            // Bits 31:24 - Timeout
    uint16_t reserved2 : 5;     // Bits 23:19 - Reserved
    uint16_t ams : 2;           // Bits 18:17 - Arbitration Mechanism Supported
    uint16_t cqr : 1;           // Bit 16 - Contiguous Queues Required
    uint16_t mqes;              // Bits 15:00 - Maximum Queue Entries Supported
} NvmeCapRegister;

typedef struct {
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

typedef struct NvmeBar0 {
    NvmeCapRegister cap;        // Controller Capabilities
    uint32_t version;           // Version
    uint32_t intms;             // Interrupt Mask Set
    uint32_t intmc;             // Interrupt Mask Clear
    uint32_t cc;                // Controller Configuration
    uint32_t reserved;          // Reserved
    uint32_t csts;              // Controller Status
    uint32_t nssr;              // NVM Subsystem Reset
    uint32_t aqa;               // Admin Queue Attributes
    uint64_t* asq;              // Admin Submission Queue Base Address
    volatile NvmeComplQueueEntry* acq;              // Admin Completion Queue Base Address
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

    volatile unsigned int sub_queue_tail_doorbell;
    volatile unsigned int comp_queue_tail_doorbell;

    volatile unsigned int io_sub_queue_tail_doorbell;
    volatile unsigned int io_cmpl_queue_tail_doorbell;
} ATTR_PACKED NvmeBar0;

typedef struct Command {
    uint8_t opcode;             // Bits 0-7: Opcode
    uint8_t fused_op    : 2;    // Bits 8-9: Fused operation
    uint8_t reserved_1  : 4;    // Bits 10-13: Reserved
    uint8_t prp_sgl     : 2;    // Bits 14-15: PRP or SGL selection
    uint16_t command_id;        // Bits 16-31: Command identifier
} Command;

typedef struct NvmeAdminCmd {
    Command command;
    uint32_t nsid;
    uint64_t reserved;
    uint64_t metadata;
    uint64_t prp1;
    uint64_t prp2;
    uint32_t command_dword[5];
} ATTR_PACKED NvmeSubmissionCmd;



typedef struct NvmeInterface {
} NvmeInterface;

typedef struct NvmeDevice {
    STORAGE_DEVICE_STRUCT_IMPL(Nvme);
    NvmeBar0* bar0;
} NvmeDevice;

bool_t init_nvme_device(NvmeDevice* nvme_device, PciDeviceNode* pci_device);

bool_t is_nvme(uint8_t class_code, uint8_t subclass);
