//! # Executable Files Processing

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const builtin = @import("builtin");
const std = @import("std");
const elf = std.elf;
const coff = std.coff;

const log = std.log.scoped(.@"sys.exe");
const sys = @import("../sys.zig");
const Process = @import("Process.zig");
const utils = @import("../utils.zig");
const vfs = @import("../vfs.zig");
const vm = @import("../vm.zig");

pub const Error = vfs.Error || error {
    BadABI,
    BadFormat,
    BadInterpreter,
};

pub const Type = enum(u2) {
    none,

    script,
    ELF,
    COFF,
};

pub const max_args_size = utils.mb_size * 8;
pub const start_args_addr = vm.max_userspace_addr - max_args_size + 1;

pub const max_stack_size = utils.mb_size * 32;
pub const start_stack_addr = start_args_addr - max_stack_size;

pub const default_virt_base = 0x8000_0000;

pub const max_elf_interp_path = 256;

pub const Arguments = struct {
    region: vm.VirtualRegion = .init(start_args_addr),
    pos: u32 = 0,
    num: u32 = 0,

    pub const Writer = std.io.Writer(*Arguments, Error, write);

    pub inline fn deinit(self: *Arguments) void {
        self.pos = 0;
        self.region.deinit(true);
    }

    pub inline fn preAllocate(self: *Arguments) Error!void {
        self.region.growUp(0, .{ .none = true }) catch return error.NoMemory;
    }

    pub inline fn writer(self: *Arguments) Writer {
        return .{ .context = self };
    }

    fn write(self: *Arguments, bytes: []const u8) Error!usize {
        const real_len = bytes.len;
        const len = if (
            (self.pos + real_len) > vm.page_size
        ) (vm.page_size - self.pos) else bytes.len;

        var buffer = self.getBuffer();
        @memcpy(buffer[self.pos..len], bytes[0..len]);

        self.pos += @truncate(len);
        errdefer self.pos -= @truncate(len);

        if (real_len == len) {
            @branchHint(.likely);
            return real_len;
        }

        try self.region.growDown(0, .{ .none = true });
        self.pos += @truncate(try self.write(bytes));

        return real_len;
    }

    fn getBuffer(self: *Arguments) *[vm.page_size]u8 {
        const page = self.region.page_list.first.?;
        const virt = vm.getVirtLma(page.data.getPhysBase());

        return @ptrFromInt(virt);
    }
};

pub const ExeFile = struct {
    file: *vfs.File,
    interp: ?*vfs.File = null,

    type: Type = .none,

    proc: *Process,
    virt_base: usize = 0,

    args: Arguments,
    buffer: []u8,

    data: union {
        elf: elf.Header,
        coff: coff.Coff,
    } = undefined,

    pub fn init(exe_dent: *vfs.Dentry, proc: *Process) Error!ExeFile {
        const role = exe_dent.inode.getRole(proc.uid, proc.gid);

        if (exe_dent.inode.type != .regular_file or
            exe_dent.inode.checkAccess(.x, role) == false
        ) {
            @branchHint(.cold);
            return error.NoAccess;
        }

        var file = try exe_dent.open(.x);
        errdefer file.deref();

        const phys = vm.PageAllocator.alloc(0) orelse return error.NoMemory;
        errdefer vm.PageAllocator.free(phys, 0);

        var buffer: []u8 = undefined;
        buffer.ptr = @ptrFromInt(vm.getVirtLma(phys));
        buffer.len = vm.page_size;

        var args: Arguments = .{};
        try args.preAllocate();
        errdefer args.deinit();

        return .{
            .file = file,
            .proc = proc,
            .args = args,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *ExeFile) void {
        self.args.deinit();

        const virt = @intFromPtr(self.buffer.ptr);
        const phys = vm.getPhysLma(virt);
        vm.PageAllocator.free(phys, 0);

        self.file.deref();
        if (self.interp) |interp| interp.deref();
    }

    pub fn preload(self: *ExeFile) Error!void {
        try self.readExe();
        log.debug("exe readed!", .{});

        const prelude: *Prelude = std.mem.bytesAsValue(Prelude, self.buffer);
        while (prelude.getType() == .script) {
            try self.loadScriptInterp();
            try self.readExe();
        }

        self.type = prelude.getType();
    }

    inline fn readExe(self: *ExeFile) !void {
        const readed = try self.file.read(self.buffer.ptr[0..vm.page_size]);
        if (readed < 2) return error.BadFormat;

        self.buffer.len = readed;
    }

    fn loadScriptInterp(self: *ExeFile) Error!void {
        const arg_writer = self.args.writer();
        const path = self.file.dentry.path();

        try arg_writer.print("{}\x00", .{path});
        self.args.num += 1;

        const content = self.buffer[Prelude.sb_sign.len..];
        const path_len = std.mem.indexOfAny(
            u8, content, "\x00\n\r"
        ) orelse content.len;
        const interp_path = content[0..path_len];

        if (interp_path.len == 0) return error.BadInterpreter;

        const interp_dent = vfs.lookup(
            self.proc.work_dir, interp_path
        ) catch |err| switch (err) {
            error.IoFailed,
            error.NoMemory => return err,
            else => return error.BadInterpreter
        };
        defer interp_dent.deref();

        const role = interp_dent.inode.getRole(self.proc.uid, self.proc.gid);
        if (!interp_dent.inode.checkAccess(.x, role))
            return error.NoAccess;

        const interp_file = try interp_dent.open(.x);

        self.file.deref();
        self.file = interp_file;
    }
};

const Prelude = extern union {
    const mz_sign = "MZ";
    const sb_sign = "#!";

    signature: [2]u8,
    magic:     [4]u8,

    pub inline fn getType(self: *Prelude) Type {
        if (std.mem.eql(u8, self.magic[0..], elf.MAGIC[0..]))
            return .ELF;
        if (std.mem.eql(u8, self.signature[0..], mz_sign[0..]))
            return .COFF;
        if (std.mem.eql(u8, self.signature[0..], sb_sign[0..]))
            return .script;

        return .none;
    }
};

pub fn load(exe_dent: *vfs.Dentry, proc: *Process) Error!ExeFile {
    var exe: ExeFile = try .init(exe_dent, proc);
    errdefer exe.deinit();

    try exe.preload();
    log.debug("exe initialized!", .{});

    switch (exe.type) {
        .ELF => try loadElf(&exe),
        .COFF => try loadCoff(&exe),
        else => return error.BadFormat,
    }

    return exe;
}

fn loadElf(self: *ExeFile) Error!void {
    std.debug.assert(self.type == .ELF);

    const ehdr_len = comptime @sizeOf(elf.Ehdr);
    const EhdrBuffer = *align(@alignOf(elf.Ehdr))const [ehdr_len]u8;

    if (self.buffer.len < ehdr_len) return error.BadFormat;
    const buffer: EhdrBuffer = @ptrCast(@alignCast(self.buffer.ptr));

    self.data = .{
        .elf = elf.Header.parse(buffer) catch return error.BadFormat 
    };
    const elf_hdr = &self.data.elf;

    log.debug("elf header parsed", .{});

    // Check ABI
    if (
        (elf_hdr.endian != builtin.cpu.arch.endian()) or
        (elf_hdr.machine != builtin.target.toElfMachine()) or
        (elf_hdr.os_abi != .NONE and elf_hdr.os_abi != .GNU) or
        (elf_hdr.type != .EXEC and elf_hdr.type != .DYN and elf_hdr.type != .REL)
    ) return error.BadABI;

    if (elf_hdr.type != .EXEC) {
        self.virt_base = default_virt_base;
    }

    log.debug("load elf!", .{});
    self.proc.assignExecutable(self.file);
    errdefer self.proc.exe_file.deref();

    var source: std.io.StreamSource = .{
        .const_buffer = .{
            .buffer = self.buffer, .pos = 0
    }};
    var phdr_iter = elf_hdr.program_header_iterator(&source);

    while (phdr_iter.next() catch return error.BadFormat) |phdr| {
        // TODO: implement interpreter loading properly.
        if (phdr.p_type == elf.PT_INTERP) {
            //return error.BadInterpreter;
            // try loadElfInterpreter(self, &phdr);
        }

        if (phdr.p_type == elf.PT_LOAD) {
            const map_flags = elfMapFlags(phdr.p_flags);
            const pages_offset = phdr.p_offset / vm.page_size;
            const offset_mod = phdr.p_offset % vm.page_size;

            const virt = phdr.p_vaddr + self.virt_base;
            const size = phdr.p_filesz + offset_mod;

            // Div ceil
            const pages = (size + (vm.page_size - 1)) / vm.page_size;

            _ = try self.proc.mmap(
                self.file, virt, @truncate(pages_offset),
                @truncate(pages), map_flags
            );
        }
    }

    log.info("{}", .{self.proc.addr_space});
}

fn elfMapFlags(p_flags: u32) vm.MapFlags {
    var flags: vm.MapFlags = .{ .user = true };

    if ((p_flags & elf.PF_W) != 0) flags.write = true;
    if ((p_flags & elf.PF_X) != 0) flags.exec = true;

    return flags;
}

fn loadElfInterpreter(self: *ExeFile, phdr: elf.Phdr) !void {
    const path_len = phdr.p_filesz - 1; // Original size includes null-terminator.

    if (path_len > max_elf_interp_path) return error.NoMemory;

    const interp_dent = if (phdr.p_offset + path_len > self.buffer.len) blk: {
        @branchHint(.unlikely);
        var path_buf: [max_elf_interp_path]u8 = undefined;

        self.file.offset = phdr.p_offset;
        try self.file.readAll(path_buf[0..path_len]);

        break :blk try vfs.lookup(self.root, path_buf[0..path_len]);
    } else try vfs.lookup(
        self.root,
        self.buffer[phdr.p_offset..phdr.p_offset + path_len]
    );
    defer interp_dent.deref();

    const role = interp_dent.inode.getRole(self.proc.uid, self.proc.gid);
    if (!interp_dent.inode.checkAccess(.x, role))
        return error.NoAccess;

    self.interp = try vfs.open(interp_dent);
}

fn loadCoff(self: *ExeFile) Error!void {
    std.debug.assert(self.type == .COFF);
    return error.BadFormat;
}
