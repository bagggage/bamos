//! Kernel API bindings

const std = @import("std");
const opts = @import("opts");

const arch = @import("kernel.zig").arch;
const dev = @import("dev.zig");
const lib = @import("lib.zig");
const sched = @import("sched.zig");
const smp = @import("smp.zig");
const sys = @import("sys.zig");
const vfs = @import("vfs.zig");
const video = @import("video.zig");
const vm =  @import("vm.zig");

extern "kernel" const kernel_lib: Kernel;

const Instance = if (opts.is_kernel) @import("kernel") else @TypeOf(&kernel_lib);

const Kernel = struct {
    arch: struct {
        context: struct {
            init: *const fn (usize, usize) arch.Context,
            initUnaligned: *const fn (usize, usize) arch.Context,
            initWorker: *const fn (usize, usize, usize) arch.Context,
        },
        getCpuInfo: *const fn () *arch.Cpu,
    },
    dev: struct {
        bus: struct {
            addDevice: *const fn (*dev.Bus, *dev.Device, ?*const dev.Driver) void,
            removeDevice: *const fn (*dev.Bus, *dev.Device) void,
            addDriver: *const fn (*dev.Bus, *dev.Driver) void,
            removeDriver: *const fn (*dev.Bus, *dev.Driver) void,
        },
        classes: struct {
            drive: struct {
                const Drive = dev.classes.Drive;

                getIoRequest: *const fn (*Drive.io.Control, u16) *Drive.io.Request,
                setup: *const fn (*Drive, dev.Name, *vfs.devfs.Region, bool, bool) Drive.Error!void,
                deinit: *const fn (*Drive) void,
                onObjectAdd: *const fn (*Drive) void,
                completeIo: *const fn (*Drive, u16, Drive.io.Status) void,
                ioAsync: *const fn (*Drive, Drive.io.Operation, usize, []u8, Drive.io.Request.Callback) void,
                ioSync: *const fn (*Drive, Drive.io.Operation, usize, []u8) Drive.Error!void,
                getPartition: *const fn (*Drive, u32) ?*vfs.Partition,
            },
            framebuffer: struct {
                const Framebuffer = dev.classes.Framebuffer;

                setup: *const fn (
                    *Framebuffer,
                    []const u8,
                    *const Framebuffer.Operations,
                    u16,
                    u16,
                    u32,
                    video.Color.Format,
                    usize,
                    usize,
                    u32,
                ) vfs.Error!void,
            },
            input: struct {
                const Input = dev.classes.Input;

                setup: *const fn (*Input, Input.Kind) Input.Error!void,
                deinit: *const fn (*Input) void,
                createHandle: *const fn (*Input, *Input.Event.Handler) Input.Error!*Input.Event.Handle,
                deleteHandle: *const fn (*Input, *Input.Event.Handle) void,
                createListener: *const fn (*Input) Input.Error!*Input.Event.Listener,
                deleteListener: *const fn (*Input, *Input.Event.Listener) void,
                safeNotifyListeners: *const fn (*Input) void,
                notifyListeners: *const fn (*Input) void,
                processEvent: *const fn (*Input, Input.Event) void,
            },
            teletype: struct {
                const Teletype = dev.classes.Teletype;

                setup: *const fn (
                    *Teletype,
                    []const u8,
                    *vfs.devfs.Region,
                    vfs.devfs.DevFile.Access,
                    *const Teletype.Operations,
                    ?*anyopaque,
                ) vfs.devfs.Error!void,
                onObjectAdd: *const fn (*Teletype) void,
                bufferInput: *const fn (*Teletype, []const u8) usize,
                bufferInputAtomic: *const fn (*Teletype, []const u8) usize,
                bufferInputByteAtomic: *const fn (*Teletype, u8) bool,
                eraseInputAtomic: *const fn (*Teletype, u32) bool,
                eraseInputLineAtomic: *const fn (*Teletype) void,
                readInput: *const fn (*Teletype, []u8) usize,
                readInputAtomic: *const fn (*Teletype, []u8) usize,
                readAllWaitInput: *const fn (*Teletype, []u8) Teletype.Error!void,
                waitForInput: *const fn (*Teletype) void,
                writeOutput: *const fn (*Teletype, []const u8) Teletype.Error!usize,
                writeOutputAtomic: *const fn (*Teletype, []const u8) Teletype.Error!usize,
                bufferOutput: *const fn (*Teletype, []const u8) usize,
                discardOutput: *const fn (*Teletype) void,
                discardInput: *const fn (*Teletype) void,
                attachSessionAtomic: *const fn (*Teletype, *sys.Process.Id) vfs.Error!void,
                detachSession: *const fn (*Teletype) void,
                controlSignal: *const fn (*Teletype, sys.Process.Signal) void,
            },
        },
        obj: struct {
            addByTypeId: *const fn (u32, *dev.obj.Node) bool,
            removeByTypeId: *const fn (u32, *dev.obj.Node) bool,
            getObjectsByTypeId: *const fn (u32) ?*dev.obj.List,
            putObjects: *const fn (*dev.obj.List) void,
        },
        io: struct {
            delay: *const fn (u32) void,
            request: *const fn ([:0]const u8, usize, usize, dev.io.Type) ?usize,
            release: *const fn (usize, dev.io.Type) void,
            isAvail: *const fn (usize, usize, dev.io.Type) bool,
        },
        intr: struct {
            const intr = dev.intr;

            requestIrq: *const fn (u8, *dev.Device, intr.Handler.Fn, intr.TriggerMode, bool) intr.Error!void,
            releaseIrq: *const fn (u8, *const dev.Device) void,
            requestMsi: *const fn (*dev.Device, intr.Handler.Fn, intr.TriggerMode, ?u16) intr.Error!u8,
            releaseMsi: *const fn (u8) void,
            getMsiMessage: *const fn (u8) intr.Msi.Message,
            allocVector: *const fn (?u16) ?intr.Vector,
            freeVector: *const fn (intr.Vector) void,
            scheduleImmediate: *const fn (*intr.SoftHandler) void,
            scheduleSoft: *const fn (*intr.SoftHandler) void,
        },
        pci: struct {
            const pci = dev.pci;
            const ConfigSpace = pci.config.ConfigSpace;

            config: struct {
                getBase: *const fn (u16, u8, u8, u8) usize,
                read: *const fn (usize) u32,
                write: *const fn (usize, u32) void,
                initCapability: *const fn (usize, u8) pci.config.Capability,
                readBar: *const fn (*const ConfigSpace, u3) pci.config.Bar,
                getMaxBus: *const fn (usize) usize,
            },
            intr: struct {
                init: *const fn (ConfigSpace) pci.intr.Control,
                request: *const fn (*pci.intr.Control, ConfigSpace, u8, u8, pci.intr.Types) pci.intr.Error!u8,
                release: *const fn (*pci.intr.Control) void,
                setup: *const fn (
                    *pci.intr.Control,
                    *dev.Device, u16,
                    dev.intr.Handler.Fn,
                    dev.intr.TriggerMode,
                    ?u16,
                ) dev.intr.Error!void,
                maskIdx: *const fn (*pci.intr.Control, u8, bool) bool,
            },
            findDevice: *const fn (u16, u8, u8, u8) ?*pci.Device,
        },
        registerBus: *const fn (*dev.Bus) void,
        getBusByHash: *const fn (u32) ?*dev.Bus,
        getKernelDriver: *const fn () *dev.Driver,
    },
    sched: struct {
        task: struct {
            create: *const fn (sched.Task.Specific, usize) vm.Error!*sched.Task,
            createWorker: *const fn ([]const u8, sched.Task.WorkerFn, lib.AnyData) vm.Error!*sched.Task,
            delete: *const fn (*sched.Task) void,
            createKernelStack: *const fn () vm.Error!usize,
        },
        sleep_queue: struct {
            const Entry = sched.SleepQueue.Entry;

            push: *const fn (*sched.SleepQueue, *Entry) void,
            removeWeak: *const fn (*sched.SleepQueue, *Entry) void,
            process: *const fn (*sched.SleepQueue, usize) ?*Entry,
        },
        isInitialized: *const fn () bool,
        rebornAsKernelTask: *const fn (*sched.Task, []const u8) void,
        enqueue: *const fn (*sched.Task) void,
        terminate: *const fn () noreturn,
        pause: *const fn () void,
        pauseUnlock: *const fn (*lib.sync.Spinlock) void,
        pauseUnlockIntr: *const fn (*lib.sync.Spinlock) void,
        wait: *const fn (*sched.WaitQueue) void,
        waitUnlock: *const fn (*sched.WaitQueue, *lib.sync.Spinlock) void,
        waitUnlockIntr: *const fn (*sched.WaitQueue, *lib.sync.Spinlock) void,
        waitEnableIntr: *const fn (*sched.WaitQueue) void,
        resumeTask: *const fn (*sched.Task) void,
        awake: *const fn (*sched.WaitQueue) ?*sched.Task,
        awakeEntry: *const fn (*sched.WaitQueue.Entry) bool,
        awakeAll: *const fn (*sched.WaitQueue) void,
        getTimeGranuleMs: *const fn () u32,
    },
    smp: struct {
        cpus_data: *[]smp.LocalData,
    },
    sys: struct {
        process: struct {
            id: struct {
                new: *const fn () ?*sys.Process.Id,
                delete: *const fn (*sys.Process.Id) void,
                deref: *const fn (*sys.Process.Id) void,
                lookup: *const fn (u32) ?*sys.Process.Id,
                sendSignalToGroupAtomic: *const fn (*sys.Process.Id, sys.Process.Signal) void,
                waitForGroupEvent: *const fn (*sys.Process.Id) *sys.Process.Id,
            },
            init: *const fn (usize, *vfs.Dentry, *vfs.Dentry) vm.Error!sys.Process,
            create: *const fn (usize, *vfs.Dentry, *vfs.Dentry) vm.Error!*sys.Process,
            clone: *const fn (*sys.Process) vfs.Error!*sys.Process,
            clear: *const fn (*sys.Process) *sched.Task,
            deinit: *const fn (*sys.Process) void,
            delete: *const fn (*sys.Process) void,
            format: *const fn (*const sys.Process, *std.Io.Writer) std.Io.Writer.Error!void,
            addChild: *const fn (*sys.Process, *sys.Process) void,
            removeChild: *const fn (*sys.Process, *sys.Process) void,
            createTask: *const fn (*sys.Process) vm.Error!*sched.Task,
            pushTask: *const fn (*sys.Process, *sched.Task) void,
            detachTask: *const fn (*sys.Process, *sched.Task) void,
            attackControlTermnial: *const fn (*sys.Process, *dev.class.Teletype) vfs.Error!void,
            pageFault: *const fn (*sys.Process, usize, vm.FaultCause) bool,
            spawnSession: *const fn (*sys.Process) void,
            terminateThreads: *const fn (*sys.Process) ?*sched.Task,
            terminate: *const fn (*sys.Process, u8) void,
            waitChildExit: *const fn (*sys.Process, bool) ?*sys.Process.Id,
            sendSignal: *const fn (*sys.Process, sys.Process.Signal) void,
            sendSignalAtomic: *const fn (*sys.Process, sys.Process.Signal) void,
        },
        map_unit: struct {
            const MapUnit = sys.AddressSpace.MapUnit;

            new: *const fn (?*vfs.File, usize, u32, u32, MapUnit.Flags) vfs.Error!*MapUnit,
            fork: *const fn (*MapUnit) vm.Error!*MapUnit,
            delete: *const fn (*MapUnit, *vm.PageTable) void,
            map: *const fn (*MapUnit, *vm.PageTable) vm.Error!void,
            unmap: *const fn (*MapUnit, *vm.PageTable) void,
            unmapRegion: *const fn (*MapUnit, u32, u32, *vm.PageTable) vm.Error!void,
            shrinkTop: *const fn (*MapUnit, u32, *vm.PageTable) vm.Error!void,
            shrinkBottom: *const fn (*MapUnit, u32, *vm.PageTable) vm.Error!void,
            moveBaseUp: *const fn (*MapUnit, u32) void,
            moveBaseDown: *const fn (*MapUnit, u32) void,
            attachPage: *const fn (*MapUnit, vm.Page) vm.Error!*vm.Page,
            attachAndMapPage: *const fn (*MapUnit, *vm.PageTable, vm.Page, vm.MapFlags) vm.Error!*vm.Page,
            detachLastPage: *const fn (*MapUnit) ?vm.Page,
            remapPage: *const fn (*MapUnit, *vm.PageTable, vm.Page, vm.MapFlags) vm.Error!*vm.Page,
            reinsertRegion: *const fn (*MapUnit, *MapUnit, u32, u32) vm.Error!void,
            getPageSafe: *const fn (*MapUnit, *vm.PageTable, u32, vm.FaultCause) vfs.Error!*vm.Page,
            copyPages: *const fn (*MapUnit, *MapUnit) vm.Error!void,
            pageFault: *const fn (*MapUnit, *vm.PageTable, usize, vm.FaultCause) vfs.Error!void,
        },
        input: struct {
            const Input = dev.classes.Input;

            registerDevice: *const fn (*Input) Input.Error!void,
            unregisterDevice: *const fn (*Input) void,
            registerHandler: *const fn (Input.Kind, *Input.Event.Handler) Input.Error!void,
            unregisterHandler: *const fn (Input.Kind, *Input.Event.Handler) void,
        },
        time: struct {
            const DateTime = sys.time.DateTime;
            const Time = sys.time.Time;

            date_time: struct {
                format: *const fn (DateTime, *std.Io.Writer) std.Io.Writer.Error!void,
                fromTime: *const fn (Time) DateTime,
                getYearDay: *const fn (DateTime) u16,
            },
            time: struct {
                fromDateTime: *const fn (DateTime) Time,
                formatDt: *const fn (Time, *std.Io.Writer) std.Io.Writer.Error!void,
                formatUs: *const fn (Time, *std.Io.Writer) std.Io.Writer.Error!void,
                formatNs: *const fn (Time, *std.Io.Writer) std.Io.Writer.Error!void,
                formatSec: *const fn (Time, *std.Io.Writer) std.Io.Writer.Error!void,
                format: *const fn (Time, *std.Io.Writer) std.Io.Writer.Error!void,
            },
            getDateTime: *const fn () DateTime,
            setDateTime: *const fn (DateTime) void,
            getTicks: *const fn () usize,
            getTime: *const fn () Time,
            getBootTime: *const fn () Time,
            getUpTime: *const fn () Time,
            getCachedTime: *const fn () Time,
            getCachedUpTime: *const fn () Time,
            getEpoch: *const fn () u64,
        },
    },
    logger: struct {
        putLog: *const fn ([]const u8, [*:0]const u8, []const u8) void,
        notifyWaiters: *const fn () error{Timeout}!void,
        panic: *const fn ([]const u8, ?*std.builtin.StackTrace, ?usize) noreturn,
    },
    lib: struct {
        mutext: struct {
            lock: *const fn (*lib.sync.Mutex) void,
            lockIntr: *const fn (*lib.sync.Mutex) void,
            lockSaveIntr: *const fn (*lib.sync.Mutex) void,
            unlock: *const fn (*lib.sync.Mutex) void,
            unlockIntr: *const fn (*lib.sync.Mutex) void,
            unlockRestoreIntr: *const fn (*lib.sync.Mutex) void,
        },
    },
    vfs: struct {
        dentry: struct {
            initName: *const fn ([]const u8) vm.Error!vfs.Dentry.Name,
            deinit: *const fn (*vfs.Dentry) void,
            lookup: *const fn (*vfs.Dentry, []const u8) ?*vfs.Dentry,
            makeDirectory: *const fn (*vfs.Dentry, []const u8, vfs.CreateOptions) vfs.Error!*vfs.Dentry,
            createFile: *const fn (*vfs.Dentry, []const u8, vfs.CreateOptions) vfs.Error!*vfs.Dentry,
            open: *const fn (*vfs.Dentry, vfs.Permissions) vfs.Error!*vfs.File,
            onClose: *const fn (*vfs.Dentry, *vfs.File) void,
            addChild: *const fn (*vfs.Dentry, *vfs.Dentry) void,
            removeChild: *const fn (*vfs.Dentry, *vfs.Dentry) void,
            touch: *const fn (*vfs.Dentry, sys.time.Time, ?sys.time.Time) vfs.Error!void,
            deref: *const fn (*vfs.Dentry) void,
        },
        file: struct {
            deref: *const fn (*vfs.File) void,
        },
        lookup_cache: struct {
            get: *const fn (u64) ?*vfs.Dentry,
            insert: *const fn (u64, *vfs.Dentry) void,
            remove: *const fn (u64) ?*vfs.Dentry,
            calcHash: *const fn (*const vfs.Dentry, []const u8) u64,
        },
        parts: struct {
            probe: *const fn (*vfs.Drive) vfs.Drive.Error!void,
        },
        pipe: struct {
            create: *const fn (u16) vm.Error![2]*vfs.File,
            delete: *const fn (*vfs.Pipe) void,
        },
        internals: struct {
            cachedRead: *const fn (*const vfs.File, usize, []u8) vfs.Error!usize,
            cachedWrite: *const fn (*vfs.File, usize, []const u8) vfs.Error!usize,
            cachedPageFault: *const fn (*sys.AddressSpace.MapUnit, *vm.PageTable, usize, vm.FaultCause) vfs.Error!*vm.Page,
            cachedUnmapPage: *const fn (*const sys.AddressSpace.MapUnit, *const vm.PageTable, vm.Page) void,
        },
        mount: *const fn (*vfs.Dentry, []const u8, ?*vfs.devfs.BlockDev) vfs.Error!*vfs.Dentry,
        tryMount: *const fn (*vfs.Dentry, *vfs.devfs.BlockDev) vfs.Error!*vfs.Dentry,
        registerFs: *const fn (*vfs.FileSystem) bool,
        unregisterFs: *const fn (*vfs.FileSystem) void,
        getFs: *const fn ([]const u8) *vfs.FileSystem,
        lookupRaw: *const fn (?*vfs.Dentry, ?*vfs.Dentry, []const u8, bool) vfs.Error!*vfs.Dentry,
        tryLookup: *const fn (?*vfs.Dentry, ?*vfs.Dentry, []const u8) ?*vfs.Dentry,
        resolveSymLink: *const fn (*vfs.Dentry) vfs.Error!*vfs.Dentry,
        changeRoot: *const fn (*vfs.Dentry) vfs.Error!void,
        getRootWeak: *const fn () *vfs.Dentry,
    },
    vm: struct {
        gpa: struct {
            alloc: *const fn (usize) callconv(.c) ?*anyopaque,
            free: *const fn (?*anyopaque) callconv(.c) void,
            getStdAllocator: *const fn () std.mem.Allocator,
        },
        page: struct {
            new: *const fn (u32, u8) ?*vm.Page,
            delete: *const fn (*vm.Page) void,
        },
        page_allocator: struct {
            alloc: *const fn (u8) ?usize,
            free: *const fn (usize, u8) void,
        },
        page_table: struct {
            translateVirtToPhys: *const fn (*const vm.PageTable, usize) ?usize,
            accessPageAttributes: *const fn (*const vm.PageTable, usize) vm.Page.Attributes,
            map: *const fn (*vm.PageTable, usize, usize, u32, vm.MapFlags) vm.Error!void,
            unmap: *const fn (*vm.PageTable, usize, u32) void,
            format: *const fn (*std.Io.Writer, *const vm.PageTable) std.Io.Writer.Error!void,
        },
        object_allocator: struct {
            deinit: *const fn (*vm.ObjectAllocator) void,
            alloc: *const fn (*vm.ObjectAllocator) ?*anyopaque,
            free: *const fn (*vm.ObjectAllocator, usize) void,
        },
        createPageTable: *const fn () ?*vm.PageTable,
        getRootPt: *const fn () *vm.PageTable,
        heapReserve: *const fn (u32) void,
        heapRelease: *const fn (usize, u32) void,
        unmmio: *const fn (usize, u32) void,
    },
};

pub inline fn getInstance() Instance {
    return if (opts.is_kernel) @import("kernel") else &kernel_lib;
}
