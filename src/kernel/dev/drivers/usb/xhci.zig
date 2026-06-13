//! eXtensible Host Controller Interface Driver

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../../dev.zig");
const devfs = @import("../../../vfs.zig").devfs;
const lib = @import("../../../lib.zig");
const log = std.log.scoped(.xhci);
const pci = dev.pci;
const sched = @import("../../../sched.zig");
const smp = @import("../../../smp.zig");
const usb = @import("../../stds/usb.zig");
const vm = @import("../../../vm.zig");

const reset_timeout = 0xF000;

pub const TRB = extern struct {
    const Type = enum(u6) {
        normal = 1,
        setup = 2,
        data = 3,
        status = 4,
        isoch = 5,
        link = 6,
        event_data = 7,
        no_op = 8,
        enable_slot = 9,
        disable_slot = 10,
        address_device = 11,
        configure_endpoint = 12,
        evaluate_context = 13,
        reset_endpoint = 14,
        stop_endpoint = 15,
        set_tr_dequeue = 16,
        reset_device = 17,
        transfer_event = 32,
        command_completion = 33,
        port_status_change = 34,
        bandwidth_request = 35,
        doorbell_event = 36,
        host_ctrl_event = 37,
        device_notification = 38,
        mfindex_wrap = 39,
        _,
    };

    const DataField = packed union {
        ptr: u64,
        imm: packed struct { lo: u32, hi: u32 }
    };

    const StatusField = packed struct(u32) {
        length: u17 = 0,
        td_size: u5 = 0,
        interrupter: u10 = 0,

        inline fn asEventStatus(self: StatusField) EventStatus {
            return @bitCast(self);
        }
    };

    const EventStatus = packed struct(u32) {
        parameter: u24,
        completion_code: CompletionCode
    };

    const CompletionCode = enum(u8) {
        invalid               = 0,
        success               = 1,
        data_buffer_error     = 2,
        babble_detected       = 3,
        usb_transaction_error = 4,
        trb_error             = 5,
        stall_errro           = 6,
        resource_error        = 7,
        bandwidth_error       = 8,
        no_slots_available    = 9,
        invalid_stream_type   = 10,
        slot_not_enabled      = 11,
        endpoint_not_enabled  = 12,
        short_packet          = 13,
        ring_underrun         = 14,
        ring_overrun          = 15,
        vf_event_ring_full    = 16,
        parameter_error       = 17,
        bandwidth_overrun     = 18,
        context_state_error   = 19,
        no_ping_response      = 20,
        event_ring_full       = 21,
        incompatible_device   = 22,
        missed_service        = 23,
        command_ring_stopped  = 24,
        command_aborted       = 25,
        stopped               = 26,
        stop_length_invalid   = 27,
        stop_short_packet     = 28,
        max_exit_latency      = 29,
        reserved              = 30,
        isoch_buffer_overrun  = 31,
        event_lost            = 32,
        undefined_error       = 33,
        invalid_stream_id     = 34,
        @"2_bandwidth_error"  = 35,
        split_transaction     = 36,
        _
    };

    const TransferType = enum(u8) {
        no_data = 0,
        // This value is reserved in specification, but driver uses it
        // to simplify setting DIR flag when TRT field is not present.
        dir_flag = 1,
        out = 2,
        in = 3,
    };

    const ControlField = packed struct(u32) {
        cycle: u1 = undefined,
        next_trb: bool = false,
        isp: bool = false,
        no_snoop: bool = false,
        chain: bool = false,
        ioc: bool = false,
        immediate: bool = false,
        _rsvd: u2 = 0,
        bei: bool = false,
        @"type": Type,
        trt: TransferType = .no_data,
        slot_id: u8 = 0,
    };

    data: DataField = .{ .ptr = 0 },
    status: StatusField = .{},
    control: ControlField,

    pub fn initSetup(request: usb.Device.Request) TRB {
        return .{
            .data = @bitCast(request),
            .status = .{ .length = @sizeOf(DataField) },
            .control = .{
                .ioc = false,
                .immediate = true,
                .@"type" = .setup,
                .trt = .in,
            },
        };
    }

    pub fn initData(addr: u64, len: u17, dir_in: bool) TRB {
        return .{
            .data = .{ .ptr = addr },
            .status = .{ .length = len },
            .control = .{
                .ioc = true,
                .@"type" = Type.data,
                .trt = @enumFromInt(@intFromBool(dir_in)),
            },
        };
    }

    pub fn initDataImmediate(data: []const u8, dir_in: bool) TRB {
        const data_ptr: *align(4) const u64 = @alignCast(@ptrCast(data.ptr));
        return .{
            .data = .{ .imm = @bitCast(data_ptr.*) },
            .status = .{ .length = @truncate(data.len) },
            .control = .{
                .ioc = true,
                .immediate = true,
                .@"type" = Type.data,
                .trt = @enumFromInt(@intFromBool(dir_in)),
            },
        };
    }

    pub fn initStatus(dir_in: bool) TRB {
        return .{
            .control = .{
                .ioc = false,
                .@"type" = Type.status,
                .trt = @enumFromInt(@intFromBool(dir_in)),
            },
        };
    }

    pub fn initEnableSlot() TRB {
        return .{
            .control = .{
                .@"type" = .enable_slot,
                .ioc = true
            },
        };
    }

    pub fn initAddressDevice(ctx_base: u64, slot_id: u8, set_address: bool) TRB {
        return .{
            .data = .{ .ptr = ctx_base },
            .control = .{
                .bei = !set_address,
                .@"type" = .address_device,
                .slot_id = slot_id,
            }
        };
    }

    pub fn initConfigureEndpoint(ctx_base: u64, slot_id: u8) TRB {
        return .{
            .data = .{ .ptr = ctx_base },
            .control = .{
                .@"type" = .configure_endpoint,
                .slot_id = slot_id
            }
        };
    }

    pub fn initEvaluateContext(ctx_base: u64, slot_id: u8) TRB {
        return .{
            .data = .{ .ptr = ctx_base },
            .control = .{
                .@"type" = .evaluate_context,
                .slot_id = slot_id,
            }
        };
    }
};

const CommandRing = struct {
    const default_capacity = 1024;

    trbs: [*]TRB,
    size: u16,
    producer: u16 = 0,
    cycle: u1 = 1,

    fn nextProducer(self: *CommandRing) *TRB {
        const idx = self.producer;
        self.producer += 1;

        if (self.producer == self.size - 1) {
            // Toggle cycle before writing link TRB
            self.cycle ^= 1;
            self.trbs[self.size - 1].control.cycle = self.cycle;
            self.producer = 0;
        }
        return &self.trbs[idx];
    }
};

const TransferRing = struct {
    const default_size = vm.page_size / @sizeOf(TRB);
    var rq_oma: vm.ObjectAllocator = .initCapacity(@sizeOf([default_size]usb.Completion), 8);

    trbs: [*]TRB = undefined,
    requests: [*]usb.Completion = undefined,
    size: u16 = 0,
    producer: u16 = 0,
    cycle: u1 = 1,

    lock: lib.sync.Spinlock = .{},

    fn create() !TransferRing {
        const phys = vm.PageAllocator.alloc(0) orelse return error.NoMemory;
        errdefer vm.PageAllocator.free(phys, 0);
        const requests = rq_oma.alloc([default_size]usb.Completion) orelse return error.NoMemory;

        const virt = vm.getVirtLma(phys);
        const buffer: [*]usize = @ptrFromInt(virt);
        @memset(buffer[0..default_size], 0);
        @memset(&requests.*, .{});

        return .{
            .trbs = @ptrCast(buffer),
            .requests = @ptrCast(requests),
            .size = default_size,
        };
    }

    fn deinit(self: *TransferRing) void {
        if (self.size == 0) {
            @branchHint(.cold);
            return;
        }

        rq_oma.free(self.requests);

        const phys = vm.getPhysLma(self.trbs);
        vm.PageAllocator.free(phys, 0);
    }

    inline fn startTransfer(self: *TransferRing) u16 {
        self.lock.lock();
        return self.producer;
    }

    inline fn insertTrb(self: *TransferRing, trb: TRB) void {
        const dst = self.nextProducer();
        dst.* = trb;
        dst.control.cycle = self.cycle;
    }

    fn completeTransferSync(
        self: *TransferRing,
        completion_idx: u16,
        doorbell: *volatile Controller.Regs.Doorbell,
        ep: u8,
    ) TRB {
        const scheduler = sched.getCurrent();
        var sync_ctx: SyncRequest = .{ .wait = scheduler.initWait() };

        const request = &self.requests[completion_idx];
        request.* = .{
            .func = &completeRequestSync,
            .ctx = .fromPtr(&sync_ctx)
        };

        doorbell.ringEndpoint(ep);
        self.lock.unlock();

        scheduler.wait();
        return sync_ctx.complete_trb;
    }

    inline fn currentProducer(self: *TransferRing) *TRB {
        const idx = (self.producer -% 1) & (self.size -% 1);
        return &self.trbs[idx];
    }

    inline fn currentRequest(self: *TransferRing) *usb.Completion {
        const idx = (self.producer -% 1) & (self.size -% 1);
        return &self.requests[idx];
    }

    fn nextProducer(self: *TransferRing) *TRB {
        const idx = self.producer;
        self.producer += 1;

        if (self.producer == self.size -% 1) {
            // Toggle cycle before writing link TRB
            self.cycle ^= 1;
            self.trbs[self.size -% 1].control.cycle = self.cycle;
            self.producer = 0;
        }
        return &self.trbs[idx];
    }

    inline fn getRequest(self: *TransferRing, trb: *TRB) *usb.Completion {
        const idx = (@intFromPtr(trb) -% @intFromPtr(self.trbs)) / @sizeOf(TRB);
        return &self.requests[idx];
    }
};

const EventRing = struct {
    const SegmentTableEntry = extern struct {
        base_addr: u64,
        size: u16,
        _rsvd: u16 = 0,
        _rsvd_1: u32 = 0,
    };

    // Event ring would have only one physical page
    table: [1]SegmentTableEntry,
    events: [*]TRB,
    imm_handler: dev.intr.SoftHandler = undefined,
    _pad: u64 = undefined,

    size: u16,
    consumer: u16 = 0,

    cycle: u1 = 1,

    pub fn dequeue(self: *EventRing) ?*TRB {
        const event = &self.events[self.consumer];
        if (event.control.cycle != self.cycle) return null;

        self.consumer += 1;
        if (self.consumer >= self.size) {
            self.consumer = 0;
            self.cycle ^= 1;
        }

        return event;
    }

    pub fn submitionPtr(self: *const EventRing) usize {
        return vm.getPhysLma(&self.events[self.consumer]) | 0x8;
    }
};

const SyncRequest = struct {
    wait: sched.WaitQueue.Entry,
    complete_trb: TRB = .{ .control = .{
        .cycle = 0, .@"type" = @enumFromInt(0) 
    }},
};

const IoMechanism = dev.io.MmioMechanism("xhci", .dword);

const Port = opaque {
    const Regs = extern struct {
        const Group = dev.regs.Group(
            IoMechanism,
            null, null,
            dev.regs.from(Regs)
        );

        const LinkState = packed union {
            read: enum(u4) {
                u0 = 0,
                u1 = 1,
                u2 = 2,
                u3 = 3,
                disabled  = 4,
                rx_detect = 5,
                inactive  = 6,
                polling   = 7,
                recovery  = 8,
                hot_reset = 9,
                compliance = 10,
                test_mode  = 11,
                @"resume"  = 15,
                _
            },
            write: enum(u4) {
                u0_from_any    = 0,
                ignored        = 1,
                u2_usb2        = 2,
                u3_from_u0     = 3,
                rx_detect_usb3 = 5,
                compliance_usb3 = 10,
                resume_for_u3_usb2 = 15,
                _
            }
        };

        const Indicator = enum(u2) {
            off = 0,
            amber = 1,
            green = 2,
            unknown = 3,
        };

        /// PORTSC register
        const StatusControl = packed struct(u32) {
            connected: u1,
            enabled: u1,
            _rsvd: u1,
            over_current: u1,
            reset: u1,
            link_state: LinkState,
            power: u1,
            speed: usb.Speed,
            indicator: Indicator,
            link_write_strobe: u1,
            connect_change: u1,
            enable_change: u1,
            warm_reset_change: u1,
            over_current_change: u1,
            reset_change: u1,
            link_state_change: u1,
            config_error_change: u1,
            cold_attach: u1,
            wake_connect_enable: u1,
            wake_disconnect_enable: u1,
            wake_over_current_enable: u1,
            _rsvd_1: u2,
            device_removable: u1,
            warm_port_reset: u1,

            inline fn clearChanges(self: StatusControl) StatusControl {
                var mutable = self;
                mutable.enabled = 0;
                mutable.link_state = .{ .write = .ignored };

                return mutable;
            }
        };

        const PowerMngmtStatusAndControl = packed union {
            usb2: packed struct(u32) {
                l1_status: enum(u3) {
                    invalid = 0,
                    success = 1,
                    not_yet = 2,
                    not_supported = 3,
                    timeout = 4,
                    _
                },
                remote_wake: u1,
                best_effort_latency: u4,
                l1_dev_slot: u8,
                hardware_lpm: u1,
                _rsvd: u11,
                test_mode: enum(u4) {
                    disabled = 0,
                    j_state = 1,
                    k_state = 2,
                    se0_nak = 3,
                    packet = 4,
                    force_enable = 5,
                    ctrl_error = 15
                }
            },
            usb3: packed struct(u32) {
                u1_timeout: u8,
                u2_timeout: u8,
                force_link: u1,
                _rsvd: u15
            },
        };

        const LinkInfo = packed union {
            usb2: packed struct(u32) { _rsvd: u32 },
            usb3: packed struct(u32) {
                error_count: u16,
                rx_lane_count: u4,
                tx_lane_count: u4,
                _rsvd: u8
            },
        };

        const LpmControl = packed union {
            usb2: packed struct(u32) {
                hirdm: u2,
                l1_timeout: u8, // in 128us
                best_effort_latency_deep: u4,
                _rsvd: u18,
            },
            usb3: packed struct(u32) { _rsvd: u32 },
        };

        status_ctrl: StatusControl,
        power_status_ctrl: PowerMngmtStatusAndControl,
        link_info: LinkInfo,
        lpm_ctrl: LpmControl
    };
};

const Slot = struct {
    port: u8 = 0,
    status: bool = false,

    ctrl: *Controller,
    device: *usb.Device = undefined,
    in_ctx: *Context.Input = undefined,
    dev_ctx: *Context.Device = undefined,
    transfer_ring: TransferRing = .{},

    fn setup(self: *Slot, port: u8) !void {
        std.debug.assert(self.status == false);

        if (self.ctrl.port_map[port] != 0) return error.Exists;

        self.port = port;
        self.status = true;

        self.in_ctx = Context.Input.new() orelse return error.NoMemory;
        errdefer self.in_ctx.delete();
        self.dev_ctx = Context.Device.new() orelse return error.NoMemory;
        errdefer self.dev_ctx.delete();

        self.transfer_ring = try .create();
        self.ctrl.port_map[port] = self.getIndex() +% 1;
    }

    fn deinit(self: *Slot) void {
        std.debug.assert(self.status == true);

        self.device.host.setPtr(null);

        self.ctrl.port_map[self.port] = 0;
        self.status = false;
        self.transfer_ring.deinit();
        self.in_ctx.delete();
        self.dev_ctx.delete();
    }

    fn sendRequestSync(self: *Slot, request: usb.Device.Request, data: []u8) TRB {
        const idx = self.transfer_ring.startTransfer();
        const dir = request.@"type".dir == .dev_to_host;
        self.transfer_ring.insertTrb(.initSetup(request));

        if (data.len > 0) if (data.len <= @sizeOf(TRB.DataField) and !dir) {
            self.transfer_ring.insertTrb(.initDataImmediate(data, dir));
        } else {
            const phys = vm.getPhysLma(data.ptr);
            self.transfer_ring.insertTrb(.initData(phys, @truncate(data.len), dir));
        };

        self.transfer_ring.insertTrb(.initStatus(!dir));

        const doorbell = &self.ctrl.doorbells[self.getIndex() +% 1];
        return self.transfer_ring.completeTransferSync(idx +% 1, doorbell, 1);
    }

    fn updateEndpoint(self: *Slot, ep: u8) !void {
        self.in_ctx.control.add_flags = .initEmpty();
        self.in_ctx.control.add_flags.set(ep);

        const phys = vm.getPhysLma(self.in_ctx);
        const trb = self.ctrl.sendCommandSync(.initEvaluateContext(phys, ep +% 1));

        if (trb.status.asEventStatus().completion_code != .success) return error.IoFailed;
    }

    inline fn getIndex(self: *Slot) u8 {
        return @truncate((@intFromPtr(self) -% @intFromPtr(self.ctrl.slots)) / @sizeOf(Slot));
    }
};

const Context = opaque {
    const Slot = extern struct {
        const State = enum(u5) {
            disabled_enabled = 0,
            default          = 1,
            addressed        = 2,
            configured       = 3,
            _
        };

        dev_info: packed struct(u64) {
            route_string: u20,
            speed: usb.Speed,
            _rsvd: u1 = 0,
            mtt: u1,
            hub: u1,
            entries: u5,

            max_exit_latency: u16,
            root_hub_port: u8,
            ports: u8,
        },

        tt_info: packed struct(u32) {
            parent_hub_slot_id: u8,
            parent_port: u8,
            ttt: u2,
            _rsvd2: u4 = 0,
            interrupter: u10,
        },

        dev_state: packed struct(u32) {
            usb_dev_addr: u8,
            _rsvd3: u19 = 0,
            state: State,
        },

        _rsvd: [4]u32,
    };

    const Endpoint = extern struct {
        const State = enum(u3) {
            disabled = 0,
            running  = 1,
            halted   = 2,
            stopped  = 3,
            @"error" = 4,
            _
        };

        const Type = enum(u3) {
            invalid   = 0,
            isoch_out = 1,
            bulk_out  = 2,
            intr_out  = 3,
            control   = 4,
            isoch_in  = 5,
            bulk_in   = 6,
            intr_in   = 7
        };

        info: packed struct (u64) {
            state: State,
            _rsvd: u5 = 0,
            mult: u2,
            max_pstreams: u5,
            linear_stream_array: u1,
            interval: u8,
            max_esit_hi: u8,

            _rsvd2: u1 = 0,
            error_count: u2,
            @"type": Type,
            _rsvd3: u1 = 0,
            host_init_disabled: u1,
            max_burst_size: u8,
            max_packet_size: u16,
        },

        tr_dequeue_ptr: u64,

        average_trb_len: u16,
        max_esit_lo: u16,

        _rsvd: [3]u32,
    };

    const Stream = packed struct(u128) {
        const Type = enum(u3) {

        };

        tr_dequeue: packed union {
            bits: packed struct(u64) {
                cycle: u1,
                @"type": u3,
                ptr: u60,
            },
            ptr: u64
        },

        stopped_edlta: u24,
        _rsvd: u40 = 0,
    };

    const InputControl = extern struct {
        const Flags = std.bit_set.IntegerBitSet(32);

        drop_flags: Flags = .initEmpty(),
        add_flags: Flags = .initEmpty(),

        _rsvd: [5]u32,

        config: u8,
        interface: u8,
        alt_setting: u8,
        _rsvd2: u8 = 0
    };

    const Input = extern struct {
        pub const alloc_config: vm.auto.Config = .{
            .allocator = .oma,
            .capacity = 31,
        };

        control: InputControl,
        slot: Context.Slot,
        eps: [Device.max_endpoints]Endpoint,

        inline fn new() ?*Input {
            const self = vm.auto.alloc(Input) orelse return null;
            @memset(std.mem.asBytes(self), 0);

            return self;
        }

        inline fn delete(self: *Input) void {
            vm.auto.free(Input, self);
        }

        fn getTrbRing(self: *Input) []TRB {
            const trbs: [*]TRB = @ptrFromInt(@intFromPtr(self) + @sizeOf(Input));
            return trbs[0..(vm.page_size - @sizeOf(Input)) / @sizeOf(TRB)];
        }

        fn asDeviceContext(self: *Input) *Device {
            return @ptrCast(&self.slot);
        }
    };

    const Device = extern struct {
        pub const alloc_config: vm.auto.Config = .{
            .allocator = .oma,
            .capacity = 16,
        };

        const max_endpoints = 31;

        slot: Context.Slot,
        eps: [max_endpoints]Endpoint,

        inline fn new() ?*Device {
            const self = vm.auto.alloc(Device) orelse return null;
            @memset(std.mem.asBytes(self), 0);

            return self;
        }

        inline fn delete(self: *Device) void {
            vm.auto.free(Device, self);
        }
    };
};

const Controller = struct {
    const Regs = struct {
        const UsbLegacySupport = extern struct {
            const Capability = packed struct(u32) {
                id:                      u8,
                next_ext_cap_ptr:        u8,
                bios_owned_sem:          u1,
                _rsvd:                   u7,
                os_owned_sem:            u1,
                _rsvd2:                  u7,
            };

            const StatusControl = packed struct(u32) {
                usb_smi_enable:          u1,
                reserved_1:              u3,
                smi_host_sys_err_enable: u1,
                reserved_2:              u8,
                smi_os_own_enable:       u1,
                smi_pci_cmd_enable:      u1,
                smi_bar_enable:          u1,
                smi_event_intr:          u1,
                reserved_3:              u3,
                smi_host_sys_err:        u1,
                reserved_4:              u8,
                smi_os_own_change:       u1,
                smi_pci_cmd:             u1,
                smi_on_bar:              u1,
            };

            cap: UsbLegacySupport.Capability,
            sts_ctrl: UsbLegacySupport.StatusControl,
        };

        const Capability = packed struct {
            const Group = dev.regs.Group(
                IoMechanism,
                null,
                0x2000,
                dev.regs.fromWithModifier(Capability, .read)
            );

            cap_length: u8,
            _rsvd_0: u8,
            hci_version: u16,
            hcs_params1: StructuralParams1,
            hcs_params2: StructuralParams2,
            hcs_params3: StructuralParams3,
            hcc_params1: CapabilityParams1, // 0x10
            doorbell_offset: u32,
            rt_regs_offset: u32,
            hcc_params2: CapabilityParams2, // 0x1C

            comptime { std.debug.assert(@offsetOf(Capability, "hcc_params2") == 0x1c); }
        };

        /// HCSPARAMS1
        const StructuralParams1 = packed struct(u32) {
            max_slots: u8,
            max_intrs: u11,
            _rsvd: u5,
            max_ports: u8,
        };

        /// HCSPARAMS2
        const StructuralParams2 = packed struct(u32) {
            ist: u4,
            erst_max: u4,
            _rsvd: u13,
            max_scratchpad_hi: u5,
            spr: u1,
            max_scratchpad_lo: u5,
        };

        /// HCSPARAMS3
        const StructuralParams3 = packed struct(u32) {
            u1_exit_latency: u8,
            _rsvd: u8,
            u2_exit_latency: u16,
        };

        /// HCCPARAMS1
        const CapabilityParams1 = packed struct(u32) {
            ac64: u1,
            bnc: u1,
            csz: u1,
            ppc: u1,
            pind: u1,
            lhrc: u1,
            ltc: u1,
            nss: u1,
            pae: u1,
            spc: u1,
            sec: u1,
            cfc: u1,
            max_psa_size: u4,
            xecp: u16,
        };

        /// HCCPARAMS2
        const CapabilityParams2 = packed struct(u32) {
            u3c: u1,
            cmc: u1,
            fsc: u1,
            ctc: u1,
            lec: u1,
            cic: u1,
            etc: u1,
            etc_tsc: u1,
            gsc: u1,
            vtc: u1,
            _rsvd: u22,
        };

        const Operational = packed struct {
            const Group = dev.regs.Group(
                IoMechanism,
                null, null,
                dev.regs.from(Operational)  
            );

            usb_cmd: UsbCommand,
            usb_sts: UsbStatus,
            pg_size: dev.regs.ReadOnlyP(u32),
            _rsvd: u64,
            dn_ctrl: DeviceNotificationControl,
            cr_ctrl: CommandRingControl,
            _rsvd2: u128,
            dcbaa_ptr: u64,
            config: Configure,

            comptime {
                std.debug.assert(@offsetOf(Operational, "dn_ctrl") == 0x14);
                std.debug.assert(@offsetOf(Operational, "config")  == 0x38);
            }
        };

        /// USBCMD register
        const UsbCommand = packed struct(u32) {
            run: u1,
            reset: u1,
            intr_enable: u1,
            host_system_error_enable: u1,
            _rsvd: u3,
            light_reset: u1,
            save_state: u1,
            restore_state: u1,
            enable_wrap_event: u1,
            enable_u3s: u1,
            _rsvd_1: u1,
            cem_enable: u1,
            ext_tbc_enable: u1,
            ext_tbc_trb_status_enable: dev.regs.ReadOnlyP(u1),
            vtio_enable: u1,
            _rsvd_2: u15,
        };

        /// USBSTS register
        const UsbStatus = packed struct(u32) {
            halted: u1,
            _rsvd: u1,
            host_system_error: u1,
            event_interrupt: u1,
            port_change_detect: u1,
            _rsvd_1: u3,
            save_state_status: dev.regs.ReadOnlyP(u1),
            restore_state_status: dev.regs.ReadOnlyP(u1),
            save_restore_error: u1,
            controller_not_ready: dev.regs.ReadOnlyP(u1),
            host_controller_error: dev.regs.ReadOnlyP(u1),
            _rsvd_2: u19,
        };

        const DeviceNotificationControl = packed struct(u32) {
            notification_enable: u16,
            _rsvd: u16,
        };

        const CommandRingControl = packed struct(u64) {
            cycle_state: u1 = 0,
            cmd_stop: u1 = 0,
            cmd_abort: u1 = 0,
            running: dev.regs.ReadOnlyP(u1) = .{ .value = 0 },
            _rsvd: u2 = 0,

            ptr_lo: u26,
            ptr_hi: u32,
        };

        const Configure = packed struct(u32) {
            max_slots_enabled: u8,
            u3_entry_enable: u1,
            config_info_enable: u1,
            _rsvd: u22
        };

        const Runtime = extern struct {
            const Group = dev.regs.Group(
                IoMechanism,
                null, null,
                dev.regs.from(Runtime)
            );

            micro_frame_idx: dev.regs.ReadOnlyE(u32),
            _rsvd: [7]u32,
            intr: [1024]Interrupter
        };

        const Interrupter = extern struct {
            const Group = dev.regs.Group(
                IoMechanism,
                null, null,
                dev.regs.from(Interrupter)
            );

            const Managment = packed struct(u32) {
                /// Write 1 to clear
                pending: bool = true,
                enable: bool,
                _rsvd: u30 = 0,
            };

            const Moderation = packed struct(u32) {
                /// 250ns increments: 4000 ~ 1ms
                interval: u16,
                counter: u16
            };

            const DequeuePointer = packed struct(u64) {
                seg_idx: u3,
                // Write 1 to clear
                handler_busy: bool = true,
                ptr: u60
            };

            managment: Managment,
            moderation: Moderation,
            seg_table_size: u32,
            _rsvd: u32,
            seg_table_addr: u64,
            dequeue_ptr: DequeuePointer
        };

        const Doorbell = packed struct(u32) {
            target: u8 = 0,
            _rsvd: u8 = 0,
            stream_id: u16 = 0,

            inline fn ringEndpoint(self: *volatile Doorbell, target: u8) void {
                dev.io.writel(@intFromPtr(self), @bitCast(Doorbell{ .target = target }));
            }

            inline fn ringController(self: *volatile Doorbell) void {
                dev.io.writel(@intFromPtr(self), @bitCast(Doorbell{}));
            }
        };
    };

    const ExtendedCapabilities = enum(u8) {
        reserved           = 0,
        usb_legacy_support = 1,
        support_protection = 2,
        ex_power_mgmt      = 3,
        io_virt            = 4,
        msg_intr           = 5,
        local_memory       = 6,
        usb_debug          = 10,
        ex_msg_intr        = 17,
        _
    };

    const Flags = packed struct(u8) {
        halted: bool = false,
        ports_update: bool = false,
        kill_worker: bool = false,
        _reserved: u5 = 0,
    };

    cap_regs: Regs.Capability.Group,
    rt_regs_offset: u32,

    cap_len: u8,
    max_slots: u8,
    max_intrs: u8,
    max_ports: u8,

    doorbells: [*]volatile Regs.Doorbell,
    dev_ctx_ptrs: [*]u64 = undefined,

    slots: [*]Slot = undefined,
    port_map: [*]u8 = undefined,
    requests: [*]usb.Completion = undefined,

    flags: Flags = .{},
    cmd_lock: lib.sync.Spinlock = .{},
    cmd_ring: CommandRing = undefined,
    event_lock: lib.sync.Spinlock = .{},
    event_wait: sched.WaitQueue = .{},
    event_rings: [*]EventRing = undefined,
    event_worker: *sched.Task = undefined,

    pci_dev: *pci.Device,

    pub fn init(self: *Controller, pci_dev: *pci.Device) !void {
        var pci_cmd = pci_dev.config.getAs(pci.config.Regs.Command, .command);
        pci_cmd.bus_master = 1;
        pci_cmd.mem_space = 1;

        pci_dev.config.setAs(.command, pci_cmd);

        const bar = pci_dev.config.readBar(0);
        const cap_regs = try Regs.Capability.Group.initBaseSized(bar.base, bar.size);
        errdefer cap_regs.deinitSized(bar.size);

        const params = cap_regs.get(Regs.StructuralParams1, .hcs_params1);
        const params2 = cap_regs.get(Regs.StructuralParams2, .hcs_params2);
        const db_virt = cap_regs.dyn_base + cap_regs.read(.doorbell_offset);

        const slots = vm.gpa.allocMany(Slot, params.max_slots) orelse return error.NoMemory;
        errdefer vm.gpa.free(slots.ptr);

        const port_map = vm.gpa.allocMany(u8, params.max_ports) orelse return error.NoMemory;
        errdefer vm.gpa.free(port_map.ptr);

        const event_worker = try sched.Task.createWorker("xhci-event", &eventWorker, .fromPtr(self));
        errdefer event_worker.delete();

        self.* = .{
            .cap_regs = cap_regs,
            .rt_regs_offset = cap_regs.read(.rt_regs_offset),
            .cap_len = cap_regs.read(.cap_length),
            .max_slots = params.max_slots,
            .max_intrs = @truncate(@min(params.max_intrs, smp.getNum())),
            .max_ports = params.max_ports,
            .slots = slots.ptr,
            .port_map = port_map.ptr,
            .event_worker = event_worker,
            .doorbells = @ptrFromInt(db_virt),
            .pci_dev = pci_dev
        };

        const scratch_pages = (@as(u16, params2.max_scratchpad_hi) << 5) | params2.max_scratchpad_lo;

        self.biosHandoff();
        try self.stop();
        try self.reset();

        try self.initDeviceContextArray(scratch_pages);
        try self.initCommandRing();
        try self.initInterrupts();

        log.info("intr: {}, slots: {}, ports: {}, scratchpad pages: {}", .{
            params.max_intrs, self.max_slots, self.max_ports, scratch_pages
        });

        @memset(slots, .{ .ctrl = self });
        @memset(port_map, 0);

        try self.checkStatus();
        try self.start();

        for (0..self.max_ports) |port| self.updatePort(@truncate(port));
    }

    pub fn deinit(self: *Controller) void {
        self.pci_dev.releaseInterrupts();
        dev.io.release(vm.getPhysLma(self.cap_regs.dyn_base), .mmio);

        self.flags.kill_worker = true;

        const scratchpad_phys = self.dev_ctx_ptrs[0];
        if (scratchpad_phys != 0) {
            const scratchpad: [*]u64 = @ptrFromInt(vm.getVirtLma(scratchpad_phys));
            var i: u32 = 0;

            while (scratchpad[i] != 0) : (i += 1) vm.PageAllocator.free(scratchpad[i], 0);
        }
        vm.gpa.free(self.dev_ctx_ptrs);

        const cmd_rank = vm.bytesToRank(self.cmd_ring.size * @sizeOf(TRB));
        vm.PageAllocator.free(vm.getPhysLma(self.cmd_ring.trbs), cmd_rank);
        const rq_rank = vm.bytesToRank(self.cmd_ring.size * @sizeOf(usb.Completion));
        vm.PageAllocator.free(vm.getPhysLma(self.requests), rq_rank);

        for (self.event_rings[0..self.max_slots]) |*ring| {
            inline for (ring.table[0..]) |*seg| {
                const seg_rank = vm.bytesToRank(seg.size * @sizeOf(TRB));
                vm.PageAllocator.free(seg.base_addr, seg_rank);
            } 
        }

        vm.gpa.free(self.event_rings);
        vm.gpa.free(self.slots);
        vm.gpa.free(self.port_map);

        self.max_slots = 0;
    }

    inline fn getOpRegs(self: *Controller) Regs.Operational.Group {
        return self.cap_regs.referenceAt(Regs.Operational, self.cap_len);
    }

    inline fn getIntrRegs(self: *Controller, idx: u16) Regs.Interrupter.Group {
        const offset = self.rt_regs_offset + 0x20 + (@as(u32, idx) * @sizeOf(Regs.Interrupter));
        return self.cap_regs.referenceAt(Regs.Interrupter, offset);
    }

    inline fn getPortRegs(self: *Controller, idx: u8) Port.Regs.Group {
        const offset = @as(u32, self.cap_len) + 0x400 + (@as(u32, idx) * @sizeOf(Port.Regs));
        return self.cap_regs.referenceAt(Port.Regs, offset);
    }

    inline fn getRequestByCmd(self: *Controller, cmd: *TRB) *usb.Completion {
        const rq_idx = (@intFromPtr(cmd) - @intFromPtr(self.cmd_ring.trbs)) / @sizeOf(TRB);
        return &self.requests[rq_idx];
    }

    fn initDeviceContextArray(self: *Controller, scratch_pages: u32) !void {
        const dev_ctx_ptrs = vm.gpa.allocMany(u64, self.max_slots) orelse return error.NoMemory;
        errdefer vm.gpa.free(dev_ctx_ptrs.ptr);

        std.debug.assert(std.mem.isAligned(@intFromPtr(dev_ctx_ptrs.ptr), 64));
    
        @memset(dev_ctx_ptrs, 0);
        self.dev_ctx_ptrs = dev_ctx_ptrs.ptr;

        if (scratch_pages > 0) {
            const array = vm.gpa.allocMany(u64, scratch_pages) orelse return error.NoMemory;
            errdefer vm.gpa.free(array.ptr);

            for (array) |*ptr| {
                ptr.* = vm.PageAllocator.alloc(0) orelse return error.NoMemory;

                const buffer: [*]u8 = @ptrFromInt(vm.getVirtLma(ptr.*));
                @memset(buffer[0..vm.page_size], 0);
            }

            self.dev_ctx_ptrs[0] = vm.getPhysLma(array.ptr);
        }

        const op_regs = self.getOpRegs();
        op_regs.writeBits(.config, .max_slots_enabled, self.max_slots);
        dev.io.writeq(op_regs.addr(.dcbaa_ptr), vm.getPhysLma(dev_ctx_ptrs.ptr));
    }

    fn initCommandRing(self: *Controller) !void {
        const cmd_rank = vm.bytesToRank(CommandRing.default_capacity * @sizeOf(TRB));
        const size = vm.rankToBytes(cmd_rank) / @sizeOf(TRB);
        const rq_rank = vm.bytesToRank(size * @sizeOf(usb.Completion));

        const cmd_phys = vm.PageAllocator.alloc(cmd_rank) orelse return error.NoMemory;
        errdefer vm.PageAllocator.free(cmd_phys, cmd_rank);
        const rq_phys = vm.PageAllocator.alloc(rq_rank) orelse return error.NoMemory;

        self.cmd_ring = .{
            .trbs = @ptrFromInt(vm.getVirtLma(cmd_phys)),
            .size = @truncate(size),
        };
        self.requests = @ptrFromInt(vm.getVirtLma(rq_phys));

        @memset(self.cmd_ring.trbs[0..size], std.mem.zeroes(TRB));
        @memset(self.requests[0..size], std.mem.zeroes(usb.Completion));

        const crcr: Regs.CommandRingControl = .{
            .cycle_state = 1,
            .ptr_lo = @truncate(cmd_phys >> 6),
            .ptr_hi = @truncate(cmd_phys >> 32)
        };

        const op_regs = self.getOpRegs();
        op_regs.set(.cr_ctrl, crcr);
    }

    fn initInterrupts(self: *Controller) !void {
        const num = try self.pci_dev.requestInterrupts(1, self.max_intrs, .{ .msi_x = true });
        const rings = vm.gpa.allocMany(EventRing, num) orelse return error.NoMemory;
        self.event_rings = rings.ptr;

        for (rings, 0..) |*ring, i| {
            const events_len = vm.page_size / @sizeOf(TRB);
            const events_phys = vm.PageAllocator.alloc(0) orelse return error.NoMemory;
            errdefer vm.PageAllocator.free(events_phys, 0);

            try self.pci_dev.setupInterrupt(@truncate(i), intrHandler, .edge, @truncate(i));

            ring.* = .{
                .table = .{ .{ .base_addr = events_phys, .size = events_len } },
                .events = @ptrFromInt(vm.getVirtLma(events_phys)),
                .imm_handler = .init(&intrImmediateHandler, self),
                .size = events_len,
            };
            @memset(ring.events[0..events_len], std.mem.zeroes(TRB));

            const intr_regs = self.getIntrRegs(@truncate(i));
            dev.io.writeq(intr_regs.addr(.dequeue_ptr), events_phys);
            intr_regs.write(.seg_table_size, 0x1);
            dev.io.writeq(intr_regs.addr(.seg_table_addr), vm.getPhysLma(&ring.table));
            intr_regs.write(.managment, 0x3);
        }

        const op_regs = self.getOpRegs();
        op_regs.writeBits(.usb_cmd, .intr_enable, 1);

        self.event_worker.stats.static_prior = sched.Task.high_static_prior + 4;
        sched.enqueue(self.event_worker);
    }

    fn updatePort(self: *Controller, port: u8) void {
        const regs = self.getPortRegs(@truncate(port));
        var status_ctrl = regs.get(Port.Regs.StatusControl, .status_ctrl);
        if (status_ctrl.connect_change == 0 and status_ctrl.connected == 0) return;

        // Write value back to clear all change bits
        regs.set(.status_ctrl, status_ctrl.clearChanges());

        if (status_ctrl.connect_change == 1 and status_ctrl.connected == 0) {
            const slot_id = self.port_map[port];
            if (slot_id == 0) return;

            log.debug("port{}: disconnect", .{port});
            self.detachDevice(slot_id -% 1);

            return;
        }

        if (status_ctrl.enabled == 0 and status_ctrl.reset == 0) switch (status_ctrl.link_state.read) {
            .polling => { // USB2 - powered state
                log.debug("port{} (usb2): reset", .{port});
                self.resetPort(regs) catch |err| log.err("port{}: failed to reset: {t}", .{port, err});
            },
            .rx_detect => { // USB3 - failed to enable
                log.warn("port{} (usb3): failed to enable", .{port});
            },
            else => return
        };

        if (
            status_ctrl.enabled == 1 and
            ((status_ctrl.connect_change == 1 and status_ctrl.link_state.read == .u0) or
            (status_ctrl.reset_change == 1 and status_ctrl.reset == 0))
        ) {
            log.debug("port{}: attach device", .{port});
            self.attachDevice(port) catch |err| {
                log.err("failed to attach device on port{}: {t}", .{port, err});
            };
        }

        if (status_ctrl.enabled == 0) log.debug("port{} is not enabled", .{port});
    }

    fn attachDevice(self: *Controller, port: u8) !void {
        const regs = self.getPortRegs(port);
        const speed = regs.get(Port.Regs.StatusControl, .status_ctrl).speed;

        const slot_id = try self.enableSlot();
        errdefer self.disableSlot(slot_id);

        const slot = &self.slots[slot_id -% 1];
        try slot.setup(port);
        errdefer slot.deinit();

        const in_ctx = slot.in_ctx;
        const dev_ctx = slot.dev_ctx;

        // Set A0 and A1 flags
        in_ctx.control.add_flags.mask = comptime std.mem.nativeToLittle(u32, 0b11);

        in_ctx.slot.dev_info.entries = 1;
        in_ctx.slot.dev_info.root_hub_port = port + 1;
        in_ctx.slot.dev_info.ports = 0; // TODO: Check if device is hub and set correct value
        in_ctx.slot.dev_info.speed = speed;

        const ep_ctx = &in_ctx.eps[0];
        ep_ctx.info.@"type" = .control;
        ep_ctx.info.error_count = 3;
        ep_ctx.tr_dequeue_ptr = vm.getPhysLma(slot.transfer_ring.trbs) | 0x1;
        ep_ctx.info.max_packet_size = switch (speed) {
            .low => 8,
            .high => 64,
            .super,
            .super_plus => 512,
            else => 8,
        };
        ep_ctx.average_trb_len = ep_ctx.info.max_packet_size;

        self.dev_ctx_ptrs[slot_id] = vm.getPhysLma(dev_ctx);
        errdefer self.dev_ctx_ptrs[slot_id] = 0;

        var trb = self.sendCommandSync(.initAddressDevice(vm.getPhysLma(in_ctx), slot_id, true));
        if (trb.status.asEventStatus().completion_code != .success) {
            log.err("address deivce failed: p/s:{}/{} {t}", .{
                port, slot_id, trb.status.asEventStatus().completion_code
            });
            return error.IoFailed;
        }

        in_ctx.slot.dev_state.usb_dev_addr = dev_ctx.slot.dev_state.usb_dev_addr;

        var desc: usb.Descriptor.Device = undefined;
        const phys = vm.translateVirtToPhys(@intFromPtr(&desc)).?;

        trb = slot.sendRequestSync(
            .{
                .@"type" = .{
                    .@"type" = .standard,
                    .dir = .dev_to_host,
                    .recipient = .device,
                },
                .code = .get_descriptor,
                .value = .{ .desc = .{ .@"type" = .device } },
                .index = 0,
                .length = @sizeOf(usb.Descriptor.Device),
            },
            @as([*]u8, @ptrFromInt(vm.getVirtLma(phys)))[0..@sizeOf(usb.Descriptor.Device)]
        );
        if (trb.status.asEventStatus().completion_code != .success) return error.IoFailed;

        if (in_ctx.eps[0].info.max_packet_size != desc.max_packet_size) {
            log.debug("max packet size: {}", .{desc.max_packet_size});

            in_ctx.eps[0].info.max_packet_size = desc.max_packet_size;
            try slot.updateEndpoint(0);
        }

        log.debug("c: {t}, s: {}, v: 0x{x}, p: 0x{x}",
            .{desc.device_class, desc.device_subclass, desc.vendor_id, desc.product_id}
        );

        slot.device = try usb.addDevice(
            .fromPtr(slot),
            desc,
            .{
                .port = slot.port,
                .slot_id = slot.getIndex() +% 1,
                .address = slot.dev_ctx.slot.dev_state.usb_dev_addr,
                .hub_port = slot.dev_ctx.slot.dev_info.root_hub_port,
            },
            &usb_ops,
        );
    }

    fn detachDevice(self: *Controller, slot: u8) void {
        const desc = &self.slots[slot];

        usb.getBus().removeDevice(&desc.device.device);

        self.disableSlot(slot + 1);
        desc.deinit();
    }

    fn intrHandler(device: *dev.Device) bool {
        const pci_dev = pci.Device.from(device);
        const controller = pci_dev.data.asPtr(Controller) orelse return false;

        dev.intr.scheduleImmediate(&controller.event_rings[smp.getIdx()].imm_handler);

        const op_regs = controller.getOpRegs();
        op_regs.writeBits(.usb_sts, .event_interrupt, 1);

        return true;
    }

    fn intrImmediateHandler(ctx: ?*anyopaque) void {
        const controller: *Controller = @alignCast(@ptrCast(ctx.?));
        const idx = smp.getIdx();

        const ring = &controller.event_rings[idx];
        var processed = false;

        while (ring.dequeue()) |event| {
            processed = true;

            switch (event.control.@"type") {
                .port_status_change => controller.handlePortStatusChange(event),
                .command_completion => controller.handleCompletionEvent(event),
                .transfer_event => controller.handleTransferEvent(event),
                else => {}
            }
        }

        if (processed) {
            const regs = controller.getIntrRegs(idx);
            dev.io.writeq(regs.addr(.dequeue_ptr), ring.submitionPtr());
        }
    }

    fn handlePortStatusChange(self: *Controller, event: *TRB) void {
        const port: u8 = @truncate((event.data.imm.lo >> 24) - 1);

        const regs = self.getPortRegs(@truncate(port));
        const status_ctrl = regs.get(Port.Regs.StatusControl, .status_ctrl);

        _ = status_ctrl;

        self.event_lock.lockAtomic();
        defer self.event_lock.unlockAtomic();

        self.flags.ports_update = true;
        sched.awakeAll(&self.event_wait);
    }

    fn handleCompletionEvent(self: *Controller, event: *TRB) void {
        const cmd_trb: *TRB = @ptrFromInt(vm.getVirtLma(event.data.ptr));
        const request = self.getRequestByCmd(cmd_trb);

        request.callback(.fromPtr(self), .fromPtr(event));
        request.func = null;
    }

    fn handleTransferEvent(self: *Controller, event: *TRB) void {
        const setup_trb: *TRB = @ptrFromInt(vm.getVirtLma(event.data.ptr));
        const slot = &self.slots[event.control.slot_id -% 1];
        const request = slot.transfer_ring.getRequest(setup_trb);

        request.callback(.fromPtr(self), .fromPtr(event));
        request.func = null;
    }

    fn eventWorker(arg: usize) noreturn {
        const self: *Controller = @ptrFromInt(arg);
        while (!self.flags.kill_worker) {
            self.event_lock.lock();

            if (self.flags.kill_worker) {
                @branchHint(.cold);
                break;
            } else if (!self.flags.ports_update) {
                sched.waitUnlock(&self.event_wait, &self.event_lock);
                continue;
            }

            self.flags.ports_update = false;
            self.event_lock.unlock();

            for (0..self.max_ports) |port| self.updatePort(@truncate(port));
        }

        sched.terminate();
    }

    fn biosHandoff(self: *Controller) void {
        var cap = self.pci_dev.config.getCapabilities();
        while (cap) |c| : (cap = c.next()) {
            const id: ExtendedCapabilities = @enumFromInt(@intFromEnum(c.header.id));
            if (id != .usb_legacy_support) continue;

            log.info("take ownership from bios", .{});

            const regs = c.as(Regs.UsbLegacySupport);
            var cap_reg = regs.get(Regs.UsbLegacySupport.Capability, .cap);

            cap_reg.os_owned_sem = 1;
            regs.set(.cap, cap_reg);

            // Wait second with step in 10ms.
            var timeout: u32 = 0;
            while (regs.readBits(.cap, .bios_owned_sem) == 1) {
                if (timeout >= 1000) break;

                sched.sleepFor(std.time.ns_per_ms * 10);
                timeout += 10;
            }

            cap_reg = regs.get(Regs.UsbLegacySupport.Capability, .cap);
            if (cap_reg.bios_owned_sem == 1) {
                log.warn("bios won't give up, force clear smi", .{});

                cap_reg.bios_owned_sem = 0;
                cap_reg.os_owned_sem = 1;
                regs.set(.cap, cap_reg);
            }

            var sts_ctrl = regs.get(Regs.UsbLegacySupport.StatusControl, .sts_ctrl);
            sts_ctrl.usb_smi_enable = 0;
            sts_ctrl.smi_host_sys_err_enable = 0;
            sts_ctrl.smi_os_own_enable = 0;
            sts_ctrl.smi_pci_cmd_enable = 0;
            sts_ctrl.smi_bar_enable = 0;
            sts_ctrl.smi_os_own_change = 0;
            sts_ctrl.smi_pci_cmd = 0;
            sts_ctrl.smi_on_bar = 0;

            regs.set(.sts_ctrl, sts_ctrl);
            return;
        }
    }

    fn reset(self: *Controller) !void {
        const op_regs = self.getOpRegs();
        var usb_cmd = op_regs.get(Regs.UsbCommand, .usb_cmd);

        // Clear all flags
        const usb_sts = op_regs.read(.usb_sts);
        op_regs.write(.usb_sts, usb_sts);

        usb_cmd.reset = 1;
        op_regs.set(.usb_cmd, usb_cmd);

        const cnr_mask = comptime dev.regs.makeMask(Regs.UsbStatus, &.{.controller_not_ready});
        const rst_mask = comptime dev.regs.makeMask(Regs.UsbCommand, &.{.reset});
        op_regs.waitBitsClear(.usb_sts, cnr_mask, reset_timeout) catch return error.ControllerNotReady;
        op_regs.waitBitsClear(.usb_cmd, rst_mask, reset_timeout) catch return error.NotReset;
    }

    fn start(self: *Controller) !void {
        const op_regs = self.getOpRegs();

        std.debug.assert(op_regs.get(Regs.UsbStatus, .usb_sts).halted == 1);
        op_regs.writeBits(.usb_cmd, .run, 1);

        const mask = comptime dev.regs.makeMask(Regs.UsbStatus, &.{.halted});
        try op_regs.waitBitsClear(.usb_sts, mask, reset_timeout);
    }

    fn stop(self: *Controller) !void {
        const op_regs = self.getOpRegs();
        op_regs.writeBits(.usb_cmd, .run, 0);

        const mask = comptime dev.regs.makeMask(Regs.UsbStatus, &.{.halted});
        try op_regs.waitBitsSet(.usb_sts, mask, reset_timeout);
    }

    fn checkStatus(self: *Controller) !void {
        const op_regs = self.getOpRegs();
        const usb_sts = op_regs.get(Regs.UsbStatus, .usb_sts);

        if (usb_sts.host_controller_error.value != 0 or usb_sts.host_system_error != 0) {
            if (usb_sts.host_controller_error.value == 1) log.err("host controller error", .{});
            if (usb_sts.host_system_error == 1) log.err("host system error", .{});

            log.debug("{any}", .{usb_sts});
            return error.StatusError;
        }
    }

    inline fn ringDoorbell(self: *Controller) void {
        self.doorbells[0].ringController();
    }

    fn sendCommandSync(self: *Controller, trb: TRB) TRB {
        const scheduler = sched.getCurrent();
        var sync_ctx: SyncRequest = .{ .wait = scheduler.initWait() };

        {
            self.cmd_lock.lock();
            defer self.cmd_lock.unlock();

            const cmd_trb = self.cmd_ring.nextProducer();
            const request = self.getRequestByCmd(cmd_trb);

            request.* = .{
                .func = &completeRequestSync,
                .ctx = .fromPtr(&sync_ctx)
            };

            cmd_trb.* = trb;
            cmd_trb.control.cycle = self.cmd_ring.cycle;

            self.ringDoorbell();
        }

        scheduler.wait();
        return sync_ctx.complete_trb;
    }

    fn enableSlot(self: *Controller) !u8 {
        const event_trb = self.sendCommandSync(.initEnableSlot());
        const code = event_trb.status.asEventStatus().completion_code;

        if (code != .success) {
            log.warn("enable slot failed: {t}", .{code});
            return error.IoFailed;
        }

        return event_trb.control.slot_id;
    }

    fn disableSlot(self: *Controller, slot_id: u8) void {
        const event_trb = self.sendCommandSync(.{ .control = .{
            .@"type" = .disable_slot, .slot_id = slot_id
        } });
        const code = event_trb.status.asEventStatus().completion_code;

        if (code != .success) log.err("disable slot failed: {t}", .{code});
    }

    fn resetPort(_: *Controller, regs: Port.Regs.Group) !void {
        var status_ctrl = regs.get(Port.Regs.StatusControl, .status_ctrl);
        status_ctrl.reset = 1;

        regs.set(.status_ctrl, status_ctrl);

        const mask = comptime dev.regs.makeMask(Port.Regs.StatusControl, &.{.enabled});
        try regs.waitBitsSet(.status_ctrl, mask, reset_timeout);
    }
};

const usb_ops: usb.Device.Operations = .{
    .get_descriptor = &usbGetDescriptor,
};

var pci_driver = pci.Driver.init(
    "xhci",
    .{
        .probe = .{ .universal = probe },
        .remove = remove,
    },
    .{
        .class_code = .serial_bus_controller,
        .subclass = .{ .serial_bus_controller = .usb },
    }
);

pub fn init() !void {
    try dev.registerDriver("pci", &pci_driver.base);
}

fn probe(device: *dev.Device) dev.Driver.Operations.ProbeResult {
    log.info("controller: {s}", .{device.name.str()});

    const pci_dev = pci.Device.from(device);
    const controller = vm.gpa.create(Controller) orelse return .no_resources;
    pci_dev.data.setPtr(@ptrCast(controller));

    controller.init(pci_dev) catch |err| {
        log.err("initialization failed: {s}", .{@errorName(err)});

        vm.gpa.free(controller);
        pci_dev.data.setPtr(null);

        return .failed;
    };

    return .success;
}

fn remove(device: *dev.Device) void {
    const pci_dev = pci.Device.from(device);
    const controller = pci_dev.data.asPtr(Controller) orelse return;

    controller.deinit();
    vm.gpa.free(controller);
}

fn completeRequestSync(_: lib.AnyData, ctx: lib.AnyData, data: lib.AnyData) void {
    const request = ctx.asPtr(SyncRequest).?;
    const complete_trb = data.asPtr(TRB).?;

    request.complete_trb = complete_trb.*;
    _ = sched.awakeEntry(&request.wait);
}

fn usbGetDescriptor(
    device: *usb.Device,
    @"type": usb.Descriptor.Type,
    index: u8,
    buffer: []u8,
) usb.Error!void {
    const slot = device.host.asPtr(Slot).?;
    const trb = slot.sendRequestSync(.{
        .@"type" = .{
            .@"type" = .standard,
            .dir = .dev_to_host,
            .recipient = .device,
        },
        .code = .get_descriptor,
        .index = 0,
        .value = .{ .desc = .{ .@"type" = @"type", .index = index } },
        .length = @truncate(buffer.len),
    }, buffer);

    if (trb.status.asEventStatus().completion_code != .success) return error.IoFailed;
}
