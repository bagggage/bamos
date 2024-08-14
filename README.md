# BamOS

It is an open-source operating system project written in the Zig programming language.

BamOS does not introduce new standards but strives for the best possible implementation of existing ones.

## Overview

The main feature and goal of this project is to develop a lightweight and extremely fast operating system with a well-documented, concise, and simple codebase, as much as possible.

It aims to include native support for multiple system ABIs between the kernel and user space (GNU/Linux, Windows NT, etc.) simultaneously. This should significantly improve the user experience and simplify the work for software developers.

## Why Zig?

Despite the familiar and established languages like C/C++ or the possibly safer Rust, our choice is Zig.

Zig is simple enough to be more maintainable than Rust while offering a safer and more functional alternative to C/C++. Zig allows generating high-speed and optimized machine code, and one of its main advantages is the build system, which makes the compilation process seamless and incredibly simple.

To create a kernel executable, all you need is the source code, the Zig compiler, and the command `zig build kernel`.

## Documentation

The kernel documentation is available on [this page](https://bagggage.github.io/bamos/). If you want to generate the documentation locally, run the following command:

```bash
zig build docs
```

A static site will be placed in the `docs` directory, which can then be launched using:

```bash
cd docs
python -m http.server
```

The Zig language description and documentation for its standard library can be found on the [official website](https://ziglang.org/).

## Building from Source

The build process is quite straightforward:

- Before you begin, ensure that the Zig compiler version [0.13.0](https://ziglang.org/download/) is installed on your workstation.

```bash
git clone https://github.com/bagggage/bamos.git
cd bamos
zig build kernel --release=[small|safe|fast]
```

By default, the build result will be located in the `.zig-out` directory. To specify a different path, use the `--prefix=[path]` option during the build.

## Creating an Image

Currently, the OS relies on the third-party [BOOTBOOT](https://gitlab.com/bztsrc/bootboot) bootloader, and the `mkbootimg` utility is used to create the image. In the future, this stage is planned to be simplified and made more cross-platform. However, for now, to create an image, you need to:

- Obtain the [BOOTBOOT](https://gitlab.com/bztsrc/bootboot) binaries.
- Specify the path to the `bootboot/dist` directory by setting the `BOOTBOOT` variable in `env.sh`.
- Run `iso.sh`.

By default, the image will be placed in the `dist` directory.

## Details

BamOS is at an early stage of development, and many things are not yet implemented. Moreover, writing the implementation and developing the operating system architecture requires an iterative approach to find the best solutions, so some details may change, but this is all for the better.

## Current Status

- The operating system supports the x86-64 architecture.
- A virtual memory management system is implemented.
- Implementations of fast and efficient allocators: physical pages, objects, and a universal allocator are present.
- Logging system and text output to the screen.
- Handling of hardware exceptions.

## Planned Features

- Development of device management architecture in the system.
- Implementation of an interrupt handling system.
- PCI bus device driver.
- Porting the NVMe driver from the `draft-c` branch.
- Implementation of drivers for other solid-state storage standards.
- Development and implementation of a virtual file system architecture.
- Implementation of various file system drivers (ext2..4, NTFS, FAT32, etc.).
- Development and implementation of process architecture, scheduling.
- Development and implementation of system call architecture and kernel-process interaction with support for various ABIs.
- And much more...