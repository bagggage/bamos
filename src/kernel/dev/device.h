#pragma once

#include "definitions.h"

#include "vm/object_mem_alloc.h"

#include "utils/list.h"

/*
Common header for all devices
For each unique device needs to define init_<device-name> function in <device-name>.h.

This function should return 'Status' and takes pointer to an device structure for current device type
like 'KeyboardDevice', status might be 'KERNEL_OK' if device initialized successfully and device structure
might be filled with device's data and interface,
otherwise if something went wrong, device structure doesn't change.
*/

// Device types
typedef enum DeviceType {
    DEV_UNKNOWN = 0,
    DEV_KEYBOARD,
    DEV_DISPLAY,
    DEV_MOUSE,
    DEV_STORAGE,
    DEV_TIMER,
    DEV_USB_BUS,
    DEV_PCI_BUS
} DeviceType;

typedef struct Device Device;

// Common device structure
typedef struct Device {
    LIST_STRUCT_IMPL(Device);

// TODO: maybe id, name, type idk... something
    uint64_t id;
    DeviceType type;
} Device;

typedef struct DevicePool {
    ListHead nodes;
    size_t size;
} DevicePool;

#define DEV_FUNC(device_name, ret_t, func_name, ...) \
   typedef ret_t (* device_name ## _ ## func_name ## _t)(__VA_ARGS__)

#define DEVICE_STRUCT_IMPL(dev_name) \
    Device common; \
    dev_name ## Interface interface

/*
Create and push new device structure into 'dev_pool'. Device structure initialized with valid id
and type fields, other filelds initialized with zeroes.
Returns valid pointer to device structure, otherwise returns NULL.
*/
Device* dev_push(const DeviceType dev_type, const uint32_t dev_struct_size);

/*
Remove device from 'dev_pool', all pointers to that device becomes invalid.
*/
void dev_remove(Device* dev);

typedef bool_t (*DevPredicat_t)(Device* dev);

Device* dev_find(Device* begin, DevPredicat_t predicat);
Device* dev_find_first(DevPredicat_t predicat);