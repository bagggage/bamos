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

/// USB Device identification structure for driver matching.
pub const Id = struct {
    pub const any = 0xffff;

    vendor_id: u16 = any,
    product_id: u16 = any,
    device_class: ?DeviceClass = null,
    device_subclass: ?u8 = null,
    device_protocol: ?u8 = null,
    interface_class: ?InterfaceClass = null,
    interface_subclass: ?u8 = null,
    interface_protocol: ?u8 = null,
};

/// USB Device Class codes (bDeviceClass)
pub const DeviceClass = enum(u8) {
    /// Device class is determined by interface descriptors
    @"interface" = 0x00,
    /// Audio device class
    audio = 0x01,
    /// Communications device class (CDC)
    communications = 0x02,
    /// Human Interface Device class (HID)
    hid = 0x03,
    /// Physical device class
    physical = 0x05,
    /// Image device class
    image = 0x06,
    /// Printer device class
    printer = 0x07,
    /// Mass Storage device class
    mass_storage = 0x08,
    /// Hub device class
    hub = 0x09,
    /// CDC-Data device class
    cdc_data = 0x0a,
    /// Smart Card device class
    smart_card = 0x0b,
    /// Content Security device class
    content_security = 0x0d,
    /// Video device class
    video = 0x0e,
    /// Personal Healthcare device class
    personal_healthcare = 0x0f,
    /// Audio/Video device class
    av = 0x10,
    /// Billboard device class
    billboard = 0x11,
    /// USB Type-C Bridge device class
    type_c_bridge = 0x12,
    /// Bulk Display device class
    bulk_display = 0x13,
    /// USB3 Vision device class
    usb3_vision = 0x14,
    /// Industrial device class
    industrial = 0x16,
    /// Authentication device class
    authentication = 0x1c,
    /// Diagnostic device class
    diagnostic = 0xdc,
    /// Wireless controller device class
    wireless_controller = 0xe0,
    /// Miscellaneous device class
    miscellaneous = 0xef,
    /// Application-specific device class
    application_specific = 0xfe,
    /// Vendor-specific device class
    vendor_specific = 0xff,
    
    _,
};

/// USB Interface Class codes (bInterfaceClass)
pub const InterfaceClass = enum(u8) {
    /// Interface class is determined by class-specific descriptors
    @"interface" = 0x00,
    /// Audio device interface
    audio = 0x01,
    /// Communications device interface (CDC)
    communications = 0x02,
    /// HID interface
    hid = 0x03,
    /// Physical device interface
    physical = 0x05,
    /// Image device interface
    image = 0x06,
    /// Printer device interface
    printer = 0x07,
    /// Mass Storage interface
    mass_storage = 0x08,
    /// Hub device interface
    hub = 0x09,
    /// CDC-Data interface
    cdc_data = 0x0a,
    /// Smart Card interface
    smart_card = 0x0b,
    /// Content Security interface
    content_security = 0x0d,
    /// Video device interface
    video = 0x0e,
    /// Personal Healthcare interface
    personal_healthcare = 0x0f,
    /// Audio/Video interface
    av = 0x10,
    /// Billboard interface
    billboard = 0x11,
    /// USB Type-C Bridge interface
    type_c_bridge = 0x12,
    /// Bulk Display interface
    bulk_display = 0x13,
    /// USB3 Vision interface
    usb3_vision = 0x14,
    /// Industrial device interface
    industrial = 0x16,
    /// Authentication device interface
    authentication = 0x1c,
    /// Diagnostic device interface
    diagnostic = 0xdc,
    /// Wireless controller interface
    wireless_controller = 0xe0,
    /// Miscellaneous device interface
    miscellaneous = 0xef,
    /// Application-specific interface
    application_specific = 0xfe,
    /// Vendor-specific interface
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

/// USB device address information
pub const AddressInfo = struct {
    /// USB address assigned by host controller (1-127)
    address: u7,
    /// Port number on the parent hub (1-15)
    port: u4,
    /// Slot/segment identifier for xHCI
    slot_id: u8,
    /// Parent device (null for root hub devices)
    parent: ?*Device = null,
    /// Hub address this device is connected through (0 for root)
    hub_address: u7 = 0,
    /// Hub port this device is connected to
    hub_port: u4 = 0,
};

pub const Descriptor = opaque {
    pub const Type = enum(u8) {
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
        superspeed_usb_endpoint_companion = 48
    };

    pub const Header = extern struct {
        length: u8,
        @"type": Type,
    };
};

// ============================================================================
// USB Device Configuration Descriptor
// ============================================================================

/// USB Device descriptor (minimal representation)
pub const DeviceDescriptor = extern struct {
    header: Descriptor.Header,
    /// USB specification version (BCD)
    usb_version: u16,
    /// Device class code
    device_class: u8,
    /// Device subclass code
    device_subclass: u8,
    /// Device protocol code
    device_protocol: u8,
    /// Maximum packet size for endpoint 0
    max_packet_size: u8,
    /// Vendor ID
    vendor_id: u16,
    /// Product ID
    product_id: u16,
    /// Device release number (BCD)
    device_version: u16,
    /// Index of manufacturer string
    manufacturer_str: u8,
    /// Index of product string
    product_str: u8,
    /// Index of serial number string
    serial_str: u8,
    /// Number of possible configurations
    num_configurations: u8,
};

/// USB Configuration descriptor (minimal representation)
pub const ConfigurationDescriptor = extern struct {
    header: Descriptor.Header,
    /// Total length of this configuration (including all descriptors)
    total_length: u16,
    /// Number of interfaces in this configuration
    num_interfaces: u8,
    /// Configuration value (1-255)
    configuration_value: u8,
    /// Configuration string index
    configuration_str: u8,
    /// Configuration attributes
    attributes: u8,
    /// Maximum power consumption (in 2mA units)
    max_power: u8,
};

/// USB Interface descriptor (minimal representation)
pub const InterfaceDescriptor = extern struct {
    header: Descriptor.Header,
    /// Interface number (0-based)
    interface_number: u8,
    /// Alternate setting number
    alternate_setting: u8,
    /// Number of endpoints in this interface
    num_endpoints: u8,
    /// Interface class
    interface_class: u8,
    /// Interface subclass
    interface_subclass: u8,
    /// Interface protocol
    interface_protocol: u8,
    /// Interface string index
    interface_str: u8,
};

/// USB Endpoint descriptor
pub const EndpointDescriptor = extern struct {
    header: Descriptor.Header,
    /// Endpoint address (direction + number)
    address: u8,
    /// Endpoint attributes (transfer type)
    attributes: u8,
    /// Maximum packet size
    max_packet_size: u16,
    /// Polling interval (in frames or microframes)
    interval: u8,

    /// Get the transfer type from attributes
    pub fn transferType(self: *const EndpointDescriptor) TransferType {
        return @enumFromInt(@as(u2, @truncate(self.attributes)));
    }

    /// Check if this is an IN endpoint
    pub fn isIn(self: *const EndpointDescriptor) bool {
        return (self.address & 0x80) != 0;
    }

    /// Get the endpoint number (0-15)
    pub fn number(self: *const EndpointDescriptor) u4 {
        return @truncate(self.address & 0x0f);
    }
};

/// Active USB configuration state
pub const ActiveConfig = struct {
    /// Configuration descriptor
    config: ConfigurationDescriptor,
    /// Interface descriptors
    interfaces: []InterfaceDescriptor,
    /// Endpoint descriptors
    endpoints: []EndpointDescriptor,
};

// ============================================================================
// USB Device State
// ============================================================================

/// USB device state
pub const DeviceState = enum {
    /// Device is not attached
    detached,
    /// Device is attached but not addressed
    attached,
    /// Device is powered but not reset
    powered,
    /// Device has been reset
    default,
    /// Device has received address
    address,
    /// Device is configured
    configured,
    /// Device has been suspended
    suspended,
};

pub const DeviceRequest = extern struct {
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

    @"type": Type,
    code: Code,
    value: u16,
    index: u16,
    length: u16,
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

// ============================================================================
// USB Device Structure
// ============================================================================

/// USB Device structure representing a connected USB device
pub const Device = struct {
    device: *dev.Device,

    /// Device identification
    id: Id,
    
    /// USB device descriptor
    descriptor: DeviceDescriptor,
    
    /// Address information
    addr_info: AddressInfo,
    
    /// Device operating speed
    speed: Speed,
    
    /// Current device state
    state: DeviceState,
    
    /// Active configuration (null if not configured)
    active_config: ?ActiveConfig,
    
    /// Number of configurations available
    configurations: []ConfigurationDescriptor,
    
    /// Device-specific data for drivers
    data: lib.AnyData = .{},

    /// Initializes a new USB device
    pub fn init(
        descriptor: DeviceDescriptor,
        addr_info: AddressInfo,
        speed: Speed
    ) Device {
        return .{
            .device = undefined,
            .id = .{
                .vendor_id = descriptor.vendor_id,
                .product_id = descriptor.product_id,
                .device_class = @enumFromInt(descriptor.device_class),
                .device_subclass = if (descriptor.device_subclass != 0) descriptor.device_subclass else null,
                .device_protocol = if (descriptor.device_protocol != 0) descriptor.device_protocol else null,
            },
            .descriptor = descriptor,
            .addr_info = addr_info,
            .speed = speed,
            .state = .attached,
            .active_config = null,
            .configurations = &.{},
        };
    }

    pub inline fn deinit(self: *Device) void {
        // Free dynamically allocated configurations if any
        if (self.configurations.len > 0) {
            // Configuration memory should be freed by the caller
            // This is a placeholder for cleanup logic
        }
    }

    /// Get the device's vendor ID
    pub inline fn vendorId(self: *const Device) u16 {
        return self.descriptor.vendor_id;
    }

    /// Get the device's product ID
    pub inline fn productId(self: *const Device) u16 {
        return self.descriptor.product_id;
    }

    /// Get the device's device class
    pub inline fn deviceClass(self: *const Device) u8 {
        return self.descriptor.device_class;
    }

    /// Get the device's interface class (from active interface if configured)
    pub inline fn interfaceClass(self: *const Device) ?u8 {
        if (self.active_config) |cfg| {
            if (cfg.interfaces.len > 0) {
                return cfg.interfaces[0].interface_class;
            }
        }
        return null;
    }

    /// Convert from generic device to USB device
    pub inline fn from(device: *const dev.Device) *Device {
        std.debug.assert(device.bus == &bus);
        return device.driver_data.asPtr(Device) orelse unreachable;
    }

    /// Get the full path string for device naming
    pub fn getPath(self: *const Device) dev.Name {
        if (self.addr_info.hub_address == 0) {
            return dev.Name.print(
                "usb-{}.{}",
                .{ self.addr_info.slot_id, self.addr_info.port }
            ) catch unreachable;
        } else {
            return dev.Name.print(
                "usb-{}.{}.{}",
                .{ self.addr_info.slot_id, self.addr_info.hub_port, self.addr_info.port }
            ) catch unreachable;
        }
    }
};

// ============================================================================
// USB Driver Structure
// ============================================================================

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

// ============================================================================
// USB Bus Management
// ============================================================================

var bus = dev.Bus.init("usb", .{
    .match = match,
    .remove = remove,
});

var dev_oma = vm.ObjectAllocator.init(Device);

/// Initialize the USB bus subsystem
pub fn init() !void {
    dev.registerBus(&bus);

    try xhci.init();
}

fn match(driver: *const dev.Driver, device: *const dev.Device) bool {
    const usb_dev = Device.from(device);
    const usb_driver = Driver.from(driver);
    const match_id = usb_driver.match_id;

    // Match by vendor/product ID
    if (match_id.vendor_id != Id.any and match_id.vendor_id != usb_dev.id.vendor_id) {
        return false;
    }

    if (match_id.product_id != Id.any and match_id.product_id != usb_dev.id.product_id) {
        return false;
    }

    // Match by device class
    if (match_id.device_class) |mc| {
        const dev_class = usb_dev.id.device_class orelse return false;
        if (@as(u8, @intFromEnum(mc)) != @as(u8, @intFromEnum(dev_class))) {
            return false;
        }
    }

    // Match by device subclass
    if (match_id.device_subclass) |ms| {
        if (usb_dev.id.device_subclass == null or ms != usb_dev.id.device_subclass.?) {
            return false;
        }
    }

    // Match by device protocol
    if (match_id.device_protocol) |mp| {
        if (usb_dev.descriptor.device_protocol != mp) {
            return false;
        }
    }

    // Match by interface class
    if (match_id.interface_class) |ic| {
        const dev_ic = usb_dev.interfaceClass() orelse return false;
        if (@as(u8, @intFromEnum(ic)) != dev_ic) {
            return false;
        }
    }

    // Match by interface subclass
    if (match_id.interface_subclass) |is| {
        const dev_is = if (usb_dev.active_config) |cfg| 
            if (cfg.interfaces.len > 0) cfg.interfaces[0].interface_subclass else null 
        else null;
        if (dev_is == null or is != dev_is.?) {
            return false;
        }
    }

    // Match by interface protocol
    if (match_id.interface_protocol) |ip| {
        const dev_ip = if (usb_dev.active_config) |cfg| 
            if (cfg.interfaces.len > 0) cfg.interfaces[0].interface_protocol else null 
        else null;
        if (dev_ip == null or ip != dev_ip.?) {
            return false;
        }
    }

    return true;
}

fn remove(device: *dev.Device) void {
    const usb_dev = Device.from(device);

    usb_dev.deinit();
    dev_oma.free(usb_dev);
}

/// Register a new USB device on the bus
/// 
/// This function is called by host controller drivers (like XHCI)
/// to register newly enumerated devices.
pub fn addDevice(
    descriptor: DeviceDescriptor,
    addr_info: AddressInfo,
    speed: Speed,
    _: ?*dev.Device
) !*Device {
    const usb_dev = dev_oma.alloc(Device) orelse return error.NoMemory;
    usb_dev.* = Device.init(descriptor, addr_info, speed);

    errdefer dev_oma.free(usb_dev);

    const device = dev.Device.new(usb_dev.getPath(), usb_dev) orelse {
        dev_oma.free(usb_dev);
        return error.NoMemory;
    };

    usb_dev.device = device;
    bus.addDevice(device, null);

    log.debug("USB device registered: VID:PID {x:0>4}:{x:0>4}, addr={}, port={}", .{
        descriptor.vendor_id,
        descriptor.product_id,
        addr_info.address,
        addr_info.port,
    });

    return usb_dev;
}

/// Remove a USB device from the bus
pub fn removeDevice(usb_dev: *Device) void {
    bus.removeDevice(usb_dev.device);
}

/// Get the USB bus instance
pub inline fn getBus() *dev.Bus {
    return &bus;
}

/// Parse a raw device descriptor from buffer
pub fn parseDeviceDescriptor(buf: []const u8) ?DeviceDescriptor {
    if (buf.len < 18) return null;
    if (buf[0] != 18) return null;   // bLength must be 18
    if (buf[1] != 0x01) return null; // bDescriptorType must be DEVICE (1)

    return .{
        .usb_version = std.mem.readInt(u16, buf[2..4], .little),
        .device_class = buf[4],
        .device_subclass = buf[5],
        .device_protocol = buf[6],
        .max_packet_size = buf[7],
        .vendor_id = std.mem.readInt(u16, buf[8..10], .little),
        .product_id = std.mem.readInt(u16, buf[10..12], .little),
        .device_version = std.mem.readInt(u16, buf[12..14], .little),
        .manufacturer_str = buf[14],
        .product_str = buf[15],
        .serial_str = buf[16],
        .num_configurations = buf[17],
    };
}

/// Parse a raw configuration descriptor from buffer
pub fn parseConfigurationDescriptor(buf: []const u8) ?ConfigurationDescriptor {
    if (buf.len < 9) return null;
    if (buf[0] != 9) return null; // bLength must be 9
    if (buf[1] != 0x02) return null; // bDescriptorType must be CONFIGURATION (2)

    return .{
        .total_length = std.mem.readInt(u16, buf[2..4], .little),
        .num_interfaces = buf[4],
        .configuration_value = buf[5],
        .configuration_str = buf[6],
        .attributes = buf[7],
        .max_power = buf[8],
    };
}

/// Parse a raw interface descriptor from buffer
pub fn parseInterfaceDescriptor(buf: []const u8) ?InterfaceDescriptor {
    if (buf.len < 9) return null;
    if (buf[0] != 9) return null; // bLength must be 9
    if (buf[1] != 0x04) return null; // bDescriptorType must be INTERFACE (4)

    return .{
        .interface_number = buf[2],
        .alternate_setting = buf[3],
        .num_endpoints = buf[4],
        .interface_class = buf[5],
        .interface_subclass = buf[6],
        .interface_protocol = buf[7],
        .interface_str = buf[8],
    };
}

/// Parse a raw endpoint descriptor from buffer
pub fn parseEndpointDescriptor(buf: []const u8) ?EndpointDescriptor {
    if (buf.len < 7) return null;
    if (buf[0] != 7) return null; // bLength must be 7
    if (buf[1] != 0x05) return null; // bDescriptorType must be ENDPOINT (5)

    return .{
        .address = buf[2],
        .attributes = buf[3],
        .max_packet_size = std.mem.readInt(u16, buf[4..6], .little),
        .interval = buf[6],
    };
}

/// Known USB vendor names for debugging
pub const VendorNames: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ 0x0403, "FTDI" },
    .{ 0x046d, "Logitech" },
    .{ 0x04b3, "IBM" },
    .{ 0x04f2, "Chicony" },
    .{ 0x058f, "Alcor Micro" },
    .{ 0x05ac, "Apple" },
    .{ 0x0644, "Toshiba" },
    .{ 0x0781, "SanDisk" },
    .{ 0x093a, "Pixart" },
    .{ 0x0b05, "ASUS" },
    .{ 0x0c45, "Microdia" },
    .{ 0x0d8c, "C-Media" },
    .{ 0x1050, "Yubico" },
    .{ 0x13d3, "IMC Networks" },
    .{ 0x1532, "Razer" },
    .{ 0x1532, "Razer" },
    .{ 0x1b3f, "Generalplus" },
    .{ 0x1d6b, "Linux Foundation" },
    .{ 0x1e4e, "Cube" },
    .{ 0x1f28, "KYE" },
    .{ 0x2001, "D-Link" },
    .{ 0x2040, "Hauppauge" },
    .{ 0x20775, "RedMango" },
    .{ 0x2149, "ACON" },
    .{ 0x2232, "GenePix" },
    .{ 0x2304, "Pinnacle" },
    .{ 0x250f, "SHARKOON" },
    .{ 0x2516, "Super Talent" },
    .{ 0x28de, "Valve" },
    .{ 0x2b73, "Freebots" },
    .{ 0x2e24, "Semitek" },
    .{ 0x30fa, "ADS" },
    .{ 0x314b, "iOne" },
    .{ 0x3285, "Natscape" },
    .{ 0x32e9, "Wondermedia" },
    .{ 0x3540, "TopSeed" },
    .{ 0x3573, "KYO" },
    .{ 0x35e5, "ShanWan" },
    .{ 0x38f8, "SHARKOON" },
    .{ 0x3f98, "Elecom" },
    .{ 0x4098, "Coby" },
    .{ 0x413c, "Dell" },
    .{ 0x42a9, "Acer" },
    .{ 0x4348, "Winbond" },
    .{ 0x45e, "Microsoft" },
    .{ 0x46d, "Logitech" },
    .{ 0x4855, "HongKong" },
    .{ 0x4857, "HongKong" },
    .{ 0x48d0, "Consistent" },
    .{ 0x49f1, "LeapFrog" },
    .{ 0x4a4f, "Gembird" },
    .{ 0x4b4f, "Kye" },
    .{ 0x4c2d, "Medion" },
    .{ 0x4e53, "NEXCELL" },
    .{ 0x534c, "Sunplus" },
    .{ 0x534d, "MacroSilicon" },
    .{ 0x54c, "Sony" },
    .{ 0x5558, "Hue" },
    .{ 0x5610, "Huawei" },
    .{ 0x5654, "INEt" },
    .{ 0x56d, "Mediacom" },
    .{ 0x5775, "Gene" },
    .{ 0x5830, "Hampoo" },
    .{ 0x5931, "Apple" },
    .{ 0x5a63, "Bossa" },
    .{ 0x5ac8, "Apple" },
    .{ 0x5af9, "Atmel" },
    .{ 0x5c6d, "AzureWave" },
    .{ 0x5e04, "Saxa" },
    .{ 0x6000, "Macronix" },
    .{ 0x601a, "Intel" },
    .{ 0x6019, "Dexatek" },
    .{ 0x6039, "SunplusIT" },
    .{ 0x603f, "Sunplus Innovation" },
    .{ 0x6112, "Twinhan" },
    .{ 0x6171, "ATech" },
    .{ 0x6189, "WaveRider" },
    .{ 0x619f, "C3aur" },
    .{ 0x620e, "Pixart" },
    .{ 0x6240, "Rocktek" },
    .{ 0x64b7, "ArcSoft" },
    .{ 0x6557, "VTrust" },
    .{ 0x6570, "Populex" },
    .{ 0x6577, "Myron" },
    .{ 0x6578, "GenesysLogic" },
    .{ 0x6666, "Prototype" },
    .{ 0x6688, "Ironx" },
    .{ 0x6666, "Prolific" },
    .{ 0x6718, "VTech" },
    .{ 0x67b, "Sigma" },
    .{ 0x6a17, "Xiaomi" },
    .{ 0x6e47, "Sierra" },
    .{ 0x6f24, "Gearhead" },
    .{ 0x704b, "BAS" },
    .{ 0x7088, "Plugable" },
    .{ 0x73b8, "JMicron" },
    .{ 0x73ba, "Hitachi" },
    .{ 0x7401, "Chips and Media" },
    .{ 0x7458, "Pioneer" },
    .{ 0x7464, "National" },
    .{ 0x7511, "Intel" },
    .{ 0x7654, "Y Media" },
    .{ 0x7666, "Hunger" },
    .{ 0x7811, "SanDisk" },
    .{ 0x7939, "AVerMedia" },
    .{ 0x7952, "Genius" },
    .{ 0x7b36, "KYE" },
    .{ 0x7d25, "Gembird" },
    .{ 0x8086, "Intel" },
    .{ 0x8087, "Intel" },
    .{ 0x8091, "StreamUnlimited" },
    .{ 0x80a6, "Lextream" },
    .{ 0x80d5, "Aluratek" },
    .{ 0x80ee, "VirtualBox" },
    .{ 0x81b3, "Innomedia" },
    .{ 0x8201, "AirTies" },
    .{ 0x83a, "Packard Bell" },
    .{ 0x8564, "Transcend" },
    .{ 0x8579, "Arkmicro" },
    .{ 0x8613, "ITE" },
    .{ 0x8644, "USB" },
    .{ 0x8686, "Realtek" },
    .{ 0x8710, "Cavium" },
    .{ 0x8733, "Conexant" },
    .{ 0x8761, "Texas Instruments" },
    .{ 0x8777, "Alcor" },
    .{ 0x8888, "Mats" },
    .{ 0x8891, "GlobalMedia" },
    .{ 0x8bb, "CML" },
    .{ 0x8c3d, "Min input" },
    .{ 0x8d1d, "Xiaomi" },
    .{ 0x8e0e, "Hugolog" },
    .{ 0x8ff, "Sunplus" },
    .{ 0x90c8, "Longcheer" },
    .{ 0x9115, "StreamUnlimited" },
    .{ 0x93a4, "NCI" },
    .{ 0x9500, "CYpress" },
    .{ 0x9710, "Comoss" },
    .{ 0x9710, "MosChip" },
    .{ 0x99ea, "Chicony" },
    .{ 0x9a05, "Delock" },
    .{ 0x9c4e, "JESS" },
    .{ 0xa11f, "VTech" },
    .{ 0xa1d2, "Greatland" },
    .{ 0xa4a4, "A4Tech" },
    .{ 0xa535, "Seenda" },
    .{ 0xa600, "SE" },
    .{ 0xa699, "USB" },
    .{ 0xa727, "ASIX" },
    .{ 0xa72a, "GenesysLogic" },
    .{ 0xa788, "PCyes" },
    .{ 0xa7bb, "Sangha" },
    .{ 0xac40, "QEMU" },
    .{ 0xac71, "Deepoon" },
    .{ 0xace1, "Astro" },
    .{ 0xad15, "Alorium" },
    .{ 0xad7d, "Alcorlink" },
    .{ 0xae31, "INVENTEC" },
    .{ 0xb05, "ASUS" },
    .{ 0xb082, "Logitech" },
    .{ 0xb1b3, "Daval" },
    .{ 0xb512, "Samsung" },
    .{ 0xb58d, "TeVii" },
    .{ 0xb68e, "Tenx" },
    .{ 0xb71b, "NVIDIA" },
    .{ 0xb813, "Elecom" },
    .{ 0xbb4, "Belkin" },
    .{ 0xbda, "Realtek" },
    .{ 0xbe00, "Marvell" },
    .{ 0xbe43, "Qualcomm" },
    .{ 0xc003, "NVidia" },
    .{ 0xc00b, "DMI" },
    .{ 0xc046, "Creative" },
    .{ 0xc07d, "Logitech" },
    .{ 0xc0a0, "Corsair" },
    .{ 0xc18d, "Fosmon" },
    .{ 0xc1a0, "VSON" },
    .{ 0xc261, "Kingsis" },
    .{ 0xc312, "DeLuxe" },
    .{ 0xc45e, "Micro-Star" },
    .{ 0xc6a, "Sunplus" },
    .{ 0xcb26, "Juniper" },
    .{ 0xcbd2, "QEMU" },
    .{ 0xcd2c, "Huawei" },
    .{ 0xcdab, "Loon" },
    .{ 0xcf00, "Mstar" },
    .{ 0xd023, "Panasonic" },
    .{ 0xd047, "Logitech" },
    .{ 0xd157, "Mats" },
    .{ 0xd15d, "Alectronic" },
    .{ 0xd1e1, "Alcorlink" },
    .{ 0xd2a5, "Alcor" },
    .{ 0xd2d4, "Parallax" },
    .{ 0xd4d4, "N/A" },
    .{ 0xd405, "Delock" },
    .{ 0xd4b4, "LeapFrog" },
    .{ 0xd526, "Logitech" },
    .{ 0xd6a2, "Sirius" },
    .{ 0xd80b, "Logitech" },
    .{ 0xd8c0, "Logitech" },
    .{ 0xdc29, "Viante" },
    .{ 0xdc4e, "Elecom" },
    .{ 0xdd04, "Asus" },
    .{ 0xdddd, "QEMU" },
    .{ 0xdeda, "Sirius" },
    .{ 0xe056, "Sirius" },
    .{ 0xe0d3, "ShanWan" },
    .{ 0xe0e5, "Riotmicro" },
    .{ 0xe0f9, "Holtek" },
    .{ 0xe0fe, "Tenx" },
    .{ 0xe105, "zte" },
    .{ 0xe1ca, "Logitech" },
    .{ 0xe3a2, "Mats" },
    .{ 0xe369, "Genius" },
    .{ 0xe3f9, "CanoSon" },
    .{ 0xe46a, "HRC" },
    .{ 0xe536, "iPro" },
    .{ 0xe5b7, "Vizio" },
    .{ 0xe8a8, "JESS" },
    .{ 0xea61, "VIA" },
    .{ 0xec21, "Granite" },
    .{ 0xee6e, "Sirius" },
    .{ 0xf11, "Datalogic" },
    .{ 0xf182, "Elecom" },
    .{ 0xf18a, "TopSeed" },
    .{ 0xf1d0, "Spreadtrum" },
    .{ 0xf1e0, "Foxconn" },
    .{ 0xf1ec, "Genius" },
    .{ 0xf2b8, "Aukey" },
    .{ 0xf3c,  "Qualcomm" },
    .{ 0xf3c0, "Raspberry Pi" },
    .{ 0xf4a5, "Fosmon" },
    .{ 0xf55e, "Raspberry Pi" },
    .{ 0xf77f, "Qualcomm" },
    .{ 0xfb4,  "Alcor" },
    .{ 0xfcd2, "ActionStar" },
    .{ 0xfd00, "Linux Foundation" },
    .{ 0xfd45, "Hills" },
    .{ 0xfde8, "Parallax" },
    .{ 0xfe8,  "HuiJia" },
    .{ 0xfef9, "Raspberry Pi" },
    .{ 0xff78, "INFRAN" },
    .{ 0xff87, "Cherry" },
});

pub fn getVendorName(vendor_id: u16) ?[]const u8 {
    return VendorNames.get(vendor_id);
}
