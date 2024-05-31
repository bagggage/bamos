#pragma once

#include "dev/device.h"

typedef struct StorageDevice StorageDevice;

DEV_FUNC(Storage, void, read, StorageDevice* const storage_device, 
        const uint64_t bytes_offset, uint64_t total_bytes, void* const buffer);
DEV_FUNC(Storage, void, write, StorageDevice* const storage_device, 
        const uint64_t bytes_offset, uint64_t total_bytes, void* const buffer);

typedef struct StorageInterface {
    Storage_read_t read;    // the bytes_offset will be round down to the nearest lba entry
    Storage_write_t write;
} StorageInterface;

typedef struct StorageDevice {
    DEVICE_STRUCT_IMPL(Storage);
    
    size_t lba_size;
} StorageDevice;

#define STORAGE_DEVICE_STRUCT_IMPL \
    Device common; \
    StorageInterface interface; \
    size_t lba_size

bool_t is_storage_device(const Device* const device);

Status init_storage_devices();