//! # Input subsystem

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../dev.zig");
const Input = dev.classes.Input;
const log = std.log.scoped(.@"sys.input");
const vm = @import("../vm.zig");

pub const Error = Input.Error;

const types_num = std.meta.fields(Input.Kind).len;

var devices: [types_num]Input.IList = .{ Input.IList{} } ** types_num;
var handlers: [types_num]Input.Event.Handler.List = .{ Input.Event.Handle.List{} } ** types_num;

pub fn registerDevice(device: *Input) Error!void {
    const idx = @intFromEnum(device.kind);
    devices[idx].prepend(&device.node);

    const h_list = &handlers[idx];
    const gen = h_list.ctrl.readLock();
    defer h_list.ctrl.readUnlock(gen);

    var node = h_list.head.load(.acquire);
    while (node) |n| : (node = n.next) {
        const handler = Input.Event.Handler.fromNode(n);
        const handle = try device.createHandle(handler);

        handler.handles.prepend(&handle.node);
    }

    log.debug("{s}({s}) registered", .{device.device.name.str(), device.dev_file.name.str()});
}

pub fn unregisterDevice(device: *Input) void {
    const idx = @intFromEnum(device.kind);
    _ = devices[idx].remove(&device.node);

    var node = device.handles.clear();
    while (node) |n| : (node = n.next) {
        const handle = Input.Event.Handle.fromNode(n);
        _ = handle.handler.handles.remove(&handle.node);
        vm.auto.free(Input.Event.Handle, handle);
    }

    log.debug("{s}({s}) unregistered", .{device.device.name.str(), device.dev_file.name.str()});
}

pub fn registerHandler(kind: Input.Kind, handler: *Input.Event.Handler) Error!void {
    const idx = @intFromEnum(kind);
    handlers[idx].prepend(&handler.node);

    const dev_list = &devices[idx];
    const gen = dev_list.ctrl.readLock();
    defer dev_list.ctrl.readUnlock(gen);

    var node = dev_list.head.load(.acquire);
    while (node) |n| : (node = n.next) {
        const device = Input.fromNode(n);
        const handle = try device.createHandle(handler);

        handler.handles.prepend(&handle.node);
    }
}

pub fn unregisterHandler(kind: Input.Kind, handler: *Input.Event.Handler) void {
    const idx = @intFromEnum(kind);
    _ = handlers[idx].remove(&handler.node);

    var node = handler.handles.head.load(.acquire);
    while (node) |n| {
        node = n.next;

        const handle = Input.Event.Handle.fromNode(n);
        handle.device.deleteHandle(handle);
    }
}
