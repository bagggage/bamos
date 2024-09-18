//! # x86-64 Architecture specific implementation
//! 
//! This module handles the initialization and management of the x86-64 CPU, 
//! Setup of control registers, enabling specific CPU features.

const lapic = @import("lapic.zig");
const log = @import("../../log.zig");
const regs = @import("regs.zig");
const intr = @import("intr.zig");
const utils = @import("../../utils.zig");

const Spinlock = utils.Spinlock;

const CpuId = packed struct {
    a: u32,
    b: u32,
    c: u32, 
    d: u32
};

pub const io = @import("io.zig");
pub const vm = @import("vm.zig");

pub const cpuid_features = 1;

var init_lock = Spinlock.init(.unlocked);
var is_initial_cpu = true;

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
    return lapic.getId();
}

/// Initialize architecture dependent devices.
pub fn devInit() !void {
    lapic.init() catch |err| log.info("APIC not initialized: {}", .{err});
}

pub inline fn cpuid(leaf: u32) CpuId {
    @setRuntimeSafety(false);

    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;

    asm volatile(
        \\cpuid
        : [a]"={eax}"(a),[b]"={ebx}"(b),[c]"={ecx}"(c),[d]"={edx}"(d)
        : [id]"{eax}"(leaf)
    );

    return .{ .a = a, .b = b, .c = c, .d = d };
}

/// Wait for initialization to complete.
inline fn waitForInit() void {
    init_lock.lock();
    init_lock.unlock();

    initCpu(false);
}

/// This function initializes the CPU's essential features and settings, such as enabling the 
/// No-Execute bit, system call extensions, and AVX.
/// 
/// If the CPU is the initial CPU, it also performs additional
/// preinitializing the virtual memory system, the interrupt system, and etc.
fn initCpu(comptime is_initial: bool) void {
    @setRuntimeSafety(false);

    enableExtentions();

    if (is_initial) initPrimaryCpu();

    gdtSwitchToLma();
}

inline fn initPrimaryCpu() void {
    vm.preinit();
    intr.preinit();
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

/// Translate GDT base in GDTR to LMA virtual address
inline fn gdtSwitchToLma() void {
    var gdtr: regs.GDTR = regs.getGdtr();
    gdtr.base += vm.lma_start;
    regs.setGdtr(gdtr);
}