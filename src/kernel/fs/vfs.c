#include "vfs.h"

#include "logger.h"
#include "mem.h"

#include "fs/ext2/ext2.h"

#include "partition/gpt.h"
#include "partition/gpt_list.h"

static VfsDentry* root_dentry = NULL;
static VfsDentry* home_dentry = NULL;

Status init_vfs() {
    if (find_gpt_tables() != KERNEL_OK) return KERNEL_ERROR;

    GptPartitionNode* partition_node = gpt_get_first_node();
    
    if (partition_node == NULL) return KERNEL_ERROR;
    
    while (partition_node != NULL) {
        if (is_ext2(partition_node->storage_device, partition_node->partition_entry.lba_start)) {
            kernel_msg("EXT2 superblock found\n");

            if (ext2_init(partition_node->storage_device,
                partition_node->partition_entry.lba_start
                ) != KERNEL_OK) {
                return KERNEL_ERROR;
            }
        }

        partition_node = partition_node->next;
    }

    return KERNEL_OK;
}

static Status vfs_mount_helper(const char* const mountpoint, 
                               const VfsDentry* const dentry, 
                               const VfsDentry* parent) {
    if (dentry == NULL || parent == NULL) return KERNEL_ERROR;
    
    char* dir_name = strtok(mountpoint, "/");

    kernel_msg("dir name %s\n", dir_name);

    if (parent->childs == NULL) {
        parent->interface.fill_dentry(parent);
    }

    for (size_t i = 0; dentry->childs[i] != NULL; ++i) {
        if(!strcmp(dir_name, dentry->childs[i]->name)) {
            parent = dentry->childs[i];

            break;
        }
    }

    // TODO: create a node on disk
    
    kfree(dir_name);

    vfs_mount_helper(mountpoint + strlen(dir_name) + 1, dentry, parent);

    return KERNEL_OK;
}

VfsInode* create_vfs_inode_by_type(const VfsInodeTypes type) {
    VfsInode* vfs_inode = NULL;

    switch (type) {
    case VFS_TYPE_DIRECTORY: {
        vfs_inode = (VfsInodeDir*)kmalloc(sizeof(VfsInodeDir));

        if (vfs_inode == NULL) return NULL;

        break;
    }
    case VFS_TYPE_FILE: {
        vfs_inode = (VfsInodeFile*)kmalloc(sizeof(VfsInodeFile));

        if (vfs_inode == NULL) return NULL;

        break;
    }
    default: {
        vfs_inode = (VfsInodeFile*)kmalloc(sizeof(VfsInodeFile));   // for now just malloc for the biggest size

        if (vfs_inode == NULL) return NULL;
        
        break;
    }
    }
        
    return vfs_inode;
}

Status vfs_mount(const char* const mountpoint, const VfsDentry* const dentry) {
    if (mountpoint == NULL || dentry == NULL) return KERNEL_ERROR;

    if (mountpoint[0] == '/' && strlen(mountpoint) == 1) {
        if (root_dentry != NULL) {
            kernel_warn("Mountpoint / already mounted\n");
            
            return KERNEL_COUGH;
        }

        root_dentry = dentry;

        return KERNEL_OK;
    }

    // add + 1 to remove '/' (e.g /home -> home)
    return vfs_mount_helper(mountpoint + 1, dentry, root_dentry);
}

VfsDentry* vfs_lookup(const VfsDentry* const dentry, const char* const dentry_name) {
    if (dentry == NULL) return NULL;
    if (dentry->childs == NULL) return NULL;

    VfsDentry* child = NULL;

    for (size_t i = 0; dentry->childs[i] != NULL; ++i) {
        if(!strcmp(dentry_name, dentry->childs[i]->name)) {
            child = dentry->childs[i];

            break;
        }
    }

    return child;
}