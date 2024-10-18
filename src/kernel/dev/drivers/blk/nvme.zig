//! # NVMe Controller driver
//! 
//! - Specification: NVM Express Base Specification, Revision 2.1

const std = @import("std");

const dev = @import("../../../dev.zig");
const log = @import("../../../log.zig");
const pci = dev.pci;
const smp = @import("../../../smp.zig");
const utils = @import("../../../utils.zig");
const vm = @import("../../../vm.zig");

const Command = SubmissionEntry.Opcode;

/// specs. reference: 4.1.1
const SubmissionEntry = packed struct {
    pub const Opcode = packed union {
        pub const Admin = enum(u8) {
            delete_submission_queue = 0x00,
            create_submission_queue = 0x01,
            get_log_page = 0x02,
            delete_completion_queue = 0x04,
            create_completion_queue = 0x05,
            identify = 0x06,
            abort = 0x08,
            set_feature = 0x09,
            get_feature = 0x0A
        };
        pub const Io = enum(u8) {
            write = 0x01,
            read = 0x02,
        };

        admin: Admin,
        io: Io
    };

    opcode: Opcode,
    fused_op: enum(u2) {
        normal = 0b00,
        first_cmd_fused_op = 0b01,
        second_cmd_fused_op = 0b10,
        reserved = 0b11
    } = .normal,

    rsrvd: u4 = 0,

    psdt: enum(u2) {
        prps_used = 0b00,
    } = .prps_used,

    cmd_id: u16,

    nsid: u32,

    cmd_dword2: u32 = 0,
    cmd_dword3: u32 = 0,

    meta_ptr: u64 = 0,

    prp_entry1: u64,
    prp_entry2: u64 = 0,

    cmd_dword10: u32 = 0,
    cmd_dword11: u32 = 0,
    cmd_dword12: u32 = 0,
    cmd_dword13: u32 = 0,
    cmd_dword14: u32 = 0,
    cmd_dword15: u32 = 0,

    pub fn init(opcode: Opcode, id: u16, nsid: u32, data: ?*anyopaque, specific: []const u32) SubmissionEntry {
        var result = SubmissionEntry{
            .opcode = opcode,
            .cmd_id = id,
            .nsid = nsid,
            .prp_entry1 = if (data) |raw| @intFromPtr(raw) else 0
        };

        const ptr: [*]u32 = @ptrCast(&result.cmd_dword10);
        for (specific, 0..) |dword, i| {
            ptr[i] = dword;
        }

        return result;
    }

    comptime {
        std.debug.assert(@sizeOf(SubmissionEntry) == 64);
    }
};

/// specs. reference: 4.2.1
const CompletionEntry = packed struct {
    cmd_specific: u64,

    sq_head_ptr: u16,
    sq_id: u16,

    cmd_id: u16,

    phase_tag: u1,
    status: u15,

    comptime {
        std.debug.assert(@sizeOf(CompletionEntry) == 16);
    }
};

const SubmissionQueue = struct {
    ptr: [*]SubmissionEntry,
    size: u16,
    tail: u16 = 0,
    cmd_id: u16 = 0,

    pub fn init(buffer: []SubmissionEntry) SubmissionQueue {
        return .{
            .ptr = buffer.ptr,
            .size = @truncate(buffer.len),
        };
    }

    pub inline fn nextTail(self: *SubmissionQueue) *SubmissionEntry {
        defer {
            self.tail = (self.tail + 1) % self.size;
            self.cmd_id +%= 1;
        }
        return &self.ptr[self.tail];
    }
};

const CompletionQueue = struct {
    ptr: [*]CompletionEntry,
    size: u16,
    head: u16 = 0,
    phase_bit: u1 = 1,

    pub fn init(buffer: []CompletionEntry) CompletionQueue {
        return .{
            .ptr = buffer.ptr,
            .size = @truncate(buffer.len),
        };
    }

    pub inline fn getHead(self: *CompletionQueue) *CompletionEntry {
        return &self.ptr[self.head];
    }

    pub inline fn nextHead(self: *CompletionQueue) *CompletionEntry {
        self.head = (self.head + 1) % self.size;
        if (self.head == 0) self.phase_bit = ~self.phase_bit;

        return &self.ptr[self.head];
    }
};

const Controller = struct {
    /// specs. reference: 5.1.13.2.1, figure 312
    const Info = extern struct {
        vendor_id: u16,
        sub_vendor_id: u16,

        serial: [20]u8,
        model: [40]u8,

        firmware: [8]u8,

        rab: u8,
        ieee_out_id: [3]u8,

        cmic: u8,
        max_transfer_size: u8,

        ctrl_id: u16,
        version: u32 align(2),

        _spacing: [432]u8,

        namespaces_num: u32 align(2),
    };

    /// specs. reference: 3.1.4
    const BarRegs = struct {
        pub const Group = dev.regs.Group(
            dev.io.MmioMechanism("nvme-controller", .dword),
            null,
            0x4000,
            dev.regs.from(Layout)
        );

        /// specs. reference: 3.1.4.1
        pub const Capabilities = packed struct {
            max_queue_ents: u16,
            cont_queues_req: u1,
            arbit_mech_supp: u2,

            rsrvd: u5,

            timeout: u8,
            doorbell_stride: u4,

            nvm_subsys_reset: u1,

            cmd_sets: u8,

            rsrvd_1: u3,

            mem_page_size_min: u4,
            mem_page_size_max: u4,

            rsrvd_2: u8
        };

        /// specs. reference: 3.1.4.2
        pub const Version = packed struct {
            rsrvd: u8,
            minor: u8,
            major: u16
        };

        /// specs. reference: 3.1.4.5
        pub const Config = packed struct {
            enable: u1,

            rsrvd: u3,

            cmd_set_selected: u3,
            mem_page_size: u4,
            arbit_mech_selected: enum(u3) {
                round_robin = 0b000,
                weighted_rr_urgent = 0b001,
                vendor_specific = 0b111
            },
            shutdown_notif: enum(u2) {
                no = 0b00,
                normal_shutdown = 0b01,
                abrupt_shutdown = 0b10,
            },

            sub_queue_ent_size: u4,
            cmpl_queue_ent_size: u4,

            rsrvd_1: u8
        };

        /// specs. reference: 3.1.4.6
        pub const Status = packed struct {
            ready: u1,
            fatal_status: u1,
            shutdown_status: enum(u2) {
                normal = 0b00,
                shutdown_occuring = 0b01,
                shutdown_complete = 0b10
            },
            subsys_reset_occured: u1,

            rsrvd: u27
        };

        /// specs. reference: 3.1.4.8
        pub const AdminQueueAttributes = packed struct {
            sub_queue_size: u12,
            rsrvd: u4 = 0,

            cmpl_queue_size: u12,
            rsrvd1: u4 = 0
        };

        const Layout = packed struct {
            ctrl_cap: dev.regs.ReadOnlyP(u64),

            version: dev.regs.ReadOnlyP(u32),
            intr_mask_set: u32,

            intr_mask_clr: u32,
            ctrl_config: u32,

            _rsrvd: u32,
            ctrl_status: u32,

            nvm_subsys_reset: u32,
            aqa: u32,

            asq: u64,
            acq: u64,
        };
    };

    const sq_len = vm.page_size / @sizeOf(SubmissionEntry);
    const cq_len = vm.page_size / @sizeOf(CompletionEntry);

    bar: BarRegs.Group,
    doorbells: usize,
    doorbell_stride: u16,

    admin_lock: utils.Spinlock = utils.Spinlock.init(.unlocked),

    admin_submission: SubmissionQueue = undefined,
    admin_completion: CompletionQueue = undefined,

    io_submission: [*]SubmissionQueue = undefined,
    io_completion: [*]CompletionQueue = undefined,

    namespaces: utils.SList(Namespace) = .{},

    pub fn init(self: *Controller, pci_dev: *pci.Device) !void {
        var pci_cmd = pci_dev.config.getAs(pci.config.Regs.Command, .command);
        pci_cmd.bus_master = 1;
        pci_cmd.mem_space = 1;

        pci_dev.config.setAs(.command, pci_cmd);

        const bar = pci_dev.config.readBar(0);
        const regs = try BarRegs.Group.initBase(bar);
        errdefer dev.io.release(bar, .mmio);

        const cap = regs.get(BarRegs.Capabilities, .ctrl_cap);

        self.* = Controller{
            .bar = regs,
            .doorbells = regs.dyn_base + 0x1000,
            .doorbell_stride = @as(u16, 4) << cap.doorbell_stride
        };

        try self.reset(pci_dev, cap);
    }

    pub fn reset(self: *Controller, pci_dev: *pci.Device, cap: BarRegs.Capabilities) !void {
        var cfg = self.bar.get(BarRegs.Config, .ctrl_config);
        var status: BarRegs.Status = undefined;

        if ((cap.cmd_sets & 1) == 0) return error.NvmeCommandSetNotSupported;

        const arch_page_size = comptime std.math.log2_int(usize, vm.page_size) - 12;
        if (cap.mem_page_size_min > arch_page_size or cap.mem_page_size_max < arch_page_size) return error.UnsupportedPageSize;

        { // Disable
            cfg.enable = 0;
            self.bar.set(.ctrl_config, cfg);

            // Wait for disabling
            status = self.bar.get(BarRegs.Status, .ctrl_status);

            while (status.ready == 1) : (status = self.bar.get(BarRegs.Status, .ctrl_status)) {
                if (status.fatal_status == 1) return error.ControllerFatal;
            }
        }

        { // Configure
            cfg.mem_page_size = arch_page_size;
            cfg.cmd_set_selected = if ((cap.cmd_sets & 0x40) != 0) 0b110 else 0b000;
            cfg.arbit_mech_selected = .round_robin;
        }

        try self.initAdminQueues();
        errdefer self.deinitAdminQueues();

        { // Enable
            cfg.enable = 1;
            self.bar.set(.ctrl_config, cfg);

            // Wait for enabling
            status = self.bar.get(BarRegs.Status, .ctrl_status);

            while (status.ready == 0) : (status = self.bar.get(BarRegs.Status, .ctrl_status)) {
                if (status.fatal_status == 1) return error.ControllerFatal;
            }
        }

        const intr_num = try pci_dev.requestInterrupts(1, @truncate(smp.getNum()), .{ .msi_x = true });
        errdefer pci_dev.releaseInterrupts();

        for (0..intr_num) |intr| {
            try pci_dev.setupInterrupt(@truncate(intr), intrHandler, .edge);
        }

        try self.initIoQueues();
        try self.identify();
    }

    pub inline fn nvmReset(self: *const Controller) void {
        const reset_magic = 0x4E564D65; // "NVMe"
        self.bar.write(.nvm_subsys_reset, reset_magic);
    }

    pub fn ringDoorbell(self: *const Controller, id: u16, num: u16, comptime kind: enum{submission_tail, completion_head}) void {
        const base = self.doorbells + ((2 * id) * self.doorbell_stride);

        switch (kind) {
            .submission_tail => dev.io.writel(base, num),
            .completion_head => dev.io.writel(base + self.doorbell_stride, num)
        }
    }

    fn initAdminQueues(self: *Controller) !void {
        const pool_phys = vm.PageAllocator.alloc(1) orelse return error.NoMemory;

        const sub_phys = pool_phys;
        const cmpl_phys = pool_phys + vm.page_size;

        const sq: [*]SubmissionEntry = @ptrFromInt(vm.getVirtLma(sub_phys));
        const cq: [*]CompletionEntry = @ptrFromInt(vm.getVirtLma(cmpl_phys));

        self.admin_submission = SubmissionQueue.init(sq[0..sq_len]);
        self.admin_completion = CompletionQueue.init(cq[0..cq_len]);

        @memset(cq[0..cq_len], std.mem.zeroes(CompletionEntry));

        self.bar.set(.aqa, BarRegs.AdminQueueAttributes{
            .sub_queue_size = sq_len - 1,
            .cmpl_queue_size = cq_len - 1,
        });

        self.bar.set(.asq, sub_phys);
        self.bar.set(.acq, cmpl_phys);
    }

    fn deinitAdminQueues(self: *Controller) void {
        vm.PageAllocator.free(@intFromPtr(self.admin_submission.ptr), 1);
    }

    fn initIoQueues(self: *Controller) !void {
        const cpus_num = smp.getNum();

        const pool_pages = cpus_num * 2;
        const pool_rank = std.math.log2_int_ceil(u32, pool_pages);
        const pool_real_size = (@as(u32, 1) << @truncate(pool_rank)) * vm.page_size;

        const pool = vm.PageAllocator.alloc(pool_rank) orelse return error.NoMemory;
        const virt = vm.getVirtLma(pool);

        comptime std.debug.assert(@sizeOf(SubmissionQueue) == @sizeOf(CompletionQueue));
        const array_size = @sizeOf(SubmissionQueue) * cpus_num;

        {
            const base = virt + pool_real_size - (array_size * 2);

            self.io_submission = @ptrFromInt(base);
            self.io_completion = @ptrFromInt(base + array_size);
        }

        for (0..cpus_num) |i| {
            const base = virt + (i * 2 * vm.page_size);
            const sq_buffer: [*]SubmissionEntry = @ptrFromInt(base);
            const cq_buffer: [*]CompletionEntry = @ptrFromInt(base + vm.page_size);

            const cq_real_len = if (i != cpus_num - 1) cq_len else (
                (cq_len * @sizeOf(CompletionEntry) - array_size) / @sizeOf(CompletionEntry)
            );

            self.io_completion[i] = CompletionQueue.init(cq_buffer[0..cq_real_len]);
            self.io_submission[i] = SubmissionQueue.init(sq_buffer[0..sq_len]);

            @memset(cq_buffer[0..cq_real_len], std.mem.zeroes(CompletionEntry));

            const id: u32 = @truncate(i + 1);

            self.sendAdminCmd(0, .create_completion_queue, @ptrCast(vm.getPhysLma(cq_buffer)), &.{
                id   | (@as(u32, cq_real_len - 1) << 16), // (doorbell id) | (size - 1)
                0b11 | (@as(u32, @truncate(i)) << 16) // (phys contiguous,intr enable) | (intr vector)
            });
            self.sendAdminCmd(0, .create_submission_queue, @ptrCast(vm.getPhysLma(sq_buffer)), &.{
                id   | (@as(u32, sq_len - 1) << 16), // (doorbell id) | (size - 1)
                0b01 | (@as(u32, id) << 16) // (phys contiguous) | (completion queue id)
            });
        }
    }

    fn identify(self: *Controller) !void {
        const buffer = vm.PageAllocator.alloc(0) orelse return error.NoMemory;
        const info: *Info = @ptrFromInt(vm.getVirtLma(buffer));

        info.vendor_id = 0xFFFF;

        self.sendAdminCmd(0, .identify, @ptrFromInt(buffer), &.{
            0x01 // (CNS) Controller identify
        });

        while (info.vendor_id == 0xFFFF) {}

        log.debug("{x}:{x}; {s}; {s}; firmware: {s}; ctrl id: {}", .{
            info.vendor_id,info.sub_vendor_id,info.serial,info.model,
            info.firmware,
            info.ctrl_id
        });

        vm.PageAllocator.free(buffer, 0);
    }

    fn sendAdminCmd(self: *Controller, nsid: u32, command: Command.Admin, data: *anyopaque, specific: []const u32) void {
        self.admin_lock.lock();
        defer self.admin_lock.unlock();

        const cmd = self.admin_submission.nextTail();
        cmd.* = SubmissionEntry.init(.{ .admin = command }, self.admin_submission.cmd_id, nsid, data, specific);

        self.ringDoorbell(0, self.admin_submission.tail, .submission_tail);
    }

    fn sendIoCmd(self: *Controller, nsid: u32, command: Command.Io, data: *anyopaque, specific: []const u32) void {
        const cpu_idx = smp.getIdx();
        const queue = &self.io_submission[cpu_idx];

        const cmd = queue.nextTail();
        cmd.* = SubmissionEntry.init(.{ .io = command }, queue.cmd_id, nsid, data, specific);

        self.ringDoorbell(cpu_idx + 1, queue.tail, .submission_tail);
    }

    fn handleIoCompletion(self: *Controller, id: u16) void {
        const queue = &self.io_completion[id];
        var complete = queue.getHead();

        while (complete.phase_tag == queue.phase_bit) : (complete = queue.nextHead()) {
            complete.phase_tag = ~queue.phase_bit;
            log.debug("{}", .{complete});
        }

        self.ringDoorbell(id + 1, queue.head, .completion_head);
    }

    fn handleAdminCompletion(self: *Controller) void {
        const queue = &self.admin_completion;
        var complete = queue.getHead();

        log.debug("phase tag: {}: id: {}", .{complete.phase_tag, complete.cmd_id});

        while (complete.phase_tag == queue.phase_bit) : (complete = queue.nextHead()) {
            complete.phase_tag = ~queue.phase_bit;
            log.debug("{}", .{complete});
        }

        self.ringDoorbell(0, queue.head, .completion_head);
    }

    fn intrHandler(device: *dev.Device) bool {
        const pci_dev = pci.Device.from(device);
        const controller = pci_dev.data.as(Controller) orelse return false;
        const cpu_idx = smp.getIdx();

        std.debug.assert(pci_dev.device == device);
        log.warn("NVMe interrupt: {}", .{cpu_idx});

        // Check admin queue
        if (cpu_idx == 0) {
            controller.handleAdminCompletion();
        }

        //controller.handleIoCompletion(cpu_idx);

        return true;
    }
};

const Namespace = struct {
};

var pci_driver = pci.Driver{
    .match_id = .{
        .class_code = .mass_storage_controller,
        .subclass = .{ .mass_storage_device = .non_volatile_mem_controller }
    },
};

var driver: *dev.Driver = undefined;

pub fn init() !void {
    const bus = try dev.getBus("pci");

    driver = try dev.registerDriver("nvme driver", bus, @ptrCast(&pci_driver), .{
        .probe = .{ .universal = probe },
        .remove = remove,
    });
}

fn probe(device: *dev.Device) dev.Driver.Operations.ProbeResult {
    log.debug("NVMe controller: {s}", .{device.name.str()});

    const pci_dev = pci.Device.from(device);
    const data = vm.alloc(Controller) orelse return .no_resources;
    pci_dev.data.set(@ptrCast(data));

    data.init(pci_dev) catch |err| {
        log.err("NVMe initialization failed: {s}", .{@errorName(err)});

        vm.free(data);
        pci_dev.data.set(null);

        return .failed;
    };

    return .success;
}

fn remove(device: *dev.Device) void {
    const pci_dev = pci.Device.from(device);
    const data = pci_dev.data.as(Controller) orelse return;

    dev.io.release(data.bar.dyn_base, .mmio);
    vm.free(pci_dev.data.ptr);
}