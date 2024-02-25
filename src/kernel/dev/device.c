#include "device.h"

#include "io/logger.h"
#include "utils/vector.h"
#include "mem.h"

DevicePool dev_pool = { NULL, 0 };

size_t last_id = 0;

static size_t get_avail_dev_id() {
    return last_id++;
}

Status add_device(DevType dev_type, void** out_dev_struct_ptr, size_t dev_struct_size) {
    if (dev_struct_size < sizeof(Device) || out_dev_struct_ptr == NULL) return KERNEL_INVALID_ARGS;
    if (vector_push_back((Vector*)&dev_pool, NULL, sizeof(Device*)) != KERNEL_OK) return KERNEL_ERROR;

    Device* new_device = (Device*)kmalloc(dev_struct_size);

    if (new_device == NULL) return KERNEL_ERROR;

    new_device->id = get_avail_dev_id();
    new_device->type = dev_type;

    dev_pool.data[dev_pool.size - 1] = new_device;

    *out_dev_struct_ptr = (void*)new_device;

    return KERNEL_OK;
}

Status remove_device(size_t idx) {
    if (idx >= dev_pool.size) return KERNEL_INVALID_ARGS;

    Device* dev = dev_pool.data[idx];
    uint64_t temp_dev_id = dev->id;

    vector_remove((Vector*)&dev_pool, idx, sizeof(Device*));
    kfree((void*)dev);

    return KERNEL_OK;
}