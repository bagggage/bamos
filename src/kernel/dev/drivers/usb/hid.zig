//! # Human Interface Device driver

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../../dev.zig");
const log = std.log.scoped(.@"usb.hid");
const sched = @import("../../../sched.zig");
const sys = @import("../../../sys.zig");
const usb = dev.usb;
const vm = @import("../../../vm.zig");

const Input = dev.classes.Input;

const Protocol = enum(u8) {
    keyboard = 1,
    mouse = 2,
    _,
};

const Descriptor = opaque {
    const Header = usb.Descriptor.Header;
    const Type = usb.Descriptor.Type;

    const Hid = extern struct {
        header: Header,
        hid_version: usb.BCD.Version,

        country_code: u8,
        num_descriptors: u8,
        desc_type: Type,
        desc_length: u16 align(1),
        opt_desc_type: Type,
        opt_desc_length: u16 align(1),
    };
};

const Device = struct {
    input: Input = undefined,

    usb_dev: *usb.Device,
    intr_pipe: usb.Pipe,

    pub fn setup(self: *Device, usb_dev: *usb.Device) usb.Error!void {
        const config = usb_dev.activeConfig();
        const interface = config.getInterface(0);

        const hid_desc = interface.getDescriptorAs(
            Descriptor.Hid, .hid, 0
        ) orelse return error.InvalidArgs;
        log.info("hid device: {any}", .{hid_desc});

        const intr_ep = interface.findEndpoint(.interrupt, 0) orelse return error.InvalidArgs;
        log.info("endpoint: {any}", .{intr_ep});

        self.* = .{
            .usb_dev = usb_dev,
            .intr_pipe = try usb_dev.createPipe(intr_ep.asPayload()),
        };
    }
};

var driver: usb.Driver = .init(
    "usb-hid",
    .{
        .probe = .{ .universal = &probe },
        .remove = &remove,
    },
    .{
        .mask = .{ .class = true, .subclass = true, .if_class = true },
        .class = .interface,
        .subclass = 0,
        .if_class = .hid,
    },
);

pub fn init() !void {
    try dev.registerDriver("usb", &driver.base);
}

fn probe(device: *dev.Device) dev.Driver.Operations.ProbeResult {
    const usb_dev = usb.Device.from(device);
    const hid_dev = vm.gpa.create(Device) orelse return .no_resources;

    if (true) return .missmatch;

    hid_dev.setup(usb_dev) catch |err| {
        log.err("failed to probe USB HID device: {t}", .{err});
        vm.gpa.free(hid_dev);

        return if (err == error.NoMemory) .no_resources else .failed;
    };

    log.debug("interrupt pipe is created", .{});
    return .success;
}

fn remove(device: *dev.Device) void {
    _ = device;
}
