#pragma once

#include "definitions.h"

#include "dev/storage.h"

typedef struct NvmeCapRegister {
    uint64_t reserved1 : 3;     // Bits 63:61 - Reserved
    uint64_t crims : 2;         // Bits 60:59 - Controller Ready Independent of Media Support
    uint64_t crwms : 1;         // Bit 60 - Controller Ready With Media Support
    uint64_t nsss : 1;          // Bit 58 - NVM Subsystem Shutdown Supported
    uint64_t cmbs : 1;          // Bit 57 - Controller Memory Buffer Supported
    uint64_t pmrs : 1;          // Bit 56 - Persistent Memory Region Supported
    uint64_t mpsmax : 4;        // Bits 55:52 - Memory Page Size Maximum
    uint64_t mpsmin : 4;        // Bits 51:48 - Memory Page Size Minimum
    uint64_t cps : 2;           // Bits 47:46 - Controller Power Scope
    uint64_t bps : 1;           // Bit 45 - Boot Partition Support
    uint64_t css : 8;           // Bits 44:37 - Command Sets Supported
    uint64_t nssrs : 1;         // Bit 36 - NVM Subsystem Reset Supported
    uint64_t dstrd : 5;         // Bits 35:32 - Doorbell Stride
    uint64_t to : 8;            // Bits 31:24 - Timeout
    uint64_t reserved2 : 5;     // Bits 23:19 - Reserved
    uint64_t ams : 2;           // Bits 18:17 - Arbitration Mechanism Supported
    uint64_t cqr : 1;           // Bit 16 - Contiguous Queues Required
    uint64_t mqes : 16;         // Bits 15:00 - Maximum Queue Entries Supported
} NvmeCapRegister;

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
    uint32_t cmbloc;            // Controller Memory Buffer Location
    uint32_t cmbsz;             // Controller Memory Buffer Size
    uint32_t bpinfo;            // Boot Partition Information
    uint32_t bprsel;            // Boot Partition Read Select
    uint64_t bpmbloc;           // Boot Partition Memory Buffer Location
    uint64_t cmbmsc;            // Controller Memory Buffer Memory Space Control
    uint32_t cmbsts;            // Controller Memory Buffer Status
    uint32_t cmbebs;            // Controller Memory Buffer Elasticity Buffer Size
    uint32_t cmbswtp;           // Controller Memory Buffer Sustained Write Throughput
    uint32_t nssd;              // NVM Subsystem Shutdown
    uint32_t crto;              // Controller Ready Timeouts
    uint32_t reserved2[5];      // Reserved
    uint32_t pmrcap;            // Persistent Memory Capabilities
    uint32_t pmrctl;            // Persistent Memory Region Control
    uint32_t pmrsts;            // Persistent Memory Region Status
    uint32_t pmrebs;            // Persistent Memory Region Elasticity Buffer Size
    uint32_t pmrswtp;           // Persistent Memory Region Sustained Write Throughput
    uint32_t pmrcmscl;          // Persistent Memory Region Controller Memory Space Control Lower
    uint32_t pmrcmscu;          // Persistent Memory Region Controller Memory Space Control Upper
} ATTR_PACKED NvmeBar0;

typedef struct NvmeInterface {
} NvmeInterface;

typedef struct NvmeDevice {
    STORAGE_DEVICE_STRUCT_IMPL(Nvme);
    NvmeBar0* bar0;
} NvmeDevice;

bool_t is_nvme(uint8_t class_code, uint8_t subclass);