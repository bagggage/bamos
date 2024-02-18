#pragma once

#include "definitions.h"

// Common header for all devices
// For each unique device needs to define init_<device-name> function in <device-name>.h
//
// This function should return 'Status' and takes pointer to an device structure for current device type
// like 'KeyboardDevice', status might be 'KERNEL_OK' if device initialized successfully and device structure
// might be filled with device's data and interface
// otherwise if something went wrong, device structure doesn't change

// Device types
typedef enum DevType {
    DEV_UNKNOWN = 0,
    DEV_KEYBOARD,
    DEV_DISPLAY,
    DEV_MOUSE,
    DEV_DRIVE,
    DEV_USB,
    DEV_PCI,
    DEV_SERIAL
} DevType;

// Common device structure
typedef struct Device {
// TODO: maybe id, name, type idk... something
    uint64_t id;
    DevType type;
} Device;

typedef struct DevicePool {
    Device** data;
    size_t size;
} DevicePool;

/*
Dynamic pool of devices, must be used only inside kernel.
There are two devices that should be always available after initialization: display and keyboard,
must be accessible at indexes 0 and 1, respectively.

+===+===============+
|Idx| Device        |
+===+===============+
| 0 | Display       |
+---+---------------+
| 1 | Keyboard      |
+---+---------------+
| n | ...           |
+---+---------------+   
*/
extern DevicePool dev_pool;

#define DEV_FUNC(device_name, ret_t, func_name, ...) \
   typedef ret_t (* device_name ## _ ## func_name ## _t)(__VA_ARGS__)

#define DEVICE_STRUCT_IMPL(dev_name) \
    Device common; \
    dev_name ## Interface interface