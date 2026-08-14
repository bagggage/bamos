//! # uACPI integration layer
//!
//! uACPI is the open-source AML interpreter used in BamOS.
//! See https://github.com/uACPI/uACPI for more information.

const std = @import("std");

const c = @cImport(
    @cInclude("uacpi/uacpi.h")
);

const boot = @import("../../../boot.zig");
const dev = @import("../../../dev.zig");
const lib = @import("../../../lib.zig");
const log = std.log.scoped(.uacpi);
const logger = @import("../../../logger.zig");
const panic = @import("../../../panic.zig");
const sched = @import("../../../sched.zig");
const sys = @import("../../../sys.zig");
const vm = @import("../../../vm.zig");

comptime {
    @export(&getRsdp, .{ .name = "uacpi_kernel_get_rsdp" });
    @export(&map,     .{ .name = "uacpi_kernel_map" });
    @export(&unmap,   .{ .name = "uacpi_kernel_unmap" });
    @export(&pciDeviceOpen, .{ .name = "uacpi_kernel_pci_device_open" });
    @export(&pciDeviceClose, .{ .name = "uacpi_kernel_pci_device_close" });
    @export(&pciRead8, .{ .name = "uacpi_kernel_pci_read8" });
    @export(&pciRead16, .{ .name = "uacpi_kernel_pci_read16" });
    @export(&pciRead32, .{ .name = "uacpi_kernel_pci_read32" });
    @export(&pciWrite8, .{ .name = "uacpi_kernel_pci_write8" });
    @export(&pciWrite16, .{ .name = "uacpi_kernel_pci_write16" });
    @export(&pciWrite32, .{ .name = "uacpi_kernel_pci_write32" });
    @export(&ioMap, .{ .name = "uacpi_kernel_io_map" });
    @export(&ioUnmap, .{ .name = "uacpi_kernel_io_unmap" });
    @export(&ioRead8, .{ .name = "uacpi_kernel_io_read8" });
    @export(&ioRead16, .{ .name = "uacpi_kernel_io_read16" });
    @export(&ioRead32, .{ .name = "uacpi_kernel_io_read32" });
    @export(&ioWrite8, .{ .name = "uacpi_kernel_io_write8" });
    @export(&ioWrite16, .{ .name = "uacpi_kernel_io_write16" });
    @export(&ioWrite32, .{ .name = "uacpi_kernel_io_write32" });
    @export(&alloc, .{ .name = "uacpi_kernel_alloc" });
    @export(&allocZeroed, .{ .name = "uacpi_kernel_alloc_zeroed" });
    @export(&free, .{ .name = "uacpi_kernel_free" });
    @export(&free, .{ .name = "uacpi_kernel_free_spinlock" });
    @export(&free, .{ .name = "uacpi_kernel_free_mutex" });
    @export(&free, .{ .name = "uacpi_kernel_free_event" });
    @export(&createSpinlock, .{ .name = "uacpi_kernel_create_spinlock" });
    @export(&createMutex, .{ .name = "uacpi_kernel_create_mutex" });
    @export(&createEvent, .{ .name = "uacpi_kernel_create_event" });
    @export(&lockSpinlock, .{ .name = "uacpi_kernel_lock_spinlock" });
    @export(&unlockSpinlock, .{ .name = "uacpi_kernel_unlock_spinlock" });
    @export(&acquireMutex, .{ .name = "uacpi_kernel_acquire_mutex" });
    @export(&releaseMutex, .{ .name = "uacpi_kernel_release_mutex" });
    @export(&signalEvent, .{ .name = "uacpi_kernel_signal_event" });
    @export(&waitForEvent, .{ .name = "uacpi_kernel_wait_for_event" });
    @export(&resetEvent, .{ .name = "uacpi_kernel_reset_event" });
    @export(&sleep, .{ .name = "uacpi_kernel_sleep" });
    @export(&stall, .{ .name = "uacpi_kernel_stall" });
    @export(&getNanosecondsSinceBoot, .{ .name = "uacpi_kernel_get_nanoseconds_since_boot" });
    @export(&scheduleWork, .{ .name = "uacpi_kernel_schedule_work" });
    @export(&waitForWorkCompletion, .{ .name = "uacpi_kernel_wait_for_work_completion" });
    @export(&firmwareRequest, .{ .name = "uacpi_kernel_handle_firmware_request" });
    @export(&installInterruptHandler, .{ .name = "uacpi_kernel_install_interrupt_handler" });
    @export(&uninstallInterruptHandler, .{ .name = "uacpi_kernel_uninstall_interrupt_handler" });
    @export(&disableInterrupts, .{ .name = "uacpi_kernel_disable_interrupts" });
    @export(&restoreInterrupts, .{ .name = "uacpi_kernel_restore_interrupts" });
    @export(&getThreadId, .{ .name = "uacpi_kernel_get_thread_id" });
    @export(&kernelLog, .{ .name = "uacpi_kernel_log" });
}

const Irq = struct {
    pin: u32,
    func: c.uacpi_interrupt_handler = null,
    ctx: c.uacpi_handle = null,
};

pub fn init() !void {
    //if (c.uacpi_initialize(0) != c.UACPI_STATUS_OK) return error.UacpiFailed;
    //if (c.uacpi_namespace_load() != c.UACPI_STATUS_OK) return error.UacpiLoadFailed;
    //if (c.uacpi_namespace_initialize() != c.UACPI_STATUS_OK) return error.UacpiNamespaceFailed;

    log.info("initialized", .{});
}

pub fn shutdown() void {
    var int_arg = c.uacpi_object_create_integer(5);
    const args: c.uacpi_object_array = .{
        .objects = &int_arg,
        .count = 1,
    };

    const status = c.uacpi_execute(c.uacpi_namespace_root(), "\\_PTS", &args);
    if (status != c.UACPI_STATUS_OK) log.err("power off failed: 0x{x}", .{status});
}

pub fn namespaceRoot() *c.uacpi_namespace_node {
    c.uacpi_namespace_root().?;
}

/// Returns the PHYSICAL address of the RSDP structure via *out_rsdp_address.
fn getRsdp(out: *c.uacpi_phys_addr) callconv(.c) c.uacpi_status {
    const rsdp_sign = "RSD PTR ";

    const efi = boot.getArchData().acpi_ptr -| 0x10000;
    const efi_buffer = @as([*]const u8, @ptrFromInt(vm.getVirtLma(efi)))[0..0x20000];

    const idx = std.mem.indexOf(u8, efi_buffer, rsdp_sign) orelse {
        const ebda: usize = @as(*const u16, @ptrFromInt(vm.getVirtLma(0x40e))).*;
        const ebda_buffer = @as([*]const u8, @ptrFromInt(vm.getVirtLma(ebda)))[0..0x400];

        const idx = std.mem.indexOf(u8, ebda_buffer, rsdp_sign) orelse return c.UACPI_STATUS_NOT_FOUND;
        out.* = ebda + idx;

        return c.UACPI_STATUS_OK;
    };

    out.* = efi + idx;
    return c.UACPI_STATUS_OK;
}

// Map a physical memory range starting at 'addr' with length 'len', and return
// a virtual address that can be used to access it.
fn map(addr: c.uacpi_phys_addr, len: c.uacpi_size) callconv(.c) c.uacpi_virt_addr {
    log.debug("map: 0x{x}", .{addr});
    if (addr + len < vm.lmaSize()) return vm.getVirtLma(addr);

    return @intFromPtr(c.UACPI_MAP_FAILED);
}

/// Unmap a virtual memory range at 'addr' with a length of 'len' bytes.
fn unmap(addr: ?*anyopaque, len: c.uacpi_size) callconv(.c) void {
    _ = addr; _ = len;
}

// Open a PCI device at 'address' for reading & writing.
//
// The handle returned via 'out_handle' is used to perform IO on the
// configuration space of the device.
fn pciDeviceOpen(address: c.uacpi_pci_address, out_handle: *c.uacpi_handle) callconv(.c) c.uacpi_status {
    const device = dev.pci.findDevice(
        address.segment,
        address.bus,
        address.device,
        address.function,
    ) orelse return c.UACPI_STATUS_NOT_FOUND;

    out_handle.* = device;

    log.debug("pci open {}:{}.{}.{} - 0x{x}", .{
        address.segment, address.bus, address.device, address.function, @intFromPtr(device)
    });
    return c.UACPI_STATUS_OK;
}

fn pciDeviceClose(handle: c.uacpi_handle) callconv(.c) void {
    _ = handle;
}

// Read & write the configuration space of a previously open PCI device.
fn pciRead8(
    device: c.uacpi_handle, offset: c.uacpi_size, value: *u8
) callconv(.c) c.uacpi_status {
    if (!std.mem.isAligned(offset, @sizeOf(u32))) @panic("not aligned pci read8");

    const pci_dev: *dev.pci.Device = @alignCast(@ptrCast(device.?));
    value.* = @truncate(pci_dev.config.read(offset));

    return c.UACPI_STATUS_OK;
}

fn pciRead16(
    device: c.uacpi_handle, offset: c.uacpi_size, value: *u16
) callconv(.c) c.uacpi_status {
    if (!std.mem.isAligned(offset, @sizeOf(u32))) @panic("not aligned pci read16");

    const pci_dev: *dev.pci.Device = @alignCast(@ptrCast(device.?));
    value.* = @truncate(pci_dev.config.read(offset));

    return c.UACPI_STATUS_OK;
}

fn pciRead32(
    device: c.uacpi_handle, offset: c.uacpi_size, value: *u32
) callconv(.c) c.uacpi_status {
    const pci_dev: *dev.pci.Device = @alignCast(@ptrCast(device.?));
    value.* = pci_dev.config.read(offset);

    return c.UACPI_STATUS_OK;
}

fn pciWrite8(
    device: c.uacpi_handle, offset: c.uacpi_size, value: u8
) callconv(.c) c.uacpi_status {
    const pci_dev: *dev.pci.Device = @alignCast(@ptrCast(device.?));
    pci_dev.config.write(offset, value);

    return c.UACPI_STATUS_OK;
}

fn pciWrite16(
    device: c.uacpi_handle, offset: c.uacpi_size, value: u16
) callconv(.c) c.uacpi_status {
    const pci_dev: *dev.pci.Device = @alignCast(@ptrCast(device.?));
    pci_dev.config.write(offset, value);

    return c.UACPI_STATUS_OK;
}

fn pciWrite32(
    device: c.uacpi_handle, offset: c.uacpi_size, value: u32
) callconv(.c) c.uacpi_status {
    const pci_dev: *dev.pci.Device = @alignCast(@ptrCast(device.?));
    pci_dev.config.write(offset, value);

    return c.UACPI_STATUS_OK;
}

/// Map a SystemIO address at [base, base + len) and return a kernel-implemented
/// handle that can be used for reading and writing the IO range.
///
/// NOTE: The x86 architecture uses the in/out family of instructions
///       to access the SystemIO address space.
fn ioMap(
    base: c.uacpi_io_addr, len: c.uacpi_size, out_handle: *c.uacpi_handle
) callconv(.c) c.uacpi_status {
    const addr = dev.io.request("uacpi", base, len, .io_ports)
        orelse return c.UACPI_STATUS_MAPPING_FAILED;

    out_handle.* = @ptrFromInt(addr);
    return c.UACPI_STATUS_OK;
}

fn ioUnmap(handle: c.uacpi_handle) callconv(.c) void {
    dev.io.release(@intFromPtr(handle), .io_ports);
}

// Read/Write the IO range mapped via uacpi_kernel_io_map
// at a 0-based 'offset' within the range.
//
// NOTE:
// The x86 architecture uses the in/out family of instructions
// to access the SystemIO address space.
//
// You are NOT allowed to break e.g. a 4-byte access into four 1-byte accesses.
// Hardware ALWAYS expects accesses to be of the exact width.
fn ioRead8(
    handle: c.uacpi_handle, offset: c.uacpi_size, out: *u8
) callconv(.c) c.uacpi_status {
    const addr = @intFromPtr(handle) + offset;
    out.* = dev.io.inb(@truncate(addr));

    return c.UACPI_STATUS_OK;
}

fn ioRead16(
    handle: c.uacpi_handle, offset: c.uacpi_size, out: *u16
) callconv(.c) c.uacpi_status {
    const addr = @intFromPtr(handle) + offset;
    out.* = dev.io.inw(@truncate(addr));

    return c.UACPI_STATUS_OK;
}

fn ioRead32(
    handle: c.uacpi_handle, offset: c.uacpi_size, out: *u32
) callconv(.c) c.uacpi_status {
    const addr = @intFromPtr(handle) + offset;
    out.* = dev.io.inl(@truncate(addr));

    return c.UACPI_STATUS_OK;
}

fn ioWrite8(
    handle: c.uacpi_handle, offset: c.uacpi_size, in: u8
) callconv(.c) c.uacpi_status {
    const addr = @intFromPtr(handle) + offset;
    dev.io.outb(@truncate(addr), in);

    return c.UACPI_STATUS_OK;
}

fn ioWrite16(
    handle: c.uacpi_handle, offset: c.uacpi_size, in: u16
) callconv(.c) c.uacpi_status {
    const addr = @intFromPtr(handle) + offset;
    dev.io.outw(@truncate(addr), in);

    return c.UACPI_STATUS_OK;
}

fn ioWrite32(
    handle: c.uacpi_handle, offset: c.uacpi_size, in: u32
) callconv(.c) c.uacpi_status {
    const addr = @intFromPtr(handle) + offset;
    dev.io.outl(@truncate(addr), in);

    return c.UACPI_STATUS_OK;
}

/// Allocate a block of memory of 'size' bytes.
/// The contents of the allocated memory are unspecified.
fn alloc(size: usize) callconv(.c) ?*anyopaque {
    if (size > vm.gpa.max_alloc_size) {
        @branchHint(.cold);
        log.warn("allocate big buffer: {} KiB", .{size / lib.kb_size});

        var pages = vm.bytesToPages(size);
        var virt = vm.heapReserve(pages);

        while (pages > 0) {
            const curr_pages = @min(pages, vm.PageAllocator.max_alloc_pages);
            const phys = vm.PageAllocator.alloc(vm.pagesToRankExact(curr_pages)) orelse return null;

            vm.getRootPt().map(
                virt, phys, curr_pages, .{ .global = true, .write = true }
            ) catch return null;

            pages -= curr_pages;
            virt += @as(usize, curr_pages) * vm.page_size;
        }

        log.debug("\t0x{x}", .{virt});
        return @ptrFromInt(virt);
    }

    const allocated = vm.gpa.alloc(size) orelse return null;
    return allocated;
}

/// Allocate a block of memory of 'size' bytes.
/// The returned memory block is expected to be zero-filled.
fn allocZeroed(size: c.uacpi_size) callconv(.c) ?*anyopaque {
    const mem: [*]u8 = @ptrCast(alloc(size) orelse return null);
    @memset(mem[0..size], 0);

    log.debug("alloc zeroed: 0x{x}", .{@intFromPtr(mem)});
    return mem;
}

/// Free a previously allocated memory block.
/// 'mem' might be a NULL pointer. In this case, the call is assumed to be a no-op.
fn free(mem: ?*anyopaque) callconv(.c) void {
    if (mem == null) return;

    const virt = @intFromPtr(mem);
    if (virt < vm.lma_start) {
        log.warn("free big buffer: 0x{x}", .{virt});
        return;
    }

    vm.gpa.free(mem);
}

/// Returns the number of nanosecond ticks elapsed since boot,
/// strictly monotonic.
fn getNanosecondsSinceBoot() callconv(.c) u64 {
    return sys.time.getUpTime().toNs();
}

/// Spin for N microseconds.
fn stall(usec: u8) callconv(.c) void {
    const nsec = @as(u64, usec) * std.time.ns_per_us;
    const begin = sys.time.getUpTime().toNs();
    var end = begin;

    while (end -% begin >= nsec) {
        dev.io.delay(1024);
        end = sys.time.getUpTime().toNs();
    }
}

/// Sleep for N milliseconds.
fn sleep(msec: u64) callconv(.c) void {
    sched.sleepFor(msec * std.time.ns_per_ms) catch {};
}

/// Create/free an opaque non-recursive kernel mutex object.
fn createMutex() callconv(.c) c.uacpi_handle {
    const mut = vm.gpa.create(lib.sync.Mutex) orelse return null;
    mut.* = .{};

    log.debug("create mutex: 0x{x}", .{@intFromPtr(mut)});
    return mut;
}

fn freeMutex(handle: c.uacpi_handle) callconv(.c) void {
    vm.gpa.free(handle);
}

/// Create/free an opaque kernel (semaphore-like) event object.
fn createEvent() callconv(.c) c.uacpi_handle {
    const sem = vm.gpa.create(lib.sync.RwSemaphore) orelse return null;
    sem.* = .{};

    log.debug("create event: 0x{x}", .{@intFromPtr(sem)});
    return sem;
}

fn freeEvent(handle: c.uacpi_handle) callconv(.c) void {
    vm.gpa.free(handle);
}

/// Returns a unique identifier of the currently executing thread.
/// The returned thread id cannot be UACPI_THREAD_ID_NONE.
fn getThreadId() callconv(.c) c.uacpi_thread_id {
    return sched.getCurrentTask();
}

/// Disable interrupts and return an kernel-defined value representing the
/// "before" state. This value is used in the subsequent call to restore the
/// prior state.
///
/// Note that this is talking about ALL interrupts on the current CPU, not just
/// those installed by uACPI. This is typically achieved by executing the 'cli'
/// instruction on x86, 'msr daifset, #3' on aarch64 etc.
fn disableInterrupts() callconv(.c) c.uacpi_interrupt_state {
    return @intFromBool(dev.intr.saveAndDisableForCpu());
}

/// Restore the state of the interrupt flags to the kernel-defined value provided
/// in 'state'.
fn restoreInterrupts(state: c.uacpi_interrupt_state) callconv(.c) void {
    dev.intr.restoreForCpu(state != 0);
}

/// Try to acquire the mutex with a millisecond timeout.
///
/// The timeout value has the following meanings:
/// 0x0000 - Attempt to acquire the mutex once, in a non-blocking manner
/// 0x0001...0xFFFE - Attempt to acquire the mutex for at least 'timeout'
///                   milliseconds
/// 0xFFFF - Infinite wait, block until the mutex is acquired
///
/// The following are possible return values:
/// 1. UACPI_STATUS_OK - successful acquire operation
/// 2. UACPI_STATUS_TIMEOUT - timeout reached while attempting to acquire (or the
///                           single attempt to acquire was not successful for
///                           calls with timeout=0)
/// 3. Any other value - signifies a host internal error and is treated as such
fn acquireMutex(handle: c.uacpi_handle, msec: u16) callconv(.c) c.uacpi_status {
    //log.debug("acquire mutex: 0x{x}", .{@intFromPtr(handle)});
    const mut: *lib.sync.Mutex = @alignCast(@ptrCast(handle.?));

    if (msec == 0xFFFF) {
        mut.lock();
        return c.UACPI_STATUS_OK;
    } else if (msec == 0) {
        return if (mut.tryLock()) c.UACPI_STATUS_OK else c.UACPI_STATUS_TIMEOUT;
    }

    const begin = sys.time.getUpTime().toNs(); 
    const nsec = @as(u64, msec) * std.time.ns_per_ms;
    while (true) {
        if (mut.tryLock()) break;

        const curr = sys.time.getUpTime().toNs();
        if (curr -% begin >= nsec) return c.UACPI_STATUS_TIMEOUT;

        sched.yield();
    }

    return c.UACPI_STATUS_OK;
}

fn releaseMutex(handle: c.uacpi_handle) callconv(.c) void {
    //log.debug("release mutex: 0x{x}", .{@intFromPtr(handle)});
    const mut: *lib.sync.Mutex = @alignCast(@ptrCast(handle.?));
    mut.unlock();
}

/// Try to wait for an event (counter > 0) with a millisecond timeout.
/// A timeout value of 0xFFFF implies infinite wait.
///
/// The internal counter is decremented by 1 if wait was successful.
/// A successful wait is indicated by returning UACPI_TRUE.
fn waitForEvent(handle: c.uacpi_handle, _: u16) callconv(.c) bool {
    log.debug("wait for event: 0x{x}", .{@intFromPtr(handle)});
    // FIXME: Implement timeout in milliseconds
    const sem: *lib.sync.RwSemaphore = @alignCast(@ptrCast(handle.?));

    sem.lock.lock();
    defer sem.lock.unlock();

    while (sem.readers == 0) {
        sched.waitUnlock(&sem.wait_queue, &sem.lock, false) catch unreachable;
        sem.lock.lock();
    }

    return true;
}

/// Signal the event object by incrementing its internal counter by 1.
/// This function may be used in interrupt contexts.
fn signalEvent(handle: c.uacpi_handle) callconv(.c) void {
    log.debug("signal event: 0x{x}", .{@intFromPtr(handle)});
    const sem: *lib.sync.RwSemaphore = @alignCast(@ptrCast(handle.?));

    sem.lock.lock();
    defer sem.lock.unlock();

    sem.readers += 1;
    sched.awakeAll(&sem.wait_queue);
}

/// Reset the event counter to 0.
fn resetEvent(handle: c.uacpi_handle) callconv(.c) void {
    log.debug("reset event: 0x{x}", .{@intFromPtr(handle)});
    const sem: *lib.sync.RwSemaphore = @alignCast(@ptrCast(handle.?));
    sem.readers = 0;
}

/// Handle a firmware request.
/// Currently either a Breakpoint or Fatal operators.
fn firmwareRequest(request: *c.uacpi_firmware_request) callconv(.c) c.uacpi_status {
    if (request.type == c.UACPI_FIRMWARE_REQUEST_TYPE_BREAKPOINT) return c.UACPI_STATUS_OK;
    return c.UACPI_STATUS_NO_HANDLER;
}

/// Install an interrupt handler at 'irq', 'ctx' is passed to the provided
/// handler for every invocation.
///
/// 'out_irq_handle' is set to a kernel-implemented value that can be used to
/// refer to this handler from other API.
fn installInterruptHandler(
    irq: u32, func: c.uacpi_interrupt_handler, ctx: c.uacpi_handle, out_handle: *c.uacpi_handle
) callconv(.c) c.uacpi_status {
    @setRuntimeSafety(false);

    log.debug("install irq: {}: 0x{x}", .{irq, @intFromPtr(func)});

    const handle = vm.gpa.create(Irq) orelse return c.UACPI_STATUS_OUT_OF_MEMORY;
    handle.* = .{ .ctx = ctx, .func = func, .pin = irq };

    dev.intr.requestIrq(@truncate(irq), @ptrCast(handle), &irqHandler, .edge, true) catch {
        vm.gpa.free(handle);
        return c.UACPI_STATUS_ALREADY_EXISTS;
    };

    out_handle.* = handle;
    return c.UACPI_STATUS_OK;
}

/// Uninstall an interrupt handler. 'irq_handle' is the value returned via
/// 'out_irq_handle' during installation.
fn uninstallInterruptHandler(
    _: c.uacpi_interrupt_handler, irq_handle: c.uacpi_handle
) callconv(.c) c.uacpi_status {
    @setRuntimeSafety(false);
    log.debug("uninstall irq: 0x{x}", .{@intFromPtr(irq_handle)});
    const handle: *Irq = @alignCast(@ptrCast(irq_handle));

    dev.intr.releaseIrq(@truncate(handle.pin) , @ptrCast(handle));
    vm.gpa.free(handle);

    return c.UACPI_STATUS_OK;
}

fn irqHandler(device: *dev.Device) bool {
    const handle: *const Irq = @ptrCast(device);
    log.debug("irq handler: 0x{x}", .{@intFromPtr(handle)});

    return handle.func.?(handle.ctx) == c.UACPI_INTERRUPT_HANDLED;
}

/// Create/free a kernel spinlock object.
/// Unlike other types of locks, spinlocks may be used in interrupt contexts.
fn createSpinlock() callconv(.c) c.uacpi_handle {
    const lock = vm.gpa.create(lib.sync.Spinlock) orelse return null;
    lock.* = .{};

    log.debug("create spinlock: 0x{x}", .{@intFromPtr(lock)});
    return lock;
}

fn freeSpinlock(handle: c.uacpi_handle) callconv(.c) void {
    vm.gpa.free(handle);
}

// Lock/unlock helpers for spinlocks.
//
// These are expected to disable interrupts, returning the previous state of cpu
// flags, that can be used to possibly re-enable interrupts if they were enabled
// before.
//
// Note that lock is infalliable.
fn lockSpinlock(handle: c.uacpi_handle) callconv(.c) c.uacpi_cpu_flags {
    log.debug("lock spinlock: 0x{x}", .{@intFromPtr(handle)});
    const lock: *lib.sync.Spinlock = @ptrCast(handle.?);
    lock.lockSaveIntr();

    return 0;
}

fn unlockSpinlock(handle: c.uacpi_handle, _: c.uacpi_cpu_flags) callconv(.c) void {
    log.debug("unlock spinlock: 0x{x}", .{@intFromPtr(handle)});
    const lock: *lib.sync.Spinlock = @ptrCast(handle.?);
    lock.unlockRestoreIntr();
}

const WorkType = enum(c.uacpi_work_type) {
    /// Schedule a GPE handler method for execution.
    /// This should be scheduled to run on CPU0 to avoid potential SMI-related
    /// firmware bugs.
    gpe_execution,
    /// Schedule a Notify(device) firmware request for execution.
    /// This can run on any CPU.
    notification,
};

/// Schedules deferred work for execution.
/// Might be invoked from an interrupt context.
fn scheduleWork(
    @"type": c.uacpi_work_type, func: c.uacpi_work_handler, ctx: c.uacpi_handle
) callconv(.c) c.uacpi_status {
    const t: WorkType = @enumFromInt(@"type");
    switch (t) {
        .gpe_execution => {},
        .notification => {}
    }

    log.warn("schedule work: {t}: {*}({*})", .{t, func, ctx});    
    return c.UACPI_STATUS_INTERNAL_ERROR;
}

// Waits for two types of work to finish:
// 1. All in-flight interrupts installed via uacpi_kernel_install_interrupt_handler
// 2. All work scheduled via uacpi_kernel_schedule_work
//
// Note that the waits must be done in this order specifically.
fn waitForWorkCompletion() callconv(.c) c.uacpi_status {
    // FIXME: Implement
    sched.yield();
    log.warn("wait for work completion: unimplemented", .{});
    return c.UACPI_STATUS_OK;
}

fn kernelLog(level: c.uacpi_log_level, msg: [*:0]const u8, ...) callconv(.c) void {
    const span = std.mem.span(msg);

    switch (level) {
        c.UACPI_LOG_DEBUG => log.debug("{s}", .{span[0..span.len -% 1]}),
        c.UACPI_LOG_INFO => log.info("{s}", .{span[0..span.len -% 1]}),
        c.UACPI_LOG_WARN => log.warn("{s}", .{span[0..span.len -% 1]}),
        c.UACPI_LOG_ERROR => log.err("{s}", .{span[0..span.len -% 1]}),
        c.UACPI_LOG_TRACE => log.info("trace: {s}", .{span[0..span.len -% 1]}),
        else => {},
    }
}