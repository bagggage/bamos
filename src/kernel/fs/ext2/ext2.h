#pragma once

#include "definitions.h"

#include "dev/storage.h"

#include "fs/vfs.h"

#define EXT2_SUPERBLOCK_OFFSET 1024

#define EXT2_SUPERBLOCK_MAGIC 0xEF53

#define EXT2_ROOT_INODE_INDEX 2

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

// Total size of the superblock 1024
typedef struct Ext2Superblock {
    uint32_t inodes_count;
    uint32_t blocks_count;
    uint32_t revered_blocks_count;      // This blocks reserved for superuser
    uint32_t free_blocks_count;
    uint32_t free_inodes_count;
    uint32_t superblock_block_number;   // Also the starting block number, NOT always zero.
    uint32_t block_size;                // Shift 1024 to the left by this to get size
    uint32_t fragment_size;             // Shift 1024 to the left by this to get size
    uint32_t blocks_per_group;
    uint32_t fragments_per_group;
    uint32_t inodes_per_group;
    uint32_t last_mount_time;           // In POSIX time
    uint32_t last_written_time;         // In POSIX time
    uint16_t times_mounted_since_fsck;
    uint16_t times_mounted_til_fsck;
    uint16_t magic;                     // Its 0xEF53
    uint16_t fs_state;
    uint16_t err_handle_type;
    uint16_t version_minor;
    uint32_t last_fsck;                 // In POSIX time
    uint32_t interval_between_fsck;     // In POSIX time
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
    uint32_t journal_inode;
    uint32_t journal_device;
    uint32_t head_orphan_inode_list;
    uint8_t reserved1[18];
    uint16_t bgt_struct_size;
} ATTR_PACKED Ext2Superblock;

typedef struct BlockGroupDescriptorTable {
    uint32_t address_of_block_bitmap;
    uint32_t address_of_inode_bitmap;
    uint32_t starting_block_of_inode_table;
    uint16_t unallocated_blocks_count;
    uint16_t unallocated_inode_count;
    uint16_t directories_count;
    uint16_t bg_pad;
    uint32_t reserved[3];
} ATTR_PACKED BlockGroupDescriptorTable;

typedef enum InodeType {
    EXT2_INODE_FIFO = 0x1000,
    EXT2_INODE_CHARACTER_DEVICE = 0x2000,
    EXT2_INODE_DIRECTORY = 0x4000,
    EXT2_INODE_BLOCK_DEVICE = 0x6000,
    EXT2_INODE_REGULAR_FILE = 0x8000,
    EXT2_INODE_SYMBOLIC_LINK = 0xA000,
    EXT2_INODE_UNIX_SOCKET = 0xC000
} InodeType;

typedef enum InodePermission {
    OTHER_EXECUTE_PERMISSION = 0x001,
    OTHER_WRITE_PERMISSION = 0x002,
    OTHER_READ_PERMISSION = 0x004,
    GROUP_EXECUTE_PERMISSION = 0x008,
    GROUP_WRITE_PERMISSION = 0x010,
    GROUP_READ_PERMISSION = 0x020,
    USER_EXECUTE_PERMISSION = 0x040,
    USER_WRITE_PERMISSION = 0x080,
    USER_READ_PERMISSION = 0x100,
    PERMISSION_STICKY_BIT = 0x200,
    PERMISSION_SET_GROUP_ID = 0x400,
    PERMISSION_SET_USER_ID = 0x800
} InodePermission;

typedef enum InodeFlags {
    INODE_FLAG_SECURE_DELETION = 0x00000001,
    INODE_FLAG_KEEP_COPY = 0x00000002,
    INODE_FLAG_FILE_COMPRESSION = 0x00000004,
    INODE_FLAG_SYNC_UPDATES = 0x00000008,
    INODE_FLAG_IMMUTABLE = 0x00000010,
    INODE_FLAG_APPEND_ONLY = 0x00000020,
    INODE_FLAG_EXCLUDE_FROM_DUMP = 0x00000040,
    INODE_FLAG_NO_LAST_ACCESS_UPDATE = 0x00000080,
    INODE_FLAG_HASH_INDEXED_DIR = 0x00010000,
    INODE_FLAG_AFS_DIR = 0x00020000,
    INODE_FLAG_JOURNAL_FILE = 0x00040000
} InodeFlags;

typedef struct Ext2Inode {
    uint16_t type_and_permission;
    uint16_t uid;
    uint32_t size_in_bytes_lower32;
    uint32_t last_access_time;              // In POSIX time
    uint32_t creation_time;                 // In POSIX time
    uint32_t last_mod_time;                 // In POSIX time
    uint32_t deletion_time;                 // In POSIX time
    uint16_t gid;
    uint16_t hard_links_count;              // When 0 marked as unallocated
    uint32_t disk_sects_count;
    uint32_t flags;
    uint32_t os_specific1;
    uint32_t i_block[12];
    uint32_t singly_indirect_block_ptr;     // Points to a block that is a list of block pointers to data
    uint32_t doubly_indirect_block_ptr;     // Points to a block that is a list of block pointers to Singly Indirect Blocks
    uint32_t triply_indirect_block_ptr;     // Points to a block that is a list of block pointers to Doubly Indirect Blocks
    uint32_t gen_num;
    uint32_t extended_attr;                 // In Ext2 version 0, this field is reserved
    uint32_t size_in_bytes_higher32;        // In Ext2 version 0, this field is reserved
    uint32_t block_fragment;
    uint8_t os_specific2[12];
} ATTR_PACKED Ext2Inode;

typedef enum DirInodeTypes {
    DIR_TYPE_UNKNOWN = 0,
    DIR_TYPE_FILE,
    DIR_TYPE_DIRECTORY,
    DIR_TYPE_CHARACTER_DEVICE,
    DIR_TYPE_BLOCK_DEVICE,
    DIR_TYPE_FIFO,
    DIR_TYPE_SOCKET,
    DIR_TYPE_SYMBOLIC_LINK
} DirInodeTypes;

typedef struct Ext2DirInode {
    uint32_t inode;			
   	uint16_t total_size;		
   	uint8_t	name_len;	
   	uint8_t	file_type;
   	char name[255];
} ATTR_PACKED Ext2DirInode; 

typedef struct Ext2Fs {
    VFS_STRCUT_IMPL;

    uint32_t block_size;
    uint32_t blocks_per_group;
    uint32_t inodes_per_group;
    uint32_t total_groups;
    uint32_t inode_struct_size;
    uint32_t bgds_count_in_block;
    uint32_t bgd_blocks_count;
    BlockGroupDescriptorTable** bgds;
} Ext2Fs;

bool_t is_ext2(const StorageDevice* const storage_device, const uint64_t partition_lba_start);

Status ext2_init(const StorageDevice* const storage_device, const uint64_t partition_lba_start);