#include "ext2.h"

#include "logger.h"
#include "math.h"
#include "mem.h"

static Ext2Fs ext2_fs;

static uint8_t* global_buffer = NULL;

static Ext2Inode* global_ext2_inode = NULL;

static void ext2_read_superblock(const StorageDevice* const storage_device,
                                 const uint64_t partition_lba_start,
                                 const Ext2Superblock* const superblock) {                               
    if (storage_device == NULL || superblock == NULL) return;
    if (partition_lba_start < 0) return;

    storage_device->interface.read(storage_device, 
    (partition_lba_start * storage_device->lba_size) + EXT2_SUPERBLOCK_OFFSET, 
    sizeof(Ext2Superblock), 
    superblock);
}

static void ext2_read_block(const size_t block_index, void* const buffer) {
    if (buffer == NULL) return;
    if (block_index < 0) return;

    const uint64_t disk_offset = ext2_fs.common.base_disk_start_offset +
                                 (block_index * ext2_fs.block_size);

    if (disk_offset > ext2_fs.common.base_disk_end_offset) {
        kernel_warn("[EXT2 read block]: disk offset is out of partition\n");
        return;
    }

    ext2_fs.common.storage_device->interface.read(
    ext2_fs.common.storage_device,
    disk_offset,
    ext2_fs.block_size,
    buffer);
}

static void ext2_write_block(const size_t block_index, void* const buffer) {
    if (buffer == NULL) return;
    if (block_index < 0) return;
    
    const uint64_t disk_offset = ext2_fs.common.base_disk_start_offset +
                                 (block_index * ext2_fs.block_size);

    if (disk_offset > ext2_fs.common.base_disk_end_offset) {
        kernel_warn("[EXT2 write block]: disk offset is out of partition\n");
        return;
    }

    ext2_fs.common.storage_device->interface.write(
    ext2_fs.common.storage_device,
    disk_offset,
    ext2_fs.block_size,
    buffer);
}

static void ext2_read_inode(const size_t inode_index, Ext2Inode* const inode) {
    if (inode == NULL) return;
    if (inode_index <= 0) return;
    
    // subtract 1 because inode starts form 1 (inode 0 = error) 
    const uint32_t group = (inode_index - 1) / ext2_fs.inodes_per_group;
    const uint32_t inode_table_block = ext2_fs.bgds[group]->starting_block_of_inode_table;
    const uint32_t index_in_group = (inode_index - 1) % ext2_fs.inodes_per_group;
    const uint32_t block_offset = (index_in_group * ext2_fs.inode_struct_size) / ext2_fs.block_size; 
    const uint32_t offset_in_block = index_in_group - block_offset * (ext2_fs.block_size / ext2_fs.inode_struct_size);

    ext2_read_block(inode_table_block + block_offset, global_buffer);
    
    memcpy(global_buffer + offset_in_block * ext2_fs.inode_struct_size, inode, sizeof(*inode));
}

static void ext2_write_inode(const size_t inode_index, Ext2Inode* const inode) {
    if (inode == NULL) return;
    if (inode_index <= 0) return;

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
    if (inode_block_index < 0) return -1;

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
        // idk how to call this helper(1,2,3), so let it be helper)
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

    kernel_warn("Cant find given block\n");

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
static int32_t ext2_find_unallocated_inode_index() {
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

                    ext2_rewrite_bgts();

                    return (i * ext2_fs.inodes_per_group + j * BYTE_SIZE + k) + 1;
                }
            }
        }
    }

    kernel_error("Ext2 is out of inodes!\n");

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

    kernel_error("Ext2 is out of blocks!\n");
    
    return -1;
}

static void ext2_free_inode(const parent_inode_index, const uint32_t child_inode_index) {
    if (child_inode_index <= 0 || parent_inode_index <= 0) return;

    const uint32_t bitmap_block_index = (child_inode_index - 1) / ext2_fs.inodes_per_group;
    const uint32_t bitmap_rows_to_skip = ((child_inode_index - 1) - bitmap_block_index * ext2_fs.inodes_per_group ) / BYTE_SIZE;
    const uint32_t bitmap_shift_count = (child_inode_index - 1) - bitmap_rows_to_skip * BYTE_SIZE;
    const uint32_t bitmap_block = ext2_fs.bgds[bitmap_block_index]->inode_bitmap_block_index;

    ext2_read_block(bitmap_block, global_buffer);

    global_buffer[bitmap_rows_to_skip] &= ~(1 << bitmap_shift_count);

    ext2_write_block(bitmap_block, global_buffer);

    ext2_fs.bgds[bitmap_block_index]->unallocated_inode_count++;

    ext2_rewrite_bgts();

    ext2_read_inode(child_inode_index, global_ext2_inode);

    //TODO deletion time
    memset(global_ext2_inode, sizeof(*global_ext2_inode), 0);
    global_ext2_inode->deletion_time = 1715343535;

    ext2_write_inode(child_inode_index, global_ext2_inode);

    // Now decrement hard links count on parent inode
    ext2_read_inode(parent_inode_index, global_ext2_inode);
    global_ext2_inode->hard_links_count--;
    ext2_write_inode(parent_inode_index, global_ext2_inode);
}

static void ext2_free_block(const uint32_t block_index) {
    if (block_index < 0) return;

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
                                           const uint32_t inode_index,
                                           uint32_t* const indirect_block) {
    if (inode == NULL || indirect_block == NULL) return FALSE;
    if (inode_index <= 0) return FALSE;

    const int32_t block_index = ext2_find_unallocated_block_index();

    if (block_index == -1) return FALSE;
    
    *indirect_block = block_index;

    ext2_write_inode(inode_index, inode);

    return TRUE;
}

static bool_t ext2_set_inode_block_index(Ext2Inode* const inode, const uint32_t inode_index, 
                                 const uint32_t inode_block_index, const uint32_t block_to_set_index) {
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
        if (inode->i_block[EXT2_DIRECT_BLOCKS] == NULL) {
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
    
    doubly_indirect_block_index = singly_indirect_block_index - indirect_blocks_max_count * indirect_blocks_max_count;
    if (doubly_indirect_block_index < 0) {
        doubly_indirect_block_index = singly_indirect_block_index / indirect_blocks_max_count;
        triply_indirect_block_index = singly_indirect_block_index - doubly_indirect_block_index * indirect_blocks_max_count;

        if (inode->i_block[EXT2_DIRECT_BLOCKS + 1] == NULL) {
            if (!ext2_allocate_indirect_block(inode, inode_index, &inode->i_block[EXT2_DIRECT_BLOCKS + 1])) {
                kfree(buffer);
                return FALSE;
            }
        }

        ext2_read_block(inode->i_block[EXT2_DIRECT_BLOCKS + 1], buffer);

        if (buffer[doubly_indirect_block_index] == NULL) {
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

    triply_indirect_block_index = doubly_indirect_block_index - 
                                  indirect_blocks_max_count * indirect_blocks_max_count * indirect_blocks_max_count;
    if (triply_indirect_block_index <= 0) {
        // idk how to call this helper(1,2,3), so let it be helper)
        // For more info https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout (Direct/Indirect Block Addressing)
        // NOTE: indexing in i_block is the same for both ext2 and ext4, thats why link above describes ext4
        const uint32_t helper1 = doubly_indirect_block_index / (indirect_blocks_max_count * indirect_blocks_max_count);
        const uint32_t helper2 = (doubly_indirect_block_index - 
                                  helper1 * indirect_blocks_max_count * indirect_blocks_max_count) / 
                                  indirect_blocks_max_count;
        const uint32_t helper3 = (doubly_indirect_block_index - 
                                  helper1 * indirect_blocks_max_count * indirect_blocks_max_count - 
                                  helper2 * indirect_blocks_max_count);
        
        if (inode->i_block[EXT2_DIRECT_BLOCKS + 2] == NULL) {
            if (!ext2_allocate_indirect_block(inode, inode_index, &inode->i_block[EXT2_DIRECT_BLOCKS + 2])) {
                kfree(buffer);
                return FALSE;
            }
        }

        ext2_read_block(inode->i_block[EXT2_DIRECT_BLOCKS + 2], buffer);

        if (buffer[helper1] == NULL) {
            if (!ext2_allocate_indirect_block(inode, inode_index, &buffer[helper1])) {
                kfree(buffer);
                return FALSE;
            }
        }

        uint32_t temp = buffer[helper1];

        ext2_read_block(buffer[helper1], buffer);

        if (buffer[helper2] == NULL) {
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

    kernel_warn("cant set given block\n");

    kfree(buffer);
    return FALSE;
}

// returns -1 on fail
static bool_t ext2_allocate_inode_block(Ext2Inode* const inode, 
                                        const uint32_t inode_index,
                                        const uint32_t inode_block_index) {
    if (inode == NULL) return FALSE;
    if (inode_index <= 0) return FALSE;
    if (inode_block_index < 0) return FALSE;
    
    uint32_t block_index = ext2_find_unallocated_block_index();

    if (block_index == -1) return FALSE;

    if (!ext2_set_inode_block_index(inode, inode_index, inode_block_index, block_index)) {
        return FALSE;
    }

    inode->disk_sects_count = (inode_block_index + 1) * (ext2_fs.block_size / 512);

    ext2_write_inode(inode_index, inode);

    return TRUE;
}

static void ext2_read_inode_block(const Ext2Inode* const inode, 
                                  const uint32_t inode_block_index, 
                                  void* const buffer) {    
    if (inode == NULL || buffer == NULL) return;
    if (inode_block_index < 0) return;

    const int32_t inode_block = ext2_get_inode_block_index(inode, inode_block_index);

    if (inode_block == -1) return;

    ext2_read_block(inode_block, buffer);
}

static void ext2_write_inode_block(const Ext2Inode* const inode, 
                                   const uint32_t inode_block_index, 
                                   void* const buffer) {
    if (inode == NULL || buffer == NULL) return;
    if (inode_block_index < 0) return;

    const int32_t inode_block = ext2_get_inode_block_index(inode, inode_block_index);

    if (inode_block == -1) return;
    
    ext2_write_block(inode_block, buffer);
}

static void ext2_read_inode_data(const VfsInodeFile* const vfs_inode, uint32_t offset,
                                 const uint32_t total_bytes, char* const buffer) {
    if (vfs_inode == NULL || buffer == NULL) return;
    if (total_bytes > ext2_fs.block_size) return;
    if (vfs_inode->inode.type == VFS_TYPE_DIRECTORY) return;
    if (offset < 0 || total_bytes <= 0) return;

    ext2_read_inode(vfs_inode->inode.index, global_ext2_inode);

    if (offset > global_ext2_inode->size_in_bytes_lower32) offset = global_ext2_inode->size_in_bytes_lower32;

    const uint32_t end_offset = (global_ext2_inode->size_in_bytes_lower32 >= offset + total_bytes) ?
                                (offset + total_bytes) : global_ext2_inode->size_in_bytes_lower32; 
    const uint32_t start_block = offset / ext2_fs.block_size;
    const uint32_t end_block = end_offset / ext2_fs.block_size;
    const uint32_t start_offset = offset % ext2_fs.block_size;
    
    // TODO: change last access time  

    uint32_t current_offset = 0;
    for (size_t i = start_block; i <= end_block; ++i) {
        uint32_t left_border = 0, right_border = ext2_fs.block_size - 1;

        ext2_read_inode_block(global_ext2_inode, i, global_buffer);

        if (i == start_block) left_border = start_offset;

        if (i == end_block) right_border = total_bytes + left_border;
                    
        memcpy(global_buffer + left_border, buffer + current_offset, right_border - left_border);

        current_offset += right_border - left_border;
    }
}

static void ext2_write_inode_data(const VfsInodeFile* const vfs_inode, uint32_t offset,
                                  const uint32_t total_bytes, char* const buffer) {
    if (vfs_inode == NULL || buffer == NULL) return;
    if (total_bytes <= 0 || total_bytes > ext2_fs.block_size) return;
    if (strlen(buffer) > ext2_fs.block_size) return;
    if (vfs_inode->inode.type == VFS_TYPE_DIRECTORY) return;
    if (offset < 0) return;

    ext2_read_inode(vfs_inode->inode.index, global_ext2_inode);

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
            if (!ext2_allocate_inode_block(global_ext2_inode, vfs_inode->inode.index, current_i_block_count)) {
                return;
            }
        }
    }

    // TODO: change last access time    

    ext2_write_inode(vfs_inode->inode.index, global_ext2_inode);

    const uint32_t end_offset = (global_ext2_inode->size_in_bytes_lower32 >= offset + total_bytes) ?
                                (offset + total_bytes) : global_ext2_inode->size_in_bytes_lower32;
    const uint32_t start_block = offset / ext2_fs.block_size;
    const uint32_t end_block = end_offset / ext2_fs.block_size;
    const uint32_t start_offset = offset % ext2_fs.block_size;
    
    uint32_t current_offset = 0;
    for (size_t i = start_block; i <= end_block; ++i) {
        uint32_t left_border = 0, right_border = ext2_fs.block_size - 1;

        ext2_read_inode_block(global_ext2_inode, i, global_buffer);

        if (i == start_block) left_border = start_offset;

        if (i == end_block) right_border = total_bytes + left_border;
                    
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
static Ext2DirInode** ext2_get_all_dir_entries(Ext2Inode* const inode) {
    if (inode == NULL) return (Ext2DirInode**)-1;
    if (!(inode->type_and_permission & EXT2_INODE_DIRECTORY)) {
        return (Ext2DirInode**)-1;
    }

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

    Ext2DirInode** all_dir_entries = (Ext2DirInode**)kmalloc(dir_count * sizeof(Ext2DirInode*));

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

static void ext2_fill_vfs_inode_interface_by_type(VfsDentry* const dentry, const VfsInodeTypes type) {
    if (dentry == NULL) return;

    switch (dentry->inode->type) {
    case VFS_TYPE_FILE: {
        ((VfsInodeFile*)dentry->inode)->interface.read = &ext2_read_inode_data;
        ((VfsInodeFile*)dentry->inode)->interface.write = &ext2_write_inode_data;

        break;
    }
    case VFS_TYPE_DIRECTORY: {
        ((VfsInodeDir*)dentry->inode)->interface; // TODO: add some funcs

        break;
    }        
    default:
        break;
    }
}

static void ext2_fill_dentry(VfsDentry* const dentry) {
    if (dentry == NULL) return;
    if (dentry->inode->type != VFS_TYPE_DIRECTORY) return;

    ext2_read_inode(dentry->inode->index, global_ext2_inode);

    Ext2DirInode** all_dirs = ext2_get_all_dir_entries(global_ext2_inode);

    if (all_dirs == (Ext2DirInode**)-1) return;

    // count all directories
    size_t dir_count = 0;
    while (all_dirs[dir_count] != NULL) dir_count++;
    
    if (dir_count == 0) return;

    dentry->childs = (VfsDentry**)kmalloc(dir_count * sizeof(VfsDentry*));

    if (dentry->childs == NULL) {
        ext2_free_all_dir_entries(all_dirs);
        return;
    }

    size_t index = 0;
    for (; index < dir_count; ++index) {
        dentry->childs[index] = (VfsDentry*)kmalloc(sizeof(VfsDentry));

        if (dentry->childs[index] == NULL) {
            ext2_free_all_dir_entries(all_dirs);
            return;
        }

        memcpy(all_dirs[index]->name, dentry->childs[index]->name, all_dirs[index]->name_len);
        dentry->childs[index]->name[all_dirs[index]->name_len] = '\0';
        
        dentry->childs[index]->inode = create_vfs_inode_by_type(all_dirs[index]->file_type);

        if (dentry->childs[index]->inode == NULL) {
            kfree(dentry->childs[index]);
            ext2_free_all_dir_entries(all_dirs);

            // end of the child array
            dentry->childs[index] = NULL;

            return;
        }

        dentry->childs[index]->inode->type = all_dirs[index]->file_type;
        dentry->childs[index]->inode->index = all_dirs[index]->inode;
        
        dentry->childs[index]->parent = dentry;
        dentry->childs[index]->childs = NULL;
        dentry->childs[index]->childs_count = 0;

        dentry->childs_count++;

        ext2_fill_vfs_inode_interface_by_type(dentry->childs[index], dentry->childs[index]->inode->type);

        dentry->childs[index]->interface.fill_dentry = &ext2_fill_dentry;
    }

    // end of the child array
    dentry->childs[index] = NULL;
    
    ext2_free_all_dir_entries(all_dirs);
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

static VfsDentry* ext2_create_dentry(const uint32_t inode_index, const char* const dentry_name, 
                                     const VfsDentry* const parent, VfsInodeTypes type) {
    if (dentry_name == NULL) return NULL;
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
    new_dentry->childs_count = 0;
    new_dentry->is_in_use = FALSE;
    
    size_t dentry_name_len = strlen(dentry_name);

    memcpy(dentry_name, new_dentry->name, dentry_name_len);
    new_dentry->name[dentry_name_len] = '\0';

    ext2_fill_dentry(new_dentry);   

    ext2_fill_vfs_inode_interface_by_type(new_dentry, new_dentry->inode->type);

    new_dentry->interface.fill_dentry = &ext2_fill_dentry;
    
    return new_dentry;
}

static bool_t ext2_create_dir_entry(const VfsDentry* const parent, const char* const entry_name, 
                                    const uint32_t entry_inode_index, DirInodeTypes type) {
    if (parent == NULL || entry_name == NULL) return FALSE;
    if (parent->inode->type != VFS_TYPE_DIRECTORY) return FALSE;
    if (entry_inode_index <= 0) return FALSE;

    ext2_read_inode(parent->inode->index, global_buffer);

    Ext2DirInode** all_dir_entries = ext2_get_all_dir_entries(global_buffer);

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

    return TRUE;
}

static void ext2_remove_dir_entry(const uint32_t parent_dir_inode_index, char* const entry_to_remove_name) {
    if (entry_to_remove_name == NULL) return;
    if ((!strcmp(entry_to_remove_name, ".")) || (!strcmp(entry_to_remove_name, ".."))) return;

    ext2_read_inode(parent_dir_inode_index, global_ext2_inode);

    Ext2DirInode** all_dir_entries = ext2_get_all_dir_entries(global_ext2_inode);

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
    if (inode_name == NULL) return;

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

    int32_t inode_index = ext2_find_unallocated_inode_index();

    if (inode_index == -1) return -1;
    
    ext2_read_inode(inode_index, global_ext2_inode);

    memset(global_ext2_inode, sizeof(*global_ext2_inode), 0);

    // TODO time
    global_ext2_inode->creation_time = 1715343535;
    global_ext2_inode->last_access_time = 1715343535;
    global_ext2_inode->last_mod_time = 1715343535;
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
        ext2_free_inode(parent->inode->index, inode_index);
        return -1;
    }

    if (!ext2_create_dir_entry(parent, inode_name, inode_index, 
                               ext2_inode_type_to_dir_inode_type(type))) {
        ext2_free_inode(parent->inode->index, inode_index);
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

static Ext2InodePermission vfs_permission_to_ext2(const VfsInodePermission permission) {
    Ext2InodePermission ext2_permission = 0;

    if (permission & VFS_OTHER_EXECUTE_PERMISSION) ext2_permission |= EXT2_OTHER_EXECUTE_PERMISSION;
    if (permission & VFS_OTHER_EXECUTE_PERMISSION) ext2_permission |= EXT2_OTHER_EXECUTE_PERMISSION;
    if (permission & VFS_OTHER_WRITE_PERMISSION)   ext2_permission |= EXT2_OTHER_WRITE_PERMISSION;
    if (permission & VFS_OTHER_READ_PERMISSION)    ext2_permission |= EXT2_OTHER_READ_PERMISSION;
    if (permission & VFS_GROUP_EXECUTE_PERMISSION) ext2_permission |= EXT2_GROUP_EXECUTE_PERMISSION;
    if (permission & VFS_GROUP_WRITE_PERMISSION)   ext2_permission |= EXT2_GROUP_WRITE_PERMISSION;
    if (permission & VFS_GROUP_READ_PERMISSION)    ext2_permission |= EXT2_GROUP_READ_PERMISSION;
    if (permission & VFS_USER_EXECUTE_PERMISSION)  ext2_permission |= EXT2_USER_EXECUTE_PERMISSION;
    if (permission & VFS_USER_WRITE_PERMISSION)    ext2_permission |= EXT2_USER_WRITE_PERMISSION;
    if (permission & VFS_USER_READ_PERMISSION)     ext2_permission |= EXT2_USER_READ_PERMISSION;

    return ext2_permission;
}

static void ext2_mkfile(VfsDentry* const parent, 
                        const char* const file_name, 
                        const VfsInodePermission permission) {
    if (parent == NULL || file_name == NULL) return;
    if (parent->inode->type != VFS_TYPE_DIRECTORY) return;
    if (permission == 0) return;

    int32_t new_inode_index = ext2_create_inode(parent, file_name, 
                                                vfs_permission_to_ext2(permission),
                                                EXT2_INODE_REGULAR_FILE);

    if (new_inode_index == -1) return;

    VfsDentry* new_dentry = ext2_create_dentry(new_inode_index, file_name, parent, VFS_TYPE_FILE);

    if (new_dentry == NULL) return;
    
    krealloc(parent->childs, parent->childs_count + 1);
    parent->childs[parent->childs_count] = new_dentry;
    parent->childs_count++;
    parent->childs[parent->childs_count] = NULL;                        
}

static void ext2_mkdir(VfsDentry* const parent, 
                       const char* const dir_name, 
                       const VfsInodePermission permission) {
    if (parent == NULL || dir_name == NULL) return;
    if (parent->inode->type != VFS_TYPE_DIRECTORY) return;
    if (permission == 0) return;
    
    int32_t new_inode_index = ext2_create_inode(parent, dir_name, 
                                                vfs_permission_to_ext2(permission), 
                                                EXT2_INODE_DIRECTORY);   

    if (new_inode_index == -1) return;

    VfsDentry* new_dentry = ext2_create_dentry(new_inode_index, dir_name, parent, VFS_TYPE_DIRECTORY);

    if (new_dentry == NULL) return;

    ext2_create_dir_entry(new_dentry, ".", new_inode_index, EXT2_DIR_TYPE_DIRECTORY);
    ext2_create_dir_entry(new_dentry, "..", parent->inode->index, EXT2_DIR_TYPE_DIRECTORY);

    krealloc(parent->childs, parent->childs_count + 1);
    parent->childs[parent->childs_count] = new_dentry;
    parent->childs_count++;
    parent->childs[parent->childs_count] = NULL; 
}

static void ext2_chmod(const VfsDentry* const dentry, const VfsInodePermission permission) {
    if (dentry == NULL) return;
    if (permission == 0) return;

    ext2_read_inode(dentry->inode->index, global_ext2_inode);

    global_ext2_inode->type_and_permission = (global_ext2_inode->type_and_permission & 0xFFFFF000) | 
                                              vfs_permission_to_ext2(permission);

    ext2_write_inode(dentry->inode->index, global_ext2_inode);
}

static void ext2_unlink(const VfsDentry* const dentry_to_unlink, const char* const name) {
    if (dentry_to_unlink == NULL || name == NULL) return;
    if (dentry_to_unlink->inode->type == VFS_TYPE_DIRECTORY) return;

    ext2_read_inode(dentry_to_unlink->inode->index, global_ext2_inode);

    // if inode already deleted
    if (global_ext2_inode->deletion_time != 0) {
        kernel_warn("inode %s already deleted\n", name);
        return;
    }

    if (global_ext2_inode->hard_links_count == 1) {
        ext2_free_inode(dentry_to_unlink->parent->inode->index, dentry_to_unlink->inode->index);
        
        uint32_t blocks_to_free = (global_ext2_inode->size_in_bytes_lower32 / ext2_fs.block_size) + 1;

        while (blocks_to_free > 0) {
            const uint32_t block_to_free = ext2_get_inode_block_index(global_ext2_inode, block_to_free);

            ext2_free_block(block_to_free);

            --blocks_to_free;
        }
    }

    ext2_remove_dir_entry(dentry_to_unlink->parent->inode->index, name);

    
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
    ext2_fs.common.storage_device = storage_device;
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