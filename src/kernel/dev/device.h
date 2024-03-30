#pragma once

#include "definitions.h"

/*
Common header for all devices
For each unique device needs to define init_<device-name> function in <device-name>.h.

This function should return 'Status' and takes pointer to an device structure for current device type
like 'KeyboardDevice', status might be 'KERNEL_OK' if device initialized successfully and device structure
might be filled with device's data and interface,
otherwise if something went wrong, device structure doesn't change.
*/

// Device types
typedef enum DevType {
    DEV_UNKNOWN = 0,
    DEV_KEYBOARD,
    DEV_DISPLAY,
    DEV_MOUSE,
    DEV_DRIVE,
    DEV_TIMER,
    DEV_USB,
    DEV_PCI,
    DEV_SERIAL,
} DevType;

typedef struct Device Device;

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

#define DEV_FUNC(device_name, ret_t, func_name, ...) \
   typedef ret_t (* device_name ## _ ## func_name ## _t)(__VA_ARGS__)

#define DEVICE_STRUCT_IMPL(dev_name) \
    Device common; \
    dev_name ## Interface interface

#define DEV_DISPLAY_ID  0
#define DEV_KEYBOARD_ID 1
#define DEV_TIMER_ID    2
#define DEV_PCI_ID      3

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

/*
Create and push new device structure into 'dev_pool'. Device structure initialized with valid id
and type fields, other filelds initialized with zeroes.
Returns 'KERNEL_OK' and set pointer to valid value, otherwise returns 'KERNEL_ERROR' or
'KERNEL_INVALID_ARGS' and leaves the pointer unchanged.
*/
Status add_device(DevType dev_type, void** out_dev_struct_ptr, size_t dev_struct_size);
/*
Remove device from 'dev_pool', all pointers to that device becomes invalid.
Returns 'KERNEL_OK' if successed, otherwise leaves 'dev_pool' unchanged.
*/
Status remove_device(size_t dev_idx);