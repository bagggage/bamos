#pragma once

#include "definitions.h"

#include "dev/storage.h"

typedef struct GptHeader { 
    uint8_t magic[8];
    uint32_t gpt_revision;
    uint32_t header_size;
    uint32_t crc32;
    uint32_t reserved;
    uint64_t lba_this;
    uint64_t lba_alternative;
    uint64_t first_usable;
    uint64_t last_usable;
    uint8_t guid [16];
    uint64_t lba_partition_entry;
    uint32_t partition_count;
    uint32_t partition_entry_size;
    uint32_t crc32_partition_entry;
} ATTR_PACKED GptHeader;

typedef struct PartitionEntry {
    uint8_t guid_type[16];
    uint8_t guid [16];
    uint64_t lba_start;
    uint64_t lba_end;
    uint64_t attribute;
    uint8_t partition_name[72];
} ATTR_PACKED PartitionEntry;

Status gpt_inspect_storage_device(const StorageDevice* const device);