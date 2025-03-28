// @noexport

//! # NVMe Controller driver
//! 
//! - Specification: NVM Express Base Specification, Revision 2.1

// Copyright (C) 2024 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const dev = @import("../../../dev.zig");
const log = std.log.scoped(.nvme);
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

    prp1: u64,
    prp2: u64 = 0,

    cmd_dword10: u32 = 0,
    cmd_dword11: u32 = 0,
    cmd_dword12: u32 = 0,
    cmd_dword13: u32 = 0,
    cmd_dword14: u32 = 0,
    cmd_dword15: u32 = 0,

    pub fn init(opcode: Opcode, id: u16, nsid: u32, prp1: u64, prp2: u64, specific: []const u32) SubmissionEntry {
        var result = SubmissionEntry{
            .opcode = opcode,
            .cmd_id = id,
            .nsid = nsid,
            .prp1 = prp1,
            .prp2 = prp2
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

    pub fn init(buffer: []SubmissionEntry) SubmissionQueue {
        return .{
            .ptr = buffer.ptr,
            .size = @truncate(buffer.len),
        };
    }

    pub inline fn nextTail(self: *SubmissionQueue) *SubmissionEntry {
        defer self.tail = (self.tail + 1) % self.size;
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

    pub inline fn getHead(self: *CompletionQueue) *volatile CompletionEntry {
        return &self.ptr[self.head];
    }

    pub inline fn nextHead(self: *CompletionQueue) *volatile CompletionEntry {
        self.head = (self.head + 1) % self.size;
        if (self.head == 0) self.phase_bit = ~self.phase_bit;

        return &self.ptr[self.head];
    }
};

const Drive = dev.classes.Drive;
const NamespaceDrive = dev.obj.Inherit(Drive, Namespace);

const Namespace = struct {
    const Info = extern struct {
        size: u64,
        capacity: u64,
        nuse: u64,
        features: u8,
        lba_num: u8,
        lba_size: u8,
        meta_caps: u8,
        prot_caps: u8,
        prot_types: u8,
        nmic_caps: u8,
        res_caps: u8,

        _offset: [72]u8,

        guid: [16]u8,
        euid: u64,

        lba_formats: [15]extern struct {
            meta_size: u16,

            data_size: u8,
            rel_perf: u8
        },
    };

    const vtable = Drive.VTable{
        .handleIo = handleIo
    };

    ctrl: *Controller,
    id: u32,

    pub fn init(self: *NamespaceDrive, ctrl: *Controller, nsid: u32, buffer: *[vm.page_size]u8) !void {
        self.derived = .{
            .ctrl = ctrl,
            .id = nsid,
        };
        self.base.vtable = &vtable;

        try identify(self, buffer);
        try self.base.init("nvme", true, true);
    }

    pub fn deinit(self: *NamespaceDrive) void {
        self.base.deinit();
    }

    pub fn handleIo(self: *Drive, request: *const Drive.IoRequest) bool {
        const ns = &@as(*NamespaceDrive, @ptrCast(self)).derived;
        const pages = request.lba_num / (vm.page_size / self.lba_size);
        const prp1 = @intFromPtr(vm.getPhysLma(request.lma_buf));
        const prp2: usize = switch (pages) {
            0 => 0,
            1 => prp1 + vm.page_size,
            else => blk: {
                // PRP List - the worst case
                // Dirty and slow....
                // FIXME!

                const phys = vm.PageAllocator.alloc(0) orelse return false;
                const list: [*]u64 = @ptrFromInt(vm.getVirtLma(phys));
                var offset: u32 = vm.page_size;

                for (0..pages - 1) |i| {
                    list[i] = prp1 + offset;
                    offset += vm.page_size;
                }

                break :blk phys;
            }
        };

        ns.ctrl.sendIoCmd(
            ns.id,
            switch (request.operation) {
                .read => .read,
                .write => .write
            },
            request.id,
            prp1,
            prp2,
            &.{
                @truncate(request.lba_offset),
                @truncate(request.lba_offset >> 32),
                request.lba_num - 1,
            },
            true
        );

        return true;
    }

    pub fn completeIo(self: *NamespaceDrive, cqe: *const CompletionEntry, sqe: *const SubmissionEntry) void {
        if (sqe.prp2 != 0 and sqe.prp2 != (sqe.prp1 + vm.page_size)) {
            vm.PageAllocator.free(sqe.prp2, 0);
        }

        self.base.completeIo(cqe.cmd_id, if (cqe.status == 0) .success else .failed);
    }

    fn identify(self: *NamespaceDrive, buffer: *[vm.page_size]u8) !void {
        const ns = &self.derived;
        const info: *volatile Info = @alignCast(@ptrCast(buffer));

        const cmd_id = ns.ctrl.admin_submission.tail +% 1;

        ns.ctrl.admin_fail = 0;
        ns.ctrl.sendAdminCmd(ns.id, .identify, cmd_id, vm.getPhysLma(buffer), &.{}, true);
        ns.ctrl.adminInitialWait(cmd_id);
        if (ns.ctrl.admin_fail != 0) return error.CommandsFailed;

        const lba_idx = (info.lba_size & 0xF) | ((info.lba_size >> 1) & 0x70);

        self.base.lba_size = @as(u16, 1) << @truncate(info.lba_formats[lba_idx].data_size);
        self.base.capacity = info.capacity * self.base.lba_size;
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
    admin_cmpl: u16 = 0, // last complete command id
    admin_fail: u16 = 0, // last failed command status

    admin_submission: SubmissionQueue = undefined,
    admin_completion: CompletionQueue = undefined,

    io_submission: [*]SubmissionQueue = undefined,
    io_completion: [*]CompletionQueue = undefined,
    io_queues_rank: u8 = 0,

    namespaces: []*NamespaceDrive = &.{},

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

    pub fn deinit(self: *Controller) void {
        for (self.namespaces) |ns| {
            Namespace.deinit(ns);
        }

        if (self.namespaces.len > 0) vm.free(@ptrCast(self.namespaces.ptr));

        self.deinitIoQueues();

        self.disable() catch |err| log.err("deinit: cannot disable controller: {s}", .{@errorName(err)});
        self.deinitAdminQueues();

        dev.io.release(vm.getPhysLma(self.bar.dyn_base), .mmio);
    }

    pub fn enable(self: *Controller) !void {
        var cfg = self.bar.get(BarRegs.Config, .ctrl_config);
        cfg.enable = 1;
        self.bar.set(.ctrl_config, cfg);

        // Wait for enabling
        var status = self.bar.get(BarRegs.Status, .ctrl_status);
        while (status.ready == 0) : (status = self.bar.get(BarRegs.Status, .ctrl_status)) {
            if (status.fatal_status == 1) return error.ControllerFatal;
        }
    }

    pub fn disable(self: *Controller) !void {
        var cfg = self.bar.get(BarRegs.Config, .ctrl_config);
        cfg.enable = 0;
        self.bar.set(.ctrl_config, cfg);

        // Wait for disabling
        var status = self.bar.get(BarRegs.Status, .ctrl_status);
        while (status.ready == 1) : (status = self.bar.get(BarRegs.Status, .ctrl_status)) {
            if (status.fatal_status == 1) return error.ControllerFatal;
        }
    }

    pub fn reset(self: *Controller, pci_dev: *pci.Device, cap: BarRegs.Capabilities) !void {
        if ((cap.cmd_sets & 1) == 0) return error.NvmeCommandSetNotSupported;

        const arch_page_size = comptime std.math.log2_int(usize, vm.page_size) - 12;
        if (cap.mem_page_size_min > arch_page_size or cap.mem_page_size_max < arch_page_size) return error.UnsupportedPageSize;

        var cfg = self.bar.get(BarRegs.Config, .ctrl_config);

        try self.disable();

        { // Configure
            cfg.enable = 0;
            cfg.mem_page_size = arch_page_size;
            cfg.cmd_set_selected = if ((cap.cmd_sets & 0x40) != 0) 0b110 else 0b000;
            cfg.arbit_mech_selected = .round_robin;

            self.bar.set(.ctrl_config, cfg);
        }

        try self.initAdminQueues();
        errdefer self.deinitAdminQueues();

        try self.enable();

        const intr_num = try pci_dev.requestInterrupts(1, @truncate(smp.getNum()), .{ .msi_x = true });
        errdefer pci_dev.releaseInterrupts();

        for (0..intr_num) |intr| {
            try pci_dev.setupInterrupt(
                @truncate(intr), intrHandler,
                .edge, @truncate(intr)
            );
        }

        try self.initIoQueues();
        errdefer self.deinitIoQueues();

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
        vm.PageAllocator.free(@intFromPtr(vm.getPhysLma(self.admin_submission.ptr)), 1);
    }

    fn initIoQueues(self: *Controller) !void {
        const cpus_num = smp.getNum();

        const pool_pages = cpus_num * 2;
        const pool_rank = std.math.log2_int_ceil(u32, pool_pages);
        const pool_real_size = (@as(u32, 1) << @truncate(pool_rank)) * vm.page_size;

        const pool = vm.PageAllocator.alloc(pool_rank) orelse return error.NoMemory;
        errdefer vm.PageAllocator.free(pool, pool_rank);

        const virt = vm.getVirtLma(pool);

        self.io_queues_rank = pool_rank;
        self.admin_fail = 0;

        comptime std.debug.assert(@sizeOf(SubmissionQueue) == @sizeOf(CompletionQueue));
        const array_size = @sizeOf(SubmissionQueue) * cpus_num;

        { // I/O arrays initialization
            const base = virt + pool_real_size - (array_size * 2);

            self.io_submission = @ptrFromInt(base);
            self.io_completion = @ptrFromInt(base + array_size);
        }

        // Configure queues structures in arrays
        for (0..cpus_num) |i| {
            const base = virt + (i * 2 * vm.page_size);
            const sq_buffer: [*]SubmissionEntry = @ptrFromInt(base);
            const cq_buffer: [*]CompletionEntry = @ptrFromInt(base + vm.page_size);

            const cq_real_len = if (i != cpus_num - 1) cq_len else (
                (cq_len * @sizeOf(CompletionEntry) - array_size * 2) / @sizeOf(CompletionEntry)
            );

            self.io_completion[i] = CompletionQueue.init(cq_buffer[0..cq_real_len]);
            self.io_submission[i] = SubmissionQueue.init(sq_buffer[0..sq_len]);

            @memset(cq_buffer[0..cq_real_len], std.mem.zeroes(CompletionEntry));
        }

        // Send commands to create completion queues
        for (0..cpus_num) |i| {
            const id: u32 = @truncate(i + 1);
            const cq = &self.io_completion[i];
            const cmd_id = self.admin_submission.tail +% 1;

            self.sendAdminCmd(0, .create_completion_queue, cmd_id, @ptrCast(vm.getPhysLma(cq.ptr)), &.{
                id   | (@as(u32, cq.size - 1) << 16), // (doorbell id) | (size - 1)
                0b11 | (@as(u32, id - 1) << 16) // (phys contiguous,intr enable) | (intr vector)
            }, false);
        }
        self.ringDoorbell(0, self.admin_submission.tail, .submission_tail);

        // Send commands to create submission queues
        for (0..cpus_num) |i| {
            const id: u32 = @truncate(i + 1);
            const sq = &self.io_submission[i];
            const cmd_id = self.admin_submission.tail +% 1;

            self.sendAdminCmd(0, .create_submission_queue, cmd_id, @ptrCast(vm.getPhysLma(sq.ptr)), &.{
                id   | (@as(u32, sq_len - 1) << 16), // (doorbell id) | (size - 1)
                0b01 | (@as(u32, id) << 16) // (phys contiguous) | (completion queue id)
            }, false);
        }
        const last_cmd = self.admin_submission.tail;
        self.ringDoorbell(0, self.admin_submission.tail, .submission_tail);

        // Wait
        self.adminInitialWait(last_cmd);
        if (self.admin_fail != 0) return error.CommandsFailed;
    }

    fn deinitIoQueues(self: *Controller) void {
        const cpus_num = smp.getNum();
        self.admin_cmpl = 0;
        self.admin_fail = 0;

        // Delete submission queues first
        for (0..cpus_num) |i| {
            const id: u32 = @truncate(i + 1);
            const cmd_id: u16 = self.admin_submission.tail +% 1;
            self.sendAdminCmd(0, .delete_submission_queue, cmd_id, null, &.{id}, false);
        }
        self.ringDoorbell(0, self.admin_submission.tail, .submission_tail);

        // Delete completion queues than
        for (0..cpus_num) |i| {
            const id: u32 = @truncate(i + 1);
            const cmd_id: u16 = self.admin_submission.tail +% 1;
            self.sendAdminCmd(0, .delete_completion_queue, cmd_id, null, &.{id}, false);
        }
        const last_cmd = self.admin_submission.tail;
        self.ringDoorbell(0, self.admin_submission.tail, .submission_tail);

        // Wait for complete
        self.adminInitialWait(last_cmd);

        if (self.admin_fail != 0) log.err("Command failed during delete I/O queues; Ignoring", .{});

        // Free memory
        const phys = vm.getPhysLma(self.io_submission[0].ptr);
        vm.PageAllocator.free(@intFromPtr(phys), self.io_queues_rank);
    }

    pub fn adminInitialWait(self: *Controller, cmd_id: u16) void {
        const idx = (cmd_id -% 1) % self.admin_completion.size;
        const cmpl: *volatile CompletionEntry = &self.admin_completion.ptr[idx];

        while (cmpl.cmd_id != cmd_id) {}

        self.handleAdminCompletion();
    }

    fn identify(self: *Controller) !void {
        const buffer = vm.PageAllocator.alloc(1) orelse return error.NoMemory;
        defer vm.PageAllocator.free(buffer, 1);

        const virt = vm.getVirtLma(buffer);

        // Identify controller
        {
            const info: *volatile Info = @ptrFromInt(virt);
            const cmd_id = self.admin_submission.tail +% 1;

            self.sendAdminCmd(0, .identify, cmd_id, @ptrFromInt(buffer), &.{
                0x01 // (CNS) Controller identify
            }, true);
            self.adminInitialWait(cmd_id);

            log.debug("{x}:{x}; {s}; {s}; firmware: {s}; ctrl id: {}", .{
                info.vendor_id,info.sub_vendor_id,info.serial,info.model,
                info.firmware,
                info.ctrl_id
            });
        }

        // Identify namespaces
        {
            const ids: [*:0]volatile u32 = @ptrFromInt(virt);
            const cmd_id = self.admin_submission.tail +% 1;

            self.sendAdminCmd(0, .identify, cmd_id, @ptrFromInt(buffer), &.{
                0x02 // (CNS) Namespace ID list
            }, true);

            // Wait
            self.adminInitialWait(cmd_id);

            const slice = ids[0..std.mem.len(@as([*:0]const u32, @volatileCast(ids)))];
            if (slice.len == 0) return;

            const ptr = vm.malloc(@sizeOf(*NamespaceDrive) * slice.len) orelse return error.NoMemory;

            self.namespaces.ptr = @alignCast(@ptrCast(ptr));
            self.namespaces.len = slice.len;
            errdefer vm.free(@ptrCast(self.namespaces.ptr));

            for (slice, 0..) |nsid, i| {
                const drive = try dev.obj.new(NamespaceDrive);
                errdefer dev.obj.free(NamespaceDrive, drive);

                self.namespaces[i] = drive;

                try Namespace.init(drive, self, nsid, @ptrFromInt(virt + vm.page_size));
                errdefer Namespace.deinit(drive);

                try dev.obj.add(Drive, &drive.base);
            }
        }
    }

    fn sendAdminCmd(
        self: *Controller, nsid: u32, command: Command.Admin,
        id: u16, data: ?*anyopaque, specific: []const u32, comptime ring: bool
    ) void {
        self.admin_lock.lock();
        defer self.admin_lock.unlock();

        const prp1: usize = if (data) |ptr| @intFromPtr(ptr) else 0;
        const cmd = self.admin_submission.nextTail();
        cmd.* = SubmissionEntry.init(
            .{ .admin = command }, id,
            nsid, prp1, 0, specific
        );

        if (ring) self.ringDoorbell(0, self.admin_submission.tail, .submission_tail);
    }

    fn sendIoCmd(
        self: *Controller, nsid: u32, command: Command.Io, id: u16,
        prp1: usize, prp2: usize, specific: []const u32,comptime ring: bool
    ) void {
        const cpu_idx = smp.getIdx();
        const queue = &self.io_submission[cpu_idx];

        const cmd = queue.nextTail();
        cmd.* = SubmissionEntry.init(
            .{ .io = command }, id,
            nsid, prp1, prp2, specific
        );

        if (ring) self.ringDoorbell(cpu_idx + 1, queue.tail, .submission_tail);
    }

    fn handleIoCompletion(self: *Controller, id: u16) void {
        const queue = &self.io_completion[id];
        const sq = &self.io_submission[id];

        var complete = queue.getHead();

        while (complete.phase_tag == queue.phase_bit) : (complete = queue.nextHead()) {
            complete.phase_tag = ~queue.phase_bit;

            const sqe_idx = queue.head % sq_len;
            const sqe = &sq.ptr[sqe_idx];

            const ns = self.namespaces[sqe.nsid - 1];
            Namespace.completeIo(ns, @volatileCast(complete), sqe);
        }

        self.ringDoorbell(id + 1, queue.head, .completion_head);
    }

    fn handleAdminCompletion(self: *Controller) void {
        const queue = &self.admin_completion;
        var complete = queue.getHead();

        while (complete.phase_tag == queue.phase_bit) : (complete = queue.nextHead()) {
            complete.phase_tag = ~queue.phase_bit;

            if (complete.status != 0) {
                self.admin_fail = complete.status;
                log.warn("failed admin command: {}", .{complete});
            }

            self.admin_cmpl = complete.cmd_id;
        }

        self.ringDoorbell(0, queue.head, .completion_head);
    }

    fn intrHandler(device: *dev.Device) bool {
        const pci_dev = pci.Device.from(device);
        const controller = pci_dev.data.as(Controller) orelse return false;
        const cpu_idx = smp.getIdx();

        if (cpu_idx == 0) controller.handleAdminCompletion();
        controller.handleIoCompletion(cpu_idx);

        return true;
    }
};

var pci_driver = pci.Driver.init("nvme-ctrl",
    .{
        .probe = .{ .universal = probe },
        .remove = remove,
    },
    .{
        .class_code = .mass_storage_controller,
        .subclass = .{ .mass_storage_device = .non_volatile_mem_controller }
    }
);

pub fn init() !void {
    try dev.registerDriver("pci", &pci_driver.base);
}

fn probe(device: *dev.Device) dev.Driver.Operations.ProbeResult {
    log.info("controller: {s}", .{device.name.str()});

    const pci_dev = pci.Device.from(device);
    const controller = vm.alloc(Controller) orelse return .no_resources;
    pci_dev.data.set(@ptrCast(controller));

    controller.init(pci_dev) catch |err| {
        log.err("initialization failed: {s}", .{@errorName(err)});

        vm.free(controller);
        pci_dev.data.set(null);

        return .failed;
    };

    return .success;
}

fn remove(device: *dev.Device) void {
    const pci_dev = pci.Device.from(device);
    const controller = pci_dev.data.as(Controller) orelse return;

    controller.deinit();

    vm.free(controller);
}