#include "storage.h"

#include "device.h"
#include "definitions.h"
#include "logger.h"
#include "mem.h"

#include "dev/blk/nvme.h"

#include "dev/stds/pci.h"

bool_t is_storage_device(const Device* const device) {
    return device->type == DEV_STORAGE;
}

Status init_storage_devices() {
    PciBus* pci_device_list = (PciBus*)dev_find(NULL, &is_pci_device);

    ListHead head = pci_device_list->nodes;

    if (pci_device_list == NULL) return KERNEL_ERROR;
    
    bool_t is_storage_device_found = FALSE;

    while (head.next != NULL) {
        PciInfo* pci_device = (PciInfo*)head.next;
            
        if (is_nvme(pci_device->pci_header.class_code, pci_device->pci_header.subclass)) {
            kernel_msg("Nvme device detected\n");

            is_storage_device_found = TRUE;

            NvmeController nvme_controller = create_nvme_controller(head.next);

            if (nvme_controller.acq == NULL || nvme_controller.asq == NULL) return KERNEL_ERROR;
            
            if (init_nvme_devices_for_controller(&nvme_controller) == FALSE) return KERNEL_ERROR;            
        }
        
        head.next = head.next->next;
    }

    if (!is_storage_device_found) {
        kernel_error("No storage device was found\n");
        
        return KERNEL_ERROR;  
    } 

    return KERNEL_OK;
}
