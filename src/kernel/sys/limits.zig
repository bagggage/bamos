//! # System limits, default values, and constants 

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const lib = @import("../lib.zig");

pub const default_stack_size = 2 * lib.mb_size;
pub const default_max_open_files = 1024;
pub const default_max_threads = 8192;
pub const default_max_process = 65565;

pub var max_threads = default_max_threads;
pub var max_process = default_max_process;