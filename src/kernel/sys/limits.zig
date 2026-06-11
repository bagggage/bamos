//! # System limits, default values, and constants 

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");

const default_host_name = "(none)";
var host_name_buffer: [std.os.linux.HOST_NAME_MAX:0]u8 = blk: {
    var buffer: [std.os.linux.HOST_NAME_MAX:0]u8 = undefined;
    @memcpy(buffer[0..default_host_name.len], default_host_name);

    break :blk buffer;
};

pub const default_stack_size = 2 * lib.mb_size;
pub const default_max_open_files = 1024;
pub const default_max_threads = 8192;
pub const default_max_process = 65565;

pub const max_stack_size = lib.mb_size * 32;
pub const max_args_size = lib.mb_size * 8;

pub var max_threads: u32 = default_max_threads;
pub var max_process: u32 = default_max_process;

pub var host_lock: lib.sync.Spinlock = .{};
pub var host_name: std.ArrayListUnmanaged(u8) = .{
    .capacity = host_name_buffer.len,
    .items = host_name_buffer[0..default_host_name.len],
};
