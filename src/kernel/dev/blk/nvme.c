#include "nvme.h"

#include "assert.h"
#include "logger.h"
#include "mem.h"

#include "cpu/io.h"

#include "vm/vm.h"

#define NVME_CTRL_ENABLE 1
#define NVME_CTRL_ERROR 0b10

#define NVME_SUB_QUEUE_SIZE 64

#define NVME_MASK_ALL_INTERRUPTS 0xffffffff

#define NVME_IDENTIFY_CONTROLLER 1
#define NVME_IDENTIFY_NAMESPACE 2

#define QUEUE_ATR_64_MASK 0x003f003f

#define QUEUE_SIZE 4096

#define NVME_CTRL_PAGE_SIZE(controller_conf) (1 << (12 + ((controller_conf & 0b11110000000) >> 7)))

#define NVME_CTRL_VERSION_MAJOR(version) (version >> 16)
#define NVME_CTRL_VERSION_MINOR(version) (((version) >> 8) & 0xFF)

#define LBA_SIZE(nvme_device, i) (1 << \
                (nvme_device->namespace_info[i]->lba_format_supports[nvme_device->namespace_info[i]->lba_format_size & 0x7].lba_data_size))

typedef struct NvmeCtrlInfo {
    uint16_t vendor_id;
    uint16_t sub_vendor_id;
    char serial[20];
    char model[40];
} ATTR_PACKED NvmeCtrlInfo;

typedef enum NvmeAdminCommands {
    NVME_ADMIN_DELETE_SUBMISSION_QUEUE   = 0,
    NVME_ADMIN_CREATE_SUBMISSION_QUEUE   = 1,
    NVME_ADMIN_GET_LOG_PAGE              = 2,
    NVME_ADMIN_DELETE_COMPLETION_QUEUE   = 4,
    NVME_ADMIN_CREATE_COMPLETION_QUEUE   = 5,
    NVME_ADMIN_IDENTIFY                  = 6,
    NVME_ADMIN_ABORT                     = 8,
    NVME_ADMIN_SET_FEATURES              = 9,
    NVME_ADMIN_GET_FEATURES              = 10
} NvmeAdminCommands;

typedef enum NvmeIOCommands {
    NVME_IO_WRITE = 1,
    NVME_IO_READ = 2
} NvmeIOCommands;

static void send_nvme_admin_command(NvmeDevice* nvme_device, const NvmeSubmissionQueueEntry* admin_cmd) {
    if (nvme_device == NULL || admin_cmd == NULL) return;

    static uint8_t admin_tail =  0;
    //kernel_msg("admin tail %u\n", admin_tail);

    memcpy(admin_cmd, nvme_device->controller.asq + admin_tail, sizeof(*admin_cmd));
    memset(&nvme_device->controller.acq[admin_tail], sizeof(nvme_device->controller.acq[admin_tail]), 0);

    // kernel_msg("//--------------------------------------------------//\n");
    // kernel_msg("status %x phase %x stat bit %x addr %x \n",nvme_device->controller.bar0->csts, 
    //                                                 nvme_device->controller.acq[admin_tail].phase,
    //                                                 nvme_device->controller.acq[admin_tail].stat,
    //                                                 nvme_device->controller.acq[admin_tail]);

    const uint8_t old_admin_tail_doorbell = admin_tail;
    admin_tail = (admin_tail + 1) % NVME_SUB_QUEUE_SIZE;

    nvme_device->controller.bar0->asq_admin_tail_doorbell = admin_tail;
    
    while (nvme_device->controller.acq[old_admin_tail_doorbell].command_raw == 0);
    
    // kernel_msg("status %x phase %x stat bit %x addr %x \n",nvme_device->controller.bar0->csts, 
    //                                             nvme_device->controller.acq[old_admin_tail_doorbell].phase,
    //                                             nvme_device->controller.acq[old_admin_tail_doorbell].stat,
    //                                             nvme_device->controller.acq[old_admin_tail_doorbell]);
    // kernel_msg("//--------------------------------------------------//\n");

    nvme_device->controller.acq[old_admin_tail_doorbell].command_raw = 0;
}

static void send_nvme_io_command(const NvmeDevice* nvme_device, const uint64_t sector_offset, const size_t nsid,
                                const uint64_t opcode, const uint64_t total_bytes, void* buffer) {
    if (nvme_device == NULL || buffer == NULL) return;
    if (nsid <= 0 || nsid > nvme_device->namespace_count) return;

    NvmeSubmissionQueueEntry cmd;
    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);

    static uint16_t command_id_counter = 0;

    cmd.command.command_id = ++command_id_counter;
    cmd.command.opcode = opcode;
    cmd.nsid = nsid;
    cmd.prp1 = get_phys_address((uint64_t)buffer);

    void* prp2 = NULL;
    if (total_bytes >= (nvme_device->page_size / nvme_device->namespace_info[nsid - 1]->sector_size)) {
        prp2 = (void*)kcalloc(PAGE_BYTE_SIZE);
        cmd.prp2 = get_phys_address((uint64_t)prp2);
    }  else {
        cmd.prp2 = 0;
    }

    cmd.command_dword[0] = sector_offset & 0xffffffff; // save lower 32 bits
    cmd.command_dword[1] = sector_offset >> 32; // save upper 32 bits
    cmd.command_dword[2] = (total_bytes & 0xffffffff) - 1;

    static uint8_t io_tail_doorbell = 0;

    memcpy(&cmd, nvme_device->controller.iosq + io_tail_doorbell, sizeof(cmd));

    static uint8_t phase = 0;
    const uint8_t old_io_tail_doorbell = io_tail_doorbell;

    if (++io_tail_doorbell == NVME_SUB_QUEUE_SIZE) {
        io_tail_doorbell = 0;
        phase = !phase;
    }

    nvme_device->controller.bar0->asq_io1_tail_doorbell = io_tail_doorbell;

    while (nvme_device->controller.iocq[old_io_tail_doorbell].phase == phase);

    nvme_device->controller.bar0->acq_io1_tail_doorbell = old_io_tail_doorbell;

    nvme_device->controller.iocq[old_io_tail_doorbell].status = 0;
    nvme_device->controller.iocq[old_io_tail_doorbell].cmd_id = 0;

    kfree((void*)prp2);
}

void* nvme_read(const NvmeDevice* nvme_device, const size_t nsid, 
                const uint64_t bytes_offset, uint64_t total_bytes) {
    size_t sector_size = nvme_device->namespace_info[nsid - 1]->sector_size;
    
    total_bytes = ((total_bytes + sector_size - 1) / sector_size) * sector_size; // round up

    if (total_bytes > PAGE_BYTE_SIZE) {
        kernel_warn("buffer size is more than %u", PAGE_BYTE_SIZE);
        return NULL;
    }

    void* buffer = (void*)kcalloc(total_bytes);

    send_nvme_io_command(nvme_device, bytes_offset / sector_size, nsid, 
                        NVME_IO_READ, total_bytes / sector_size, buffer);
    
    return buffer;
}

bool_t init_nvme_device(NvmeDevice* nvme_device, const PciDeviceNode* pci_device) {
    if (nvme_device == NULL || pci_device == NULL) return FALSE;

    // Enable interrupts, bus-mastering DMA, and memory space access
    uint32_t command = pci_config_readl(pci_device->bus, pci_device->dev, pci_device->func, 0x04);
    command &= ~(1 << 10);
    command |= (1 << 1) | (1 << 2);

    pci_config_writel(pci_device->bus, pci_device->dev, pci_device->func, 0x04, command);

    nvme_device->controller.bar0 = (NvmeBar0*)pci_device->pci_header.bar0;

    const uint32_t default_controller_state = nvme_device->controller.bar0->cc;

    nvme_device->controller.acq = (NvmeComplQueueEntry*)kmalloc(QUEUE_SIZE);
    nvme_device->controller.asq = (NvmeSubmissionQueueEntry*)kmalloc(QUEUE_SIZE);

    nvme_device->controller.bar0->cc &= ~NVME_CTRL_ENABLE;

    kernel_msg("Waiting for nvme device ready...\n");
    while ((nvme_device->controller.bar0->csts & NVME_CTRL_ENABLE)){
        if (nvme_device->controller.bar0->csts & NVME_CTRL_ERROR){
            kernel_error("Nvme csts.cfs set\n");
            return FALSE;
        }
    }
    kernel_msg("Nvme device ready\n");

    nvme_device->controller.bar0->aqa = QUEUE_ATR_64_MASK;
    nvme_device->controller.bar0->acq = get_phys_address((uint64_t)nvme_device->controller.acq);
    nvme_device->controller.bar0->asq = get_phys_address((uint64_t)nvme_device->controller.asq);
    
    nvme_device->page_size = NVME_CTRL_PAGE_SIZE(nvme_device->controller.bar0->cc);
    nvme_device->controller.bar0->intms = NVME_MASK_ALL_INTERRUPTS;
    nvme_device->controller.bar0->cc = default_controller_state;

    kernel_msg("Nvme page size %u\n", nvme_device->page_size);
    kernel_msg("Controller verion %u.%u\n", NVME_CTRL_VERSION_MAJOR(nvme_device->controller.bar0->version),
                                            NVME_CTRL_VERSION_MINOR(nvme_device->controller.bar0->version));            

    kernel_msg("Waiting for nvme device ready...\n");
    while (!(nvme_device->controller.bar0->csts & NVME_CTRL_ENABLE)){
        if (nvme_device->controller.bar0->csts & NVME_CTRL_ERROR){
            kernel_error("Nvme csts.cfs set\n");
            return FALSE;
        }
    }
    kernel_msg("Nvme device ready\n");

    NvmeSubmissionQueueEntry cmd;
    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);

    cmd.command.opcode = NVME_ADMIN_CREATE_COMPLETION_QUEUE;
    cmd.command.command_id = 1;
    
    nvme_device->controller.iocq = (NvmeComplQueueEntry*)kmalloc(QUEUE_SIZE);

    cmd.prp1 = get_phys_address((uint64_t)nvme_device->controller.iocq);
    cmd.command_dword[0] = 0x003f0001; // queue id 1, 64 entries
    cmd.command_dword[1] = 1;

    send_nvme_admin_command(nvme_device, &cmd);

    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);
    cmd.command.opcode = NVME_ADMIN_CREATE_SUBMISSION_QUEUE;
    cmd.command.command_id = 1;
    
    nvme_device->controller.iosq = (NvmeSubmissionQueueEntry*)kmalloc(QUEUE_SIZE);

    cmd.prp1 = get_phys_address((uint64_t)nvme_device->controller.iosq);
    cmd.command_dword[0] = 0x003f0001; // queue id 1, 64 entries
    cmd.command_dword[1] = 0x00010001; // CQID 1 (31:16), pc enabled (0)

    send_nvme_admin_command(nvme_device, &cmd);

    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);
    
    cmd.command.opcode = NVME_ADMIN_IDENTIFY;
    cmd.command.command_id = 1;
    cmd.command_dword[0] = NVME_IDENTIFY_CONTROLLER;

    NvmeCtrlInfo* ctrl_info = (NvmeCtrlInfo*)kcalloc(PAGE_BYTE_SIZE);

    cmd.prp1 = get_phys_address((uint64_t)ctrl_info);

    send_nvme_admin_command(nvme_device, &cmd);

    kernel_msg("Vendor: %x\n", (uint64_t)ctrl_info->vendor_id);
    kernel_msg("Sub vendor: %x\n", (uint64_t)ctrl_info->sub_vendor_id);
    kernel_msg("Model: %s\n", ctrl_info->model);
    kernel_msg("Serial: %s\n", ctrl_info->serial);

    kfree((void*)ctrl_info);

    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);

    cmd.command.opcode = NVME_ADMIN_IDENTIFY;
    cmd.command.command_id = 1; 
    cmd.command_dword[0] = NVME_IDENTIFY_NAMESPACE;
    
    nvme_device->controller.namespace_list = (uint32_t*)kcalloc(sizeof(uint32_t));

    cmd.prp1 = get_phys_address((uint64_t)nvme_device->controller.namespace_list);

    send_nvme_admin_command(nvme_device, &cmd);

    nvme_device->namespace_count = 0;
    for (size_t i = 0; nvme_device->controller.namespace_list[i] != NULL; ++i) {
        kernel_msg("Namespace : %x\n", nvme_device->controller.namespace_list[i]);

        nvme_device->namespace_count++;

        memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);
        // identify namespace
        cmd.command.opcode = NVME_ADMIN_IDENTIFY;
        cmd.command.command_id = 1; 
        cmd.nsid = nvme_device->controller.namespace_list[i];

        if (i == 0){
            nvme_device->namespace_info = (NvmeNamespaceInfo**)kcalloc(sizeof(NvmeNamespaceInfo*));
        }

        nvme_device->namespace_info[i] = (NvmeNamespaceInfo*)kcalloc(sizeof(NvmeNamespaceInfo));

        cmd.prp1 = get_phys_address((uint64_t)nvme_device->namespace_info[i]);

        send_nvme_admin_command(nvme_device, &cmd);

        nvme_device->namespace_info[i]->sector_size = LBA_SIZE(nvme_device, i);
        kernel_msg("Namespace No. %u LBA size: %u\n", i + 1, nvme_device->namespace_info[i]->sector_size);
    }

    nvme_device->interface.nvme_read = &nvme_read;

    return TRUE;
}

bool_t is_nvme(const uint8_t class_code, const uint8_t subclass) {
    if (class_code == PCI_CLASS_CODE_STORAGE_CONTROLLER &&
        subclass == PCI_SUBCLASS_NVME_CONTROLLER) {
            return TRUE;
        }

    return FALSE;
}
