#include "file.h"

#include "assert.h"
#include "mem.h"

#include "proc.h"
#include "local.h"

#include "libc/errno.h"
#include "libc/fcntl.h"
#include "libc/stdio.h"

static ObjectMemoryAllocator* fd_oma = NULL;

FileDescriptor* fd_new() {
    if (fd_oma == NULL) {
        fd_oma = oma_new(sizeof(FileDescriptor));

        if (fd_oma == NULL) return NULL;
    }

    return (FileDescriptor*)oma_alloc(fd_oma);
}

void fd_delete(FileDescriptor* const descriptor) {
    oma_free(descriptor, fd_oma);
}

static inline long fd_push(Process* const process, FileDescriptor* const descriptor) {
    long result = -1;

    if (process->files == NULL) {
        process->files = (FileDescriptor**)kmalloc(sizeof(FileDescriptor*));

        if (process->files == NULL) return -1;

        process->files[0] = descriptor;
        process->files_capacity++;

        result = 0;
    }
    else {
        for (uint32_t i = 0; i < process->files_capacity; ++i) {
            if (process->files[i] == NULL) {
                process->files[i] = descriptor;
                result = i;

                break;
            }
        }

        if (result < 0) {
            FileDescriptor** files =
                (FileDescriptor**)krealloc(process->files, (process->files_capacity + 1) * sizeof(FileDescriptor*));

            if (files == NULL) return -1;

            process->files = files;
            process->files[process->files_capacity] = descriptor;

            result = process->files_capacity;
            process->files_capacity++;
        }
    }

    return result;
}

long fd_open(Process* const process, const VfsDentry* parent, const char* const filename, int flags) {
    VfsDentry* const dentry = vfs_open(filename, parent == NULL ? process->work_dir : parent);

    if (dentry == NULL) return -ENOENT;
    if ((flags & O_DIRECTORY) != 0 && dentry->inode->type != VFS_TYPE_DIRECTORY) return -ENOTDIR;
    if (dentry->inode->type == VFS_TYPE_DIRECTORY &&
        (
            (flags & O_WRONLY) != 0 ||
            (flags & O_RDWR) != 0
        )
    ) {
        return -EISDIR;
    }

    spin_lock(&process->files_lock);

    FileDescriptor* descriptor = fd_new();

    if (descriptor == NULL) {
        spin_release(&process->files_lock);
        return -ENOMEM;
    }

    long idx = fd_push(process, descriptor);

    if (idx < 0) {
        spin_release(&process->files_lock);
        fd_delete(descriptor);
        return -ENOMEM;
    }

    descriptor->dentry = dentry;

    spin_release(&process->files_lock);

    descriptor->cursor_offset = 0;
    descriptor->mode = flags;
    descriptor->lock = spinlock_init();

    return idx;
}

bool_t fd_close(Process* const process, const uint32_t idx) {
    spin_lock(&process->files_lock);

    if (idx >= process->files_capacity) {
        spin_release(&process->files_lock);
        return FALSE;
    }

    FileDescriptor* descriptor = process->files[idx];

    if (descriptor == NULL) {
        spin_release(&process->files_lock);
        return FALSE;
    }

    process->files[idx] = NULL;

    spin_release(&process->files_lock);

    oma_free((void*)descriptor, fd_oma);

    return TRUE;
}