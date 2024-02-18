#pragma once

#include "definitions.h"

// Initialization interface for any devices, streams and other structures that might be initialized at kernel startup

// Init all stuff needed for normal kernel working, default i/o streams(stdio, stdout, stderr), memory allocator and so on
Status init_kernel();

// Init keyboard, display and disk driver
Status init_io_devices();
// Init stdio, stdout, stderr, should be called 
Status init_io_streams();

// Init memory allocator
Status init_memory();
// Init user space handler
Status init_userspace();
