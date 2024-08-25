//! # x86-64 Architecture specific implementation
//! 
//! This module handles the initialization and management of the x86-64 CPU, 
//! Setup of control registers, enabling specific CPU features.

const acpi = @import("../../dev/stds/acpi.zig");
const log = @import("../../log.zig");
const lapic = @import("lapic.zig");
const regs = @import("regs.zig");
const intr = @import("intr.zig");
const utils = @import("../../utils.zig");

const Spinlock = @import("../../Spinlock.zig");

pub const io = @import("io.zig");
pub const vm = @import("vm.zig");

pub const CPUID_GET_FEATURE = 1;

var init_lock = Spinlock.init(Spinlock.UNLOCKED);
var is_initial_cpu = true;

pub inline fn startImpl() void {
    asm volatile (
        \\push 0x0
        \\jmp main
    );
}

/// Ensure that only one CPU is performing the initialization at a time.
/// If the CPU is the initial one, it will proceed to initialization. If not, it waits until 
/// the initialization lock is available.
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

/// Wait for initialization to complete.
fn waitForInit() void {
    init_lock.lock();
    init_lock.unlock();
}

/// This function initializes the CPU's essential features and settings, such as enabling the 
/// No-Execute (NX) bit, system call extensions, and AVX (Advanced Vector Extensions).
/// 
/// If the CPU is the initial CPU, it also performs additional system-wide initialization, 
/// including preinitializing the virtual memory (VM) system, the interrupt system, and etc.
fn initCpu(is_initial: bool) void {
    var efer = regs.getEfer();
    efer.noexec_enable = 1;
    efer.syscall_ext = 1;
    regs.setEfer(efer);

    // Enable AVX
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

    if (is_initial) {
        vm.preinit();
        intr.preinit();

        acpi.init();
        lapic.init();
    }

    var gdtr: regs.GDTR = regs.getGdtr();
    gdtr.base += vm.lma_start;
    regs.setGdtr(gdtr);
}
