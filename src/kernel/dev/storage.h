#pragma once

#include "dev/device.h"

typedef enum StorageDevType {
    STORAGE_DEV_IDE = 0,
    STORAGE_DEV_SATA,
    STORAGE_DEV_NVME
} StorageDevType;

typedef struct StorageDevice StorageDevice;

DEV_FUNC(Storage, void*, read, const StorageDevice* const storage_device, 
        const uint64_t bytes_offset, uint64_t total_bytes);

typedef struct StorageInterface {
    Storage_read_t read;
} StorageInterface;

typedef struct StorageNode {
    void* device;
    StorageDevType type;
    struct StorageNode* next;
} StorageNode;

typedef struct StorageDevice {
    DEVICE_STRUCT_IMPL(Storage);
    StorageNode* head;
} StorageDevice;

#define STORAGE_DEVICE_STRUCT_IMPL \
    StorageDevice storage_common; \
    StorageInterface storage_interface

Status add_storage_device(StorageDevice* storage_device, const void* const new_device, const StorageDevType type);

bool_t is_storage_device(const Device* const device);

Status init_storage_device(StorageDevice* storage_device);