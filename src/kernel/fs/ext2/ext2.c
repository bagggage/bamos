#include "ext2.h"

#include "mem.h"

bool_t is_ext2(const StorageDevice* const storage_device, const uint64_t partition_lba_start) {
    if (storage_device == NULL) return FALSE;

    Ext2Superblock* superblock =  (Ext2Superblock*)kmalloc(sizeof(Ext2Superblock));

    storage_device->interface.read(storage_device, (partition_lba_start * storage_device->lba_size) + EXT2_SUPERBLOCK_OFFSET, 
                                    sizeof(Ext2Superblock), superblock);

    const uint16_t magic = superblock->magic;

    kfree(superblock);

    return (magic == EXT2_SUPERBLOCK_MAGIC) ? TRUE : FALSE;
}








