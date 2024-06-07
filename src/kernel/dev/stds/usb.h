#pragma once

#include "definitions.h"

#include "dev/device.h"

typedef struct UsbDevice {
    LIST_STRUCT_IMPL(UsbDevice)
} UsbDevice;

#define USB_DEV_STRUCT_IMPL \
    UsbDevice common;

typedef struct UsbBus {
    BUS_STRUCT_IMPL;
} UsbBus;

Status init_usb();

void usb_bus_push(UsbDevice* const device);