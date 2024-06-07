#include "vfs.h"

#include "assert.h"
#include "logger.h"
#include "mem.h"

#include "fs/ext2/ext2.h"
#include "fs/udev/udev.h"

#include "partition/gpt.h"
#include "partition/gpt_list.h"

#include "vm/object_mem_alloc.h"

static VfsDentry* root_dentry = NULL;
static VfsDentry* home_dentry = NULL;
static ObjectMemoryAllocator* dentry_oma = NULL;

Status init_vfs() {
    UNUSED(home_dentry);

    if (find_gpt_tables() != KERNEL_OK) {
        error_str = "Not found any GPT table";
        return KERNEL_ERROR;
    }

    GptPartitionNode* partition_node = gpt_get_first_node();

    if (partition_node == NULL) {
        error_str = "There is no any partition detected on disk";
        return KERNEL_ERROR;
    }

    dentry_oma = oma_new(sizeof(VfsDentry));

    if (dentry_oma == NULL) {
        error_str = "Not enough memory for vfs OMA";
        return KERNEL_ERROR;
    }

    while (partition_node != NULL) {
        if (is_ext2(partition_node->storage_device, partition_node->partition_entry.lba_start)) {
            kernel_msg("EXT2 superblock found\n");

            if (ext2_init(
                    partition_node->storage_device,
                    partition_node->partition_entry.lba_start,
                    partition_node->partition_entry.lba_end
                ) != KERNEL_OK) {
                error_str = "Ext2 fs initialization failed";
                return KERNEL_ERROR;
            }
        }

        partition_node = partition_node->next;
    }

    if (udev_init() == KERNEL_ERROR) return KERNEL_ERROR;

    return KERNEL_OK;
}

VfsInode* vfs_new_inode_by_type(const VfsInodeTypes type) {
    VfsInode* vfs_inode = NULL;

    switch (type) {
    case VFS_TYPE_DIRECTORY: {
        vfs_inode = (VfsInode*)kmalloc(sizeof(VfsInodeDir));

        if (vfs_inode == NULL) return NULL;

        break;
    }
    case VFS_TYPE_BLOCK_DEVICE:
    case VFS_TYPE_CHARACTER_DEVICE:
    case VFS_TYPE_SOCKET:
    case VFS_TYPE_FIFO:
    case VFS_TYPE_FILE: {
        vfs_inode = (VfsInode*)kmalloc(sizeof(VfsInodeFile));

        if (vfs_inode == NULL) return NULL;

        break;
    }
    case VFS_TYPE_SYMBOLIC_LINK: {
        vfs_inode = (VfsInode*)kmalloc(sizeof(VfsInodeFile));

        if (vfs_inode == NULL) return NULL;

        break;
    }
    default: {
        break;
    }
    }

    vfs_inode->type = type;

    return vfs_inode;
}

// Currently unused
//static bool_t vfs_dentry_add_child(VfsDentry* const parent, const VfsDentry* const child) {
//    kassert(parent != NULL && child != NULL);
//
//    VfsDentry** new_childs = (VfsDentry**)krealloc(parent->childs, (parent->childs_count + 2) * sizeof(VfsDentry*));
//
//    if (new_childs == NULL) return FALSE;
//
//    new_childs[parent->childs_count++] = (VfsDentry*)child;
//    new_childs[parent->childs_count] = NULL;
//
//    return TRUE;
//}

static void vfs_dentry_replace_child(VfsDentry* const parent, VfsDentry* const child, VfsDentry* const new) {
    for (uint32_t i = 0; i < parent->childs_count; ++i) {
        if (parent->childs[i] == child) {
            kassert(new->inode == NULL);

            new->inode = child->inode;
            parent->childs[i] = new;

            vfs_delete_dentry(child);

            break;
        }
    }
}

static Status vfs_mount_helper(const char* const mountpoint,
                               VfsDentry* const mnt_dentry) {
    if (mnt_dentry == NULL) return KERNEL_ERROR;

    char* const temp_filename = kcalloc(strlen(mountpoint) + 1);
    memcpy(mountpoint, temp_filename, strlen(mountpoint) + 1);

    char* current_token = strtok(temp_filename, "/");
    char* next_token = strtok(NULL, "/");

    VfsDentry* dentry = root_dentry;

    while (next_token != NULL) {
        current_token = next_token;

        if (dentry->childs == NULL) {
            dentry->interface.fill_dentry(dentry);
        }

        if ((dentry = vfs_lookup(dentry, current_token)) == NULL) {
            kfree(temp_filename);
            return KERNEL_ERROR;
        }

        if (dentry->inode->type != VFS_TYPE_DIRECTORY) {
            kfree(temp_filename);
            return KERNEL_ERROR;
        }

        next_token = strtok(NULL, "/");
    }

    dentry = vfs_lookup(dentry, current_token);

    if (dentry == NULL) {
        kfree(temp_filename);
        return KERNEL_ERROR;
    }

    memcpy(current_token, mnt_dentry->name, strlen(current_token) + 1);
    kfree(temp_filename);

    mnt_dentry->parent = dentry->parent;
    vfs_dentry_replace_child(dentry->parent, dentry, mnt_dentry);

    return KERNEL_OK;
}

Status vfs_mount(const char* const mountpoint, VfsDentry* const mnt_dentry) {
    if (mountpoint == NULL || mnt_dentry == NULL) return KERNEL_ERROR;

    if (mountpoint[0] == '/' && strlen(mountpoint) == 1) {
        if (root_dentry != NULL) {
            kernel_warn("Mountpoint '/' already mounted\n");
            return KERNEL_ERROR;
        }

        root_dentry = mnt_dentry;

        return KERNEL_OK;
    }

    return vfs_mount_helper(mountpoint, mnt_dentry);
}

VfsDentry* vfs_lookup(const VfsDentry* const dentry, const char* const dentry_name) {
    if (dentry == NULL) return NULL;

    if (strcmp(dentry_name, ".") == 0) return dentry;
    if (strcmp(dentry_name, "..") == 0) {
        return dentry == root_dentry ? dentry : dentry->parent;
    }

    if (dentry->childs == NULL &&
        dentry->inode->type == VFS_TYPE_DIRECTORY &&
        dentry->interface.fill_dentry != NULL) {
        dentry->interface.fill_dentry((VfsDentry*)dentry);
    }

    VfsDentry* child = NULL;

    for (size_t i = 0; dentry->childs[i] != NULL; ++i) {
        if(!strcmp(dentry_name, dentry->childs[i]->name)) {
            child = dentry->childs[i];

            break;
        }
    }

    return child;
}

VfsDentry* vfs_open(const char* const filename, VfsDentry* const parent) {
    if (filename == NULL) return NULL;

    VfsDentry* dentry = parent;

    if (parent == NULL || filename[0] == '/' ||
        (filename[0] == '~' && filename[1] == '/')) {
        dentry = root_dentry;
    }
    if (filename[0] == '.' && (filename[1] == '\0' ||
        (filename[1] == '/' && filename[2] == '\0'))) {
        return dentry;
    }

    char* const temp_filename = kcalloc(strlen(filename) + 1);
    memcpy(filename, temp_filename, strlen(filename) + 1);

    char* current_token = strtok(temp_filename, "/");
    char* next_token = strtok(NULL, "/");

    if (current_token == NULL) current_token = ".";

    while (next_token != NULL) {
        if (dentry->inode->type != VFS_TYPE_DIRECTORY) {
            kfree(temp_filename);
            return NULL;
        }

        if ((dentry = vfs_lookup(dentry, current_token)) == NULL) {
            kfree(temp_filename);
            return NULL;
        }

        current_token = next_token;
        next_token = strtok(NULL, "/");
    }

    dentry = vfs_lookup(dentry, current_token);

    kfree(temp_filename);

    return dentry;
}

uint32_t vfs_read(const VfsDentry* const dentry, const uint32_t offset, 
                 const uint32_t total_bytes, void* const buffer) {
    if (dentry == NULL || buffer == NULL) return 0;
    if (total_bytes == 0) return 0;
    if (dentry->inode->type != VFS_TYPE_FILE) return 0;

    VfsInodeFile* vfs_file = (VfsInodeFile*)dentry->inode;

    const uint32_t buffer_size = (total_bytes >= VFS_MAX_BUFFER_SIZE) ? VFS_MAX_BUFFER_SIZE : total_bytes;

    uint32_t counts_to_read = (total_bytes / VFS_MAX_BUFFER_SIZE) + 1;
    uint32_t start_offset = 0;

    while (counts_to_read > 0) {
        vfs_file->interface.read(vfs_file, offset + start_offset, buffer_size, (char*)buffer + start_offset);

        start_offset += VFS_MAX_BUFFER_SIZE;
        counts_to_read--;
    }

    return total_bytes;
}

uint32_t vfs_write(const VfsDentry* const dentry, const uint32_t offset, 
                 const uint32_t total_bytes, const void* buffer) {
    if (dentry == NULL || buffer == NULL) return 0;
    if (total_bytes == 0 || total_bytes > VFS_MAX_BUFFER_SIZE) return 0;
    if (dentry->inode->type != VFS_TYPE_FILE) return 0;

    VfsInodeFile* vfs_file = (VfsInodeFile*)dentry->inode;

    const uint32_t buffer_size = (total_bytes >= VFS_MAX_BUFFER_SIZE) ? VFS_MAX_BUFFER_SIZE : total_bytes;

    uint32_t counts_to_write = (total_bytes / VFS_MAX_BUFFER_SIZE) + 1;
    uint32_t start_offset = 0;

    while (counts_to_write > 0) {
        vfs_file->interface.write(vfs_file, offset + start_offset, buffer_size, (const char*)buffer + start_offset);

        start_offset += VFS_MAX_BUFFER_SIZE;
        counts_to_write--;
    }

    return total_bytes;
}

static unsigned int _vfs_get_path(const VfsDentry* const dentry, char* const buffer) {
    if (dentry->parent != NULL) {
        unsigned int length = _vfs_get_path(dentry->parent, buffer);

        if (buffer[length - 1] != '/') {
            buffer[length] = '/';
            buffer[length + 1] = '\0';
        }
        else {
            length = 0;
        }

        return strcpy(buffer + length + 1, dentry->name) + length + 1;
    }
    else {
        return strcpy(buffer, dentry->name);
    }
}

bool_t vfs_get_path(const VfsDentry* const dentry, char* const buffer) {
    kassert(dentry != NULL);

    buffer[0] = '\0';

    return (_vfs_get_path(dentry, buffer) > 0 ? TRUE : FALSE);
}

void vfs_close(VfsDentry* const dentry) {
    if (dentry == NULL) return;
}

VfsDentry* vfs_new_dentry() {
    VfsDentry* dentry = (VfsDentry*)oma_alloc(dentry_oma);

    if (dentry != NULL) dentry->parent = NULL;

    return dentry;
}

void vfs_delete_dentry(VfsDentry* dentry) {
    return oma_free((void*)dentry, dentry_oma);
}