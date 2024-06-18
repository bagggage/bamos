#include "nvme.h"

#include "assert.h"
#include "logger.h"
#include "math.h"
#include "mem.h"

#include "cpu/io.h"

#include "partition/gpt.h"

#include "vm/vm.h"

#define LOG_PREFIX "Nvme: "

#define NVME_CTRL_ENABLE 1
#define NVME_CTRL_ERROR 0b10

#define QUEUE_SIZE 4096
#define NVME_SUB_QUEUE_SIZE 64

#define NVME_MASK_ALL_INTERRUPTS 0xffffffff

#define NVME_IDENTIFY_CONTROLLER 1
#define NVME_IDENTIFY_NAMESPACE 2

#define QUEUE_ATR_64_MASK 0x003f003f

#define NVME_CTRL_PAGE_SIZE(controller_conf) (1 << (12 + ((controller_conf & 0b11110000000) >> 7)))

#define NVME_CTRL_VERSION_MAJOR(version) (version >> 16)
#define NVME_CTRL_VERSION_MINOR(version) (((version) >> 8) & 0xFF)

#define LBA_SIZE(nvme_device) (1 << \
                (nvme_device->namespace_info->lba_format_supports[nvme_device->namespace_info->lba_format_size & 0x7].lba_data_size))

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
    NVME_IO_READ
} NvmeIOCommands;

static void nvme_send_admin_command(NvmeController* const nvme, 
                                    const NvmeSubmissionQueueEntry* const admin_cmd) {
    kassert(nvme != NULL || admin_cmd != NULL);

    static uint8_t admin_tail =  0;
    static uint8_t admin_head = 0;

    memcpy(admin_cmd, (void*)(nvme->asq + admin_tail), sizeof(*admin_cmd));
    memset((void*)&nvme->acq[admin_tail], sizeof(nvme->acq[admin_tail]), 0);

    const uint8_t old_admin_tail_doorbell = admin_tail;

    admin_tail = (admin_tail + 1) % NVME_SUB_QUEUE_SIZE;
    admin_head = (admin_head + 1) % NVME_SUB_QUEUE_SIZE;

    nvme->bar0->asq_admin_tail_doorbell = admin_tail;
    
    while (nvme->acq[old_admin_tail_doorbell].command_raw == 0);

    nvme->bar0->acq_admin_head_doorbell = admin_head;
    
    nvme->acq[old_admin_tail_doorbell].command_raw = 0;
}

static void nvme_send_io_command(NvmeDevice* const nvme, const uint64_t sector_offset,
                                 const uint64_t opcode, const uint64_t total_bytes, void* const buffer) {
    kassert(nvme != NULL || buffer != NULL);

    NvmeSubmissionQueueEntry cmd;
    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);

    static uint16_t command_id_counter = 0;

    cmd.command.command_id = ++command_id_counter;
    cmd.command.opcode = opcode;
    cmd.nsid = nvme->nsid;
    cmd.prp1 = get_phys_address((uint64_t)buffer);

    void* prp2 = NULL;

    if (total_bytes >= (nvme->controller->page_size / nvme->lba_size)) {
        prp2 = (void*)kcalloc(PAGE_BYTE_SIZE);

        if (prp2 == NULL) return;

        cmd.prp2 = get_phys_address((uint64_t)prp2);
    } 
    else {
        cmd.prp2 = 0;
    }

    cmd.command_dword[0] = sector_offset & 0xffffffff; // save lower 32 bits
    cmd.command_dword[1] = sector_offset >> 32; // save upper 32 bits
    cmd.command_dword[2] = (total_bytes & 0xffffffff) - 1;

    static uint8_t io_tail = 0;
    static uint8_t io_head = 0;

    memcpy(&cmd, (void*)(nvme->controller->iosq + io_tail), sizeof(cmd));
    memset((void*)&nvme->controller->iocq[io_tail], sizeof(nvme->controller->iocq[io_tail]), 0);

    const uint8_t old_io_tail_doorbell = io_tail;

    io_tail = (io_tail + 1) % NVME_SUB_QUEUE_SIZE;
    io_head = (io_head + 1) % NVME_SUB_QUEUE_SIZE;

    nvme->controller->bar0->asq_io1_tail_doorbell = io_tail;

    while (nvme->controller->iocq[old_io_tail_doorbell].command_raw == 0);

    nvme->controller->bar0->acq_io1_head_doorbell = io_head;
    nvme->controller->iocq[old_io_tail_doorbell].command_raw = 0;

    kfree((void*)prp2);
}

static void nvme_read(StorageDevice* const device, const uint64_t bytes_offset,
                      uint64_t total_bytes, void* const buffer) {
    kassert(device != NULL || buffer != NULL);

    const size_t sector_size = device->lba_size;

    total_bytes = ((total_bytes + sector_size - 1) / sector_size) * sector_size; // round up
    //div_with_roundup(total_bytes, sector_size) * sector_size;

    kassert(total_bytes <= PAGE_BYTE_SIZE);

    nvme_send_io_command((void*)device, bytes_offset / sector_size, 
                         NVME_IO_READ, total_bytes / sector_size, buffer);
}

static void nvme_write(StorageDevice* const device, const uint64_t bytes_offset,
                       uint64_t total_bytes, void* const buffer) {
    kassert(device != NULL || buffer != NULL);

    const size_t sector_size = device->lba_size;

    nvme_send_io_command((void*)device, bytes_offset / sector_size, 
                         NVME_IO_WRITE, total_bytes / sector_size, buffer);
}

bool_t is_nvme_controller(const PciDevice* const pci_device) {
    return (
        pci_device->config.class_code == PCI_STORAGE_CONTROLLER &&
        pci_device->config.subclass == NVME_CONTROLLER
    ) ? TRUE : FALSE;
}

Status init_nvme_controller(const PciDevice* const pci_device) {
    kassert(pci_device != NULL);
    kassert(is_nvme_controller(pci_device));

    NvmeController* nvme = (NvmeController*)kcalloc(sizeof(NvmeController));

    if (nvme == NULL) {
        error_str = LOG_PREFIX "no memory";
        return KERNEL_ERROR;
    }

    nvme->pci_device = (PciDevice*)pci_device;
    nvme->bar0 = (NvmeBar0*)vm_map_mmio(pci_device->bar0, PAGES_PER_2MB);

    if (nvme->bar0 == 0) {
        error_str = LOG_PREFIX "Failed to map BAR0 space";
        kfree(nvme);

        return KERNEL_ERROR;
    }

    // Enable interrupts, bus-mastering DMA, and memory space access
    uint32_t command = pci_config_readl(pci_device->config_base, 0x04);
    command &= ~(1 << 10);
    command |= (1 << 1) | (1 << 2);

    pci_config_writel(pci_device->config_base, 0x04, command);

    const uint32_t default_controller_state = nvme->bar0->cc;
    
    nvme->acq = (NvmeComplQueueEntry*)kmalloc(QUEUE_SIZE);
    nvme->asq = (NvmeSubmissionQueueEntry*)kmalloc(QUEUE_SIZE);

    if (nvme->acq == NULL || nvme->asq == NULL) {
        error_str = LOG_PREFIX "no memory";

        kfree(nvme->acq);
        kfree(nvme->asq);
        kfree(nvme);

        return KERNEL_ERROR;
    }

    nvme->bar0->cc &= ~NVME_CTRL_ENABLE;

    //kernel_msg("Waiting for nvme controller ready...\n");
    while ((nvme->bar0->csts & NVME_CTRL_ENABLE)){
        if (nvme->bar0->csts & NVME_CTRL_ERROR){
            error_str = LOG_PREFIX "csts.cfs is set";

            kfree(nvme->acq);
            kfree(nvme->asq);
            kfree(nvme);

            return KERNEL_ERROR;
        }
    }
    //kernel_msg("Nvme controller ready\n");

    nvme->bar0->aqa = QUEUE_ATR_64_MASK;
    nvme->bar0->acq = get_phys_address((uint64_t)nvme->acq);
    nvme->bar0->asq = get_phys_address((uint64_t)nvme->asq);
    
    nvme->page_size = NVME_CTRL_PAGE_SIZE(nvme->bar0->cc);
    nvme->bar0->intms = NVME_MASK_ALL_INTERRUPTS;
    nvme->bar0->cc = default_controller_state;

    kernel_msg("Nvme page size %u\n", nvme->page_size);
    kernel_msg("Controller version %u.%u\n", NVME_CTRL_VERSION_MAJOR(nvme->bar0->version),
                                            NVME_CTRL_VERSION_MINOR(nvme->bar0->version));            

    //kernel_msg("Waiting for nvme controller ready...\n");
    while (!(nvme->bar0->csts & NVME_CTRL_ENABLE)) {
        if (nvme->bar0->csts & NVME_CTRL_ERROR){
            error_str = LOG_PREFIX "csts.cfs is set";

            kfree(nvme->acq);
            kfree(nvme->asq);
            kfree(nvme);

            return KERNEL_ERROR;
        }
    }
    //kernel_msg("Nvme controller ready\n");

    NvmeSubmissionQueueEntry cmd;
    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);

    cmd.command.opcode = NVME_ADMIN_CREATE_COMPLETION_QUEUE;
    cmd.command.command_id = 1;
    
    nvme->iocq = (NvmeComplQueueEntry*)kmalloc(QUEUE_SIZE);

    if (nvme->iocq == NULL) {
        error_str = LOG_PREFIX "failed to allocate I/O command queue";

        kfree(nvme->acq);
        kfree(nvme->asq);
        kfree(nvme);

        return KERNEL_ERROR;
    }

    cmd.prp1 = get_phys_address((uint64_t)nvme->iocq);
    cmd.command_dword[0] = 0x003f0001; // queue id 1, 64 entries
    cmd.command_dword[1] = 1;

    nvme_send_admin_command(nvme, &cmd);

    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);
    cmd.command.opcode = NVME_ADMIN_CREATE_SUBMISSION_QUEUE;
    cmd.command.command_id = 1;

    nvme->iosq = (NvmeSubmissionQueueEntry*)kmalloc(QUEUE_SIZE);

    if (nvme->iosq == NULL) {
        error_str = LOG_PREFIX "failed to allocate I/O submission queue";

        kfree(nvme->acq);
        kfree(nvme->asq);
        kfree(nvme->iocq);
        kfree(nvme);

        return KERNEL_ERROR;
    }

    cmd.prp1 = get_phys_address((uint64_t)nvme->iosq);
    cmd.command_dword[0] = 0x003f0001; // queue id 1, 64 entries
    cmd.command_dword[1] = 0x00010001; // CQID 1 (31:16), pc enabled (0)

    nvme_send_admin_command(nvme, &cmd);

    // Identify
    {
        memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);
    
        cmd.command.opcode = NVME_ADMIN_IDENTIFY;
        cmd.command.command_id = 1;
        cmd.command_dword[0] = NVME_IDENTIFY_CONTROLLER;

        NvmeCtrlInfo* ctrl_info = (NvmeCtrlInfo*)kcalloc(PAGE_BYTE_SIZE);

        if (ctrl_info != NULL) {
            cmd.prp1 = get_phys_address((uint64_t)ctrl_info);

            nvme_send_admin_command(nvme, &cmd);

            kernel_msg("Vendor: %x\n", (uint64_t)ctrl_info->vendor_id);
            kernel_msg("Sub vendor: %x\n", (uint64_t)ctrl_info->sub_vendor_id);
            kernel_msg("Model: %s\n", ctrl_info->model);
            kernel_msg("Serial: %s\n", ctrl_info->serial);

            kfree(ctrl_info);
        }
    }

    if (nvme_init_devices_for_controller(nvme) == FALSE) {
        kfree(nvme->acq);
        kfree(nvme->asq);
        kfree(nvme->iocq);
        kfree(nvme->iosq);
        kfree(nvme);

        return KERNEL_ERROR;
    }

    return KERNEL_OK;
}

bool_t nvme_init_devices_for_controller(NvmeController* const nvme_controller) {
    kassert(nvme_controller != NULL);

    NvmeSubmissionQueueEntry cmd;
    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);

    cmd.command.opcode = NVME_ADMIN_IDENTIFY;
    cmd.command.command_id = 1; 
    cmd.command_dword[0] = NVME_IDENTIFY_NAMESPACE;     

    uint32_t* namespace_array = (uint32_t*)kcalloc(PAGE_BYTE_SIZE);

    if (namespace_array == NULL) {
        error_str = LOG_PREFIX "no memory";
        return FALSE;
    }

    cmd.prp1 = get_phys_address((uint64_t)namespace_array);

    nvme_send_admin_command(nvme_controller, &cmd);

    for (size_t i = 0; namespace_array[i] != 0; ++i) {
        kernel_msg("Namespace : %x\n", namespace_array[i]);

        memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);

        cmd.command.opcode = NVME_ADMIN_IDENTIFY;
        cmd.command.command_id = 1; 
        cmd.nsid = namespace_array[i];

        NvmeDevice* nvme_device = (NvmeDevice*)dev_push(DEV_STORAGE, sizeof(NvmeDevice));

        if (nvme_device == NULL) {
            error_str = LOG_PREFIX "failed to create nvme device";
            kfree(namespace_array);
            return FALSE;
        }

        nvme_device->controller = nvme_controller;
        nvme_device->namespace_info = (NvmeNamespaceInfo*)kmalloc(sizeof(NvmeNamespaceInfo));
        nvme_device->nsid = namespace_array[i];

        cmd.prp1 = get_phys_address((uint64_t)nvme_device->namespace_info);

        nvme_send_admin_command(nvme_controller, &cmd);

        nvme_device->lba_size = LBA_SIZE(nvme_device);
        kernel_msg("Namespace No. %u LBA size: %u\n", i + 1, nvme_device->lba_size);

        nvme_device->interface.read = &nvme_read;
        nvme_device->interface.write = &nvme_write;

        if (gpt_inspect_storage_device((void*)nvme_device) != KERNEL_OK) {
            kernel_error(LOG_PREFIX "failed to inspect namespace.%u for GPT partitions\n", nvme_device->nsid);
        }
    }

    kfree(namespace_array);

    return TRUE;
}
