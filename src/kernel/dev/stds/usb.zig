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

pub const max_interfaces = 32;
pub const cmd_timeout_ns = std.time.ns_per_s;

pub const Error = vm.Error || error{
    InvalidArgs,
    IoFailed,
    Timeout,
};

/// USB Device identification structure for driver matching.
pub const Id = struct {
    pub const any = 0xffff;

    vendor_id: u16 = any,
    product_id: u16 = any,

    mask: packed struct(u8) {
        class: bool = false,
        subclass: bool = false,
        protocol: bool = false,
        if_class: bool = false,
        if_subclass: bool = false,
        if_protocol: bool = false,
        if_number: bool = false,
        _reserved: bool = false,
    },

    class: Class = .interface,
    subclass: u8 = 0,
    protocol: u8 = 0,

    if_class: Class = .interface,
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
    unknown = 0,
    full = 1, // 12 Mb/s (USB 1.1)
    low = 2, // 1.5 Mb/s (USB 1.0)
    high = 3, // 480 Mb/s (USB 2.0)
    super = 4, // 5 Gb/s (USB 3.0)
    super_plus = 5, // 10 Gb/s (USB 3.1+)
    _,
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
        _,
    };

    pub const Header = extern struct {
        length: u8,
        type: Type,

        pub inline fn next(self: *const Header) *Header {
            return @ptrFromInt(@intFromPtr(self) + self.length);
        }

        pub fn iterateTo(self: *const Header, idx: u8) *Header {
            var temp = self;
            for (0..idx) |_| temp = temp.next();

            return temp;
        }
    };

    pub const Device = extern struct {
        /// Content of descriptor without header
        pub const Payload = extern struct {
            usb_version: BCD.Version,

            class: Class,
            subclass: u8,
            protocol: u8,
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

        class: Class,
        subclass: u8,
        protocol: u8,
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
            total_length: u16 align(1) = 0,
            num_interfaces: u8 = 0,
            value: u8 = 0,
            string: u8 = 0,
            attributes: u8 = 0,
            max_power: u8 = 0,
        };

        header: Descriptor.Header,
        /// Total length of this configuration (including all descriptors)
        total_length: u16 align(1),
        num_interfaces: u8,
        value: u8,
        string: u8,
        attributes: u8,
        /// Maximum power consumption (in 2mA units)
        max_power: u8,
    };

    pub const Interface = extern struct {
        /// Content of descriptor without header
        pub const Payload = extern struct {
            number: u8,
            alternate_setting: u8,
            num_endpoints: u8,

            class: Class,
            subclass: u8,
            protocol: u8,
            string: u8,
        };

        header: Descriptor.Header,
        number: u8,
        alternate_setting: u8,
        num_endpoints: u8,

        class: Class,
        subclass: u8,
        protocol: u8,
        string: u8,
    };

    pub const Endpoint = extern struct {
        pub const Payload = extern struct {
            address: Address = .{},
            attributes: Attributes = .{},
            max_packet_size: u16 align(1),
            interval: u8 = 0,
        };

        pub const Address = packed struct(u8) {
            number: u4 = 0,
            rsvd: u3 = 0,
            dir: Direction = .in,
        };

        pub const Attributes = packed struct(u8) {
            type: TransferType = .control,
            payload: packed union {
                ctrl: packed struct(u6) { rsvd: u6 = 0 },
                bulk: packed struct(u6) { rsvd: u6 = 0 },
                iso: packed struct(u6) {
                    rsvd0: u2 = 0,
                    usage: enum(u2) {
                        periodic = 0,
                        notification = 1,
                        rsvd0 = 2,
                        rsvd1 = 3,
                    },
                    rsvd1: u2 = 0,
                },
                intr: packed struct(u6) {
                    sync_type: enum(u2) { none = 0, async = 1, adaptive = 2, sync = 3 },
                    usage_type: enum(u2) {
                        data = 0,
                        feedback = 1,
                        impl_data = 2,
                        rsvd = 3,
                    },
                    rsvd: u2 = 0,
                },

                comptime {
                    std.debug.assert(@bitSizeOf(@This()) == 6);
                }
            } = .{ .ctrl = .{} },
        };

        header: Descriptor.Header,
        address: Address,
        attributes: Attributes,
        max_packet_size: u16 align(1),
        interval: u8,

        pub inline fn asPayload(self: *const Descriptor.Endpoint) *const Payload {
            return @ptrCast(&self.address);
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

pub const Pipe = struct {
    endpoint: Descriptor.Endpoint.Payload,
    host: lib.AnyData = .{},
};

pub const Completion = struct {
    pub const List = std.SinglyLinkedList;
    pub const Node = List.Node;

    pub const CallbackFn = *const fn (device: lib.AnyData, ctx: lib.AnyData, data: lib.AnyData) void;

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
        addressed = 4,
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
                _,
            },
            @"type": enum(u2) {
                standard = 0,
                class = 1,
                vendor = 2,
                reserved = 3,
            },
            dir: enum(u1) {
                host_to_dev = 0,
                dev_to_host = 1,
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
                type: Descriptor.Type,
            },
        };

        type: Type,
        code: Code,
        value: Value,
        index: u16,
        length: u16,

        pub fn initSetConfiguration(config: u8) Request {
            return .{
                .type = .{
                    .@"type" = .standard,
                    .recipient = .device,
                    .dir = .host_to_dev,
                },
                .code = .set_config,
                .value = .{ .raw = config },
                .index = 0,
                .length = 0,
            };
        }

        pub fn initGetConfiguration() Request {
            return .{
                .type = .{
                    .@"type" = .standard,
                    .recipient = .device,
                    .dir = .dev_to_host,
                },
                .code = .get_config,
                .value = .{ .raw = 0 },
                .index = 0,
                .length = 1,
            };
        }

        pub fn initGetDescriptor(@"type": Descriptor.Type, len: u16, index: u8) Request {
            return .{
                .@"type" = .{
                    .@"type" = .standard,
                    .recipient = .device,
                    .dir = .dev_to_host,
                },
                .code = .get_descriptor,
                .value = .{ .desc = .{
                    .type = @"type",
                    .index = index,
                } },
                .index = 0,
                .length = len,
            };
        }
    };

    pub const Interface = struct {
        desc: *const Descriptor.Interface,
        end: usize,

        pub fn getDescriptor(self: *const Interface, @"type": Descriptor.Type, index: u8) ?*const Descriptor.Header {
            var temp = self.desc.header.next();
            var i: u8 = 0;
            while (@intFromPtr(temp) < self.end) : (temp = temp.next()) {
                if (temp.type != @"type") continue;
                if (i == index) return temp;

                i += 1;
            }

            return null;
        }

        pub inline fn getDescriptorAs(
            self: *const Interface,
            comptime T: type,
            @"type": Descriptor.Type,
            index: u8,
        ) ?*const T {
            return @ptrCast(self.getDescriptor(@"type", index) orelse return null);
        }

        pub fn nextDesciptor(self: *const Interface, curr: *const Descriptor.Header) ?*const Descriptor.Header {
            var temp = curr.next();
            while (@intFromPtr(temp) < self.end) : (temp = temp.next()) {
                if (temp.type == curr.type) return temp;
            }

            return null;
        }

        pub inline fn nextDescriptorAs(
            self: *const Interface,
            comptime T: type,
            curr: *const T,
        ) ?*const T {
            return @ptrCast(self.nextDesciptor(&curr.header) orelse return null);
        }

        pub fn findEndpoint(self: *const Interface, @"type": TransferType, index: u8) ?*const Descriptor.Endpoint {
            var temp = self.getDescriptorAs(Descriptor.Endpoint, .endpoint, 0) orelse return null;

            var i: u8 = 0;
            while (true) : (temp = self.nextDescriptorAs(Descriptor.Endpoint, temp) orelse return null) {
                if (temp.attributes.type != @"type") continue;
                if (i == index) return temp;

                i += 1;
            }
        }
    };

    pub const Config = struct {
        desc: *Descriptor.Configuration,

        pub inline fn findDescriptor(self: Config, @"type": Descriptor.Type, index: u8) ?*const Descriptor.Header {
            const end = @intFromPtr(self.desc) + self.desc.total_length;
            var temp = self.desc.header.next();

            var i: u8 = 0;
            while (@intFromPtr(temp) < end) : (temp = temp.next()) {
                if (temp.type != @"type") continue;
                if (i == index) return temp;

                i += 1;
            }

            return null;
        }

        pub fn getInterface(self: Config, index: u8) Interface {
            const desc = self.findDescriptor(.interface, index).?;

            const end = @intFromPtr(self.desc) + self.desc.total_length;
            var temp = desc.next();
            while (@intFromPtr(temp) < end) : (temp = temp.next()) {
                if (temp.type == .interface) break;
            }

            return .{ .desc = @ptrCast(desc), .end = @intFromPtr(temp) };
        }
    };

    pub const Operations = struct {
        pub const SendRequestFn = *const fn (*Device, ?*Pipe, Request, []u8) Error!void;
        pub const CreatePipeFn = *const fn (*Device, *const Descriptor.Endpoint.Payload) Error!Pipe;

        send_request: SendRequestFn,
        create_pipe: CreatePipeFn,
    };

    pub const alloc_config: vm.auto.Config = .{
        .allocator = .oma,
        .capacity = 32,
    };

    device: dev.Device,
    address: AddressInfo,

    state: State = .default,
    active_config: u8 = 0,

    info: Descriptor.Device.Payload,
    configs: [*]Config = undefined,

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
        self.address = address;
        self.* = .{
            .device = .init(dev.Name.print("usb-{f}", .{self}) catch unreachable, self),
            .info = desc,
            .address = address,
            .host = host,
            .ops = ops,
        };
    }

    pub fn deinit(self: *Device) void {
        const configs = self.getConfigs();
        for (configs) |config| vm.gpa.free(config.desc);

        if (configs.len > 0) vm.gpa.free(@ptrCast(self.configs));
    }

    pub fn format(self: *const Device, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.address.hub_address == 0) {
            try writer.print("{}.{}", .{ self.address.slot_id, self.address.port });
        } else {
            try writer.print("{}.{}.{}", .{ self.address.slot_id, self.address.hub_port, self.address.port });
        }
    }

    pub inline fn from(device: *dev.Device) *Device {
        std.debug.assert(device.bus == &bus);
        return @fieldParentPtr("device", device);
    }

    pub inline fn sendControlRequest(self: *Device, request: Request, data: []u8) Error!void {
        return self.ops.send_request(self, null, request, data);
    }

    pub inline fn createPipe(self: *Device, ep: *const Descriptor.Endpoint.Payload) Error!Pipe {
        return self.ops.create_pipe(self, ep);
    }

    pub fn identify(self: *Device) Error!void {
        var header: Descriptor.Configuration align(8) = undefined;
        const config = getLmaPtr(Descriptor.Configuration, &header);

        const num = self.info.num_configurations;
        const configs = vm.gpa.allocMany(Config, num) orelse return error.NoMemory;
        errdefer vm.gpa.free(configs.ptr);

        var i: u8 = 0;
        errdefer for (0..i) |_| vm.gpa.free(configs[i].desc);

        while (i < num) : (i += 1) {
            log.debug("read config descriptor: {}", .{i});
            try self.readDescriptor(.config, i, std.mem.asBytes(config));

            const buffer = vm.gpa.allocMany(u8, config.total_length) orelse return error.NoMemory;
            errdefer vm.gpa.free(buffer.ptr);

            try self.readDescriptor(.config, i, buffer);
            configs[i].desc = @ptrCast(buffer.ptr);
        }

        self.configs = configs.ptr;
        self.state = .addressed;
    }

    pub fn setConfiguration(self: *Device, index: u8) Error!void {
        const config = &self.configs[index];
        try self.sendControlRequest(.initSetConfiguration(config.desc.value), &.{});

        self.active_config = index;
        self.state = .configured;
    }

    pub fn readDescriptor(
        self: *Device,
        @"type": Descriptor.Type,
        index: u8,
        buffer: []u8,
    ) Error!void {
        return self.sendControlRequest(
            .initGetDescriptor(@"type", @truncate(buffer.len), index),
            buffer,
        );
    }

    pub inline fn activeConfig(device: *const Device) Config {
        return device.configs[device.active_config];
    }

    pub inline fn getConfigs(device: *const Device) []const Config {
        std.debug.assert(device.state != .default);
        return device.configs[0..device.info.num_configurations];
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
        comptime match_id: Id,
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
    try @import("../drivers/usb/hid.zig").init();
}

pub inline fn getBus() *dev.Bus {
    return &bus;
}

/// Register a new USB device on the bus
///
/// This function is called by host controller drivers (like XHCI)
/// to register newly enumerated devices.
pub fn addDevice(
    host: lib.AnyData,
    desc: Descriptor.Device,
    address: AddressInfo,
    ops: *const Device.Operations,
) Error!*Device {
    const usb_dev = vm.auto.alloc(Device) orelse return error.NoMemory;
    errdefer vm.auto.free(Device, usb_dev);

    log.debug("setup device: VID: 0x{x:0>4} PID: 0x{x:0>4}", .{ desc.vendor_id, desc.product_id });
    usb_dev.setup(host, desc.asPayload().*, address, ops);

    try usb_dev.identify();
    //try usb_dev.setConfiguration(0);

    bus.addDevice(&usb_dev.device, null);

    return usb_dev;
}

fn match(driver: *const dev.Driver, device: *const dev.Device) bool {
    const usb_dev = Device.from(@constCast(device));
    const usb_driver = Driver.from(driver);
    const match_id = &usb_driver.match_id;

    log.debug("device: class: {t}, subclass: {}, protocol: {}", .{
        usb_dev.info.class,
        usb_dev.info.subclass,
        usb_dev.info.protocol,
    });

    const if_desc = usb_dev.activeConfig().getInterface(0).desc;
    log.debug("interface: class: {t}, subclass: {}, protocol: {}", .{
        if_desc.class,
        if_desc.subclass,
        if_desc.protocol,
    });

    if ((match_id.vendor_id != Id.any and
        (match_id.vendor_id != usb_dev.info.vendor_id)) or
        (match_id.product_id != Id.any and
            (match_id.product_id != usb_dev.info.product_id)) or
        (match_id.mask.class and
            (match_id.class != usb_dev.info.class)) or
        (match_id.mask.subclass and
            (match_id.subclass != usb_dev.info.subclass)) or
        (match_id.mask.protocol and
            (match_id.protocol != usb_dev.info.protocol)) or
        (match_id.mask.if_class and
            (match_id.if_class != if_desc.class)) or
        (match_id.mask.if_subclass and
            (match_id.if_subclass != if_desc.subclass)) or
        (match_id.mask.if_protocol and
            (match_id.if_protocol != if_desc.protocol))) return false;

    return true;
}

fn remove(device: *dev.Device) void {
    const usb_dev = Device.from(device);
    usb_dev.deinit();
}

inline fn getLmaPtr(comptime T: type, ptr: *T) *T {
    const phys = vm.translateVirtToPhys(@intFromPtr(ptr)).?;
    return @ptrFromInt(vm.getVirtLma(phys));
}
