#include "device.h"

#include "assert.h"
#include "logger.h"
#include "mem.h"

/*
Dynamic pool of devices, must be used only inside kernel.

+===+===============+
|Idx| Device        |
+===+===============+
  ||            /\
  \/            ||
+---+---------------+
| 0 | Display       |
+---+---------------+
  ||            /\
  \/            ||
+---+---------------+
| 1 | Keyboard      |
+---+---------------+
  ||            /\
  \/            ||
+---+---------------+
| n | ...           |
+---+---------------+
*/
DevicePool dev_pool = { { NULL, NULL }, 0 };

size_t last_id = 0;

static inline size_t get_avail_dev_id() {
    return last_id++;
}

Device* dev_push(const DeviceType dev_type, const uint32_t dev_struct_size) {
    kassert(dev_struct_size > sizeof(Device));

    Device* new_device = (Device*)kcalloc(dev_struct_size);

    if (new_device == NULL) return NULL;

    new_device->id = get_avail_dev_id();
    new_device->type = dev_type;

    if (dev_pool.nodes.next == NULL) {
        dev_pool.nodes.next = (void*)new_device;
        dev_pool.nodes.prev = (void*)new_device;
    }
    else {
        new_device->prev = (Device*)dev_pool.nodes.prev;

        dev_pool.nodes.prev->next = (void*)new_device;
        dev_pool.nodes.prev = (void*)new_device;
    }

    dev_pool.size++;

    return new_device;
}

void dev_remove(Device* dev) {
    kassert(dev != NULL);

    if (dev_pool.nodes.next == dev_pool.nodes.prev) {
        kassert(dev == dev_pool.nodes.next);

        dev_pool.nodes.next == NULL;
        dev_pool.nodes.prev == NULL;
    }
    else if (dev == dev_pool.nodes.next) {
        dev->next->prev = NULL;
        dev_pool.nodes.next = (void*)dev->next;
    }
    else if (dev == dev_pool.nodes.prev) {
        dev->prev->next = NULL;
        dev_pool.nodes.prev = (void*)dev->prev;
    }
    else {
        dev->next->prev = dev->prev;
        dev->prev->next = dev->next;
    }

    dev_pool.size--;

    kfree((void*)dev);
}

Device* dev_find(Device* begin, DevPredicat_t predicat) {
    Device* curr_dev = (begin == NULL ? dev_pool.nodes.next : begin);

    while (curr_dev != NULL && predicat(curr_dev) == FALSE) {
        curr_dev = curr_dev->next;
    }

    return curr_dev;
}

Device* dev_find_first(DevPredicat_t predicat) {
    return dev_find((Device*)dev_pool.nodes.next, predicat);
}