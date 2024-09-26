//! # x86-64 Architecture specific implementation
//! 
//! This module handles the initialization and management of the x86-64 CPU, 
//! Setup of control registers, enabling specific CPU features.

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

pub const io = @import("io.zig");
pub const intr = @import("intr.zig");
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
    return if (lapic.isInitialized()) lapic.getId() else @truncate(cpuid(cpuid_features).b >> 24);
}

pub inline fn smpInit() void {
    init_lock.unlock();
}

/// Initialize architecture dependent devices.
pub inline fn devInit() !void {
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

pub inline fn halt() void {
    asm volatile("hlt");
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