#include "nvme.h"

#include "assert.h"
#include "logger.h"
#include "mem.h"
#include "vm/vm.h"

#include "cpu/io.h"

#define NVME_CTRL_ENABLE 1
#define NVME_CTRL_ERROR 0b10

#define NVME_SUB_QUEUE_SIZE 64

#define NVME_MASK_ALL_INTERRUPTS 0xffffffff

#define QUEUE_ATR_64_MASK 0x003f003f

#define ADMIN_QUEUE_SIZE 4096

#define NVME_CTRL_PAGE_SIZE(controller_conf) (1 << (12 + ((controller_conf & 0b11110000000) >> 7)))

#define NVME_CTRL_VERSION_MAJOR(version) (version >> 16)
#define NVME_CTRL_VERSION_MINOR(version) (((version) >> 8) & 0xFF)

typedef struct NvmeCtrlInfo{

    unsigned short vendor_id;
    unsigned short sub_vendor_id;

    char serial[20];
    char model[40];

    //FIXME: complete nvme ctrl info
} ATTR_PACKED NvmeCtrlInfo;

typedef enum NvmeAdminCommands {
    NVM_ADMIN_DELETE_SUBMISSION_QUEUE   = 0,
    NVM_ADMIN_CREATE_SUBMISSION_QUEUE   = 1,
    NVM_ADMIN_GET_LOG_PAGE              = 2,
    NVM_ADMIN_DELETE_COMPLETION_QUEUE   = 4,
    NVM_ADMIN_CREATE_COMPLETION_QUEUE   = 5,
    NVM_ADMIN_IDENTIFY                  = 6,
    NVM_ADMIN_ABORT                     = 8,
    NVM_ADMIN_SET_FEATURES              = 9,
    NVM_ADMIN_GET_FEATURES              = 10
} NvmeAdminCommands;

volatile void send_nvme_admin_command(NvmeDevice* nvme_device, NvmeSubmissionCmd* admin_cmd) {
    if (nvme_device == NULL || admin_cmd == NULL) return;

    static uint32_t admin_tail =  0;
    kernel_msg("admin tail %u\n", admin_tail);
    memset(&nvme_device->acq[admin_tail], sizeof(nvme_device->acq[admin_tail]), 0);

    kernel_msg("//--------------------------------------------------//\n");
    kernel_msg("status %x phase %x stat bit %x addr %x %x\n",nvme_device->bar0->csts, 
                                                    nvme_device->acq[admin_tail].phase,
                                                    nvme_device->acq[admin_tail].stat,
                                                    nvme_device->acq[admin_tail],
                                                    nvme_device->acq[admin_tail].cint3_raw);

    if (admin_tail >= NVME_SUB_QUEUE_SIZE) {
        return;
    }

    memcpy(admin_cmd, nvme_device->bar0->asq + admin_tail, sizeof(admin_cmd));

    // uint64_t* admin_submission_queue = nvme_device->bar0->asq;
    // admin_submission_queue[admin_tail++] = *(uint64_t*)admin_cmd;
    admin_tail++;
    nvme_device->bar0->sub_queue_tail_doorbell = admin_tail;

    //while (nvme_device->acq[admin_tail - 1].cint3_raw == 0);

    kernel_msg("status %x phase %x stat bit %x addr %x %x\n",nvme_device->bar0->csts, 
                                                    nvme_device->acq[admin_tail - 1].phase,
                                                    nvme_device->acq[admin_tail - 1].stat,
                                                    nvme_device->acq[admin_tail - 1],
                                                    nvme_device->acq[admin_tail - 1].cint3_raw);

    kernel_msg("//--------------------------------------------------//\n");
}

bool_t init_nvme_device(NvmeDevice* nvme_device, PciDeviceNode* pci_device) {
    kernel_msg("NVME PCI Dev: %x\n", pci_device);

    if (nvme_device == NULL || pci_device == NULL) return FALSE;

    nvme_device->bar0 = (NvmeBar0*)pci_device->pci_header.bar0;

    vm_map_phys_to_virt(
        (uint64_t)pci_device->pci_header.bar0,
        (uint64_t)pci_device->pci_header.bar0,
        1,
        (VMMAP_FORCE | VMMAP_WRITE | VMMAP_CACHE_DISABLED));

    // Enable PCI Bus Mastering
    uint32_t command = pci_config_readl(pci_device->bus, pci_device->dev, pci_device->func, 0x04);
    command |= 1 << 2;
    pci_config_writel(pci_device->bus, pci_device->dev, pci_device->func, 0x04, command);

    uint32_t default_controller_state = nvme_device->bar0->cc;
    kernel_msg("Controller state %x\n", default_controller_state);
    kernel_msg("Controller verion %u.%u\n", NVME_CTRL_VERSION_MAJOR(nvme_device->bar0->version),
                                            NVME_CTRL_VERSION_MINOR(nvme_device->bar0->version));

    kernel_msg("Door bell: %x\n", nvme_device->bar0->sub_queue_tail_doorbell);
    kernel_msg("VENDOR ID: %x\n", (uint64_t)pci_device->pci_header.vendor_id);
    kernel_msg("ID: %x\n", (uint64_t)pci_device->pci_header.device_id);
    kernel_msg("CLASS: %x\n", (uint64_t)pci_device->pci_header.class_code);
    kernel_msg("SUBCLASS: %x\n", (uint64_t)pci_device->pci_header.subclass);
    kernel_msg("BAR0: %x\n", (uint64_t)pci_device->pci_header.bar0);
    kernel_msg("BAR1: %x\n", (uint64_t)pci_device->pci_header.bar1);
    kernel_msg("BAR2: %x\n", (uint64_t)pci_device->pci_header.bar2);
    kernel_msg("BAR3: %x\n", (uint64_t)pci_device->pci_header.bar3);
    kernel_msg("BAR4: %x\n", (uint64_t)pci_device->pci_header.bar4);
    kernel_msg("BAR5: %x\n", (uint64_t)pci_device->pci_header.bar5);

    //while((nvme_device->bar0->csts % 1) == 0){
    //    if(nvme_device->bar0->csts & 0b10){
    //        kernel_error("NVME CSTS.CFS SET\n");
    //        return;
    //    }
    //}

    nvme_device->bar0->cc &= ~NVME_CTRL_ENABLE;
    nvme_device->acq = (NvmeComplQueueEntry*)kmalloc(ADMIN_QUEUE_SIZE);
    nvme_device->asq = (NvmeComplQueueEntry*)kmalloc(ADMIN_QUEUE_SIZE);

    kassert(sizeof(Command) == 4);
    kernel_msg("%u\n", sizeof(NvmeSubmissionCmd));
    kassert(sizeof(NvmeSubmissionCmd) == 64);
    kassert(sizeof(NvmeCapRegister) == sizeof(uint64_t));
    kassert(((uint64_t)nvme_device->acq % PAGE_BYTE_SIZE) == 0 && ((uint64_t)nvme_device->asq % PAGE_BYTE_SIZE) == 0);

    nvme_device->bar0->aqa = QUEUE_ATR_64_MASK;
    nvme_device->bar0->acq = get_phys_address((uint64_t)nvme_device->acq);
    nvme_device->bar0->asq = get_phys_address((uint64_t)nvme_device->asq);

    nvme_device->bar0->intms = NVME_MASK_ALL_INTERRUPTS;
    nvme_device->bar0->cc = default_controller_state;

    NvmeSubmissionCmd cmd;
    memset(&cmd, sizeof(NvmeSubmissionCmd), 0);

    cmd.command.opcode = 0;
    cmd.command.command_id = 1;
    cmd.command_dword[0] = 1;

    send_nvme_admin_command(nvme_device, &cmd);

    memset(&cmd, sizeof(NvmeSubmissionCmd), 0);

    cmd.command.opcode = 0x4;
    cmd.command.command_id = 1;
    cmd.command_dword[0] = 1;

    send_nvme_admin_command(nvme_device, &cmd);

    cmd.command.opcode = 0x5;
    cmd.command.command_id = 1;
    cmd.command_dword[0] = 0x003f0001;
    cmd.command_dword[1] = 0x00000001;
    cmd.nsid = 0;

    VMPageFrame io_cmpl_queue_frame = vm_alloc_pages(1, cpu_get_current_pml4(), VMMAP_CACHE_DISABLED | VMMAP_WRITE);
    VMPageFrame io_sbm_queue_frame = vm_alloc_pages(1, cpu_get_current_pml4(), VMMAP_CACHE_DISABLED | VMMAP_WRITE);

    const uint64_t io_cmpl_phys = (uint64_t)((VMPageList*)io_cmpl_queue_frame.phys_pages.next)->phys_page_base * PAGE_BYTE_SIZE;
    const uint64_t io_sbm_phys = (uint64_t)((VMPageList*)io_sbm_queue_frame.phys_pages.next)->phys_page_base * PAGE_BYTE_SIZE;

    cmd.prp1 = io_cmpl_phys;

    send_nvme_admin_command(nvme_device, &cmd);

    cmd.command.opcode = 0x1;
    cmd.command_dword[1] = 0x00010001;
    cmd.prp1 = io_sbm_phys;

    send_nvme_admin_command(nvme_device, &cmd);

    memset(&cmd, sizeof(NvmeSubmissionCmd), 0);

    cmd.command.opcode = 0x6;
    cmd.command.command_id = 1;
    cmd.command_dword[0] = 0x00000001;
    cmd.nsid = 0;

    NvmeCtrlInfo* ctrl_info = (NvmeCtrlInfo*)kcalloc(PAGE_BYTE_SIZE);

    cmd.prp1 = get_phys_address((uint64_t)ctrl_info);

    send_nvme_admin_command(nvme_device, &cmd);

    kernel_msg("Vendor: %x\n", (uint64_t)ctrl_info->vendor_id);
    kernel_msg("Sub vendor: %x\n", (uint64_t)ctrl_info->sub_vendor_id);
    kernel_msg("Model: %s\n", ctrl_info->model);
    kernel_msg("Serial: %s\n", ctrl_info->serial);

    kfree((void*)ctrl_info);

    return TRUE;
}

bool_t is_nvme(uint8_t class_code, uint8_t subclass) {
    if (class_code == PCI_CLASS_CODE_STORAGE_CONTROLLER &&
        subclass == PCI_SUBCLASS_NVME_CONTROLLER) {
            return TRUE;
        }

    return FALSE;
}
