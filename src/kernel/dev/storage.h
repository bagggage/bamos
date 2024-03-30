#pragma once

#include "dev/device.h"

typedef enum StorageDevType {
    STORAGE_DEV_IDE = 0,
    STORAGE_DEV_SATA,
    STORAGE_DEV_NVME
} StorageDevType;

typedef struct StorageDevice {
    StorageDevType type;
} StorageDevice;

typedef struct StorageNode {
    StorageDevice* dev;
    struct StorageNode* next;
} StorageNode;

#define STORAGE_DEVICE_STRUCT_IMPL(dev_name) \
    StorageDevice common; \
    dev_name ## Interface interface

Status init_storage_devices();