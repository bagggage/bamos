#pragma once

#include "definitions.h"

#include "dev/storage.h"

#define VFS_MAX_INODE_NAME 255

#define VFS_MAX_BUFFER_SIZE 4096

typedef enum VfsInodeTypes {
    VFS_TYPE_UNKNOWN = 0,
    VFS_TYPE_FILE,
    VFS_TYPE_DIRECTORY,
    VFS_TYPE_CHARACTER_DEVICE,
    VFS_TYPE_BLOCK_DEVICE,
    VFS_TYPE_FIFO,
    VFS_TYPE_SOCKET,
    VFS_TYPE_SYMBOLIC_LINK
} VfsInodeTypes;

typedef enum VfsInodePermission {
    VFS_UNKNOWN_PERMISSION = 0x0,
    VFS_OTHER_EXECUTE_PERMISSION = 0x1,
    VFS_OTHER_WRITE_PERMISSION = 0x2,
    VFS_OTHER_READ_PERMISSION = 0x4,
    VFS_GROUP_EXECUTE_PERMISSION = 0x8,
    VFS_GROUP_WRITE_PERMISSION = 0x10,
    VFS_GROUP_READ_PERMISSION = 0x20,
    VFS_USER_EXECUTE_PERMISSION = 0x40,
    VFS_USER_WRITE_PERMISSION = 0x80,
    VFS_USER_READ_PERMISSION = 0x100,
    VFS_PERMISSION_STICKY_BIT = 0x200,
    VFS_PERMISSION_SET_GROUP_ID = 0x400,
    VFS_PERMISSION_SET_USER_ID = 0x800
} VfsInodePermission;

typedef struct VfsInode {
    VfsInodeTypes type;
    VfsInodePermission mode;
    uint32_t index;
    uint32_t hard_link_count;
    uint32_t access_time;
    uint32_t change_time;
    uint64_t file_size;
} VfsInode;

typedef struct VfsDentry VfsDentry;
typedef struct VfsInodeFile VfsInodeFile;

DEV_FUNC(Vfs, uint32_t, read, const VfsInodeFile* const inode, const uint32_t offset,
                          const uint32_t total_bytes, char* const buffer);
DEV_FUNC(Vfs, uint32_t, write, const VfsInodeFile* const inode, const uint32_t offset,
                           const uint32_t total_bytes, const char* buffer);

typedef struct InodeFileInterface {
    Vfs_read_t read;
    Vfs_write_t write;
} InodeFileInterface;

typedef struct VfsInodeFile {
    VfsInode inode;
    InodeFileInterface interface;
} VfsInodeFile;

typedef struct InodeDirInterface {
} InodeDirInterface;

typedef struct VfsInodeDir {
    VfsInode inode;
    InodeDirInterface interface;
} VfsInodeDir;

DEV_FUNC(Vfs, void, fill_dentry, VfsDentry* const dentry);
DEV_FUNC(Vfs, void, mkfile, VfsDentry* const parent, 
                            const char* const file_name,
                            const VfsInodePermission permission);
DEV_FUNC(Vfs, void, mkdir, VfsDentry* const parent, 
                            const char* const dir_name,
                            const VfsInodePermission permission);
DEV_FUNC(Vfs, void, chmod, const VfsDentry* const dentry, const VfsInodePermission permission);
DEV_FUNC(Vfs, void, unlink, const VfsDentry* const dentry_to_unlink, const char* const name);

typedef struct DentryInterface {
    Vfs_fill_dentry_t fill_dentry;
    Vfs_mkfile_t mkfile;
    Vfs_mkdir_t mkdir;
    Vfs_chmod_t chmod;
    Vfs_unlink_t unlink;
} DentryInterface;

typedef struct VfsDentry {    
    DentryInterface interface;
	VfsInode* inode;
    uint32_t childs_count;
	struct VfsDentry* parent;	
	struct VfsDentry** childs;	
	char name[VFS_MAX_INODE_NAME];
} VfsDentry;

typedef struct Vfs {
    size_t base_disk_start_offset;
    size_t base_disk_end_offset;
    uint32_t block_size;
    StorageDevice* storage_device;
} Vfs;

typedef enum VfsOpenFlags {
    VFS_READ = 0,
    VFS_WRITE,
} VfsOpenFlags;

#define VFS_STRCUT_IMPL \
    Vfs common

Status init_vfs();

Status vfs_mount(const char* const mountpoint, VfsDentry* const mnt_dentry);

VfsInode* vfs_new_inode_by_type(VfsInodeTypes type);

VfsDentry* vfs_lookup(const VfsDentry* const dentry, const char* const dir_name);

VfsDentry* vfs_open(const char* const filename, VfsDentry* const parent);
uint32_t vfs_write(const VfsDentry* const dentry, const uint32_t offset, const uint32_t total_bytes, const void* buffer);
uint32_t vfs_read(const VfsDentry* const dentry, const uint32_t offset, const uint32_t total_bytes, void* const buffer);
void vfs_close(VfsDentry* const dentry);

bool_t vfs_get_path(const VfsDentry* const dentry, char* const buffer);

VfsDentry* vfs_new_dentry();
void vfs_delete_dentry(VfsDentry* dentry);
