//! # Executable Files Processing

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const builtin = @import("builtin");
const std = @import("std");
const coff = std.coff;

const lib = @import("../lib.zig");
const sys = @import("../sys.zig");
const Process = @import("Process.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

const elf = @import("exe/elf.zig");

pub const start_args_addr = vm.max_userspace_addr - sys.limits.max_args_size + 1;
pub const start_stack_addr = start_args_addr - sys.limits.max_stack_size;

pub const default_virt_base = lib.misc.alignDown(usize, (start_stack_addr / 3) * 2, vm.page_size);

pub const Error = vfs.Error || error {
    BadAbi,
    BadFormat,
    BadInterpreter
};

pub const Type = enum(u2) {
    none,
    script,
    elf,
    coff,
};

pub const RunContext = struct {
    entry_ptr: usize,
    stack_ptr: usize
};

pub const Binary = struct {
    const Prelude = extern union {
        const mz_sign = "MZ";
        const sb_sign = "#!";

        signature: [2]u8,
        magic:     [4]u8,

        inline fn getType(self: *Prelude) Type {
            if (std.mem.eql(u8, self.magic[0..], std.elf.MAGIC[0..]))
                return .elf;
            if (std.mem.eql(u8, self.signature[0..], mz_sign[0..]))
                return .coff;
            if (std.mem.eql(u8, self.signature[0..], sb_sign[0..]))
                return .script;

            return .none;
        }
    };

    file: *vfs.File,
    interp: ?*vfs.File = null,

    type: Type = .none,

    proc: *Process,
    role: vfs.Role,
    virt_base: usize = 0,

    args: Arguments,
    buffer: []u8,

    data: union {
        elf: elf.Data,
        coff: coff.Coff,

        run_ctx: RunContext
    } = undefined,

    pub fn init(exe_dent: *vfs.Dentry, proc: *Process) Error!Binary {
        const role = exe_dent.inode.getRole(proc.uid, proc.gid);
        if (exe_dent.inode.type != .regular_file or
            exe_dent.inode.checkAccess(.x, role) == false
        ) {
            @branchHint(.cold);
            return error.NoAccess;
        }

        var file = try exe_dent.open(.rx);
        errdefer file.deref();

        const phys = vm.PageAllocator.alloc(0) orelse return error.NoMemory;

        var buffer: []u8 = undefined;
        buffer.ptr = @ptrFromInt(vm.getVirtLma(phys));
        buffer.len = vm.page_size;

        return .{
            .file = file,
            .proc = proc,
            .role = role,
            .args = .init(),
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *Binary) void {
        self.args.deinit();

        const virt = @intFromPtr(self.buffer.ptr);
        const phys = vm.getPhysLma(virt);
        vm.PageAllocator.free(phys, 0);

        self.file.deref();
        if (self.interp) |interp| interp.deref();
    }

    pub fn load(self: *Binary, args: []const [*:0]const u8, envs: []const [*:0]const u8) Error!void {
        try self.readExe();

        const prelude: *Prelude = std.mem.bytesAsValue(Prelude, self.buffer);
        while (prelude.getType() == .script) {
            try self.loadScriptInterpreter();
            try self.readExe();
        }

        self.type = prelude.getType();
        switch (self.type) {
            .elf => try elf.load(self, args, envs),
            else => return error.BadFormat,
        }
    }

    pub inline fn readExe(self: *Binary) Error!void {
        const readed = try self.file.read(self.buffer.ptr[0..vm.page_size]);
        if (readed < 2) return error.BadFormat;

        self.buffer.len = readed;
    }

    pub fn readExeBuffered(self: *Binary, offset: usize, buffer: []u8) Error![]u8 {
        const end = offset + buffer.len;
        if (end <= self.buffer.len) return self.buffer[offset..end];

        self.file.offset = offset;
        try self.file.readAll(buffer);
        return buffer;
    }

    pub fn readExeCached(self: *Binary, offset: usize, buffer: []u8) Error!void {
        const end = offset + buffer.len;
        if (end > self.buffer.len) {
            self.file.offset = offset;
            return self.file.readAll(buffer);
        }

        @memcpy(buffer, self.buffer[offset..end]);
    }

    fn loadScriptInterpreter(self: *Binary) Error!void {
        try self.args.printArgument("{f}", .{self.file.dentry.path()});

        const content = self.buffer[Prelude.sb_sign.len..];
        const path_len = std.mem.indexOfAny(u8, content, "\x00\n\r") orelse return error.BadInterpreter;
        if (path_len == 0) return error.BadInterpreter;

        const interp_path = content[0..path_len];
        const interp_dent = vfs.lookup(
            self.proc.root_dir, self.proc.work_dir, interp_path
        ) catch |err| switch (err) {
            error.IoFailed,
            error.NoMemory => return err,
            else => return error.BadInterpreter
        };
        defer interp_dent.deref();

        if (!interp_dent.inode.checkAccess(.x, self.role)) return error.NoAccess;
        const interp_file = try interp_dent.open(.rx);

        self.file.deref();
        self.file = interp_file;
    }
};

const Arguments = struct {
    const array_max_size = sys.limits.max_args_size / 8;
    const vtable: std.Io.Writer.VTable = .{
        .drain = drain
    };

    entries: lib.VirtualArray(usize),
    content: vm.VirtualRegion = .init(start_args_addr),
    writer: std.Io.Writer = .{
        .buffer = &.{},
        .vtable = &vtable
    },

    fn init() Arguments {
        return .{ .entries = .initVirtualSize(array_max_size) };
    }

    fn deinit(self: *Arguments) void {
        self.writer.buffer = &.{};
        self.writer.end = 0;

        self.entries.clearAndFree();
        self.entries.deinitVirtualSize(array_max_size);
        self.content.deinit();
    }

    pub fn printArgument(self: *Arguments, comptime fmt: []const u8, args: anytype) Error!void {
        try self.entries.append(self.getCurrentPtr());
        errdefer _ = self.entries.pop();

        self.writer.print(fmt++"\x00", args) catch return error.NoMemory;
    }

    pub fn complete(self: *Arguments) Error!vm.VirtualRegion {
        const entries_pages = self.entries.region.pagesNum();
        const base = self.content.base - (entries_pages * vm.page_size);

        var region = self.entries.region;
        defer {
            self.entries.region.unmap();
            self.entries.region.page_list = .{};
            self.content = .{ .base = 0 };
        }

        region.base = base;
        while (self.content.page_list.popFirst()) |n| {
            const page = vm.Page.fromNode(n);
            page.dim.idx += @truncate(entries_pages);

            region.attachPage(page);
        }

        return region;
    }

    pub inline fn getCurrentPagePtr(self: *const Arguments) usize {
        const page = self.content.getLastPage() orelse return self.content.base;
        return self.content.base + page.getOffset();
    }

    pub fn getCurrentPtr(self: *const Arguments) usize {
        return self.getCurrentPagePtr() + self.writer.end;
    }

    pub fn getBuffer(self: *const Arguments) []u8 {
        const page = self.content.getLastPage() orelse return &.{};
        const ptr: [*]u8 = @ptrFromInt(vm.getVirtLma(page.getPhysBase()));

        return ptr[0..page.size()];
    }

    pub fn allocateBuffer(self: *Arguments, size: usize) Error![]u8 {
        self.content.growUp(vm.bytesToRank(size), .{ .none = true }) catch return error.NoMemory;
        const buffer = self.getBuffer();

        if (self.writer.buffer.len == 0 and buffer.len > size) {
            self.writer.buffer = buffer;
            self.writer.end = size;
        }

        return buffer[0..size];
    }

    pub fn alignWriter(self: *Arguments, alignment: u8) std.Io.Writer.Error!void {
        const new_end = lib.misc.alignUp(usize,self.writer.end, alignment);
        if (new_end < self.writer.buffer.len) {
            self.writer.end = new_end;
        } else {
            try self.writer.flush();
        }
    }

    pub fn appendAuxv(self: *Arguments, @"type": comptime_int, value: usize) Error!void {
        const auxv = try self.entries.addManyAsSlice(@sizeOf(std.elf.Auxv) / @sizeOf(usize));

        auxv[0] = @"type";
        auxv[1] = value;
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Arguments = @fieldParentPtr("writer", writer);
        if (data.len == 0) return 0;

        var writen: usize = 0;
        for (0..data.len - 1) |i| {
            try self.writeAlloc(data[i]);
            writen += data[i].len;
        }

        const slice = data[data.len - 1];
        for (0..splat) |_| {
            try self.writeAlloc(slice);
            writen += slice.len;
        }

        return writen;
    }

    fn writeAlloc(self: *Arguments, bytes: []const u8) std.Io.Writer.Error!void {
        var slice = bytes;
        while (slice.len > 0) {
            const remain = self.writer.buffer.len - self.writer.end;

            if (remain < slice.len) {
                if (remain > 0) {
                    @memcpy(self.writer.buffer[self.writer.end..], slice[0..remain]);
                    slice = slice[remain..];
                }

                self.content.growUp(0, .{ .none = true }) catch return error.WriteFailed;

                self.writer.buffer = self.getBuffer();
                self.writer.end = 0;
            } else {
                @memcpy(self.writer.buffer[self.writer.end..], slice[0..]);
                self.writer.end += slice.len;

                return;
            }
        }
    }
};
