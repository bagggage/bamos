const acpi = @import("../../dev/stds/acpi.zig");
const log = @import("../../log.zig");
const lapic = @import("lapic.zig");
const regs = @import("regs.zig");
const intr = @import("intr.zig");

const Spinlock = @import("../../Spinlock.zig");

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

pub fn preinit() void {
    init_lock.lock();

    if (is_initial_cpu) {
        is_initial_cpu = false;
    } else {
        waitForInit();
    }

    initCpu(true);
}

pub inline fn getCpuIdx() u32 {
    return lapic.getId();
}

fn waitForInit() void {
    init_lock.lock();
    init_lock.unlock();
}

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
        ::: "rcx", "rax", "rdx");

    if (is_initial) {
        vm.preinit();
        intr.preinit();

        acpi.init();
        lapic.init();
    }

    var gdtr: regs.GDTR = regs.getGdtr();
    gdtr.base += vm.dma_start;
    regs.setGdtr(gdtr);
}
