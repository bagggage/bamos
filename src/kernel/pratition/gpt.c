#include "gpt.h"

#include "logger.h"
#include "mem.h"

#include "dev/blk/nvme.h"

#include "fs/ext2/superblock.h"

#define GPT_HEADER_OFFSET 512

#define GPT_MAGIC "EFI MAGIC"

static int strcmp(const char* s1, const char* s2) {
    while (*s1 && (*s1 == *s2)) {
        s1++;
        s2++;
    }

    return *(const unsigned char*)s1 - *(const unsigned char*)s2;
}

Status find_gpt_table(const StorageDevice* const storage_device) {
    GptHeader* gpt_header = storage_device->interface.read(storage_device, GPT_HEADER_OFFSET, sizeof(GptHeader));

    if (!strcmp(gpt_header->magic, GPT_MAGIC)) return KERNEL_ERROR;

    kernel_msg("GPT entry found\n");
    kernel_msg("GUID: %u\n", gpt_header->guid);
    kernel_msg("GPT partitions count: %u\n", gpt_header->partition_count);
    kernel_msg("Partitions size: %u\n", gpt_header->partition_entry_size);
    
    size_t lba_offset = (gpt_header->lba_partition_entry * GPT_HEADER_OFFSET);
    for (size_t i = 0; i < 32; ++i) {
        size_t total_bytes = storage_device->lba_size;

        //kernel_msg("Offset %u, LBA No.%u\n", lba_offset, lba_offset / storage_device->lba_size);
        char* buffer = storage_device->interface.read(storage_device, lba_offset, total_bytes);

        for (size_t j = 0; j < storage_device->lba_size / sizeof(PartitionEntry); ++j) {
            PartitionEntry* partition_entry = (PartitionEntry*)&buffer[j * sizeof(PartitionEntry)];

            uint128_t type_unknown = 0;
            if (!memcmp(partition_entry->guid_type, &type_unknown, sizeof(partition_entry->guid_type))) continue;

            for (size_t k = 0; k < sizeof(partition_entry->partition_name); k++) {
                raw_putc(partition_entry->partition_name[k]);
            }
            raw_putc('\n');
            kernel_msg("Partition start: %u\n", partition_entry->lba_start);

            // char* superblock = storage_device->interface.read(storage_device, partition_entry->lba_start, sizeof(extfs_superblock) + 1024);
            // extfs_superblock* block = superblock + 1024; 
            // kernel_msg("magic: %x\n", block->magic);
        }

        lba_offset += storage_device->lba_size;
    }

    return KERNEL_OK;
}