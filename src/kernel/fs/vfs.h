#pragma once

#include "definitions.h"

#include "dev/storage.h"

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

typedef struct VfsInode {
    VfsInodeTypes type;           
    uint32_t index;              
    uint32_t mode;   
    uint32_t hard_link_count;            
    uint32_t uid;              
    uint32_t gid;               
    uint32_t access_time;            
    uint32_t modify_time;            
    uint32_t change_time;         
} VfsInode;

typedef struct VfsDentry VfsDentry;
typedef struct VfsInodeFile VfsInodeFile;

DEV_FUNC(Vfs, void, read, const VfsInodeFile* const inode, char* const buffer);

typedef struct InodeFileInterface {
    Vfs_read_t read;
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

DEV_FUNC(Vfs, VfsDentry*, fill_dentry, VfsDentry* const dentry);

typedef struct DentryInterface {
    Vfs_fill_dentry_t fill_dentry;
} DentryInterface;

typedef struct VfsDentry {    
    DentryInterface interface;
	VfsInode* inode;
	struct VfsDentry* parent;	
	struct VfsDentry** childs;	
	char name[255];
} VfsDentry;

typedef struct Vfs {
    size_t base_disk_offset;
    StorageDevice* storage_device;
} Vfs;

#define VFS_STRCUT_IMPL \
    Vfs common

Status init_vfs();

Status vfs_mount(const char* const mountpoint, const VfsDentry* const dentry);

VfsInode* create_vfs_inode_by_type(VfsInodeTypes type);

VfsDentry* vfs_lookup(const VfsDentry* const dentry, const char* const dir_name);
