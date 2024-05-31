#include "ext2.h"

#include "assert.h"
#include "logger.h"
#include "math.h"
#include "mem.h"

#include "dev/clock.h"

#include "utils/string_utils.h"

static Ext2Fs ext2_fs;

static uint8_t* global_buffer = NULL;

static Ext2Inode* global_ext2_inode = NULL;

static ClockDevice* clock_device = NULL;

// Forward declaration
static VfsDentry* ext2_create_dentry(const uint32_t inode_index, const char* const dentry_name, 
                                     const VfsDentry* const parent, VfsInodeTypes type);

static void ext2_read_superblock(const StorageDevice* const storage_device,
                                 const uint64_t partition_lba_start,
                                 const Ext2Superblock* const superblock) {                               
    kassert(storage_device != NULL || superblock != NULL);

    storage_device->interface.read((StorageDevice*)storage_device, 
    (partition_lba_start * storage_device->lba_size) + EXT2_SUPERBLOCK_OFFSET, 
    sizeof(Ext2Superblock), 
    (void*)superblock);
}

static void ext2_read_block(const uint64_t block_index, void* const buffer) {
    kassert(buffer != NULL);

    const uint64_t disk_offset = ext2_fs.common.base_disk_start_offset +
                                 (block_index * ext2_fs.block_size);

    if (disk_offset > ext2_fs.common.base_disk_end_offset) {
        kernel_warn("[EXT2 read block]: disk offset is out of partition\n");
        return;
    }

    ext2_fs.common.storage_device->interface.read(
        (StorageDevice*)ext2_fs.common.storage_device,
        disk_offset,
        ext2_fs.block_size,
        buffer
    );
}

static void ext2_write_block(const uint64_t block_index, void* const buffer) {
    kassert(buffer != NULL);
    
    const uint64_t disk_offset = ext2_fs.common.base_disk_start_offset +
                                 (block_index * ext2_fs.block_size);

    if (disk_offset > ext2_fs.common.base_disk_end_offset) {
        kernel_warn("[EXT2 write block]: disk offset is out of partition\n");
        return;
    }

    ext2_fs.common.storage_device->interface.write(
    (StorageDevice*)ext2_fs.common.storage_device,
    disk_offset,
    ext2_fs.block_size,
    buffer);
}

static void ext2_read_inode(const int32_t inode_index, Ext2Inode* const inode) {
    kassert(inode != NULL);
    kassert(!(inode_index < 0));
    
    // subtract 1 because inode starts form 1 (inode 0 = error) 
    const uint32_t group = (inode_index - 1) / ext2_fs.inodes_per_group;
    const uint32_t inode_table_block = ext2_fs.bgds[group]->starting_block_of_inode_table;
    const uint32_t index_in_group = (inode_index - 1) % ext2_fs.inodes_per_group;
    const uint32_t block_offset = (index_in_group * ext2_fs.inode_struct_size) / ext2_fs.block_size; 
    const uint32_t offset_in_block = index_in_group - block_offset * (ext2_fs.block_size / ext2_fs.inode_struct_size);

    ext2_read_block(inode_table_block + block_offset, global_buffer);
    
    memcpy(global_buffer + offset_in_block * ext2_fs.inode_struct_size, inode, sizeof(*inode));
}

static void ext2_write_inode(const int32_t inode_index, Ext2Inode* const inode) {
    kassert(inode != NULL);
    kassert(!(inode_index < 0));

    // subtract 1 because inode starts form 1 (inode 0 = error) 
    const uint32_t group = (inode_index - 1) / ext2_fs.inodes_per_group;
    const uint32_t inode_table_block = ext2_fs.bgds[group]->starting_block_of_inode_table;
    const uint32_t index_in_group = (inode_index - 1) % ext2_fs.inodes_per_group;
    const uint32_t block_offset = (index_in_group * ext2_fs.inode_struct_size) / ext2_fs.block_size; 
    const uint32_t offset_in_block = index_in_group - block_offset * (ext2_fs.block_size / ext2_fs.inode_struct_size);

    ext2_read_block(inode_table_block + block_offset, global_buffer);
    
    memcpy(inode, global_buffer + offset_in_block * ext2_fs.inode_struct_size, sizeof(*inode));

    ext2_write_block(inode_table_block + block_offset, global_buffer);
}

// returns -1 on fail
static int32_t ext2_get_inode_block_index(const Ext2Inode* const inode, uint32_t inode_block_index) {
    if (inode == NULL) return -1;

    uint32_t indirect_block_max_count = ext2_fs.block_size / 4;

    int32_t direct_block_index;
    int32_t singly_indirect_block_index;
    int32_t doubly_indirect_block_index;
    int32_t triply_indirect_block_index;

    uint32_t* buffer = (uint32_t*)kmalloc(ext2_fs.block_size);

    if (buffer == NULL) return -1;

    uint32_t return_block_index;

    direct_block_index = inode_block_index - EXT2_DIRECT_BLOCKS;
    if (direct_block_index < 0) {
        return_block_index = inode->i_block[inode_block_index];
        
        kfree(buffer);
        return return_block_index;
    }

    singly_indirect_block_index = direct_block_index - indirect_block_max_count;
    if (singly_indirect_block_index < 0) {
        ext2_read_block(inode->i_block[EXT2_DIRECT_BLOCKS], buffer);

        return_block_index = buffer[direct_block_index];

        kfree(buffer);
        return return_block_index;
    }

    doubly_indirect_block_index = singly_indirect_block_index - pow(indirect_block_max_count, 2);
    if (doubly_indirect_block_index < 0) {
        doubly_indirect_block_index = singly_indirect_block_index / indirect_block_max_count;
        triply_indirect_block_index = singly_indirect_block_index - doubly_indirect_block_index * indirect_block_max_count;

        ext2_read_block(inode->i_block[EXT2_DIRECT_BLOCKS + 1], buffer);
        ext2_read_block(buffer[doubly_indirect_block_index], buffer);

        return_block_index = buffer[triply_indirect_block_index];

        kfree(buffer);
        return return_block_index;
    }

    triply_indirect_block_index = doubly_indirect_block_index - pow(indirect_block_max_count, 3);
    if (triply_indirect_block_index < 0) {
        // idk how to call this helper(1,2,3), so let it be helper
        // For more info https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout (Direct/Indirect Block Addressing)
        // NOTE: indexing in i_block is the same for both ext2 and ext4, thats why link above describes ext4
        const uint32_t helper1 = doubly_indirect_block_index / (indirect_block_max_count * indirect_block_max_count);
        const uint32_t helper2 = (doubly_indirect_block_index - 
                                  helper1 * indirect_block_max_count * indirect_block_max_count) / 
                                  indirect_block_max_count;
        const uint32_t helper3 = (doubly_indirect_block_index - 
                                  helper1 * indirect_block_max_count * indirect_block_max_count - 
                                  helper2 * indirect_block_max_count);

        ext2_read_block(inode->i_block[EXT2_DIRECT_BLOCKS + 2], buffer);
        ext2_read_block(buffer[helper1], buffer);
        ext2_read_block(buffer[helper2], buffer);

        return_block_index = buffer[helper3];

        kfree(buffer);
        return return_block_index;
    }

    kernel_warn("[EXT2 get inode block]: Cant find given block\n");

    kfree(buffer);
    return -1;
}

static void ext2_rewrite_bgts() {
    size_t bgt_index = 0;    
    for (size_t i = ext2_fs.bgt_start_block; i <= ext2_fs.bgd_blocks_count; ++i) {
        for (size_t j = 0; j < ext2_fs.bgds_count_in_block && bgt_index < ext2_fs.total_groups; ++j) {
            ((BlockGroupDescriptorTable*)global_buffer)[j] = *ext2_fs.bgds[bgt_index];

            ++bgt_index;
        }

        ext2_write_block(i, global_buffer);
    }   
}

// returns -1 on fail
static int32_t ext2_find_unallocated_inode_index(const Ext2InodeType new_inode_type) {
    if (new_inode_type == 0) return -1;

    for (size_t i = 0; i < ext2_fs.total_groups; ++i) {
        if (ext2_fs.bgds[i]->unallocated_inode_count == 0) continue;

        const uint32_t bitmap_block = ext2_fs.bgds[i]->inode_bitmap_block_index;

        ext2_read_block(bitmap_block, global_buffer);

        for (size_t j = 0; j < ext2_fs.block_size; ++j) {
            if (global_buffer[j] == 0xFF) continue;   // if all inode are used
            if (i == 0 && j == 0) continue; // we need to skip first raw of the first block, because first 10 inode are reserved
                                            // size_t k = (i == 0 && j == 1) ? 2 : 0 this will skip remaining 2 inodes to inode 11

            // if not, go through all bits to find first unallocated
            for (size_t k = ((i == 0 && j == 1) ? 2 : 0); k < BYTE_SIZE; ++k) {
                const uint8_t current_bit = (global_buffer[j] >> k) & 0b1;

                if (current_bit == 0) {
                    global_buffer[j] |= (0b1 << k);

                    ext2_write_block(bitmap_block, global_buffer);

                    ext2_fs.bgds[i]->unallocated_inode_count--;

                    if (new_inode_type == EXT2_INODE_DIRECTORY) ext2_fs.bgds[i]->directories_count++;

                    ext2_rewrite_bgts();

                    return (i * ext2_fs.inodes_per_group + j * BYTE_SIZE + k) + 1;
                }
            }
        }
    }

    kernel_error("[EXT2 find unallocated inode index]: Ext2 is out of inodes!\n");

    return -1;
}

// returns -1 on fail
static int32_t ext2_find_unallocated_block_index() {
    for (size_t i = 0; i < ext2_fs.total_groups; ++i) {
        if (!ext2_fs.bgds[i]->unallocated_blocks_count) continue;

        const uint32_t bitmap_block = ext2_fs.bgds[i]->block_bitmap_block_index;

        ext2_read_block(bitmap_block, global_buffer);

        for (size_t j = 0; j < ext2_fs.block_size; ++j) {
            if (global_buffer[j] == 0xFF) continue;   // if all blocks are used

            // if not, go through all bits to find first unallocated
            for (size_t k = 0; k < BYTE_SIZE; ++k) {
                uint8_t current_bit = (global_buffer[j] >> k) & 0b1;

                if (current_bit == 0) {
                    global_buffer[j] |= (0b1 << k);

                    ext2_write_block(bitmap_block, global_buffer);

                    ext2_fs.bgds[i]->unallocated_blocks_count--;

                    ext2_rewrite_bgts();

                    return i * ext2_fs.blocks_per_group + j * BYTE_SIZE + k;
                }
            }
        }
    }

    kernel_error("[EXT2 find unallocated block index]: Ext2 is out of blocks!\n");
    
    return -1;
}

static void ext2_free_inode(const int32_t parent_inode_index, const int32_t child_inode_index, const Ext2InodeType child_inode_type) {
    kassert(!(child_inode_index <= 0 || parent_inode_index <= 0 || child_inode_type <= 0x1000));

    const uint32_t bitmap_block_index = (child_inode_index - 1) / ext2_fs.inodes_per_group;
    const uint32_t bitmap_rows_to_skip = ((child_inode_index - 1) - bitmap_block_index * ext2_fs.inodes_per_group ) / BYTE_SIZE;
    const uint32_t bitmap_shift_count = (child_inode_index - 1) - bitmap_rows_to_skip * BYTE_SIZE;
    const uint32_t bitmap_block = ext2_fs.bgds[bitmap_block_index]->inode_bitmap_block_index;

    ext2_read_block(bitmap_block, global_buffer);

    global_buffer[bitmap_rows_to_skip] &= ~(1 << bitmap_shift_count);

    ext2_write_block(bitmap_block, global_buffer);

    ext2_fs.bgds[bitmap_block_index]->unallocated_inode_count++;

    if (child_inode_type == EXT2_INODE_DIRECTORY) ext2_fs.bgds[bitmap_block_index]->directories_count--;

    ext2_rewrite_bgts();

    ext2_read_inode(child_inode_index, global_ext2_inode);

    memset(global_ext2_inode, sizeof(*global_ext2_inode), 0);
    global_ext2_inode->deletion_time = get_current_posix_time(clock_device);

    ext2_write_inode(child_inode_index, global_ext2_inode);

    if (child_inode_type == EXT2_INODE_DIRECTORY) {
        ext2_read_inode(parent_inode_index, global_ext2_inode);
        global_ext2_inode->hard_links_count--;
        ext2_write_inode(parent_inode_index, global_ext2_inode);
    }
}

static void ext2_free_block(const int32_t block_index) {
    kassert(!(block_index < 0));

    const uint32_t bitmap_block_index = block_index / ext2_fs.inodes_per_group;
    const uint32_t bitmap_rows_to_skip = (block_index - bitmap_block_index * ext2_fs.inodes_per_group ) / BYTE_SIZE;
    const uint32_t bitmap_shift_count = block_index - bitmap_rows_to_skip * BYTE_SIZE;
    const uint32_t bitmap_block = ext2_fs.bgds[bitmap_block_index]->block_bitmap_block_index;

    ext2_read_block(bitmap_block, global_buffer);

    global_buffer[bitmap_rows_to_skip] &= ~(1 << bitmap_shift_count);

    ext2_write_block(bitmap_block, global_buffer);

    ext2_fs.bgds[bitmap_block_index]->unallocated_blocks_count++;

    ext2_rewrite_bgts();
}

static bool_t ext2_allocate_indirect_block(Ext2Inode* const inode,
                                           const int32_t inode_index,
                                           uint32_t* const indirect_block) {
    if (inode == NULL || indirect_block == NULL) return FALSE;
    if (inode_index <= 0) return FALSE;

    const int32_t block_index = ext2_find_unallocated_block_index();

    if (block_index == -1) return FALSE;
    
    *indirect_block = block_index;

    ext2_write_inode(inode_index, inode);

    return TRUE;
}

static bool_t ext2_set_inode_block_index(Ext2Inode* const inode, const int32_t inode_index, 
                                 const int32_t inode_block_index, const int32_t block_to_set_index) {
    if (inode == NULL) return FALSE;
    if (inode_index <= 0 || inode_block_index < 0 || block_to_set_index < 0) {
        return FALSE;
    } 

    uint32_t indirect_blocks_max_count = ext2_fs.block_size / 4;

    int32_t direct_block_index;
    int32_t singly_indirect_block_index;
    int32_t doubly_indirect_block_index;
    int32_t triply_indirect_block_index;

    uint32_t* buffer = (uint32_t*)kmalloc(ext2_fs.block_size);

    if (buffer == NULL) return FALSE;

    direct_block_index = inode_block_index - EXT2_DIRECT_BLOCKS;
    if (direct_block_index < 0) {
        inode->i_block[inode_block_index] = block_to_set_index;

        kfree(buffer);
        return TRUE;
    }

    singly_indirect_block_index = direct_block_index - indirect_blocks_max_count;
    if (singly_indirect_block_index < 0) {
        if (inode->i_block[EXT2_DIRECT_BLOCKS] == 0) {
            if (!ext2_allocate_indirect_block(inode, inode_index, &inode->i_block[EXT2_DIRECT_BLOCKS])) {
                kfree(buffer);
                return FALSE;
            }
        }

        ext2_read_block(inode->i_block[EXT2_DIRECT_BLOCKS], buffer);

        buffer[direct_block_index] = block_to_set_index;

        ext2_write_block(inode->i_block[EXT2_DIRECT_BLOCKS], buffer);

        kfree(buffer);
        return TRUE;
    }
    
    doubly_indirect_block_index = singly_indirect_block_index - pow(indirect_blocks_max_count, 2);
    if (doubly_indirect_block_index < 0) {
        doubly_indirect_block_index = singly_indirect_block_index / indirect_blocks_max_count;
        triply_indirect_block_index = singly_indirect_block_index - doubly_indirect_block_index * indirect_blocks_max_count;

        if (inode->i_block[EXT2_DIRECT_BLOCKS + 1] == 0) {
            if (!ext2_allocate_indirect_block(inode, inode_index, &inode->i_block[EXT2_DIRECT_BLOCKS + 1])) {
                kfree(buffer);
                return FALSE;
            }
        }

        ext2_read_block(inode->i_block[EXT2_DIRECT_BLOCKS + 1], buffer);

        if (buffer[doubly_indirect_block_index] == 0) {
            if (!ext2_allocate_indirect_block(inode, inode_index, &buffer[doubly_indirect_block_index])) {
                kfree(buffer);
                return FALSE;
            }
        }

        uint32_t temp = buffer[doubly_indirect_block_index];

        ext2_read_block(temp, buffer);

        buffer[triply_indirect_block_index] = block_to_set_index;
        ext2_write_block(temp, buffer);
        
        kfree(buffer);
        return TRUE;
    }

    triply_indirect_block_index = doubly_indirect_block_index - pow(indirect_blocks_max_count, 3);
    if (triply_indirect_block_index <= 0) {
        // idk how to call this helper(1,2,3), so let it be helper
        // For more info https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout (Direct/Indirect Block Addressing)
        // NOTE: indexing in i_block is the same for both ext2 and ext4, thats why link above describes ext4
        const uint32_t helper1 = doubly_indirect_block_index / (indirect_blocks_max_count * indirect_blocks_max_count);
        const uint32_t helper2 = (doubly_indirect_block_index - 
                                  helper1 * indirect_blocks_max_count * indirect_blocks_max_count) / 
                                  indirect_blocks_max_count;
        const uint32_t helper3 = (doubly_indirect_block_index - 
                                  helper1 * indirect_blocks_max_count * indirect_blocks_max_count - 
                                  helper2 * indirect_blocks_max_count);
        
        if (inode->i_block[EXT2_DIRECT_BLOCKS + 2] == 0) {
            if (!ext2_allocate_indirect_block(inode, inode_index, &inode->i_block[EXT2_DIRECT_BLOCKS + 2])) {
                kfree(buffer);
                return FALSE;
            }
        }

        ext2_read_block(inode->i_block[EXT2_DIRECT_BLOCKS + 2], buffer);

        if (buffer[helper1] == 0) {
            if (!ext2_allocate_indirect_block(inode, inode_index, &buffer[helper1])) {
                kfree(buffer);
                return FALSE;
            }
        }

        uint32_t temp = buffer[helper1];

        ext2_read_block(buffer[helper1], buffer);

        if (buffer[helper2] == 0) {
            if (!ext2_allocate_indirect_block(inode, inode_index, &buffer[helper2])) {
                kfree(buffer);
                return FALSE;
            }
        }

        temp = buffer[helper2];

        ext2_read_block(buffer[helper2], buffer);

        buffer[helper3] = block_to_set_index;

        ext2_write_block(temp, buffer);

        kfree(buffer);
        return TRUE;
    }

    kernel_warn("[EXT2 set inode block index]: cant set given block\n");

    kfree(buffer);
    return FALSE;
}

static bool_t ext2_allocate_inode_block(Ext2Inode* const inode, 
                                        const int32_t inode_index,
                                        const int32_t inode_block_index) {
    if (inode == NULL) return FALSE;
    if (inode_index <= 0) return FALSE;
    if (inode_block_index < 0) return FALSE;
    
    int32_t block_index = ext2_find_unallocated_block_index();

    if (block_index == -1) return FALSE;

    if (!ext2_set_inode_block_index(inode, inode_index, inode_block_index, block_index)) {
        return FALSE;
    }

    inode->disk_sects_count = (inode_block_index + 1) * (ext2_fs.block_size / 512);

    ext2_write_inode(inode_index, inode);

    return TRUE;
}

static void ext2_read_inode_block(const Ext2Inode* const inode, 
                                  const int32_t inode_block_index, 
                                  void* const buffer) {    
    kassert(inode != NULL || buffer != NULL);
    kassert(!(inode_block_index < 0));

    const int32_t inode_block = ext2_get_inode_block_index(inode, inode_block_index);

    if (inode_block == -1) return;

    ext2_read_block(inode_block, buffer);
}

static void ext2_write_inode_block(const Ext2Inode* const inode, 
                                   const int32_t inode_block_index, 
                                   void* const buffer) {
    kassert(inode != NULL || buffer != NULL);
    kassert(!(inode_block_index < 0));

    const int32_t inode_block = ext2_get_inode_block_index(inode, inode_block_index);

    if (inode_block == -1) return;
    
    ext2_write_block(inode_block, buffer);

    return;
}

static void ext2_read_inode_data(const VfsInodeFile* const vfs_inode, uint32_t offset,
                                 const uint32_t total_bytes, char* const buffer) {
    kassert(vfs_inode != NULL || buffer != NULL);
    kassert(!(total_bytes > ext2_fs.block_size));
    kassert(vfs_inode->inode.type != VFS_TYPE_DIRECTORY);
    kassert(total_bytes != 0);

    ext2_read_inode(vfs_inode->inode.index, global_ext2_inode);

    if (offset > global_ext2_inode->size_in_bytes_lower32) offset = global_ext2_inode->size_in_bytes_lower32;

    const uint32_t start_offset = offset % ext2_fs.block_size;
    const uint32_t end_offset = (global_ext2_inode->size_in_bytes_lower32 >= offset + total_bytes) ?
                                (offset + total_bytes) : global_ext2_inode->size_in_bytes_lower32; 
    const uint32_t start_block = offset / ext2_fs.block_size;
    const uint32_t end_block = end_offset / ext2_fs.block_size;
    
    global_ext2_inode->last_access_time = get_current_posix_time(clock_device);
    ext2_write_inode(vfs_inode->inode.index, global_ext2_inode);

    uint32_t current_offset = 0;

    for (size_t i = start_block; i <= end_block; ++i) {
        ext2_read_inode_block(global_ext2_inode, i, global_buffer);

        uint32_t in_block_offset = 0;
        uint32_t in_block_size = ext2_fs.block_size;

        if (i == start_block) {
            in_block_offset = start_offset;

            if (i == end_block) in_block_size = end_offset - start_offset;
        }
        else if (i == end_block) {
            in_block_size = end_offset % ext2_fs.block_size;

            if (in_block_size == 0) break;
        }
                    
        memcpy(global_buffer + in_block_offset, buffer + current_offset, in_block_size);

        current_offset += in_block_size;
    }
}

static void ext2_write_inode_data(const VfsInodeFile* const vfs_inode, uint32_t offset,
                                  const uint32_t total_bytes, char* const buffer) {
    kassert(vfs_inode != NULL || buffer != NULL);
    kassert(!(total_bytes > ext2_fs.block_size));
    kassert(vfs_inode->inode.type != VFS_TYPE_DIRECTORY);    
    kassert(total_bytes != 0);

    const uint32_t buffer_len = strlen(buffer);

    kassert(!(buffer_len > ext2_fs.block_size));

    ext2_read_inode(vfs_inode->inode.index, global_ext2_inode);

    // if offset if out of file
    if (offset > global_ext2_inode->size_in_bytes_lower32 && global_ext2_inode->size_in_bytes_lower32 != 1) {
        offset = global_ext2_inode->size_in_bytes_lower32;
    } else if (offset > global_ext2_inode->size_in_bytes_lower32 && global_ext2_inode->size_in_bytes_lower32 == 1) {
        offset = 0;
    }

    if (total_bytes + offset > global_ext2_inode->size_in_bytes_lower32) {
        const uint32_t current_i_block_count = (global_ext2_inode->size_in_bytes_lower32 / ext2_fs.block_size) + 1;

        global_ext2_inode->size_in_bytes_lower32 = total_bytes + offset;

        const uint32_t new_i_block_count = (global_ext2_inode->size_in_bytes_lower32 / ext2_fs.block_size) + 1;

        if (current_i_block_count != new_i_block_count) {
            if(!ext2_allocate_inode_block(global_ext2_inode, vfs_inode->inode.index, current_i_block_count)) {
                return;
            }
        }
    }

    global_ext2_inode->last_access_time = get_current_posix_time(clock_device);
    global_ext2_inode->last_mod_time = get_current_posix_time(clock_device);

    ext2_write_inode(vfs_inode->inode.index, global_ext2_inode);

    const uint32_t start_offset = offset % ext2_fs.block_size;
    const uint32_t end_offset = (global_ext2_inode->size_in_bytes_lower32 >= offset + total_bytes) ?
                                (offset + total_bytes) : global_ext2_inode->size_in_bytes_lower32;
    const uint32_t start_block = offset / ext2_fs.block_size;
    const uint32_t end_block = end_offset / ext2_fs.block_size;
    
    uint32_t current_offset = 0;
    for (size_t i = start_block; i <= end_block; ++i) {
        uint32_t left_border = 0, right_border = ext2_fs.block_size - 1;

        ext2_read_inode_block(global_ext2_inode, i, global_buffer);

        if (i == start_block) {
            left_border = start_offset;
        }   

        if (i == end_block) {
            right_border = total_bytes + left_border;

            // if buffer for text file then last symbol is '\n' (LF)
            if (!is_buffer_binary(buffer)) {
                buffer[buffer_len] = '\n';
            }
        }
                    
        memcpy(buffer + current_offset, global_buffer + left_border, right_border - left_border);

        ext2_write_inode_block(global_ext2_inode, i, global_buffer);

        current_offset += right_border - left_border;
    }
}

static void ext2_free_all_dir_entries(Ext2DirInode** all_dir_entries) {
    if (all_dir_entries == NULL) return;

    size_t index = 0;
    while (all_dir_entries[index] != NULL) kfree(all_dir_entries[index++]);
    kfree(all_dir_entries); 
}

// on error returns -1
static Ext2DirInode** ext2_getdents(Ext2Inode* const inode) {
    if (inode == NULL) return (Ext2DirInode**)-1;
    if (!(inode->type_and_permission & EXT2_INODE_DIRECTORY)) return (Ext2DirInode**)-1;

    ext2_read_block(inode->i_block[0], global_buffer);

    Ext2DirInode* temp_dir_inode = (Ext2DirInode*)kmalloc(sizeof(Ext2DirInode));

    if (temp_dir_inode == NULL) return (Ext2DirInode**)-1;

    // count total dir entries
    size_t dir_count = 0;
    for (size_t i = 0; i < inode->size_in_bytes_lower32;) {
        memcpy(global_buffer + i, temp_dir_inode, sizeof(Ext2DirInode));

        if (temp_dir_inode->total_size == 0) break;

        i += temp_dir_inode->total_size;
        ++dir_count;
    }

    // dir is empty
    if (dir_count == 0) {
        kfree(temp_dir_inode);
        return NULL;
    }

    Ext2DirInode** all_dir_entries = (Ext2DirInode**)kmalloc((dir_count + 1) * sizeof(Ext2DirInode*));

    if (all_dir_entries == NULL) {
        kfree(temp_dir_inode);
        return (Ext2DirInode**)-1;
    }

    size_t dir_index = 0;
    for (size_t i = 0; i < inode->size_in_bytes_lower32;) {
        all_dir_entries[dir_index] = (Ext2DirInode*)kmalloc(sizeof(Ext2DirInode));

        if (all_dir_entries[dir_index] == NULL) {
            kfree(temp_dir_inode);
            ext2_free_all_dir_entries(all_dir_entries);
            return (Ext2DirInode**)-1;
        }

        memcpy(global_buffer + i, all_dir_entries[dir_index], sizeof(Ext2DirInode));

        i += all_dir_entries[dir_index]->total_size;
        ++dir_index;
    }
    
    // end of the array
    all_dir_entries[dir_index] = NULL;

    kfree(temp_dir_inode);

    return all_dir_entries;
}

static void ext2_fill_vfs_inode_interface_by_type(VfsDentry* const dentry) {
    if (dentry == NULL) return;

    switch (dentry->inode->type) {
    case VFS_TYPE_CHARACTER_DEVICE:
    case VFS_TYPE_BLOCK_DEVICE:
    case VFS_TYPE_SOCKET:
    case VFS_TYPE_FIFO:
    case VFS_TYPE_FILE: {
        ((VfsInodeFile*)dentry->inode)->interface.read = &ext2_read_inode_data;
        ((VfsInodeFile*)dentry->inode)->interface.write = &ext2_write_inode_data;

        break;
    }
    case VFS_TYPE_DIRECTORY: {
        break;
    }
    case VFS_TYPE_SYMBOLIC_LINK: {
        break;
    } 
    default:
        break;
    }
}

static void ext2_fill_vfs_inode(VfsInode* const inode, const VfsInodeTypes type, const int32_t inode_index) {
    kassert(inode != NULL);
    kassert(!(inode_index < 0));

    if (inode_index == 0) {
        inode->type = 0;
        inode->index = 0;
        inode->access_time = 0;
        inode->change_time = 0;
        inode->hard_link_count = 0;
        inode->mode = 0;
        inode->file_size = 0;
        
        return;
    }

    ext2_read_inode(inode_index, global_ext2_inode);

    inode->type = type;
    inode->index = inode_index;
    inode->access_time = global_ext2_inode->last_access_time;
    inode->change_time = global_ext2_inode->last_mod_time;
    inode->hard_link_count = global_ext2_inode->hard_links_count;
    inode->mode = global_ext2_inode->type_and_permission & 0x00000FFF;

    if (type != (VfsInodeTypes)EXT2_DIR_TYPE_DIRECTORY) {
        inode->file_size = (
            global_ext2_inode->size_in_bytes_lower32 +
            ((uint64_t)global_ext2_inode->size_in_bytes_higher32 << 32)
        );           
    }
    else {
        inode->file_size = 0;
    }
}

static DirInodeTypes ext2_inode_type_to_dir_inode_type(const Ext2InodeType type) {
    switch (type) {
        case EXT2_INODE_DIRECTORY:          return EXT2_DIR_TYPE_DIRECTORY;
        case EXT2_INODE_REGULAR_FILE:       return EXT2_DIR_TYPE_FILE;
        case EXT2_INODE_SYMBOLIC_LINK:      return EXT2_DIR_TYPE_SYMBOLIC_LINK;
        case EXT2_INODE_CHARACTER_DEVICE:   return EXT2_DIR_TYPE_CHARACTER_DEVICE;
        case EXT2_INODE_BLOCK_DEVICE:       return EXT2_DIR_TYPE_BLOCK_DEVICE;
        case EXT2_INODE_UNIX_SOCKET:        return EXT2_DIR_TYPE_SOCKET;
        case EXT2_INODE_FIFO:               return EXT2_DIR_TYPE_FIFO;
        default:                            return EXT2_DIR_TYPE_UNKNOWN;
    }

    return EXT2_DIR_TYPE_UNKNOWN;
}

static bool_t ext2_create_dir_entry(const VfsDentry* const parent, const char* const entry_name, 
                                    const uint32_t entry_inode_index, DirInodeTypes type) {
    if (parent == NULL || entry_name == NULL) return FALSE;
    if (parent->inode->type != VFS_TYPE_DIRECTORY) return FALSE;
    if (entry_inode_index <= 0) return FALSE;

    ext2_read_inode(parent->inode->index, global_ext2_inode);

    Ext2DirInode** all_dir_entries = ext2_getdents(global_ext2_inode);

    if (all_dir_entries == (Ext2DirInode**)-1) return FALSE;

    size_t index = 0;
    while (all_dir_entries[index] != NULL) {
        if (!strcmp(all_dir_entries[index]->name, entry_name)) {
            kernel_warn("Inode %s already exist\n", entry_name);
            return FALSE;
        }

        ++index;
    }

    Ext2DirInode* new_dir_entry = (Ext2DirInode*)kmalloc(sizeof(Ext2DirInode));

    if (new_dir_entry == NULL) {
        ext2_free_all_dir_entries(all_dir_entries);
        return FALSE;
    }

    // total size must be aligned to 4-byte boundaries, but name is the only field that could be any size, 
    // so we need to check name_len, is it aligned, and if not add aligned value.
    // also total size of the last dir contains total_size + free block space,
    // so now we need to remove free block space and add to the new entry(last entry)
    if (all_dir_entries != NULL) {
        all_dir_entries[index - 1]->total_size = (all_dir_entries[index - 1]->name_len % 4 == 0) ?
        8 + all_dir_entries[index - 1]->name_len : // 8 means the size of all other fields in bytes
        8 + ((all_dir_entries[index - 1]->name_len / 4) + 1) * 4;
    }

    index = 0;
    size_t total_used_size = 0;
    while (all_dir_entries[index] != NULL) {   // now we can correctly get total used size
        total_used_size += all_dir_entries[index]->total_size;

        ++index;
    }                    

    const uint32_t unallocated_space = ext2_fs.block_size - total_used_size;

    uint32_t new_dir_entry_actual_size = 8 + ((all_dir_entries[index - 1]->name_len / 4) + 1) * 4;

    // check is it enough space for new entry
    if (new_dir_entry_actual_size > unallocated_space) {
        ext2_free_all_dir_entries(all_dir_entries);
        kfree(new_dir_entry);
        return FALSE;
    }

    new_dir_entry->file_type = type;
    new_dir_entry->inode = entry_inode_index;
    new_dir_entry->name_len = strlen(entry_name);
    memcpy(entry_name, new_dir_entry->name, strlen(entry_name) + 1);
    new_dir_entry->total_size = unallocated_space;     

    uint8_t* new_inode_block = (uint8_t*)kcalloc(ext2_fs.block_size);

    if (new_inode_block == NULL) {
        ext2_free_all_dir_entries(all_dir_entries);
        kfree(new_dir_entry);
        return FALSE;
    }

    index = 0;
    size_t written_size = 0;
    while (all_dir_entries[index] != NULL) {
        memcpy(all_dir_entries[index], 
               new_inode_block + written_size, 
               all_dir_entries[index]->total_size);

        written_size += all_dir_entries[index]->total_size;
        ++index;
    }

    memcpy(new_dir_entry, new_inode_block + total_used_size, new_dir_entry_actual_size);
    
    ext2_write_block(global_ext2_inode->i_block[0], new_inode_block);

    ext2_free_all_dir_entries(all_dir_entries);
    kfree(new_dir_entry);
    kfree(new_inode_block);

    return TRUE;
}

static void ext2_remove_dir_entry(const uint32_t parent_dir_inode_index, const char* const entry_to_remove_name) {
    kassert(entry_to_remove_name != NULL);
    kassert((strcmp(entry_to_remove_name, ".")) || (strcmp(entry_to_remove_name, "..")));

    ext2_read_inode(parent_dir_inode_index, global_ext2_inode);

    Ext2DirInode** all_dir_entries = ext2_getdents(global_ext2_inode);

    if (all_dir_entries == (Ext2DirInode**)-1) return;

    size_t index = 0;
    size_t entry_to_remove_index = 0;
    uint32_t last_entry_start_offset = 0;
    uint32_t entry_to_remove_start_offset = 0;
    bool_t is_entry_found = FALSE;

    while (all_dir_entries[index] != NULL) {
        if (!strcmp(all_dir_entries[index]->name, entry_to_remove_name)) {
            is_entry_found = TRUE;
            entry_to_remove_index = index;
        }

        if (!is_entry_found) {
            entry_to_remove_start_offset += all_dir_entries[index]->total_size;
        }

        if (all_dir_entries[index + 1] != NULL) {
            last_entry_start_offset += all_dir_entries[index]->total_size;
        }

        ++index;
    }

    if (!is_entry_found) {
        kernel_warn("Cant unlink %s, not found\n");

        ext2_free_all_dir_entries(all_dir_entries);

        return;
    }

    ext2_read_block(global_ext2_inode->i_block[0], global_buffer);    

    const uint32_t entry_to_remove_end_offset = entry_to_remove_start_offset + 
                                                all_dir_entries[entry_to_remove_index]->total_size;

    // entry to remove is not the last entry
    if (entry_to_remove_index + 1 != index) {
        all_dir_entries[index - 1]->total_size += all_dir_entries[entry_to_remove_index]->total_size;

        //first update last entry total size
        memcpy(all_dir_entries[index - 1], global_buffer + last_entry_start_offset, 8);

        //then delete entry
        memcpy(global_buffer + entry_to_remove_end_offset,
               global_buffer + entry_to_remove_start_offset,
               ext2_fs.block_size - entry_to_remove_end_offset);
        memset(global_buffer + ext2_fs.block_size - entry_to_remove_end_offset, entry_to_remove_end_offset, 0);
    } 
    else {
        const uint32_t actual_entry_size = all_dir_entries[entry_to_remove_index - 1]->total_size;

        all_dir_entries[entry_to_remove_index - 1]->total_size +=  all_dir_entries[entry_to_remove_index]->total_size;

        //first update before the last entry total size
        memcpy(all_dir_entries[entry_to_remove_index - 1],
        global_buffer + (last_entry_start_offset - actual_entry_size),
        8);

        //then delete entry
        memset(global_buffer + entry_to_remove_start_offset, ext2_fs.block_size - entry_to_remove_start_offset, 0);
    }

    ext2_write_block(global_ext2_inode->i_block[0], global_buffer);

    ext2_free_all_dir_entries(all_dir_entries);
}

static bool_t ext2_is_valid_inode_name(const char* const inode_name) {
    if (inode_name == NULL) return FALSE;

    for (uint32_t i = 0; inode_name[i] != '\0'; ++i) {
        if (inode_name[i] == '/') return FALSE;
    }
    
    return TRUE;
}

// On success return new inode index, otherwise return -1
static int32_t ext2_create_inode(VfsDentry* const parent, const char* const inode_name,
                                  const uint32_t permission, const Ext2InodeType type) {
    if (parent == NULL || inode_name == NULL) return -1;
    if (parent->inode->type != VFS_TYPE_DIRECTORY) return -1;
    if (permission == 0) return -1;
    if (strlen(inode_name) > EXT2_MAX_INODE_NAME) return -1;
    if (!ext2_is_valid_inode_name(inode_name)) return -1;

    size_t index = 0;
    while (parent->childs[index] != NULL) {
        if (!strcmp(parent->childs[index]->name, inode_name)) {
            kernel_warn("Inode %s already exist\n", inode_name);
            return -1;
        }

        ++index;
    }

    int32_t inode_index = ext2_find_unallocated_inode_index(type);

    if (inode_index == -1) return -1;
    
    ext2_read_inode(inode_index, global_ext2_inode);

    memset(global_ext2_inode, sizeof(*global_ext2_inode), 0);

    global_ext2_inode->creation_time = get_current_posix_time(clock_device);
    global_ext2_inode->last_access_time = get_current_posix_time(clock_device);;
    global_ext2_inode->last_mod_time = get_current_posix_time(clock_device);
    global_ext2_inode->type_and_permission = type;
    global_ext2_inode->type_and_permission |= 0xff & permission;

    if (type == EXT2_INODE_DIRECTORY) {
        global_ext2_inode->size_in_bytes_lower32 = ext2_fs.block_size;
        global_ext2_inode->hard_links_count = 2;
    } 
    else {
        global_ext2_inode->hard_links_count = 1;
        global_ext2_inode->size_in_bytes_lower32 = 0;
    }

    if (!ext2_allocate_inode_block(global_ext2_inode, inode_index, 0)) {
        ext2_free_inode(parent->inode->index, inode_index, type);
        return -1;
    }

    if (!ext2_create_dir_entry(parent, inode_name, inode_index, 
                               ext2_inode_type_to_dir_inode_type(type))) {
        ext2_free_inode(parent->inode->index, inode_index, type);
        ext2_free_block(global_ext2_inode->i_block[0]);
        return -1;
    }

    if (type == EXT2_INODE_DIRECTORY) {
        ext2_read_inode(parent->inode->index, global_ext2_inode);
        global_ext2_inode->hard_links_count++;
        ext2_write_inode(parent->inode->index, global_ext2_inode);
    }

    return inode_index;
}

static void ext2_mkfile(VfsDentry* const parent, 
                        const char* const file_name, 
                        const VfsInodePermission permission) {
    kassert(parent != NULL || file_name != NULL);
    kassert(parent->inode->type == VFS_TYPE_DIRECTORY);
    kassert(permission != 0);

    int32_t new_inode_index = ext2_create_inode(parent, file_name, permission, EXT2_INODE_REGULAR_FILE);

    if (new_inode_index == -1) return;

    VfsDentry* new_dentry = ext2_create_dentry(new_inode_index, file_name, parent, VFS_TYPE_FILE);

    if (new_dentry == NULL) return;
    
    parent->childs = krealloc(parent->childs, parent->childs_count + 2);
    parent->childs[parent->childs_count] = new_dentry;
    parent->childs_count++;
    parent->childs[parent->childs_count] = NULL;                        
}

static void ext2_mkdir(VfsDentry* const parent, 
                       const char* const dir_name, 
                       const VfsInodePermission permission) {
    kassert(parent != NULL || dir_name != NULL);
    kassert(parent->inode->type == VFS_TYPE_DIRECTORY);
    kassert(permission != 0);
    
    int32_t new_inode_index = ext2_create_inode(parent, dir_name, permission, EXT2_INODE_DIRECTORY);   

    if (new_inode_index == -1) return;

    VfsDentry* new_dentry = ext2_create_dentry(new_inode_index, dir_name, parent, VFS_TYPE_DIRECTORY);

    if (new_dentry == NULL) return;

    ext2_create_dir_entry(new_dentry, ".", new_inode_index, EXT2_DIR_TYPE_DIRECTORY);
    ext2_create_dir_entry(new_dentry, "..", parent->inode->index, EXT2_DIR_TYPE_DIRECTORY);

    parent->childs = krealloc(parent->childs, parent->childs_count + 2);
    parent->childs[parent->childs_count] = new_dentry;
    parent->childs_count++;
    parent->childs[parent->childs_count] = NULL; 
}

static void ext2_chmod(const VfsDentry* const dentry, const VfsInodePermission permission) {
    kassert(dentry != NULL);
    kassert(permission != 0);

    ext2_read_inode(dentry->inode->index, global_ext2_inode);

    global_ext2_inode->type_and_permission = (global_ext2_inode->type_and_permission & 0xFFFFF000) | permission;

    ext2_write_inode(dentry->inode->index, global_ext2_inode);
}

static void ext2_unlink(const VfsDentry* const dentry_to_unlink, const char* const name) {
    kassert(dentry_to_unlink != NULL || name != NULL);

    ext2_read_inode(dentry_to_unlink->inode->index, global_ext2_inode);

    VfsDentry* parent = dentry_to_unlink->parent;

    // if inode already deleted
    if (global_ext2_inode->deletion_time != 0) {
        kernel_warn("inode %s already deleted\n", name);
        return;
    }
    
    if (global_ext2_inode->hard_links_count == 1) {
        ext2_free_inode(parent->inode->index, 
                        dentry_to_unlink->inode->index, 
                        global_ext2_inode->type_and_permission & 0x0000F000);
        
            uint32_t blocks_to_free_count = (global_ext2_inode->size_in_bytes_lower32 / ext2_fs.block_size) + 1;

            while (blocks_to_free_count > 0) {
                const int32_t block_to_free = ext2_get_inode_block_index(global_ext2_inode, blocks_to_free_count - 1);

                if (block_to_free == -1) break;

                ext2_free_block(block_to_free);

                --blocks_to_free_count;
            }
        
    }

    ext2_remove_dir_entry(parent->inode->index, name);

    uint32_t i = 0;
    while (parent->childs[i] != dentry_to_unlink) {
        ++i;
    }

    while (parent->childs[i] != NULL) {
        parent->childs[i] = parent->childs[i + 1];
        ++i;
    }

    parent->childs = krealloc(parent->childs, --parent->childs_count);
}

static void ext2_fill_dentry(VfsDentry* const dentry) {
    kassert(dentry != NULL);
    if (dentry->inode->type != VFS_TYPE_DIRECTORY) return;

    ext2_read_inode(dentry->inode->index, global_ext2_inode);

    Ext2DirInode** all_dirs = ext2_getdents(global_ext2_inode);

    if (all_dirs == (Ext2DirInode**)-1) return;

    // count all directories
    size_t dir_count = 0;
    while (all_dirs[dir_count] != NULL) dir_count++;
    
    if (dir_count == 0) return;

    dentry->childs = (VfsDentry**)kmalloc((dir_count + 1) * sizeof(VfsDentry*));

    if (dentry->childs == NULL) {
        ext2_free_all_dir_entries(all_dirs);
        return;
    }

    size_t index = 0;
    for (; index < dir_count; ++index) {
        dentry->childs[index] = vfs_new_dentry();

        if (dentry->childs[index] == NULL) {
            ext2_free_all_dir_entries(all_dirs);
            return;
        }

        memcpy(all_dirs[index]->name, dentry->childs[index]->name, all_dirs[index]->name_len);
        dentry->childs[index]->name[all_dirs[index]->name_len] = '\0';
        
        dentry->childs[index]->inode = vfs_new_inode_by_type(all_dirs[index]->file_type);

        if (dentry->childs[index]->inode == NULL) {
            vfs_delete_dentry(dentry->childs[index]);
            ext2_free_all_dir_entries(all_dirs);

            // end of the child array
            dentry->childs[index] = NULL;

            return;
        }

        ext2_fill_vfs_inode(dentry->childs[index]->inode, all_dirs[index]->file_type, all_dirs[index]->inode);

        dentry->childs[index]->parent = dentry;
        dentry->childs[index]->childs = NULL;
        dentry->childs[index]->childs_count = 0;

        dentry->childs_count++;

        ext2_fill_vfs_inode_interface_by_type(dentry->childs[index]);

        dentry->childs[index]->interface.fill_dentry = &ext2_fill_dentry;
        dentry->childs[index]->interface.mkdir = &ext2_mkdir;
        dentry->childs[index]->interface.mkfile = &ext2_mkfile;
        dentry->childs[index]->interface.chmod = &ext2_chmod;
        dentry->childs[index]->interface.unlink = &ext2_unlink;
    }

    // end of the child array
    dentry->childs[index] = NULL;

    ext2_free_all_dir_entries(all_dirs);
}

static VfsDentry* ext2_create_dentry(const uint32_t inode_index, const char* const dentry_name, 
                                     const VfsDentry* const parent, VfsInodeTypes type) {
    if (dentry_name == NULL) return NULL;
    if (inode_index <= 0) return NULL;

    VfsDentry* new_dentry = (VfsDentry*)vfs_new_dentry();

    if (new_dentry == NULL) return NULL;

    new_dentry->inode = vfs_new_inode_by_type(type);

    if (new_dentry->inode == NULL) {
        vfs_delete_dentry(new_dentry);
        return NULL;
    }

    ext2_fill_vfs_inode(new_dentry->inode, type, inode_index);

    new_dentry->parent = (VfsDentry*)parent;
    new_dentry->childs_count = 0;
    
    size_t dentry_name_len = strlen(dentry_name);

    memcpy(dentry_name, new_dentry->name, dentry_name_len);
    new_dentry->name[dentry_name_len] = '\0';

    ext2_fill_dentry(new_dentry);   

    ext2_fill_vfs_inode_interface_by_type(new_dentry);

    new_dentry->interface.fill_dentry = &ext2_fill_dentry;
    new_dentry->interface.mkdir = &ext2_mkdir;
    new_dentry->interface.mkfile = &ext2_mkfile;
    new_dentry->interface.chmod = &ext2_chmod;
    new_dentry->interface.unlink = &ext2_unlink;
    
    return new_dentry;
}

bool_t is_ext2(const StorageDevice* const storage_device, const uint64_t partition_lba_start) {
    if (storage_device == NULL) return FALSE;

    Ext2Superblock* superblock = (Ext2Superblock*)kmalloc(sizeof(Ext2Superblock));

    if (superblock == NULL) return FALSE;

    ext2_read_superblock(storage_device, partition_lba_start, superblock);

    bool_t result = 
        superblock->magic == EXT2_SUPERBLOCK_MAGIC &&
        (superblock->version_major < 1 || superblock->bgt_struct_size != 64);

    kfree(superblock);

    return result;
}

Status ext2_init(const StorageDevice* const storage_device,
                 const uint64_t partition_lba_start,
                 const uint64_t partition_lba_end) {
    if (storage_device == NULL) return KERNEL_INVALID_ARGS;
    if (partition_lba_start > partition_lba_end) return KERNEL_INVALID_ARGS;

    Ext2Superblock* superblock = (Ext2Superblock*)kmalloc(sizeof(Ext2Superblock));

    if (superblock == NULL) return KERNEL_ERROR;

    ext2_read_superblock(storage_device, partition_lba_start, superblock);

    ext2_fs.common.base_disk_start_offset = (partition_lba_start * storage_device->lba_size);
    ext2_fs.common.base_disk_end_offset = (partition_lba_end * storage_device->lba_size);
    ext2_fs.block_size = 1024 << superblock->block_size;
    ext2_fs.inodes_per_group = superblock->inodes_per_group;
    ext2_fs.inode_struct_size = (superblock->version_major >= 1) ? superblock->inode_struct_size : 128;
    ext2_fs.blocks_per_group = superblock->blocks_per_group;
    ext2_fs.total_groups = superblock->blocks_count / ext2_fs.blocks_per_group;

    if (ext2_fs.total_groups == 0 && superblock->blocks_count > 0) {
        ext2_fs.total_groups = 1;
    }

    ext2_fs.common.storage_device = (StorageDevice*)storage_device;
    ext2_fs.bgds_count_in_block = ext2_fs.block_size / 2 * sizeof(BlockGroupDescriptorTable);
    ext2_fs.bgd_blocks_count = (ext2_fs.total_groups / ext2_fs.bgds_count_in_block);
    ext2_fs.bgt_start_block = (ext2_fs.block_size == 1024) ? 2 : 1;

    global_buffer = (uint8_t*)kcalloc(ext2_fs.block_size);

    if (global_buffer == NULL) {
        kfree(superblock);
        return KERNEL_ERROR;
    }

    global_ext2_inode = (Ext2Inode*)kmalloc(sizeof(Ext2Inode));

    if (global_ext2_inode == NULL) {
        kfree(superblock);
        kfree(global_buffer);
        return KERNEL_ERROR;
    }

    // round up
    if (ext2_fs.bgds_count_in_block * ext2_fs.bgd_blocks_count != ext2_fs.total_groups) {
        ext2_fs.bgd_blocks_count++;
    }

    ext2_fs.bgds = (BlockGroupDescriptorTable**)kmalloc(ext2_fs.total_groups * sizeof(BlockGroupDescriptorTable*));

    if (ext2_fs.bgds == NULL) {
        kfree(superblock);
        kfree(global_buffer);
        kfree(superblock);
        return KERNEL_ERROR;
    }

    size_t bgt_index = 0;    
    for (size_t i = ext2_fs.bgt_start_block; i <= ext2_fs.bgd_blocks_count; ++i) {
        ext2_read_block(i, global_buffer);

        for (size_t j = 0; j < ext2_fs.bgds_count_in_block && bgt_index < ext2_fs.total_groups; ++j) {
            ext2_fs.bgds[bgt_index] = (BlockGroupDescriptorTable*)kmalloc(sizeof(BlockGroupDescriptorTable));

            if (ext2_fs.bgds[bgt_index] == NULL) {
                kfree(superblock);
                kfree(global_buffer);
                kfree(superblock);
                return KERNEL_ERROR;
            }

            *ext2_fs.bgds[bgt_index] = ((BlockGroupDescriptorTable*)global_buffer)[j];

            ++bgt_index;
        }
    }

    clock_device = (ClockDevice*)dev_find(NULL, &is_clock_device);

    if (clock_device == NULL) {    
        kfree(superblock);
        kfree(global_buffer);
        kfree(superblock); 
        return KERNEL_ERROR;
    }

    VfsDentry* root_dentry = ext2_create_dentry(EXT2_ROOT_INODE_INDEX, "/", NULL, VFS_TYPE_DIRECTORY);

    if (vfs_mount("/", root_dentry) != KERNEL_OK) {    
        kfree(superblock);
        kfree(global_buffer);
        kfree(superblock); 
        return KERNEL_ERROR;
    }
    
    kfree(superblock); 

    return KERNEL_OK;
}