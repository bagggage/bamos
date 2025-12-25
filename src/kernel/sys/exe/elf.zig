//! # Executable and Linking Format

// Copyright (C) 2025 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const elf = std.elf;
const exe = @import("../exe.zig");
const lib = @import("../../lib.zig");
const log = std.log.scoped(.@"exe.elf");
const vfs = @import("../../vfs.zig");
const vm = @import("../../vm.zig");

pub const Data = elf.Header;

const max_interp_path = 256;

pub fn load(bin: *exe.Binary, args: []const [*:0]const u8, envs: []const [*:0]const u8) exe.Error!void {
    std.debug.assert(bin.type == .elf);

    const elf_hdr = (try loadAndValidateHeader(bin)).*;
    if (elf_hdr.type != .EXEC) bin.virt_base = exe.default_virt_base;

    bin.proc.assignExecutable(bin.file);
    errdefer bin.proc.detachExecutable();

    // Load executable itself
    var elf_phdrs_virt: usize = 0;
    const elf_phdrs: []elf.Phdr = blk: {
        const size = @as(usize, elf_hdr.phnum) * @sizeOf(elf.Phdr);
        const buffer = try bin.args.allocateBuffer(size);
        elf_phdrs_virt = bin.args.getCurrentPagePtr();

        try bin.readExeCached(elf_hdr.phoff, buffer);
        break :blk @ptrCast(@alignCast(buffer));
    };

    var interp_phdr: ?*elf.Phdr = null;
    var elf_max_seg: usize = 0; 
    for (elf_phdrs) |*phdr| switch (phdr.p_type) {
        elf.PT_INTERP => {
            if (interp_phdr != null) return error.BadFormat;
            interp_phdr = phdr;
        },
        elf.PT_LOAD => {
            elf_max_seg = @max(elf_max_seg, bin.virt_base + phdr.p_vaddr + phdr.p_memsz);
            try loadProgramSegment(bin, bin.file, phdr, bin.virt_base);
        },
        else => {}
    };

    const addr_space = bin.proc.addr_space;
    try addr_space.heapInit(lib.misc.alignUp(usize, elf_max_seg, vm.page_size));

    const interp_base = if (interp_phdr) |phdr| blk: {
        const interp = openInterpreter(bin, phdr) catch |err| {
            if (err == error.NoEnt) return error.BadInterpreter;
            return err; 
        };
        const base = try loadInterpreter(bin, interp);

        bin.proc.assignInterpreter(interp);
        break :blk base;
    } else null;
    errdefer bin.proc.detachInterpreter();

    try buildArgsAndEnvs(bin, args, envs);
    try buildAuxVectors(bin, &elf_hdr, interp_base, elf_phdrs_virt);

    var stack_region = try bin.args.complete();
    errdefer stack_region.deinit();

    try bin.proc.addr_space.mapRegion(&stack_region, .{
            .map = .{ .write = true, .user = true },
            .grow_down = true
        }
    );

    const entry = bin.data.elf.entry + (interp_base orelse bin.virt_base);
    bin.data = .{ .run_ctx = .{
        .entry_ptr = entry,
        .stack_ptr = stack_region.base,
    }};
}

fn loadAndValidateHeader(self: *exe.Binary) exe.Error!*const elf.Header {
    if (self.buffer.len < @sizeOf(elf.Ehdr)) return error.BadFormat;

    var reader = std.Io.Reader.fixed(self.buffer);
    self.data = .{ .elf = elf.Header.read(&reader) catch return error.BadFormat };
    const elf_hdr = &self.data.elf;

    // Check ABI
    if ((elf_hdr.endian != builtin.cpu.arch.endian()) or
        (elf_hdr.machine != builtin.target.toElfMachine()) or
        (elf_hdr.os_abi != .NONE and elf_hdr.os_abi != .GNU) or
        (elf_hdr.type != .EXEC and elf_hdr.type != .DYN and elf_hdr.type != .REL)
    ) return error.BadAbi;
    return elf_hdr;
}

fn loadProgramSegment(self: *exe.Binary, file: *vfs.File, phdr: *const elf.Phdr, base: usize) exe.Error!void {
    if (phdr.p_align > 0 and
        (!std.math.isPowerOfTwo(phdr.p_align) or
        (phdr.p_vaddr > 0 and !std.mem.isAligned(base + phdr.p_vaddr -| phdr.p_offset, phdr.p_align)))
    ) return error.BadFormat;

    const map_flags = phdrFlagsToMapFlags(phdr.p_flags);
    const pages_offset = phdr.p_offset / vm.page_size;

    const offset_mod = phdr.p_offset % vm.page_size;
    const virt = phdr.p_vaddr + base;

    const mem_size = phdr.p_memsz + offset_mod;
    const file_size = phdr.p_filesz + offset_mod;

    const map_size = @min(file_size, mem_size);
    const map_pages = (map_size + (vm.page_size - 1)) / vm.page_size;
    const mem_pages = (mem_size + (vm.page_size - 1)) / vm.page_size;

    if (map_pages > 0) {
        // Div ceil
        _ = try self.proc.mmap(
            file, virt, @truncate(pages_offset),
            @truncate(map_pages), .{ .map = map_flags }
        );
    }

    if (mem_pages > map_pages) {
        _ = try self.proc.mmap(
            null, virt + (map_pages * vm.page_size), 0,
            @truncate(mem_pages - map_pages), .{ .map = map_flags }
        );
    }
}

fn phdrFlagsToMapFlags(p_flags: u32) vm.MapFlags {
    var flags: vm.MapFlags = .{ .user = true };
    if ((p_flags & elf.PF_W) != 0) flags.write = true;
    if ((p_flags & elf.PF_X) != 0) flags.exec = true;

    return flags;
}

fn loadInterpreter(bin: *exe.Binary, interp: *vfs.File) exe.Error!usize {
    const readed = try interp.read(bin.buffer.ptr[0..vm.page_size]);
    bin.buffer.len = readed;

    const interp_elf_hdr = try loadAndValidateHeader(bin);
    var phdr_iter = interp_elf_hdr.iterateProgramHeadersBuffer(bin.buffer);

    // Find suitable mapping area for interpreter
    const base = blk: {
        var interp_bounds: [2]usize = .{ std.math.maxInt(usize), 0 };
        var max_alignment: usize = 1;
        while (phdr_iter.next() catch return error.BadInterpreter) |phdr| switch (phdr.p_type) {
            elf.PT_INTERP => return error.BadInterpreter,
            elf.PT_LOAD => {
                max_alignment = @max(max_alignment, phdr.p_align);
                interp_bounds[0] = @min(interp_bounds[0], phdr.p_vaddr);
                interp_bounds[1] = @min(interp_bounds[1], phdr.p_vaddr + phdr.p_memsz);
            },
            else => {}
        };

        // Include page bounds
        const interp_size =
            lib.misc.alignUp(usize, interp_bounds[1], vm.page_size) -
            lib.misc.alignDown(usize, interp_bounds[0], vm.page_size);
        const used_region = bin.proc.addr_space.calculateUsedRegion();
        const used_top_aligned = lib.misc.alignUp(usize, used_region[1], max_alignment);

        const top_avail_size = exe.start_stack_addr - used_top_aligned;
        if (top_avail_size >= interp_size) {
            const tmp_base = @min(exe.start_stack_addr - interp_size, (exe.start_stack_addr + used_top_aligned) / 4 * 3);
            break :blk lib.misc.alignDown(usize, tmp_base, max_alignment);
        } else if (used_region[0] >= interp_size) {
            const tmp_base = @min(used_region[0] - interp_size, used_region[0] / 3);
            break :blk lib.misc.alignDown(usize, tmp_base, max_alignment);
        }

        log.warn("Can't find suitable memory region for interpreter: used: {any}, size: {}", .{used_region, interp_size});
        return error.BadInterpreter;
    };

    phdr_iter.index = 0;
    while (phdr_iter.next() catch unreachable) |phdr| {
        if (phdr.p_type != elf.PT_LOAD) continue;
        try loadProgramSegment(bin, interp, &phdr, base);
    }

    return base;
}

fn openInterpreter(bin: *exe.Binary, pt_interp: *const elf.Phdr) exe.Error!*vfs.File {
    const path_len = pt_interp.p_filesz - 1; // Original size includes null-terminator.
    if (path_len > max_interp_path) return error.NoMemory;

    var path_buf: [max_interp_path]u8 = undefined;
    const path = try bin.readExeBuffered(pt_interp.p_offset, path_buf[0..path_len]);

    const interp_dent = try vfs.lookup(bin.proc.root_dir, bin.proc.work_dir, path);
    defer interp_dent.deref();

    if (!interp_dent.inode.checkAccess(.x, bin.role)) return error.NoAccess;

    const interp = try interp_dent.open(.rwx);
    return interp;
}

fn buildArgsAndEnvs(bin: *exe.Binary, args: []const [*:0]const u8, envs: []const [*:0]const u8) exe.Error!void {
    std.debug.assert(bin.args.entries.len == 0);

    const args_num_ptr: *usize = try bin.args.entries.addOne();
    for (args) |arg| try bin.args.printArgument("{s}", .{arg});

    args_num_ptr.* = bin.args.entries.len - 1;
    try bin.args.entries.append(0);

    for (envs) |env| try bin.args.printArgument("{s}", .{env});
    try bin.args.entries.append(0);
}

fn buildAuxVectors(bin: *exe.Binary, elf_hdr: *const elf.Header, interp_base: ?usize, phdrs_ptr: usize) exe.Error!void {
    const file_name_ptr = bin.args.getCurrentPtr();
    bin.args.writer.print("{f}\x00", .{bin.file.dentry.path()}) catch return error.NoMemory;

    const platform_ptr = bin.args.getCurrentPtr();
    bin.args.writer.print("{t}\x00", .{builtin.target.cpu.arch}) catch return error.NoMemory;
    bin.args.alignWriter(@alignOf(usize)) catch return error.NoMemory;

    const rand_ptr = bin.args.getCurrentPtr();
    var rand = std.Random.Xoroshiro128.init(sys.time.getUpTime().toNs());
    const entropy: [2]u64 = .{ rand.next(), rand.next() };

    bin.args.writer.writeAll(std.mem.asBytes(&entropy)) catch return error.NoMemory;

    try bin.args.appendAuxv(elf.AT_PAGESZ, vm.page_size);
    try bin.args.appendAuxv(elf.AT_BASE, interp_base orelse bin.virt_base);
    try bin.args.appendAuxv(elf.AT_FLAGS, 0);
    try bin.args.appendAuxv(elf.AT_ENTRY, elf_hdr.entry + bin.virt_base);
    try bin.args.appendAuxv(elf.AT_PHDR, phdrs_ptr);
    try bin.args.appendAuxv(elf.AT_PHNUM, elf_hdr.phnum);
    try bin.args.appendAuxv(elf.AT_PHENT, elf_hdr.phentsize);
    try bin.args.appendAuxv(elf.AT_UID, bin.proc.uid);
    try bin.args.appendAuxv(elf.AT_EUID, bin.proc.uid);
    try bin.args.appendAuxv(elf.AT_GID, bin.proc.gid);
    try bin.args.appendAuxv(elf.AT_EGID, bin.proc.gid);
    try bin.args.appendAuxv(elf.AT_SECURE, 0);
    try bin.args.appendAuxv(elf.AT_RANDOM, rand_ptr);
    try bin.args.appendAuxv(elf.AT_EXECFN, file_name_ptr);
    try bin.args.appendAuxv(elf.AT_PLATFORM, platform_ptr);
    try bin.args.appendAuxv(elf.AT_NULL, 0);
}
