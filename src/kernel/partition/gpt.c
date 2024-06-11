#include "gpt.h"

#include "assert.h"
#include "logger.h"
#include "mem.h"

#include "dev/blk/nvme.h"

#include "fs/ext2/ext2.h"

#include "partition/gpt_list.h"

#define GPT_HEADER_OFFSET 512
#define GPT_TOTAL_LBA_COUNT 32
#define GPT_MAGIC "EFI PART"

Status gpt_inspect_storage_device(const StorageDevice* const device) {
    kassert(device != NULL);

    GptHeader* gpt_header = (GptHeader*)kmalloc(sizeof(GptHeader));

    if (gpt_header == NULL) return KERNEL_ERROR;

    device->interface.read((StorageDevice*)device, GPT_HEADER_OFFSET, sizeof(GptHeader), gpt_header);

    if (memcmp(gpt_header->magic, GPT_MAGIC, sizeof(gpt_header->magic)) != 0) {
        kfree(gpt_header);
        return KERNEL_OK;
    }

    kernel_msg("GPT entry found\n");
    kernel_msg("GPT partitions count: %u\n", gpt_header->partition_count);
    kernel_msg("Partitions size: %u\n", gpt_header->partition_entry_size);
    
    size_t lba_offset_in_bytes = gpt_header->lba_partition_entry * GPT_HEADER_OFFSET;
    const size_t total_bytes = device->lba_size;

    uint8_t* buffer = (uint8_t*)kmalloc(total_bytes);

    if (buffer == NULL) {
        kfree(gpt_header);
        return KERNEL_ERROR;
    }

    for (size_t i = 0; i < GPT_TOTAL_LBA_COUNT; ++i) {
        device->interface.read((void*)device, lba_offset_in_bytes, total_bytes, buffer);

        for (size_t j = 0; j < device->lba_size / sizeof(PartitionEntry); ++j) {
            PartitionEntry* partition_entry = (PartitionEntry*)kmalloc(sizeof(PartitionEntry));

            if (partition_entry == NULL) {
                kfree(gpt_header);
                kfree(buffer);
                return KERNEL_ERROR;
            }

            memcpy(buffer + (j * sizeof(PartitionEntry)), partition_entry, sizeof(PartitionEntry));
        
            const uint128_t type_unused = 0;
            if (!memcmp(partition_entry->guid_type, &type_unused, sizeof(partition_entry->guid_type))) continue;

            GptPartitionNode* new_node = (GptPartitionNode*)kmalloc(sizeof(GptPartitionNode));

            if (new_node == NULL) {
                kfree(gpt_header);
                kfree(buffer);
                kfree(partition_entry);
                return KERNEL_ERROR;
            }

            new_node->partition_entry = *partition_entry;
            new_node->storage_device = (void*)device;
            new_node->next = NULL;
            new_node->prev = NULL;

            gpt_push(new_node);
        }

        lba_offset_in_bytes += device->lba_size;
    }

    kfree(buffer);
    kfree(gpt_header);

    return KERNEL_OK;
}