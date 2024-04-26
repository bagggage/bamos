#include "ext2.h"

bool_t is_ext2(const StorageDevice* const storage_device, const uint64_t partition_lba_start) {
    if (storage_device == NULL) return FALSE;

    const Ext2Superblock* superblock = (Ext2Superblock*)storage_device->interface.read(storage_device, 
                                (partition_lba_start * storage_device->lba_size) + EXT2_SUPERBLOCK_OFFSET, 
                                sizeof(Ext2Superblock));

    return (superblock->magic == EXT2_SUPERBLOCK_MAGIC) ? TRUE : FALSE;
}








