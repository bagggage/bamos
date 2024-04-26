#pragma once

#include "definitions.h"

#include "dev/storage.h"

#define EXT2_SUPERBLOCK_OFFSET 1024

#define EXT2_SUPERBLOCK_MAGIC 0xEF53

typedef enum FileSystemState {
    FILE_SYSTEM_CLEAN = 1,
    FILE_SYSTEM_HAS_ERROR
} FileSystemState;

typedef enum ErrorHandlingMethods {
    IGNORE_THE_ERROR = 1,
    REMOUNT_AS_READONLY,
    EXT2_CRITICAL_ERROR
} ErrorHandlingMethods;

typedef enum CreatorOperatingSystemId {
    LINUX = 0,
    GNU_HURD,
    MASIX,
    FREE_BSD,
    OTHER_OS,
} CreatorOperatingSystemId;

typedef enum OptionalFlags {
    PREALLOCATE_SOME_BLOCKS = 1,
    AFS_SERVER_INODE_EXIST = 2,
    FS_HAS_A_JOURNAL = 4,
    INODES_HAS_EXTENDED_ATTR = 8,
    FS_CAN_RESIZE_ITSELF = 16,
    DIRECTORIES_USE_HASH_INDEX = 32
} OptionalFlags;

typedef enum RequiredFlags {
    COMPRESSION_IS_USED = 1,
    DIRECTORY_ENTRY_CONTAIN_A_TYPE_FIELD = 2,
    FS_NEEDS_TO_REPLAY_JOURNAL = 4,
    FS_USE_JOURNAL_DEVICE = 8
} RequiredFlags;

typedef enum ReadonlyFlags {
    SPARSE_SUPERBLOCK_AND_GROUP_DT = 1,
    BIT64_FILE_SIZE = 2,
    DIRECTORY_CONTENT_STORES_IN_BIN_TREE = 4
} ReadonlyFlags;

typedef struct Ext2Superblock {
    uint32_t inodes_count;
    uint32_t blocks_count;
    uint32_t revered_blocks_count;      // NOTE: this blocks reserved for superuser
    uint32_t free_blocks_count;
    uint32_t free_inodes_count;
    uint32_t superblock_block_number;
    uint32_t block_size;                //NOTE: shift 1024 by this to get size
    uint32_t fragment_size;
    uint32_t blocks_per_group;
    uint32_t fragments_per_group;
    uint32_t inodes_per_group;
    uint32_t last_mount_time;           // NOTE: in POSIX time
    uint32_t last_written_time;         // NOTE: in POSIX time
    uint16_t times_mounted_since_fsck;
    uint16_t times_mounted_til_fsck;
    uint16_t magic;                     //NOTE: its 0xEF53
    uint16_t fs_state;
    uint16_t err_handle_type;
    uint16_t version_minor;
    uint32_t last_fsck;                 // NOTE: in POSIX time
    uint32_t interval_between_fsck;     // NOTE: in POSIX time
    uint32_t os_id;
    uint32_t version_major;
    uint16_t user_id_of_reserved_block;
    uint16_t group_id_of_reserved_block; 
    //---------------------------------------------Extended Superblock fields (if version_major >= 1)
    uint32_t first_unreserved_inode;
    uint16_t inode_struct_size;
    uint16_t superblock_block_group;
    uint32_t optional_flags;
    uint32_t required_flags;
    uint32_t readonly_flags;
    uint128_t fs_id;
    char name[16];
    char last_mounted_path[64];
    uint32_t compression_algos;
    uint8_t prealloc_blocks_for_file;
    uint8_t prealloc_blocks_for_dir;
    uint16_t reserved;
    uint128_t journal_id;
    //uint32_t journal_inode;
    //uint32_t journal_device;
    //uint32_t head_orphan_inode_list;
} ATTR_PACKED Ext2Superblock;

typedef struct BlockGroupDescriptorTable {
    uint32_t address_of_block_bitmap;
    uint32_t address_of_inode_bitmap;
    uint32_t starting_block_address_of_inode_table;
    uint16_t unallocated_blocks_in_group_count;
    uint16_t unallocated_inode_in_group_count;
    uint16_t directories_in_group_count;
} ATTR_PACKED BlockGroupDescriptorTable;

bool_t is_ext2(const StorageDevice* const storage_device, const uint64_t partition_lba_start);