#include "nvme.h"

#include "dev/stds/pci.h"

bool_t is_nvme(uint8_t class_code, uint8_t subclass) {
    if (class_code == PCI_CLASS_CODE_STORAGE_CONTROLLER &&
        subclass == PCI_SUBCLASS_NVME_CONTROLLER) {
            return TRUE;
        }

    return FALSE;
}