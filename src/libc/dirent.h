#pragma once 

struct linux_dirent {
    long            d_ino;
    long            d_off;
    unsigned short d_reclen;
    char           d_name[];
};
