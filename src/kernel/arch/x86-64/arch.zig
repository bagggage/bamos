//! # x86-64 Architecture specific implementation
//! 
//! This module handles the initialization and management of the x86-64 CPU, 
//! Setup of control registers, enabling specific CPU features.

const std = @import("std");

const boot = @import("../../boot.zig");
const gdt = @import("gdt.zig");
const hlvl_vm = @import("../../vm.zig");
const lapic = @import("intr/lapic.zig");
const log = @import("../../log.zig");
const regs = @import("regs.zig");
const utils = @import("../../utils.zig");

const Spinlock = utils.Spinlock;

const CpuId = packed struct {
    a: u32,
    b: u32,
    c: u32, 
    d: u32
};

const CpuVendor = enum {
    unknown,
    Intel,
    AMD
};

pub const io = @import("io.zig");
pub const intr = @import("intr.zig");
pub const vm = @import("vm.zig");

pub const cpuid_features = 1;

var init_lock = Spinlock.init(.unlocked);
var is_initial_cpu = true;

var cpu_vendor: CpuVendor = undefined;
var cpu_idx_bitmask: u32 = undefined;
var cpu_idx_shift: u3 = 0;

/// `_start` implementation
pub inline fn startImpl() void {
    asm volatile (
        \\push 0x0
        \\jmp main
    );
}

/// Ensure that only one CPU is performing the initialization at a time.
/// If the CPU is the initial one, it will proceed to initialization.
/// If not, it waits until the initialization lock is available.
pub fn preinit() void {
    init_lock.lock();

    if (is_initial_cpu) {
        is_initial_cpu = false;
    } else {
        waitForInit();
    }

    initCpu(true);
}

/// This function retrieves the current CPU's
/// local APIC ID, which is used to identify the CPU uniquely.
/// 
/// - Returns: The Local APIC ID.
pub inline fn getCpuIdx() u32 {
    const lapic_id =
    if (lapic.isInitialized())
        lapic.getId()
    else
        cpuid(cpuid_features, undefined, undefined, undefined).b >> 24;

    return (lapic_id >> cpu_idx_shift) & cpu_idx_bitmask;
}

pub inline fn smpInit() void {
    init_lock.unlock();
}

/// Initialize architecture dependent devices.
pub inline fn devInit() !void {
}

pub inline fn cpuid(eax: u32, ebx: u32, ecx: u32, edx: u32) CpuId {
    @setRuntimeSafety(false);

    var a: u32 = eax;
    var b: u32 = ebx;
    var c: u32 = ecx;
    var d: u32 = edx;

    asm volatile(
        \\cpuid
        : [a]"={eax}"(a),[b]"={ebx}"(b),[c]"={ecx}"(c),[d]"={edx}"(d)
        : [id]"{eax}"(a),[i_b]"{ebx}"(b),[i_c]"{ecx}"(c),[i_d]"{edx}"(d)
    );

    return .{ .a = a, .b = b, .c = c, .d = d };
}

pub inline fn halt() void {
    asm volatile("hlt");
}

pub inline fn getCpuVendor() []const u8 {
    return @tagName(cpu_vendor);
}

/// Wait for initialization to complete.
inline fn waitForInit() void {
    initCpu(false);

    init_lock.unlock();

    log.warn("CPU {} initialized", .{getCpuIdx()});
    utils.halt();
}

/// This function initializes the CPU's essential features and settings, such as enabling the 
/// No-Execute bit, system call extensions, and AVX.
/// 
/// If the CPU is the initial CPU, it also performs additional
/// preinitializing the virtual memory system, the interrupt system, and etc.
fn initCpu(comptime is_primary: bool) void {
    @setRuntimeSafety(false);
    enableExtentions();

    if (is_primary) {
        initCpuIdx();

        vm.preinit();

        gdt.init();
        intr.preinit();
    } else {
        vm.setPt(hlvl_vm.getRootPt());

        const pt = hlvl_vm.newPt() orelse {
            log.err("Not enough memory to allocate page table per each cpu", .{});
            utils.halt();
        };

        vm.setPt(pt);
    }

    const cpu_idx: u8 = @truncate(getCpuIdx());

    gdt.setupCpu();

    intr.setupCpu(cpu_idx);
    intr.enable();
}

/// Enables kernel needed CPUs extentions
/// - syscall/sysret
/// - non-executable pages
inline fn enableExtentions() void {
    var efer = regs.getEfer();
    efer.noexec_enable = 1;
    efer.syscall_ext = 1;
    regs.setEfer(efer);
}

/// Enable AVX
inline fn enableAvx() void {
    asm volatile (
        \\mov %%cr4,%%rax
        \\or $0x40600,%%rax
        \\mov %%rax,%%cr4
        \\xor %%rcx,%%rcx
        \\xgetbv
        \\or $7,%%rax
        \\xsetbv
        ::: "rcx", "rax", "rdx"
    );
}

fn initCpuIdx() void {
    const amd_ecx = 0x444d4163; // "cAMD"
    const intel_ecx = 0x6c65746e; // "ntel"

    const cpuid0_ecx = cpuid(0, undefined, 0, undefined).c;

    switch (cpuid0_ecx) {
        amd_ecx => cpu_vendor = .AMD,    
        intel_ecx => cpu_vendor = .Intel,
        else => cpu_vendor = .unknown
    }

    const bits_number = switch (cpu_vendor) {
        .AMD => blk: {
            const temp = cpuid(0x80000008, undefined, undefined, undefined).c;

            break :blk if ((temp & 0xF000) != 0) ((temp >> 12) & 0xF) else {
                const cores_num = (temp & 0xF) + 1;
                break :blk std.math.log2_int_ceil(u32, cores_num);
            };
        },
        .Intel => blk: {
            cpu_idx_shift = @truncate(cpuid(0x0B, undefined, 0, undefined).a);

            break :blk std.math.log2_int_ceil(u32, boot.getCpusNum());
        },
        else => @bitSizeOf(u32)
    };

    cpu_idx_bitmask = (@as(u32, 1) << @truncate(bits_number)) - 1;
}