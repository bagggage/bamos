#pragma once

typedef unsigned long long off_t;

struct dirent {
    long            d_ino;
    long            d_off;
    unsigned short d_reclen;
    char           d_name[];
};

typedef struct dirstream {
	off_t tell;
	long fd;
    unsigned long buf_pos;
    unsigned long buf_end;

	char buf[2048];
} DIR;

DIR*           opendir(const char* path);
int            closedir(DIR* dir);
struct dirent* readdir(DIR* dir);
void           seekdir(DIR* dir, long int offset);
long int       telldir(DIR* dir);
//int            readdir_r(DIR* dirp, struct dirent* dirent, struct dirent **);
//void           rewinddir(DIR *);
