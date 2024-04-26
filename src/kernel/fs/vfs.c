#include "vfs.h"

#include "logger.h"
#include "mem.h"

#include "fs/ext2/ext2.h"

#include "partition/gpt.h"
#include "partition/gpt_partitions_list.h"

Status init_vfs() {
    if (find_gpt_tables() != KERNEL_OK) return KERNEL_ERROR;

    GptPartitionNode* partition_node = gpt_get_first_node();

    if (partition_node == NULL) return KERNEL_ERROR;
    
    while (partition_node != NULL) {
        if (is_ext2(partition_node->storage_device, partition_node->partition_entry.lba_start)) {
            kernel_msg("EXT2 superblock found\n");

            const StorageDevice* storage_device = partition_node->storage_device;
            
            BlockGroupDescriptorTable* bgd_table = (BlockGroupDescriptorTable*)kmalloc(sizeof(BlockGroupDescriptorTable));

            storage_device->interface.read(storage_device, 
            (partition_node->partition_entry.lba_start * storage_device->lba_size) + 2 * EXT2_SUPERBLOCK_OFFSET, 
            sizeof(BlockGroupDescriptorTable),
            bgd_table);

            kernel_msg("Address %x, Dir in group %u\n",bgd_table->address_of_block_bitmap, bgd_table->directories_in_group_count);
        }

        partition_node = partition_node->next;
    }

    return KERNEL_OK;
}