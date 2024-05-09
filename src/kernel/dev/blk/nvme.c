#include "nvme.h"

#include "assert.h"
#include "logger.h"
#include "mem.h"

#include "cpu/io.h"

#include "vm/vm.h"

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

static void send_nvme_admin_command(NvmeController* const nvme_controller, 
                                    const NvmeSubmissionQueueEntry* const admin_cmd) {
    if (nvme_controller == NULL || admin_cmd == NULL) return;

    static uint8_t admin_tail =  0;
    static uint8_t admin_head = 0;

    memcpy(admin_cmd, nvme_controller->asq + admin_tail, sizeof(*admin_cmd));
    memset(&nvme_controller->acq[admin_tail], sizeof(nvme_controller->acq[admin_tail]), 0);

    const uint8_t old_admin_tail_doorbell = admin_tail;

    admin_tail = (admin_tail + 1) % NVME_SUB_QUEUE_SIZE;
    admin_head = (admin_head + 1) % NVME_SUB_QUEUE_SIZE;

    nvme_controller->bar0->asq_admin_tail_doorbell = admin_tail;
    
    while (nvme_controller->acq[old_admin_tail_doorbell].command_raw == 0);

    nvme_controller->bar0->acq_admin_head_doorbell = admin_head;
    
    nvme_controller->acq[old_admin_tail_doorbell].command_raw = 0;
}

static void send_nvme_io_command(NvmeDevice* const nvme_device, const uint64_t sector_offset,
                                 const uint64_t opcode, const uint64_t total_bytes, void* const buffer) {
    if (nvme_device == NULL || buffer == NULL) return;

    NvmeSubmissionQueueEntry cmd;
    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);

    static uint16_t command_id_counter = 0;

    cmd.command.command_id = ++command_id_counter;
    cmd.command.opcode = opcode;
    cmd.nsid = nvme_device->nsid;
    cmd.prp1 = get_phys_address((uint64_t)buffer);

    void* prp2 = NULL;

    if (total_bytes >= (nvme_device->controller.page_size / nvme_device->lba_size)) {
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

    memcpy(&cmd, nvme_device->controller.iosq + io_tail, sizeof(cmd));
    memset(&nvme_device->controller.iocq[io_tail], sizeof(nvme_device->controller.iocq[io_tail]), 0);

    const uint8_t old_io_tail_doorbell = io_tail;

    io_tail = (io_tail + 1) % NVME_SUB_QUEUE_SIZE;
    io_head = (io_head + 1) % NVME_SUB_QUEUE_SIZE;

    nvme_device->controller.bar0->asq_io1_tail_doorbell = io_tail;

    while (nvme_device->controller.iocq[old_io_tail_doorbell].command_raw == 0);

    nvme_device->controller.bar0->acq_io1_head_doorbell = io_head;

    nvme_device->controller.iocq[old_io_tail_doorbell].command_raw = 0;

    kfree((void*)prp2);
}

static void nvme_read(const NvmeDevice* const nvme_device, const uint64_t bytes_offset,
                      uint64_t total_bytes, void* const buffer) {
    if (nvme_device == NULL || buffer == NULL) return;

    const size_t sector_size = nvme_device->lba_size;

    total_bytes = ((total_bytes + sector_size - 1) / sector_size) * sector_size; // round up

    if (total_bytes > PAGE_BYTE_SIZE) {
        kernel_warn("Buffer size is more than %u", PAGE_BYTE_SIZE);
        return;
    }

    send_nvme_io_command(nvme_device, bytes_offset / sector_size, 
                         NVME_IO_READ, total_bytes / sector_size, buffer);
}

static void nvme_write(const NvmeDevice* const nvme_device, const uint64_t bytes_offset,
                       uint64_t total_bytes, void* const buffer) {
    if (nvme_device == NULL || buffer == NULL) return;

    const size_t sector_size = nvme_device->lba_size;

    send_nvme_io_command(nvme_device, bytes_offset / sector_size, 
                         NVME_IO_WRITE, total_bytes / sector_size, buffer);
}

bool_t is_nvme(const uint8_t class_code, const uint8_t subclass) {
    if (class_code == PCI_STORAGE_CONTROLLER &&
        subclass == NVME_CONTROLLER) {
        return TRUE;
    }

    return FALSE;
}

NvmeController create_nvme_controller(const PciDevice* const pci_device) {
    if (pci_device == NULL) return (NvmeController){NULL, NULL, NULL, NULL, NULL, 0};

    NvmeController nvme_controller;

    nvme_controller.pci_device = pci_device;
    nvme_controller.bar0 = (NvmeBar0*)pci_device->config.bar0;

    // Enable interrupts, bus-mastering DMA, and memory space access
    uint32_t command = pci_config_readl(pci_device->bus, pci_device->dev, pci_device->func, 0x04);
    command &= ~(1 << 10);
    command |= (1 << 1) | (1 << 2);

    pci_config_writel(pci_device->bus, pci_device->dev, 
                      pci_device->func, 0x04, command);

    const uint32_t default_controller_state = nvme_controller.bar0->cc;
    
    nvme_controller.acq = (NvmeComplQueueEntry*)kmalloc(QUEUE_SIZE);
    nvme_controller.asq = (NvmeSubmissionQueueEntry*)kmalloc(QUEUE_SIZE);
    nvme_controller.bar0->cc &= ~NVME_CTRL_ENABLE;

    kernel_msg("Waiting for nvme controller ready...\n");
    while ((nvme_controller.bar0->csts & NVME_CTRL_ENABLE)){
        if (nvme_controller.bar0->csts & NVME_CTRL_ERROR){
            kernel_error("Nvme csts.cfs set\n");

            kfree(nvme_controller.acq);
            kfree(nvme_controller.asq);

            return (NvmeController){NULL, NULL, NULL, NULL, NULL, 0};
        }
    }
    kernel_msg("Nvme controller ready\n");

    nvme_controller.bar0->aqa = QUEUE_ATR_64_MASK;
    nvme_controller.bar0->acq = get_phys_address((uint64_t)nvme_controller.acq);
    nvme_controller.bar0->asq = get_phys_address((uint64_t)nvme_controller.asq);
    
    nvme_controller.page_size = NVME_CTRL_PAGE_SIZE(nvme_controller.bar0->cc);
    nvme_controller.bar0->intms = NVME_MASK_ALL_INTERRUPTS;
    nvme_controller.bar0->cc = default_controller_state;

    kernel_msg("Nvme page size %u\n", nvme_controller.page_size);
    kernel_msg("Controller verion %u.%u\n", NVME_CTRL_VERSION_MAJOR(nvme_controller.bar0->version),
                                            NVME_CTRL_VERSION_MINOR(nvme_controller.bar0->version));            

    kernel_msg("Waiting for nvme controller ready...\n");
    while (!(nvme_controller.bar0->csts & NVME_CTRL_ENABLE)){
        if (nvme_controller.bar0->csts & NVME_CTRL_ERROR){
            kernel_error("Nvme csts.cfs set\n");

            kfree(nvme_controller.acq);
            kfree(nvme_controller.asq);

            return (NvmeController){NULL, NULL, NULL, NULL, NULL, 0};
        }
    }
    kernel_msg("Nvme controller ready\n");

    NvmeSubmissionQueueEntry cmd;
    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);

    cmd.command.opcode = NVME_ADMIN_CREATE_COMPLETION_QUEUE;
    cmd.command.command_id = 1;
    
    nvme_controller.iocq = (NvmeComplQueueEntry*)kmalloc(QUEUE_SIZE);

    if (nvme_controller.iocq == NULL) {
        kfree(nvme_controller.acq);
        kfree(nvme_controller.asq);

        return (NvmeController){NULL, NULL, NULL, NULL, NULL, 0};
    }

    cmd.prp1 = get_phys_address((uint64_t)nvme_controller.iocq);
    cmd.command_dword[0] = 0x003f0001; // queue id 1, 64 entries
    cmd.command_dword[1] = 1;

    send_nvme_admin_command(&nvme_controller, &cmd);

    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);
    cmd.command.opcode = NVME_ADMIN_CREATE_SUBMISSION_QUEUE;
    cmd.command.command_id = 1;
    
    nvme_controller.iosq = (NvmeSubmissionQueueEntry*)kmalloc(QUEUE_SIZE);

    if (nvme_controller.iosq == NULL) {
        kfree(nvme_controller.acq);
        kfree(nvme_controller.asq);
        kfree(nvme_controller.iocq);

        return (NvmeController){NULL, NULL, NULL, NULL, NULL, 0};
    }

    cmd.prp1 = get_phys_address((uint64_t)nvme_controller.iosq);
    cmd.command_dword[0] = 0x003f0001; // queue id 1, 64 entries
    cmd.command_dword[1] = 0x00010001; // CQID 1 (31:16), pc enabled (0)

    send_nvme_admin_command(&nvme_controller, &cmd);

    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);
    
    cmd.command.opcode = NVME_ADMIN_IDENTIFY;
    cmd.command.command_id = 1;
    cmd.command_dword[0] = NVME_IDENTIFY_CONTROLLER;

    NvmeCtrlInfo* ctrl_info = (NvmeCtrlInfo*)kcalloc(PAGE_BYTE_SIZE);

    if (ctrl_info == NULL) return nvme_controller;

    cmd.prp1 = get_phys_address((uint64_t)ctrl_info);

    send_nvme_admin_command(&nvme_controller, &cmd);

    kernel_msg("Vendor: %x\n", (uint64_t)ctrl_info->vendor_id);
    kernel_msg("Sub vendor: %x\n", (uint64_t)ctrl_info->sub_vendor_id);
    kernel_msg("Model: %s\n", ctrl_info->model);
    kernel_msg("Serial: %s\n", ctrl_info->serial);

    kfree(ctrl_info);
    
    return nvme_controller;
}

bool_t init_nvme_devices_for_controller(const NvmeController* const nvme_controller) {
    if (nvme_controller == NULL) return FALSE;

    NvmeSubmissionQueueEntry cmd;
    memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);
    
    cmd.command.opcode = NVME_ADMIN_IDENTIFY;
    cmd.command.command_id = 1; 
    cmd.command_dword[0] = NVME_IDENTIFY_NAMESPACE;     
    
    uint32_t* namespace_array = (uint32_t*)kcalloc(PAGE_BYTE_SIZE);

    if (namespace_array == NULL) return FALSE;

    cmd.prp1 = get_phys_address((uint64_t)namespace_array);

    send_nvme_admin_command(nvme_controller, &cmd);

    for (size_t i = 0; namespace_array[i] != NULL; ++i) {
        kernel_msg("Namespace : %x\n", namespace_array[i]);

        memset(&cmd, sizeof(NvmeSubmissionQueueEntry), 0);
        
        cmd.command.opcode = NVME_ADMIN_IDENTIFY;
        cmd.command.command_id = 1; 
        cmd.nsid = namespace_array[i];

        NvmeDevice* nvme_device = dev_push(DEV_STORAGE, sizeof(NvmeDevice));

        if (nvme_device == NULL) {
            kfree(namespace_array);
            return FALSE;
        }

        nvme_device->controller = *nvme_controller;
        nvme_device->namespace_info = (NvmeNamespaceInfo*)kmalloc(sizeof(NvmeNamespaceInfo));
        nvme_device->nsid = namespace_array[i];
    
        cmd.prp1 = get_phys_address((uint64_t)nvme_device->namespace_info);

        send_nvme_admin_command(nvme_controller, &cmd);

        nvme_device->lba_size = LBA_SIZE(nvme_device);
        kernel_msg("Namespace No. %u LBA size: %u\n", i + 1, nvme_device->lba_size);

        nvme_device->interface.read = &nvme_read;
        nvme_device->interface.write = &nvme_write;
    }
    
    kfree(namespace_array);
    
    return TRUE;
}
