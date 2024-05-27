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
    PciBus* pci_device_list = (PciBus*)dev_find(NULL, &is_pci_bus);

    if (pci_device_list == NULL) return KERNEL_ERROR;
     
    bool_t is_storage_device_found = FALSE;

    PciDevice* pci_device = (PciDevice*)pci_device_list->nodes.next;

    if (pci_device == NULL) return KERNEL_ERROR;

    while (pci_device != NULL) {
        if (is_nvme(pci_device->config.class_code, pci_device->config.subclass)) {
            kernel_msg("Nvme device detected\n");

            is_storage_device_found = TRUE;

            NvmeController nvme_controller = create_nvme_controller(pci_device);

            if (nvme_controller.acq == NULL || nvme_controller.asq == NULL) return KERNEL_ERROR;
            
            if (init_nvme_devices_for_controller(&nvme_controller) == FALSE) return KERNEL_ERROR;            
        }
        
        pci_device = pci_device->next;
    }

    if (!is_storage_device_found) {
        error_str = "No supportable storage device was found";
        return KERNEL_ERROR;  
    }

    return KERNEL_OK;
}
