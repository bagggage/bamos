#pragma once

#ifndef KERNEL
typedef long long ssize_t;
typedef unsigned long long size_t;
#endif

typedef struct iovec {
    void* iov_base;	/* Pointer to data.  */
    size_t iov_len;	/* Length of data.  */
} iovec;

#ifndef KERNEL

ssize_t writev(int fd, const struct iovec* iov, int iovcnt);

#endif