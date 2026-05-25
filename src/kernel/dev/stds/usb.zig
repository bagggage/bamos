//! # USB Bus builtin driver
//!
//! This module provides USB bus abstraction and device management.
//! XHCI controllers will register devices through this interface.

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../dev.zig");
const lib = @import("../../lib.zig");
const log = std.log.scoped(.usb);
const vm = @import("../../vm.zig");
const xhci = @import("../drivers/usb/xhci.zig");

pub const Error = vm.Error || error {
    IoFailed,
};

/// USB Device identification structure for driver matching.
pub const Id = struct {
    pub const any = 0xffff;

    vendor_id: u16 = any,
    product_id: u16 = any,

    mask: packed struct (u8) {
        class: bool = false,
        subclass: bool = false,
        protocol: bool = false,
        if_class: bool = false,
        if_subclass: bool = false,
        if_protocol: bool = false,
        if_number: bool = false,
        _reserved: bool = false,
    },

    class: Class = 0,
    subclass: u8 = 0,
    protocol: u8 = 0,

    if_class: Class = 0,
    if_subclass: u8 = 0,
    if_protocol: u8 = 0,
    if_number: u8 = 0,
};

/// USB Device Class codes (bDeviceClass)
pub const Class = enum(u8) {
    /// Device class is determined by interface descriptors
    interface = 0x00,
    audio = 0x01,
    communications = 0x02,
    hid = 0x03,
    physical = 0x05,
    image = 0x06,
    printer = 0x07,
    mass_storage = 0x08,
    hub = 0x09,
    cdc_data = 0x0a,
    smart_card = 0x0b,
    content_security = 0x0d,
    video = 0x0e,
    personal_healthcare = 0x0f,
    /// Audio/Video device class
    av = 0x10,
    billboard = 0x11,
    type_c_bridge = 0x12,
    bulk_display = 0x13,
    usb3_vision = 0x14,
    industrial = 0x16,
    authentication = 0x1c,
    diagnostic = 0xdc,
    wireless_controller = 0xe0,
    miscellaneous = 0xef,
    application_specific = 0xfe,
    vendor_specific = 0xff,
    _,
};

/// USB device operating speed
pub const Speed = enum(u4) {
    unknown    = 0,
    full       = 1, // 12 Mb/s (USB 1.1)
    low        = 2, // 1.5 Mb/s (USB 1.0)
    high       = 3, // 480 Mb/s (USB 2.0)
    super      = 4, // 5 Gb/s (USB 3.0)
    super_plus = 5, // 10 Gb/s (USB 3.1+)
    _
};

/// USB endpoint transfer type
pub const TransferType = enum(u2) {
    control = 0,
    isochronous = 1,
    bulk = 2,
    interrupt = 3,
};

/// USB endpoint direction
pub const Direction = enum(u1) {
    out = 0,
    in = 1,
};

pub const AddressInfo = struct {
    address: u8,
    port: u8,
    slot_id: u8,
    hub_address: u8 = 0,
    hub_port: u8 = 0,
};

pub const BCD = packed struct(u8) {
    pub const Version = extern struct {
        minor: BCD = .{},
        major: BCD = .{},

        pub fn format(self: Version, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try self.major.format(writer);
            try writer.writeByte('.');
            try self.minor.format(writer);
        }
    };

    lo: u4 = 0,
    hi: u4 = 0,

    pub inline fn format(self: BCD, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.hi > 0) try writer.writeByte(@as(u8, '0') +% self.hi);
        try writer.writeByte(@as(u8, '0') +% self.lo);
    }
};

pub const Descriptor = opaque {
    pub const Type = enum(u8) {
        none = 0,
        device = 1,
        config = 2,
        string = 3,
        interface = 4,
        endpoint = 5,
        interface_power = 8,
        otg = 9,
        debug = 10,
        interface_association = 11,
        bos = 15,
        device_capability = 16,
        hid = 33,
        superspeed_usb_endpoint_companion = 48,
        _
    };

    pub const Header = extern struct {
        length: u8,
        @"type": Type,
    };

    pub const Device = extern struct {
        /// Content of descriptor without header
        pub const Payload = extern struct {
            usb_version: BCD.Version,

            device_class: Class,
            device_subclass: u8,
            device_protocol: u8,
            max_packet_size: u8,

            vendor_id: u16,
            product_id: u16,
            device_version: BCD.Version,

            manufacturer_str: u8,
            product_str: u8,
            serial_str: u8,

            num_configurations: u8,
        };

        header: Header,
        usb_version: BCD.Version,

        device_class: Class,
        device_subclass: u8,
        device_protocol: u8,
        max_packet_size: u8,

        vendor_id: u16,
        product_id: u16,
        device_version: BCD.Version,

        manufacturer_str: u8,
        product_str: u8,
        serial_str: u8,

        num_configurations: u8,

        pub inline fn asPayload(self: *const Descriptor.Device) *const Payload {
            return @ptrCast(&self.usb_version);
        }
    };

    pub const Configuration = extern struct {
        pub const Payload = extern struct {
            num_interfaces: u8 = 0,
            configuration_value: u8 = 0,
            configuration_str: u8 = 0,
            attributes: u8 = 0,
            max_power: u8 = 0,
        };

        header: Descriptor.Header,
        /// Total length of this configuration (including all descriptors)
        total_length: u16,
        num_interfaces: u8,
        configuration_value: u8,
        configuration_str: u8,
        attributes: u8,
        /// Maximum power consumption (in 2mA units)
        max_power: u8,
    };

    pub const Interface = extern struct {
        /// Content of descriptor without header
        pub const Payload = extern struct {
            interface_number: u8,
            alternate_setting: u8,
            num_endpoints: u8,

            interface_class: Class,
            interface_subclass: u8,
            interface_protocol: u8,
            interface_str: u8,
        };

        header: Descriptor.Header,
        interface_number: u8,
        alternate_setting: u8,
        num_endpoints: u8,

        interface_class: Class,
        interface_subclass: u8,
        interface_protocol: u8,
        interface_str: u8,
    };

    pub const Endpoint = extern struct {
        header: Descriptor.Header,
        address: u8,
        attributes: u8,
        max_packet_size: u16,
        interval: u8,
    
        /// Get the transfer type from attributes
        pub inline fn transferType(self: *const Endpoint) TransferType {
            return @enumFromInt(@as(u2, @truncate(self.attributes)));
        }
    
        /// Check if this is an IN endpoint
        pub inline fn isIn(self: *const Endpoint) bool {
            return (self.address & 0x80) != 0;
        }

        pub inline fn number(self: *const Endpoint) u4 {
            return @truncate(self.address & 0x0f);
        }
    };

    pub const String = extern struct {
        header: Header,
        value: u8,

        pub inline fn asSlice(self: *const String) []const u8 {
            return @as([*]const u8, @ptrCast(&self.value))[0..self.len()];
        }

        pub inline fn len(self: *const String) u8 {
            return self.header.length - @sizeOf(Header);
        }
    };
};

pub const ActiveConfig = struct {
    config: Descriptor.Configuration,
    interfaces: []Descriptor.Interface,
    endpoints: []Descriptor.Endpoint,
};

pub const Completion = struct {
    pub const List = std.SinglyLinkedList;
    pub const Node = List.Node;

    pub const CallbackFn = *const fn(device: lib.AnyData, ctx: lib.AnyData, data: lib.AnyData) void;

    pub const allo_config: vm.auto.Config = .{ .allocator = .oma };

    func: ?CallbackFn = null,
    ctx: lib.AnyData = .{},

    pub inline fn fromNode(node: *Node) *Completion {
        return @fieldParentPtr("node", node);
    }

    pub inline fn callback(self: *Completion, device: lib.AnyData, data: lib.AnyData) void {
        if (self.func) |func| func(device, self.ctx, data);
    }
};

/// USB Device structure representing a connected USB device
pub const Device = struct {
    pub const State = enum(u8) {
        detached = 0,
        attached = 1,
        powered = 2,
        default = 3,
        address = 4,
        configured = 5,
        suspended = 6,
    };

    pub const Request = extern struct {
        pub const Type = packed struct(u8) {
            recipient: enum(u5) {
                device = 0,
                interface = 1,
                endpoint = 2,
                other = 3,
                _
            },
            @"type": enum(u2) {
                standard = 0,
                class = 1,
                vendor = 2,
                reserved = 3
            },
            dir: enum(u1) {
                host_to_dev = 0,
                dev_to_host = 1
            }
        };

        pub const Code = enum(u8) {
            get_status = 0,
            clear_feature = 1,
            set_feature = 3,
            set_address = 5,
            get_descriptor = 6,
            set_descriptor = 7,
            get_config = 8,
            set_config = 9,
            get_interface = 10,
            set_interface = 11,
            synch_frame = 12,
            set_sel = 48,
            set_isoch_delay = 49, 
        };

        pub const Value = extern union {
            raw: u16,
            desc: extern struct {
                index: u8 = 0,
                @"type": Descriptor.Type,
            },
        };

        @"type": Type,
        code: Code,
        value: Value,
        index: u16,
        length: u16,
    };

    pub const Operations = struct {
        pub const GetDescriptorFn = *const fn (*Device, Descriptor.Type, u8, []u8) Error!void;

        get_descriptor: GetDescriptorFn,
    };

    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma,
        .capacity = 32
    };

    device: dev.Device,
    address: AddressInfo,

    desc: Descriptor.Device.Payload,
    config: Descriptor.Configuration.Payload = .{},
    interfaces: [*]Descriptor.Interface = undefined,

    host: lib.AnyData,
    data: lib.AnyData = .{},

    ops: *const Operations,

    pub fn setup(
        self: *Device,
        host: lib.AnyData,
        desc: Descriptor.Device.Payload,
        address: AddressInfo,
        ops: *const Operations,
    ) void {
        self.* = .{
            .device = .init(printName(&address), self),
            .desc = desc,
            .address = address,
            .host = host,
            .ops = ops,
        };
    }

    pub inline fn deinit(self: *Device) void {
        if (self.config.num_interfaces > 0) vm.gpa.free(self.interfaces);
        self.config.num_interfaces = 0;
    }

    pub fn identify(self: *Device) Error!void {
        var config: Descriptor.Configuration = undefined;
        const phys = vm.translateVirtToPhys(@intFromPtr(&config)).?;
        const virt: *Descriptor.Configuration = @ptrFromInt(vm.getVirtLma(phys));

        log.debug("get descriptor", .{});
        try self.getDescriptor(.config, 0, std.mem.asBytes(virt));

        log.debug("config:\n{any}\n", .{config});
        const buffer = vm.gpa.allocMany(u8, config.total_length) orelse return error.NoMemory;
        defer vm.gpa.free(buffer.ptr);

        try self.getDescriptor(.config, 0, buffer);

        var temp = buffer;
        while (true) {
            const header: *Descriptor.Header = @alignCast(@ptrCast(temp.ptr));
            //if (header.@"type" == .interface) break;
            log.debug("{*}", .{header});
            log.debug("{x:0>2}: len: {}", .{@intFromEnum(header.@"type"), header.length});

            temp = temp[header.length..];
            if (temp.len == 0) break;//return error.NoMemory;
        }

        //const interface: *Descriptor.Interface = @alignCast(@ptrCast(temp.ptr));
        //log.debug("interface:\n{any}\n", .{interface});
    }

    pub inline fn getDescriptor(
        self: *Device,
        @"type": Descriptor.Type,
        index: u8,
        buffer: []u8,
    ) Error!void {
        return self.ops.get_descriptor(self, @"type", index, buffer);
    }

    pub inline fn from(device: *dev.Device) *Device {
        std.debug.assert(device.bus == &bus);
        return @fieldParentPtr("device", device);
    }

    fn printName(address: *const AddressInfo) dev.Name {
        if (address.hub_address == 0) {
            return dev.Name.print(
                "usb-{}.{}",
                .{ address.slot_id, address.port },
            ) catch unreachable;
        } else {
            return dev.Name.print(
                "usb-{}.{}.{}",
                .{ address.slot_id, address.hub_port, address.port },
            ) catch unreachable;
        }
    }
};

/// USB Driver structure for device-specific drivers
pub const Driver = struct {
    base: dev.Driver,
    match_id: Id,

    /// Initialize a new USB driver
    pub fn init(
        comptime name: []const u8,
        comptime ops: dev.Driver.Operations,
        comptime match_id: Id
    ) Driver {
        return .{
            .base = dev.Driver.init(name, ops),
            .match_id = match_id,
        };
    }

    /// Convert from generic driver to USB driver
    pub inline fn from(driver: *const dev.Driver) *const Driver {
        return @fieldParentPtr("base", driver);
    }
};

var bus = dev.Bus.init(
    "usb",
    .{
        .match = match,
        .remove = remove,
    },
);

pub fn init() !void {
    dev.registerBus(&bus);

    try xhci.init();
}

pub fn addDevice(
    host: lib.AnyData,
    desc: Descriptor.Device,
    address: AddressInfo,
    ops: *const Device.Operations,
) Error!*Device {
    const usb_dev = vm.auto.alloc(Device) orelse return error.NoMemory;
    errdefer vm.auto.free(Device, usb_dev);

    log.debug("setup {*}", .{usb_dev});
    usb_dev.setup(host, desc.asPayload().*, address, ops);

    try usb_dev.identify();

    bus.addDevice(&usb_dev.device, null);
    return usb_dev;
}

fn match(driver: *const dev.Driver, device: *const dev.Device) bool {
    //const usb_dev = Device.from(@constCast(device));
    //const usb_driver = Driver.from(driver);
    _ = driver; _ = device;

    return true;
}

fn remove(device: *dev.Device) void {
    _ = device;
}

/// Register a new USB device on the bus
/// 
/// This function is called by host controller drivers (like XHCI)
/// to register newly enumerated devices.
//pub fn addDevice(
//    descriptor: Descriptor.Device,
//    addr_info: AddressInfo,
//) !*Device {
//}

pub inline fn getBus() *dev.Bus {
    return &bus;
}
