#include "udev.h"

#include "logger.h"
#include "mem.h"
#include "string.h"

#include "dev/device.h"
#include "dev/stds/pci.h"
#include "dev/keyboard.h"
#include "fs/vfs.h"

#define TERMINAL_DEV_NAME "tty"

static VfsDentry root_dentry = {
    .childs = NULL,
    .childs_count = 0,
    .inode = NULL,
    .parent = NULL
};

static UdevFs udev_fs = {
    .pci_bus = NULL
};

void udev_read_pci(const VfsInodeFile* const inode, const uint32_t offset, const uint32_t total_bytes, char* const buffer) {
    if (inode->inode.index >= udev_fs.pci_bus->size) return;
    if (offset >= sizeof(PciConfigurationSpace)) return;

    PciDevice* device = (PciDevice*)udev_fs.pci_bus->nodes.next;
    const uint32_t idx = inode->inode.index;

    for (uint32_t i = 0; i < idx; ++i) {
        device = device->next;
    }

    const uint32_t accessable_bytes = sizeof(PciConfigurationSpace) - offset;
    const uint32_t bytes_to_read = total_bytes > accessable_bytes ? accessable_bytes : total_bytes;

    memcpy(
        (const void*)(((const uint8_t*)&device->config) + offset),
        (void*)buffer,
        bytes_to_read
    );
}

void udev_read_tty(const VfsInodeFile* const inode, const uint32_t offset, const uint32_t total_bytes, char* const buffer) {
    if (inode->inode.index != 0 || offset != 0 || total_bytes == 0) return;

    KeyboardDevice* device = (KeyboardDevice*)dev_find_by_type(NULL, DEV_KEYBOARD);

    for (uint32_t i = 0; i < total_bytes; ++i) {
        KernelScancode scancode;

        while ((scancode = device->interface.get_scan_code()) == SCAN_CODE_NONE);

        buffer[i] = scan_code_to_ascii(scancode);
    }
}

static inline bool_t is_ascii(const char c) {
    return ((c >= ' ' && c <= '~') ? 1 : 0);
}

void udev_write_tty(const VfsInodeFile* const inode, const uint32_t offset, const uint32_t total_bytes, char* const buffer) {
    kernel_msg("Writing to tty...\n");

    if (inode->inode.index != 0 || offset != 0 || total_bytes == 0) return;

    for (uint32_t i = 0; i < total_bytes; ++i) {
        const char c = buffer[i];

        if (is_ascii(c)) raw_putc(buffer[i]);
    }
}

static VfsDentry* make_tty(const uint16_t idx) {
    VfsDentry* result = vfs_new_dentry();

    if (result == NULL) return NULL;

    result->inode = vfs_new_inode_by_type(VFS_TYPE_FILE);

    if (result->inode == NULL) {
        vfs_delete_dentry(result);
        return NULL;
    }

    result->inode->index = idx;
    result->inode->hard_link_count = 1;
    ((VfsInodeFile*)result->inode)->interface.read = &udev_read_tty;
    ((VfsInodeFile*)result->inode)->interface.write = &udev_write_tty;

    sprintf(result->name, "tty%u", idx);
    kernel_msg("udev fs: tty: %s\n", result->name);

    result->childs = NULL;
    result->childs_count = 0;
    result->interface.fill_dentry = NULL;
    result->parent = &root_dentry;

    return result;
}

static bool_t make_pci_entries() {
    PciBus* bus = (PciBus*)dev_find_by_type(NULL, DEV_PCI_BUS);

    if (bus == NULL) return TRUE;

    const uint32_t begin_idx = root_dentry.childs_count;
    root_dentry.childs_count += bus->size;

    if (root_dentry.childs != NULL) {
        VfsDentry** childs = (VfsDentry**)krealloc((void*)root_dentry.childs, (root_dentry.childs_count + 1) * sizeof(VfsDentry*));

        if (childs == NULL) {
            error_str = "failed to allocate childs array";
            return FALSE;
        }

        root_dentry.childs = childs;
    }
    else {
        root_dentry.childs = (VfsDentry**)kmalloc((root_dentry.childs_count + 1) * sizeof(VfsDentry*));

        if (root_dentry.childs == NULL) {
            error_str = "failed to allocate childs array";
            return FALSE;
        }
    }

    root_dentry.childs[root_dentry.childs_count] = NULL;

    PciDevice* device = (PciDevice*)bus->nodes.next;

    for (uint32_t i = begin_idx; i < root_dentry.childs_count; ++i) {
        VfsDentry* dentry = vfs_new_dentry();

        if (dentry == NULL) {
            root_dentry.childs = krealloc((void*)root_dentry.childs, (begin_idx + 1) * sizeof(VfsDentry*));
            root_dentry.childs[root_dentry.childs_count] = NULL;
            root_dentry.childs_count = begin_idx;

            error_str = "failed to allocate dentry";

            return FALSE;
        }

        dentry->inode = vfs_new_inode_by_type(VFS_TYPE_FILE);

        if (dentry->inode == NULL) {
            vfs_delete_dentry(dentry);

            root_dentry.childs = krealloc((void*)root_dentry.childs, (begin_idx + 1) * sizeof(VfsDentry*));
            root_dentry.childs[root_dentry.childs_count] = NULL;
            root_dentry.childs_count = begin_idx;

            error_str = "failed to allocate inode";

            return FALSE;
        }

        dentry->inode->hard_link_count = 1;
        dentry->inode->index = i - begin_idx;
        ((VfsInodeFile*)dentry->inode)->interface.read = &udev_read_pci;
        ((VfsInodeFile*)dentry->inode)->interface.write = NULL;

        sprintf(dentry->name, "pci-%u:%u.%u", device->bus, device->dev, device->func);
        kernel_msg("udev fs: pci entry: %s\n", dentry->name);

        dentry->interface.fill_dentry = NULL;
        dentry->childs = NULL;
        dentry->childs_count = 0;
        dentry->parent = &root_dentry;

        device = device->next;
    }

    return TRUE;
}

Status udev_init() {
    VfsDentry* tty_dentry = make_tty(0);

    if (tty_dentry == NULL) {
        error_str = "udev fs: Failed to make 'tty0' entry";
        return KERNEL_ERROR;
    }

    root_dentry.childs_count = 1;

    if (make_pci_entries() == FALSE) {
        vfs_delete_dentry(tty_dentry);

        if (root_dentry.childs != NULL) {
            kfree(root_dentry.childs);
            root_dentry.childs = 0;
        }

        sprintf(error_str, "udev fs: Failed to make entries for pci devices: %s", error_str);
        return KERNEL_ERROR;
    }

    root_dentry.childs[0] = tty_dentry;

    vfs_mount("/dev", &root_dentry);

    return KERNEL_OK;
}