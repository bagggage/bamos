#include "storage.h"

#include "device.h"
#include "definitions.h"
#include "logger.h"
#include "mem.h"

#include "dev/blk/nvme.h"

#include "dev/stds/pci.h"

Status add_storage_device(StorageDevice* storage_device, const void* const new_device, const StorageDevType type) {
    if (storage_device == NULL) return KERNEL_INVALID_ARGS;

    if (storage_device->head == NULL) {
        storage_device->head = (StorageNode*)kmalloc(sizeof(StorageNode));

        storage_device->head->device = new_device;
        storage_device->head->type = type;
        storage_device->head->next = NULL;

        return KERNEL_OK;
    }

    StorageNode* current_node = storage_device->head;

    while (current_node->next != NULL) {
        current_node = current_node->next;
    }
    
    current_node->next->device = new_device;
    current_node->next->type = type;
    current_node->next->next = NULL;
    
    return KERNEL_OK;
}

bool_t is_storage_device(const Device* const device) {
    return device->type == DEV_STORAGE;
}

Status init_storage_device(StorageDevice* storage_device) {
    PciDevice* pci_device_list = (PciDevice*)dev_find(NULL, &is_pci_device);

    if (pci_device_list == NULL) return KERNEL_ERROR;
    
    while (pci_device_list->head != NULL) {
        if (is_nvme(pci_device_list->head->pci_info.pci_header.class_code, 
                    pci_device_list->head->pci_info.pci_header.subclass)) {
            kernel_msg("Nvme device detected\n");

            NvmeController nvme_controller = create_nvme_controller(pci_device_list->head);

            if (init_nvme_devices_for_controller(storage_device, &nvme_controller) == FALSE) return KERNEL_ERROR;            
        }
        
        pci_device_list->head = pci_device_list->head->next;
    }

    return KERNEL_OK;
}
