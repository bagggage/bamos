#include "usb.h"

#include "ehci.h"
#include "logger.h"

static UsbBus* usb_bus = NULL;

Status init_usb() {
    usb_bus = (UsbBus*)dev_push(DEV_USB_BUS, sizeof(UsbBus));

    if (usb_bus == NULL) {
        error_str = "Not enough memory";
        return KERNEL_ERROR;
    }

    return init_ehci();
}

void usb_bus_push(UsbDevice* const device) {
    device->next = NULL;

    if (usb_bus->nodes.next == NULL) {
        usb_bus->nodes.next = (void*)device;
        device->prev = NULL;
    }
    else {
        device->prev = (void*)usb_bus->nodes.prev;
        usb_bus->nodes.prev->next = (void*)device;
    }

    usb_bus->nodes.prev = (void*)device;
}