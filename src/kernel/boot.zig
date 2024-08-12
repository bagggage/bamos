const c = @cImport({
    @cInclude("stdint.h");
    @cInclude("bootboot.h");
});

const std = @import("std");
const log = @import("log.zig");
const utils = @import("utils.zig");
const vm = @import("vm.zig");

const Framebuffer = @import("video/Framebuffer.zig");

// Kernel linking symbols.
// Defined at `config/linker.ld`
extern "C" var bootboot: c.BOOTBOOT;
extern "C" const mmio: u32;

pub extern "C" var fb: u32;
pub extern "C" const environment: u32;
pub extern "C" const initstack: u32;
pub extern "C" const kernel_elf_start: u32;
pub extern "C" const kernel_elf_end: u32;

pub const MemMap = struct {
    pub const Entry = struct {
        const Type = enum(u8) { free, dev, used };

        base: u32,
        pages: u32,
        type: Type,
    };

    entries: [*]Entry,
    len: u32,

    pub inline fn isEmpty(self: *const @This()) bool {
        return self.len == 0;
    }

    pub inline fn maxPage(self: *const @This()) u32 {
        var i = self.len;

        while (i > 0) : (i -= 1) {
            const entry = &self.entries[i - 1];

            if (entry.type != .free) continue;
            return entry.base + entry.pages - 1;
        }

        return 0;
    }

    pub fn remove(self: *@This(), idx: usize) void {
        self.len -= 1;

        if (idx == self.len) return;

        for (0..self.len) |i| {
            self.entries[i] = self.entries[i + 1];
        }
    }
};

const MappingEntry = struct {
    virt: usize = undefined,
    phys: usize = undefined,
    pages: u32 = undefined,
    flags: vm.MapFlags = undefined,

    pub fn init(virt: usize, phys: usize, size: usize, flags: vm.MapFlags) MappingEntry {
        const pages = std.math.divCeil(usize, size, vm.page_size) catch unreachable;

        return MappingEntry{ .virt = virt, .phys = phys, .pages = @truncate(pages), .flags = flags };
    }
};

const mapNull = MappingEntry.init(0, 0, 0, .{});

var mem_map: MemMap = undefined;

fn makeColorFmt(bb_fmt: u8) Framebuffer.ColorFormat {
    return switch (bb_fmt) {
        c.FB_ABGR => .ABGR,
        c.FB_ARGB => .ARGB,
        c.FB_BGRA => .BRGA,
        c.FB_RGBA => .RGBA,
        else => unreachable,
    };
}

pub fn getFb(fb_ptr: *Framebuffer) void {
    fb_ptr.* = .{ .base = @ptrCast(&fb), .width = bootboot.fb_width, .height = bootboot.fb_height, .scanline = bootboot.fb_scanline / @sizeOf(u32), .format = makeColorFmt(bootboot.fb_type) };
}

pub inline fn getMappings() vm.Error![]MappingEntry {
    const MMap = MappingEntry;
    const Order = enum { DMA, Fb, Boot, Kernel, Envir, Stack };

    const buffer = vm.PageAllocator.alloc(0) orelse return vm.Error.NoMemory;
    const mappings: [*]MMap = @ptrFromInt(vm.getVirtDma(buffer));

    mappings[@intFromEnum(Order.DMA)] = MMap.init(vm.dma_start, 0x0, vm.dma_size, .{ .write = true, .global = true, .large = true });
    mappings[@intFromEnum(Order.Fb)] = MMap.init(@intFromPtr(&fb), bootboot.fb_ptr, 16 * utils.mb_size, .{ .write = true, .global = true, .large = true, .cache_disable = true });
    mappings[@intFromEnum(Order.Boot)] = MMap.init(@intFromPtr(&bootboot), @intFromPtr(vm.getPhys(&bootboot) orelse unreachable), vm.page_size, .{ .write = true, .global = true });

    const kernel_elf_size = @intFromPtr(&kernel_elf_end) - @intFromPtr(&kernel_elf_start);

    mappings[@intFromEnum(Order.Kernel)] = MMap.init(@intFromPtr(&kernel_elf_start), @intFromPtr(vm.getPhys(&kernel_elf_start) orelse unreachable), kernel_elf_size, .{ .write = true, .global = true, .exec = true });
    mappings[@intFromEnum(Order.Envir)] = MMap.init(@intFromPtr(&environment), @intFromPtr(vm.getPhys(&environment) orelse unreachable), vm.page_size, .{ .write = true, .global = true });

    const stack_size = @intFromPtr(&initstack);
    const stack_pages = std.math.divCeil(usize, bootboot.numcores * stack_size, vm.page_size) catch unreachable;
    const stack_base = std.math.maxInt(usize) - vm.page_size + 1;

    for (0..stack_pages) |page_idx| {
        const base = stack_base - (page_idx * vm.page_size);

        mappings[@intFromEnum(Order.Stack) + page_idx] = MMap.init(base, vm.getPhys(base) orelse unreachable, vm.page_size, .{ .write = true, .global = true });
    }

    return mappings[0 .. @intFromEnum(Order.Stack) + stack_pages];
}

pub inline fn freeMappings(mappings: []MappingEntry) void {
    vm.PageAllocator.free(@intFromPtr(vm.getPhysDma(mappings.ptr)), 0);
}

pub inline fn getMemMap() *const MemMap {
    return &mem_map;
}

pub inline fn getCpusNum() u16 {
    return bootboot.numcores;
}

pub inline fn getArchData() @TypeOf(&bootboot.arch) {
    return &bootboot.arch;
}

pub fn alloc(pages: u32) ?usize {
    if (vm.PageAllocator.isInitialized()) {
        @panic(
            \\Using boot memory allocator is not available after initialization,
            \\use page allocator instead.
        );
    }

    if (mem_map.isEmpty()) initMemMap();

    for (mem_map.entries[0..mem_map.len], 0..mem_map.len) |*entry, i| {
        if (entry.pages < pages or entry.type != .free) continue;

        const base = entry.base + entry.pages - pages;

        if (base == entry.base) {
            mem_map.remove(i);
        } else {
            entry.pages -= pages;
        }

        return base * vm.page_size;
    }

    return null;
}

pub inline fn switchToDma() void {
    mem_map.entries = vm.getVirtDma(mem_map.entries);
}

var _debug_offset: u32 = 0;

pub fn debug() void {
    const dest: [*]u32 = @ptrCast(&fb);
    const start = _debug_offset;
    _debug_offset += bootboot.fb_scanline;
    const end = _debug_offset;
    _debug_offset += bootboot.fb_scanline;

    @memset(dest[start..end], 0xFFFFFFFF);
}

inline fn calcMmapSize() usize {
    return (@as(usize, bootboot.size) -
        (@intFromPtr(&bootboot.mmap) -
        @intFromPtr(&bootboot))) / @sizeOf(c.MMapEnt);
}

fn earlyAlloc(pages: u32) ?usize {
    const len = calcMmapSize();
    const entries: [*]c.MMapEnt = @ptrCast(&bootboot.mmap);

    for (entries[0..len]) |*entry| {
        const pages_num = c.MMapEnt_Size(entry) / vm.page_size;

        if (pages_num >= pages and c.MMapEnt_Type(entry) == c.MMAP_FREE) {
            const result = c.MMapEnt_Ptr(entry) + ((pages_num - pages) * vm.page_size);
            entry.size = (c.MMapEnt_Size(entry) - (pages * vm.page_size)) | c.MMapEnt_Type(entry);

            return result;
        }
    }

    return null;
}

fn initMemMap() void {
    mem_map.len = @truncate(calcMmapSize());

    const page = earlyAlloc(1);
    mem_map.entries = @ptrFromInt(page.?);

    const boot_ents: [*]const c.MMapEnt = @ptrCast(&bootboot.mmap);

    var invalid_ents: u32 = 0;
    var j: u32 = 0;
    var i: u32 = 0;

    while (i < mem_map.len) : (i += 1) {
        const boot_ent = &boot_ents[i];
        const ent = &mem_map.entries[j];

        if (c.MMapEnt_Size(boot_ent) == 0) continue;

        if (((c.MMapEnt_Size(boot_ent) % vm.page_size) > 0) or
            ((c.MMapEnt_Ptr(boot_ent) % vm.page_size) > 0))
        {
            invalid_ents += 1;
            continue;
        }

        const base: u32 = @truncate(c.MMapEnt_Ptr(boot_ent) / vm.page_size);

        ent.base = base;
        ent.pages = @truncate(c.MMapEnt_Size(boot_ent) / vm.page_size);
        ent.type = switch (c.MMapEnt_Type(boot_ent)) {
            c.MMAP_ACPI, c.MMAP_MMIO => .dev,
            c.MMAP_USED => .used,
            c.MMAP_FREE => .free,
            else => unreachable,
        };

        j += 1;
    }

    mem_map.len = j;

    if (invalid_ents > 0) log.err("Invalid memory map entries: {}", .{invalid_ents});
}
