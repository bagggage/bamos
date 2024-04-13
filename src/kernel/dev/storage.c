#include "storage.h"

#include "device.h"
#include "definitions.h"
#include "logger.h"
#include "mem.h"

#include "dev/blk/nvme.h"

#include "dev/stds/pci.h"

StorageNode* storage_pool = NULL;

static Status add_storage_device(const StorageDevType dev_type, void** out_dev_struct_ptr, size_t dev_struct_size) {
    if (dev_struct_size < sizeof(StorageDevice) || out_dev_struct_ptr == NULL) return KERNEL_INVALID_ARGS;

    StorageDevice* new_device = (StorageDevice*)kmalloc(dev_struct_size);
    
    if (new_device == NULL) return KERNEL_ERROR;

    new_device->type = dev_type;

    StorageNode* new_node = (StorageNode*)kmalloc(sizeof(StorageNode));
    new_node->dev = new_device;
    new_node->next = NULL;

    if (storage_pool == NULL) {
        storage_pool = new_node;
    } else {
        StorageNode* temp = storage_pool;
        
        while (temp->next != NULL) {
            temp = temp->next;
        }

        temp->next = new_node;
    }
    
    *out_dev_struct_ptr = (void*)new_device;
    
    return KERNEL_OK;
}

Status init_storage_devices() {
    PciDevice* pci_device_list = dev_pool.data[DEV_PCI_ID];
    PciDeviceNode* device_list = pci_device_list->device_list;

    while (device_list != NULL) {
        if (is_nvme(device_list->pci_header.class_code, device_list->pci_header.subclass)) {
            kernel_msg("Nvme device detected\n");

            NvmeDevice* nvme_device;

            if (add_storage_device(STORAGE_DEV_NVME, (void**)&nvme_device, sizeof(NvmeDevice)) != KERNEL_OK) return KERNEL_ERROR;
            if (init_nvme_device(nvme_device, device_list) != TRUE) return KERNEL_ERROR;
        }

        device_list = device_list->next;
    }

    return KERNEL_OK;
}
