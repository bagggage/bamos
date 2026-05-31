//! # Nvidia open-gpu-kernel-module driver port

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const c = @cImport(
    @cInclude("nvstatus.h")
);

pub const NvU32 = c.NvU32;
pub const NV_STATUS = c.NV_STATUS;

pub fn init() !void {
}

export fn os_cond_acquire_rwlock_write() callconv(.c) NV_STATUS {
    return 0;
}