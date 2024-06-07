#include "dirent.h"

#include "errno.h"
#include "fcntl.h"
#include "stdlib.h"
#include "stdio.h"

#include "sys/syscall.h"

static struct dirent _dirent;

DIR* opendir(const char* path) {
    int fd;
    DIR* dir = (DIR*)calloc(sizeof(DIR), 1);

    if (dir == NULL) {
        return NULL;
    }
    if ((fd = open(path, O_RDONLY | O_DIRECTORY)) < 0) {
        free(dir);
        return NULL;
    }

    dir->fd = fd;

    return dir;
}

int closedir(DIR* dir) {
    int ret = close(dir->fd);

	free(dir);

	return ret;
}

//typedef char dirstream_buf_alignment_check[1-2*(int)(offsetof(struct dirstream, buf) % sizeof(off_t))];

struct dirent* readdir(DIR* dir) {
	struct dirent *dirent;
	
	if (dir->buf_pos >= dir->buf_end) {
		int length = _syscall_arg3(SYS_GETDENTS, dir->fd, dir->buf, sizeof(dir->buf));

		if (length <= 0) {
			if (length < 0 && length != -ENOENT) errno = -length;
			return NULL;
		}
    
		dir->buf_end = length;
		dir->buf_pos = 0;
	}

	dirent = (void*)(dir->buf + dir->buf_pos);

	dir->buf_pos += dirent->d_reclen;
	dir->tell = dirent->d_off;

	return dirent;
}

void seekdir(DIR* dirp, long int offset) {
}

long int telldir(DIR* dirp) {
}