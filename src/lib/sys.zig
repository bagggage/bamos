//! # Generic OS subsystems

// Copyright (C) 2025-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

pub const AddressSpace = Process.AddressSpace;
pub const FileTable = @import("sys/FileTable.zig");
pub const input = @import("sys/input.zig");
pub const limits = @import("sys/limits.zig");
pub const Process = @import("sys/Process.zig");
pub const time = @import("sys/time.zig");
