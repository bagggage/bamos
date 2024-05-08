#include "ext2.h"

#include "logger.h"
#include "mem.h"

static Ext2Fs ext2_fs;

static void ext2_read_superblock(const StorageDevice* const storage_device,
                                 const uint64_t partition_lba_start,
                                 const Ext2Superblock* const superblock) {                               
    if (superblock == NULL) return;

    storage_device->interface.read(storage_device, 
    (partition_lba_start * storage_device->lba_size) + EXT2_SUPERBLOCK_OFFSET, 
    sizeof(Ext2Superblock), superblock);
}

static void ext2_read_block(const Ext2Fs* const ext2_fs, const size_t block, void* const buffer) {
    ext2_fs->common.storage_device->interface.read(
    ext2_fs->common.storage_device, 
    ext2_fs->common.base_disk_offset + (block * ext2_fs->block_size), 
    ext2_fs->block_size,
    buffer);
}

static void ext2_write_block(const Ext2Fs* const ext2_fs, const size_t block, void* const buffer) {
    ext2_fs->common.storage_device->interface.write(
    ext2_fs->common.storage_device, 
    ext2_fs->common.base_disk_offset + (block * ext2_fs->block_size), 
    ext2_fs->block_size,
    buffer);
}

static void ext2_read_inode(const Ext2Fs* const ext2_fs, const size_t inode_index, Ext2Inode* const inode) {
    if (ext2_fs == NULL || inode == NULL) return;
    if (inode_index == 0) return;

    const uint32_t group = inode_index / ext2_fs->inodes_per_group;
    const uint32_t inode_table_block = ext2_fs->bgds[group]->starting_block_of_inode_table;
    const uint32_t index_in_group = inode_index - group * ext2_fs->inodes_per_group;

    // subtract 1 because inode starts form 1 (inode 0 = error) 
    const uint32_t block_offset = (index_in_group - 1) * ext2_fs->inode_struct_size / ext2_fs->block_size;
    const uint32_t offset_in_block = (index_in_group - 1) - block_offset * (ext2_fs->block_size / ext2_fs->inode_struct_size);

    uint8_t* buffer = kmalloc(ext2_fs->block_size);

    if (buffer == NULL) return;

    ext2_read_block(ext2_fs, inode_table_block + block_offset, buffer);
    
    memcpy(buffer + offset_in_block * ext2_fs->inode_struct_size, inode, sizeof(*inode));

    kfree(buffer);
}

static void ext2_read_inode_data(const VfsInodeFile* const inode, char* const buffer) {
    if (inode == NULL || buffer == NULL) return;

    Ext2Inode* ext2_inode = (Ext2Inode*)kmalloc(sizeof(Ext2Inode));

    if (ext2_inode == NULL) return;

    ext2_read_inode(&ext2_fs, inode->inode.index, ext2_inode);

    ext2_read_block(&ext2_fs, ext2_inode->i_block[0], buffer);

    kfree(ext2_inode);
}

// last entry = NULL
static Ext2DirInode** ext2_get_all_dirs(const Ext2Fs* const ext2_fs, Ext2Inode* const inode) {
    if (ext2_fs == NULL || inode == NULL) return NULL;

    if (!(inode->type_and_permission & EXT2_INODE_DIRECTORY)) return NULL;

    uint8_t* buffer = (uint8_t*)kmalloc(ext2_fs->block_size);

    if (buffer == NULL) return NULL;
    
    ext2_read_block(ext2_fs, inode->i_block[0], buffer);
    
    size_t dir_count = 0;
    Ext2DirInode* temp_dir_inode = (Ext2DirInode*)kmalloc(sizeof(Ext2DirInode));

    if (temp_dir_inode == NULL) {
        kfree(buffer);
        return NULL;
    }

    // count total dirs
    for (size_t i = 0; i < inode->size_in_bytes_lower32;) {
        memcpy(buffer + i, temp_dir_inode, sizeof(Ext2DirInode));

        i += temp_dir_inode->total_size;
        ++dir_count;
    }

    Ext2DirInode** dir_inode = (Ext2DirInode**)kmalloc(dir_count * sizeof(Ext2DirInode*));

    if (dir_inode == NULL) {
        kfree(buffer);
        kfree(temp_dir_inode);
        return NULL;
    }

    size_t dir_index = 0;
    for (size_t i = 0; i < inode->size_in_bytes_lower32;) {
        dir_inode[dir_index] = (Ext2DirInode*)kmalloc(sizeof(Ext2DirInode));

        if (dir_inode[dir_index] == NULL) {
            kfree(buffer);
            kfree(temp_dir_inode);
            return NULL;
        }

        memcpy(buffer + i, dir_inode[dir_index], sizeof(Ext2DirInode));

        i += dir_inode[dir_index]->total_size;
        ++dir_index;
    }
    
    // end of the array
    dir_inode[dir_index] = NULL;

    kfree(buffer);
    kfree(temp_dir_inode);

    return dir_inode;
}

static void ext2_free_all_dirs(Ext2DirInode** all_dirs) {
    size_t index = 0;
    while (all_dirs[index] != NULL) kfree(all_dirs[index++]);
    kfree(all_dirs); 
}

static void ext2_fill_dentry(VfsDentry* const dentry) {
    if (dentry == NULL) return;

    Ext2Inode* ext2_inode = (Ext2Inode*)kmalloc(sizeof(Ext2Inode));

    if (ext2_inode == NULL) return;

    ext2_read_inode(&ext2_fs, dentry->inode->index, ext2_inode);

    Ext2DirInode** all_dirs = ext2_get_all_dirs(&ext2_fs, ext2_inode);

    if (all_dirs == NULL) {
        kfree(ext2_inode);
        return;
    }

    // count all directories
    size_t dir_count = 0;
    while (all_dirs[dir_count] != NULL) dir_count++;

    dentry->childs = (VfsDentry**)kmalloc(dir_count * sizeof(VfsDentry*));

    if (dentry->childs == NULL) {
        kfree(ext2_inode);
        ext2_free_all_dirs(all_dirs);
        return;
    }

    size_t index = 0;
    for (; index < dir_count; ++index) {
        dentry->childs[index] = (VfsDentry*)kmalloc(sizeof(VfsDentry));

        if (dentry->childs[index] == NULL) {
            kfree(ext2_inode);
            ext2_free_all_dirs(all_dirs);
            return;
        }

        memcpy(all_dirs[index]->name, dentry->childs[index]->name, all_dirs[index]->name_len);
        dentry->childs[index]->name[all_dirs[index]->name_len] = '\0';
        
        dentry->childs[index]->inode = create_vfs_inode_by_type(all_dirs[index]->file_type);

        if (dentry->childs[index]->inode == NULL) {
            kfree(ext2_inode);
            kfree(dentry->childs[index]);
            ext2_free_all_dirs(all_dirs);

            // end of the child array
            dentry->childs[index + 1] = NULL;

            return;
        }

        dentry->childs[index]->inode->type = all_dirs[index]->file_type;
        dentry->childs[index]->inode->index = all_dirs[index]->inode;
        dentry->childs[index]->parent = dentry;
        dentry->childs[index]->childs = NULL;

        switch (dentry->childs[index]->inode->type) {
        case VFS_TYPE_FILE: {
            ((VfsInodeFile*)dentry->childs[index]->inode)->interface.read = &ext2_read_inode_data;

            break;
        }
        case VFS_TYPE_DIRECTORY: {
            ((VfsInodeDir*)dentry->childs[index]->inode)->interface; // TODO: add some funcs

            break;
        }        
        default:
            break;
        }
    }

    // end of the child array
    dentry->childs[index] = NULL;
    
    ext2_free_all_dirs(all_dirs);
    kfree(ext2_inode);
}

static VfsDentry* ext2_create_dentry(const uint32_t inode_index, const char* const name, 
                                     const VfsDentry* const parent, VfsInodeTypes type) {
    if (name == NULL) return NULL;
    if (inode_index <= 0) return NULL;

    VfsDentry* new_dentry = (VfsDentry*)kmalloc(sizeof(VfsDentry));

    if (new_dentry == NULL) return NULL;

    new_dentry->inode = create_vfs_inode_by_type(type);

    if (new_dentry->inode == NULL) {
        kfree(new_dentry);
        return NULL;
    }

    new_dentry->inode->index = inode_index;
    new_dentry->inode->type = type;
    new_dentry->parent = parent;
    
    size_t dentry_name_len = strlen(name);

    memcpy(name, new_dentry->name, dentry_name_len);
    new_dentry->name[dentry_name_len] = '\0';

    ext2_fill_dentry(new_dentry);

    new_dentry->interface.fill_dentry = &ext2_fill_dentry;
    
    return new_dentry;
}

bool_t is_ext2(const StorageDevice* const storage_device, const uint64_t partition_lba_start) {
    if (storage_device == NULL) return FALSE;

    Ext2Superblock* superblock = (Ext2Superblock*)kmalloc(sizeof(Ext2Superblock));

    if (superblock == NULL) return FALSE;

    ext2_read_superblock(storage_device, partition_lba_start, superblock);

    const uint16_t magic = superblock->magic;
    const uint16_t bgt_struct_size = superblock->bgt_struct_size;

    kfree(superblock);

    return (magic == EXT2_SUPERBLOCK_MAGIC && bgt_struct_size != 64) ? TRUE : FALSE;
}

Status ext2_init(const StorageDevice* const storage_device, const uint64_t partition_lba_start) {
    if (storage_device == NULL) return KERNEL_ERROR;

    Ext2Superblock* superblock = (Ext2Superblock*)kmalloc(sizeof(Ext2Superblock));

    if (superblock == NULL) return KERNEL_ERROR;
    
    ext2_read_superblock(storage_device, partition_lba_start, superblock);
    
    ext2_fs.common.base_disk_offset = (partition_lba_start * storage_device->lba_size);
    ext2_fs.block_size = 1024 << superblock->block_size;
    ext2_fs.inodes_per_group = superblock->inodes_per_group;
    ext2_fs.inode_struct_size = (superblock->version_major >= 1) ? superblock->inode_struct_size : 128;
    ext2_fs.blocks_per_group = superblock->blocks_per_group;
    ext2_fs.total_groups = superblock->blocks_count / ext2_fs.blocks_per_group;
    ext2_fs.common.storage_device = storage_device;
    ext2_fs.bgds_count_in_block = ext2_fs.block_size / 2 * sizeof(BlockGroupDescriptorTable);
    ext2_fs.bgd_blocks_count = (ext2_fs.total_groups / ext2_fs.bgds_count_in_block);

    // round up
    if (ext2_fs.bgds_count_in_block * ext2_fs.bgd_blocks_count != ext2_fs.total_groups) {
        ext2_fs.bgd_blocks_count++;
    }

    ext2_fs.bgds = (BlockGroupDescriptorTable**)kmalloc(ext2_fs.total_groups * sizeof(BlockGroupDescriptorTable*));

    if (ext2_fs.bgds == NULL) {
        kfree(superblock);
        return KERNEL_ERROR;
    }

    uint8_t* buffer = (uint8_t*)kmalloc(ext2_fs.block_size);

    if (buffer == NULL) {
        kfree(superblock);
        kfree(ext2_fs.bgds);
        return KERNEL_ERROR;
    }

    size_t bgt_index = 0;    
    const uint32_t bgt_start_block = (ext2_fs.block_size == 1024) ? 2 : 1;

    for (size_t i = bgt_start_block; i <= ext2_fs.bgd_blocks_count; ++i) {
        ext2_read_block(&ext2_fs, i, buffer);

        for (size_t j = 0; j < ext2_fs.bgds_count_in_block; ++j) {

            if (bgt_index > ext2_fs.total_groups) break;

            ext2_fs.bgds[bgt_index] = (BlockGroupDescriptorTable*)kmalloc(sizeof(BlockGroupDescriptorTable));

            if (ext2_fs.bgds[bgt_index] == NULL) {
                kfree(buffer);
                kfree(superblock);
                return KERNEL_ERROR;
            }

            memcpy(buffer + (j * sizeof(BlockGroupDescriptorTable)), 
                   ext2_fs.bgds[bgt_index], 
                   sizeof(BlockGroupDescriptorTable));

            ++bgt_index;
        }
    }

    VfsDentry* root_dentry = ext2_create_dentry(EXT2_ROOT_INODE_INDEX, "/", NULL, VFS_TYPE_DIRECTORY);

    if (vfs_mount("/", root_dentry) != KERNEL_OK)  return KERNEL_ERROR;

    kfree(buffer);
    kfree(superblock);

    return KERNEL_OK;
}