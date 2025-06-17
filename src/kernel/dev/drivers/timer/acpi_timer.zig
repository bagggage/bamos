//! # ACPI timer driver

const std = @import("std");

const acpi = dev.acpi;
const dev = @import("../../../dev.zig");
const Timer = dev.classes.Timer;
const log = std.log.scoped(.acpi_pm);

const device_name = "acpi_pm";
const frequency_hz = 3_579_545;

var vtable: Timer.VTable = .{
    .getCounter = undefined
};

var base: usize = undefined;
var timer: ?*Timer = null;

pub fn init() void {
    if (isAvailable() == false) return;

    initDevice(dev.getKernelDriver()) catch |err| {
        log.err("initialization failed: {s}", .{@errorName(err)});
        timer = null;
    };
}

pub inline fn getObject() ?*Timer {
    return timer;
}

inline fn isAvailable() bool {
    return acpi.getFadt().pm_timer_len == 4;
}

fn initDevice(self: *const dev.Driver) !void {
    const device = try self.addDevice(dev.nameOf(device_name), null);
    errdefer dev.removeDevice(device);

    try initTimer();
    errdefer deinitTimer();

    const obj = try dev.obj.new(Timer);
    errdefer dev.obj.free(Timer, obj);

    obj.init(
        device, &vtable,
        frequency_hz, .system_high,
        .periodic, .periodic
    );
    obj.mask = calcCounterMask();

    try dev.obj.add(Timer, obj);
    timer = obj;
}

fn initTimer() !void {
    const fadt = acpi.getFadt();
    var is_mmio = false;

    if (fadt.pm_timer_blk != 0) {
        // Use `pm_timer_blk`
        base = fadt.pm_timer_blk;
        vtable.getCounter = &getCounterPio;
    } else {
        // Use `x_pm_timer_blk`
        base = fadt.x_pm_timer_blk.address;
        switch (fadt.x_pm_timer_blk.addr_space) {
            .system_io => vtable.getCounter = &getCounterPio,
            .system_mem => {
                is_mmio = true;
                vtable.getCounter = &getCounterMmio;
            },
            else => return error.UnsupportedAddressSpace
        }
    }

    if (is_mmio) {
        _ = dev.io.request(device_name, base, @sizeOf(u32), .mmio)
            orelse return error.IoUnavailable;
    } else {
        _ = dev.io.request(device_name, base, @sizeOf(u32), .io_ports)
            orelse return error.IoUnavailable;
    }
}

fn deinitTimer() void {
    // Check address space
    if (vtable.getCounter == &getCounterPio) {
        dev.io.release(base, .io_ports);
    } else {
        dev.io.release(base, .mmio);
    }
}

inline fn calcCounterMask() u64 {
    return if ((acpi.getFadt().flags & 256) != 0) std.math.maxInt(u32) else std.math.maxInt(u24);
}

fn getCounterPio(_: *const Timer) usize {
    return dev.io.inl(@truncate(base));
}

fn getCounterMmio(_: *const Timer) usize {
    return dev.io.readl(base);
}