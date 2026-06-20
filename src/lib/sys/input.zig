//! # Input subsystem

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const bindings = @import("../bindings.zig");
const dev = @import("../dev.zig");
const Input = dev.classes.Input;

pub const Error = Input.Error;

pub inline fn registerDevice(device: *Input) Error!void {
    return bindings.getInstance().sys.input.registerDevice(device);
}

pub inline fn unregisterDevice(device: *Input) void {
    return bindings.getInstance().sys.input.unregisterDevice(device);
}

pub inline fn registerHandler(kind: Input.Kind, handler: *Input.Event.Handler) Error!void {
    return bindings.getInstance().sys.input.registerHandler(kind, handler);
}

pub inline fn unregisterHandler(kind: Input.Kind, handler: *Input.Event.Handler) void {
    return bindings.getInstance().sys.input.unregisterHandler(kind, handler);
}
