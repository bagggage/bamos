#include "gpt.h"

#include "logger.h"
#include "mem.h"

#include "dev/blk/nvme.h"

#include "fs/ext2/ext2.h"

#include "partition/gpt_partitions_list.h"

#define GPT_HEADER_OFFSET 512

#define GPT_TOTAL_LBA_COUNT 32

#define GPT_MAGIC "EFI MAGIC"

static int strcmp(const char* s1, const char* s2) {
    while (*s1 && (*s1 == *s2)) {
        s1++;
        s2++;
    }

    return *(const unsigned char*)s1 - *(const unsigned char*)s2;
}

static Status find_gpt_table_on_storage_device(const StorageDevice* const storage_device) {
    const GptHeader* gpt_header = storage_device->interface.read(storage_device, GPT_HEADER_OFFSET, sizeof(GptHeader));

    if (!strcmp(gpt_header->magic, GPT_MAGIC)) return KERNEL_ERROR;

    kernel_msg("GPT entry found\n");
    kernel_msg("GUID: %u\n", gpt_header->guid);
    kernel_msg("GPT partitions count: %u\n", gpt_header->partition_count);
    kernel_msg("Partitions size: %u\n", gpt_header->partition_entry_size);
    
    size_t lba_offset = (gpt_header->lba_partition_entry * GPT_HEADER_OFFSET);
    for (size_t i = 0; i < GPT_TOTAL_LBA_COUNT; ++i) {
        const size_t total_bytes = storage_device->lba_size;

        //kernel_msg("Offset %u, LBA No.%u\n", lba_offset, lba_offset / storage_device->lba_size);

        const char* buffer = storage_device->interface.read(storage_device, lba_offset, total_bytes);

        for (size_t j = 0; j < storage_device->lba_size / sizeof(PartitionEntry); ++j) {
            const PartitionEntry* partition_entry = (PartitionEntry*)&buffer[j * sizeof(PartitionEntry)];

            const uint128_t type_unused = 0;
            if (!memcmp(partition_entry->guid_type, &type_unused, sizeof(partition_entry->guid_type))) continue;

            for (size_t k = 0; k < sizeof(partition_entry->partition_name); ++k) {
                raw_putc(partition_entry->partition_name[k]);
            }
            raw_putc('\n');
            kernel_msg("Partition start: %u, Partition LBA: %u\n", 
                    partition_entry->lba_start,
                    partition_entry->lba_start / storage_device->lba_size);

            GptPartitionNode* new_node = (GptPartitionNode*)kmalloc(sizeof(GptPartitionNode));

            new_node->partition_entry = *partition_entry;
            new_node->storage_device = storage_device;
            new_node->next = NULL;
            new_node->prev = NULL;

            gpt_push(new_node);
        }

        lba_offset += storage_device->lba_size;
    }

    return KERNEL_OK;
}

Status find_gpt_tables() {
    StorageDevice* storage_device = NULL;

    while ((storage_device = (StorageDevice*)dev_find(storage_device, &is_storage_device)) != NULL) {
        find_gpt_table_on_storage_device(storage_device);
    }

    return (storage_device == NULL) ? KERNEL_OK : KERNEL_ERROR;
}