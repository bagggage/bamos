const std = @import("std");

const apic = @import("intr/apic.zig");
const log = @import("../../log.zig");
const panic = @import("../../panic.zig");
const pic = @import("intr/pic.zig");
const intr = @import("../../dev/intr.zig");
const regs = @import("regs.zig");
const utils = @import("../../utils.zig");

pub const table_len = 256;

pub const trap_gate_flags = 0x8F;
pub const intr_gate_flags = 0x8E;

pub const kernel_stack = 0;
pub const user_stack = 2;

pub const reserved_vectors = 32;
pub const max_vectors = 256;
pub const avail_vectors = max_vectors - reserved_vectors;

pub const irq_base_vec = reserved_vectors;

const rsrvd_vec_num = 32;

pub const Descriptor = packed struct {
    offset_1: u16 = 0,
    selector: u16 = 0,
    ist: u8 = 0,
    type_attrs: u8 = 0,
    offset_2: u48 = 0,
    rsrvd: u32 = 0,

    pub fn init(isr: u64, stack: u8, attr: u8) @This() {
        var result: @This() = .{
            .ist = stack,
            .type_attrs = attr,
            .selector = regs.getCs()
        };

        result.offset_1 = @truncate(isr);
        result.offset_2 = @truncate(isr >> 16);

        return result;
    }
};

pub const DescTable = [table_len]Descriptor;
const ExceptISR = @TypeOf(&commonExcpHandler);

var base_idt: DescTable = .{Descriptor{}} ** table_len;
var except_handlers: [rsrvd_vec_num]ExceptISR = undefined;

pub fn preinit() void {
    initExceptHandlers();
    useIdt(&base_idt);
}

pub fn init() !intr.Chip {
    pic.init() catch return error.PicIoBusy;

    return blk: {
        apic.init() catch |err| {
            log.warn("APIC initialization failed: {}; using PIC", .{err});
            break :blk pic.chip();
        };

        break :blk apic.chip();  
    };
}

pub inline fn useIdt(idt: *DescTable) void {
    const idtr: regs.IDTR = .{ .base = @intFromPtr(idt), .limit = @sizeOf(DescTable) - 1 };

    regs.setIdtr(idtr);
}

fn initExceptHandlers() void {
    inline for (0..rsrvd_vec_num) |vec| {
        const Handler = ExcpHandler(vec);

        base_idt[vec] = Descriptor.init(
            @intFromPtr(&Handler.isr),
            kernel_stack,
            trap_gate_flags
        );
        except_handlers[vec] = &commonExcpHandler;
    }
}

export fn excpHandlerCaller() callconv(.Naked) noreturn {
    @setRuntimeSafety(false);
    regs.saveState();

    asm volatile (
        \\mov %rsp,%rdi
        \\mov -0x8(%rsp),%rdx
        \\mov -0x10(%rsp),%rsi
    );

    if (comptime (@sizeOf(regs.IntrState) % 0x10) == 0) {
        asm volatile ("sub $0x8,%rsp");
    }

    asm volatile (
        \\mov %[table],%rcx
        \\jmp *(%rcx,%rsi,8)
        :
        : [table] "i" (&except_handlers),
    );
}

fn ExcpHandler(vec: comptime_int) type {
    return struct {
        fn hasErrorCode() bool {
            const vec_with_errors = comptime [_]comptime_int{
                8, 10, 11, 12, 13, 14, 17, 21
            };

            for (vec_with_errors) |entry| {
                if (vec == entry) return true;
            }

            return false;
        }

        pub fn isr() callconv(.Naked) noreturn {
            const size = comptime @sizeOf(regs.CalleeRegs) + @sizeOf(regs.ScratchRegs) + @sizeOf(u64);

            if (comptime hasErrorCode()) {
                asm volatile (std.fmt.comptimePrint("pop -{}(%%rsp)", .{size}));
            } else {
                asm volatile (std.fmt.comptimePrint("movq $0,-{}(%%rsp)", .{size}));
            }

            asm volatile (std.fmt.comptimePrint(
                    \\movq %[vec],-{}(%%rsp)
                    \\jmp excpHandlerCaller
                , .{size + @sizeOf(u64)})
                :
                : [vec] "i" (vec),
            );
        }
    };
}

fn commonExcpHandler(state: *regs.IntrState, vec: u32, error_code: u32) callconv(.C) noreturn {
    log.excp(vec, error_code);
    log.warn(
        \\Regs:
        \\rax: 0x{x}, rcx: 0x{x}, rdx: 0x{x}, rbx: 0x{x}
        \\rip: 0x{x}, rsp: 0x{x}, rbp: 0x{x}, rflags: 0x{x}
        \\r8: 0x{x}, r9: 0x{x}, r10: 0x{x}, r11: 0x{x}
        \\r12: 0x{x}, r13: 0x{x}, r14: 0x{x}, r15: 0x{x}
        \\cr2: 0x{x}, cr3: 0x{x}, cr4: 0x{x}
    , .{
        state.scratch.rax, state.scratch.rcx, state.scratch.rdx, state.callee.rbx,
        state.intr.rip, state.intr.rsp, state.callee.rbp, state.intr.rflags,
        state.scratch.r8, state.scratch.r9, state.scratch.r10, state.scratch.r11,
        state.callee.r12, state.callee.r13, state.callee.r14, state.callee.r15,
        regs.getCr2(), regs.getCr3(), regs.getCr4()
    });

    var it = std.debug.StackIterator.init(state.intr.rip, state.callee.rbp);
    panic.trace(&it);

    utils.halt();
}
