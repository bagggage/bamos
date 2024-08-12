const std = @import("std");
const dbg = @import("dbg.zig");

pub const Config = struct {
    input: []const u8 = undefined,
    output: []const u8 = undefined,
};

const DebugEntry = struct {
    addr: usize = undefined,
    size: u32 = undefined,
    name: [64]u8 = undefined,

    pub fn init(addr: usize, size: u32, name: *const [64]u8) DebugEntry {
        var result = DebugEntry{
            .addr = addr,
            .size = size,
        };

        @memcpy(&result.name, name);
        result.name[result.name.len - 1] = 0;

        return result;
    }
};

const DebugEntArray = std.ArrayList(DebugEntry);

pub fn makeDebugInfo(config: *const Config, allocator: std.mem.Allocator) !void {
    var debug_entries = DebugEntArray.init(allocator);
    defer debug_entries.deinit();

    const elf_file = try std.fs.openFileAbsolute(config.input, .{});
    defer elf_file.close();

    var header = try std.elf.Header.read(elf_file);
    const strtab_offset = try elfGetStrtabOffset(elf_file, &header);

    var section = header.section_header_iterator(elf_file);

    while (try section.next()) |sect| {
        if (sect.sh_type != std.elf.SHT_SYMTAB) continue;

        try elf_file.seekTo(sect.sh_offset);

        for (0..(sect.sh_size / sect.sh_entsize)) |_| {
            var symbol: std.elf.Sym = undefined;
            const buffer = @as([*]u8, @ptrCast(&symbol))[0..@sizeOf(std.elf.Sym)];

            _ = elf_file.read(buffer) catch break;

            if (symbol.st_type() != std.elf.STT_FUNC) continue;

            var symbol_name: [64]u8 = undefined;
            const name: [*:0]u8 = @ptrCast(&symbol_name);

            try elfReadName(elf_file, strtab_offset, symbol.st_name, symbol_name[0..]);

            if (std.mem.eql(u8, name[0..2], "__")) continue;

            try debug_entries.append(DebugEntry.init(symbol.st_value, @truncate(symbol.st_size), &symbol_name));
        }

        break;
    }

    try saveDebugInfo(config.output, &debug_entries);
    try makeDebugScript(config.output, allocator);
}

fn makeDebugScript(path: []const u8, allocator: std.mem.Allocator) !void {
    const script_path = try std.mem.concat(allocator, u8, &.{path, ".zig"});
    defer allocator.free(script_path);

    const out_file = try std.fs.createFileAbsolute(script_path, .{});

    try std.fmt.format(
        out_file.writer(),
        \\const dbg = @import("dbg-info");
        \\
        \\const debug_syms = @embedFile("{s}");
        \\
        \\export fn getDebugSyms() *const dbg.Header {{
        \\    return @ptrCast(@alignCast(debug_syms));
        \\}}
        , .{path}
    );
}

fn saveDebugInfo(path: []const u8, debug_entries: *const DebugEntArray) !void {
    const out_file = try std.fs.createFileAbsolute(path, .{});
    defer out_file.close();

    const strtab_offset = @sizeOf(dbg.Header) + (@sizeOf(dbg.Entry) * debug_entries.items.len);
    const header = dbg.Header{
        .entries_num = @truncate(debug_entries.items.len),
        .strtab_offset = @truncate(strtab_offset)
    };

    try writeStruct(dbg.Header, out_file, &header);

    var strtab_idx: usize = 0;

    // Write entries
    for (debug_entries.items[0..]) |*entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name_len = std.mem.len(name_ptr);

        const file_entry = dbg.Entry{
            .addr = @truncate(entry.addr),
            .size = entry.size,
            .name_offset = @truncate(strtab_idx),
        };

        strtab_idx += name_len + 1;

        try writeStruct(dbg.Entry, out_file, &file_entry);
    }

    // Write string table
    for (debug_entries.items[0..]) |*entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name_len = std.mem.len(name_ptr);

        var buffer: []const u8 = undefined;
        buffer.ptr = @ptrCast(name_ptr);
        buffer.len = name_len + 1;

        _ = try out_file.write(buffer);
    }
}

fn writeStruct(comptime T: type, file: std.fs.File, strct: *const T) !void {
    const buffer = @as(*const [@sizeOf(T)]u8, @ptrCast(strct));
    _ = try file.write(buffer[0..]);
}

fn elfReadName(file: std.fs.File, strtab_offset: usize, st_idx: u32, buffer: []u8) !void {
    const prev_pos = try file.getPos();

    try file.seekTo(strtab_offset + st_idx);
    _ = try file.read(buffer);

    try file.seekTo(prev_pos);
}

fn elfGetStrtabOffset(file: std.fs.File, hdr: *const std.elf.Header) !usize {
    var section = hdr.section_header_iterator(file);
    const shstrtab_name = ".shstrtab";
    var shstrtab_buff: [shstrtab_name.len]u8 = undefined;

    while (try section.next()) |sect| {
        if (sect.sh_type == std.elf.SHT_STRTAB) {
            const prev_pos = try file.getPos();

            try file.seekTo(sect.sh_offset + sect.sh_name);
            _ = try file.read(shstrtab_buff[0..]);
    
            try file.seekTo(prev_pos);

            if (std.mem.eql(u8, shstrtab_name[0..], shstrtab_buff[0..])) continue;

            return sect.sh_offset;
        }
    }

    unreachable;
}