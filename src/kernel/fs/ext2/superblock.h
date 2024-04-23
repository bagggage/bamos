#pragma once

#include "definitions.h"

typedef struct ExtSuperblock {
    unsigned int num_inodes;
    unsigned int num_blks;

    unsigned int num_rsvd_blks;

    unsigned int num_free_blks;
    unsigned int num_free_inodes;

    unsigned int sb_blknum;
    unsigned int blksz; //NOTE: shift 1024 by this to get sz
    unsigned int fragsz;

    unsigned int num_blks_grp;
    unsigned int num_frags_grp;
    unsigned int num_inodes_grp;

    unsigned int t_lastmount;
    unsigned int t_lastwrite;
    unsigned short times_mounted_since_fsck;
    unsigned short times_mounted_til_fsck;

    unsigned short magic; //NOTE: its' 0xef53

    unsigned short state;
    unsigned short err_handle_type;

    unsigned short ver_minor;
    unsigned int t_last_fsck;
    unsigned int int_between_fskc;

    unsigned int os_id;
    unsigned int ver_major;

    unsigned short uid_of_rsvd_blk;
    unsigned short gid_of_rsvd_blk;

    unsigned int first_unrsvd_inode;

    unsigned short inode_struct_sz_b;
    unsigned short sb_blkgrp;
    unsigned int opt_flags;
    unsigned int req_flags;
    unsigned int ro_flags;
    __uint128_t uuid;
    char name[16];
    char last_path[64];
    unsigned int comp_algos;
    unsigned char blk_prealloc_file;
    unsigned char blk_prealloc_dir;
    unsigned short rsvd;
    __uint128_t j_uuid;
    unsigned int j_inode;
    unsigned int j_dev;
    unsigned int head_orphan_inode_list;
    unsigned int htree_hash_seed[4];
    unsigned char dir_hash_algo;
    unsigned char j_blk_ha_inode_blk_n_sz;
    unsigned short bgd_sz_b;
    unsigned int mnt_flags;
    unsigned int blk_first_meta_grp;
    unsigned int t_creation;
    unsigned int j_inode_backup[17];
    unsigned int num_blks_h;
    unsigned int num_rsvd_blks_h;
    unsigned int num_free_blks_h;
} ATTR_PACKED ExtSuperblock;