#include "nvme.h"

#include "logger.h"
#include "mem.h"

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

typedef struct nvme_ctrl_info{

    unsigned short vendor_id;
    unsigned short sub_vendor_id;

    char serial[20];
    char model[40];

    //FIXME: complete nvme ctrl info


}__attribute__((packed)) nvme_ctrl_info;

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
    memset(&nvme_device->bar0->acq[admin_tail], sizeof(nvme_device->bar0->acq[admin_tail]), 0);

    kernel_msg("//--------------------------------------------------//\n");
    kernel_msg("status %x phase %x stat bit %x addr %x %x\n",nvme_device->bar0->csts, 
                                                    nvme_device->bar0->acq[admin_tail].phase,
                                                    nvme_device->bar0->acq[admin_tail].stat,
                                                    nvme_device->bar0->acq[admin_tail],
                                                    nvme_device->bar0->acq[admin_tail].cint3_raw);

    if (admin_tail >= NVME_SUB_QUEUE_SIZE) {
        return;
    }

    memcpy(admin_cmd, nvme_device->bar0->asq + admin_tail, sizeof(admin_cmd));

    // uint64_t* admin_submission_queue = nvme_device->bar0->asq;
    // admin_submission_queue[admin_tail++] = *(uint64_t*)admin_cmd;
    admin_tail++;
    nvme_device->bar0->sub_queue_tail_doorbell = admin_tail;

    // while (nvme_device->bar0->acq[admin_tail - 1].cint3_raw == 0) {

    // }

kernel_msg("status %x phase %x stat bit %x addr %x %x\n",nvme_device->bar0->csts, 
                                                    nvme_device->bar0->acq[admin_tail - 1].phase,
                                                    nvme_device->bar0->acq[admin_tail - 1].stat,
                                                    nvme_device->bar0->acq[admin_tail - 1],
                                                    nvme_device->bar0->acq[admin_tail - 1].cint3_raw);

    kernel_msg("//--------------------------------------------------//\n");
}

bool_t init_nvme_device(NvmeDevice* nvme_device, PciDeviceNode* pci_device) {
    if (nvme_device == NULL || pci_device == NULL) return FALSE;

    nvme_device->bar0 = (NvmeBar0*)pci_device->pci_header.bar0;
    
    // Enable PCI Bus Mastering
    uint32_t command = pci_config_readl(pci_device->bus, pci_device->dev, pci_device->func, 0x04);
    command |= 1 << 2;
    pci_config_writel(pci_device->bus, pci_device->dev, pci_device->func, 0x04, command);

    uint32_t default_controller_state = nvme_device->bar0->cc;
    kernel_msg("contr state %x\n", default_controller_state);

    nvme_device->bar0->cc &= ~NVME_CTRL_ENABLE;

    nvme_device->bar0->aqa = QUEUE_ATR_64_MASK;
    nvme_device->bar0->acq = (uint64_t*)get_phys_address((uint64_t*)kmalloc(ADMIN_QUEUE_SIZE));
    nvme_device->bar0->asq = (uint64_t*)get_phys_address((uint64_t*)kmalloc(ADMIN_QUEUE_SIZE));

    nvme_device->bar0->intms = NVME_MASK_ALL_INTERRUPTS;
    nvme_device->bar0->cc = default_controller_state;

    return TRUE;
}

bool_t is_nvme(uint8_t class_code, uint8_t subclass) {
    if (class_code == PCI_CLASS_CODE_STORAGE_CONTROLLER &&
        subclass == PCI_SUBCLASS_NVME_CONTROLLER) {
            return TRUE;
        }

    return FALSE;
}
