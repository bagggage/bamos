//! # TTY line discipline

// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

const LineDiscipline = Teletype.LineDiscipline;
const linux = std.os.linux;
const control_code = std.ascii.control_code;
const log = std.log.scoped(.@"Teletype.tty");
const Teletype = @import("../Teletype.zig");
const sys = @import("../../../sys.zig");

pub const self: LineDiscipline = .{
    .name = "tty",
    .ops = .{
        .setup = &setup,
        .read = &read,
        .receive = &receive,
        .write = &write,
    }
};

fn setup(tty: *Teletype) Teletype.Error!void {
    tty.config.iflag = .{
        .ICRNL = true,
        .IGNBRK = true,
        .BRKINT = true,
    };
    tty.config.oflag = .{
        .OPOST = true,
        .ONLCR = true,
        .ONOCR = true,
    };
    tty.config.lflag = .{
        .ECHO = true,
        .ECHOE = true,
        .ECHOKE = true,
        .ECHOCTL = true,
        .ICANON = true,
        .ISIG = true
    };

    tty.config.cc[@intFromEnum(Teletype.V.ERASE)] = control_code.del;
    tty.config.cc[@intFromEnum(Teletype.V.KILL)]  = control_code.nak;
    tty.config.cc[@intFromEnum(Teletype.V.INTR)]  = control_code.etx;
    tty.config.cc[@intFromEnum(Teletype.V.SUSP)]  = control_code.sub;
    tty.config.cc[@intFromEnum(Teletype.V.QUIT)]  = control_code.fs;
    tty.config.cc[@intFromEnum(Teletype.V.EOF)]   = control_code.eot;
    tty.config.cc[@intFromEnum(Teletype.V.LNEXT)] = control_code.syn;
    tty.config.cc[@intFromEnum(Teletype.V.START)] = control_code.xon;
    tty.config.cc[@intFromEnum(Teletype.V.STOP)]  = control_code.xoff;
}

fn read(tty: *Teletype, buffer: []u8) Teletype.Error!usize {
    if (tty.config.lflag.ICANON) return canonicalRead(tty, buffer);

    const v_min = tty.config.cc[@intFromEnum(linux.V.MIN)];
    const to_read = if (buffer.len < v_min) buffer.len else v_min;

    const readed = tty.readInput(buffer);
    if (readed < to_read) {
        try tty.readAllWaitInput(buffer[readed..to_read]);
        return to_read;
    }

    return readed;
}

fn canonicalRead(tty: *Teletype, buffer: []u8) Teletype.Error!usize {
    tty.in_lock.lock();
    defer tty.in_lock.unlock();

    while (tty.inputEmpty()) {
        tty.in_lock.unlock();
        defer tty.in_lock.lock();

        tty.waitForInput();
    }

    return tty.readInputAtomic(buffer);
}

fn receive(tty: *Teletype, buffer: []const u8) Teletype.Error!void {
    tty.in_lock.lock();
    defer tty.in_lock.unlock();

    if (tty.in_buffer.len == 0) return;
    if (tty.config.lflag.ICANON) return canonicalReceive(tty, buffer);

    _ = tty.bufferInputAtomic(buffer);
    tty.notifyInputReceived();
}

fn canonicalReceive(tty: *Teletype, buffer: []const u8) void {
    const erase = tty.config.cc[@intFromEnum(Teletype.V.ERASE)];
    const kill = tty.config.cc[@intFromEnum(Teletype.V.KILL)];
    const intr = tty.config.cc[@intFromEnum(Teletype.V.INTR)];
    const susp = tty.config.cc[@intFromEnum(Teletype.V.SUSP)];
    const quit = tty.config.cc[@intFromEnum(Teletype.V.QUIT)];
    const eof = tty.config.cc[@intFromEnum(Teletype.V.EOF)];
    const lnext = tty.config.cc[@intFromEnum(Teletype.V.LNEXT)];

    for (buffer) |c| {
        if (isLiteralNext(tty)) {
            @branchHint(.unlikely);
            putByte(tty, c);
        } else if (c == control_code.cr and !tty.config.iflag.IGNCR) {
            const out: u8 = if (tty.config.iflag.ICRNL) control_code.lf else control_code.cr;
            putByte(tty, out);
        } else if (c == erase) {
            const success = tty.eraseInputAtomic(1);
            if (success and tty.config.lflag.ECHOE) echoEraseSequence(tty);
        } else if (c == kill) {
            const pos = tty.in_buffer.pos;
            tty.eraseInputLineAtomic();

            if (tty.config.lflag.ECHOKE) {
                const len = (pos -% tty.in_buffer.pos) & (tty.in_buffer.len - 1);
                for (0..len) |_| echoEraseSequence(tty);
            } else if (tty.config.lflag.ECHOK) {
                tty.flushRaw(&.{control_code.lf}) catch {};
            }
        } else if (c == intr) {
            sendControlSignal(tty, intr, .INTR);
        } else if (c == susp) {
            sendControlSignal(tty, susp, .SUSP);
        } else if (c == quit) {
            sendControlSignal(tty, quit, .QUIT);
        } else if (c == eof) {
            tty.notifyInputReceived();
            echoControl(tty, eof);
            return;
        } else if (c == lnext) {
            setLiteralNext(tty);
        } else {
            putByte(tty, c);
        }
    }
}

fn write(tty: *Teletype, buffer: []const u8) Teletype.Error!usize {
    const writen = if (tty.config.lflag.ICANON) blk: {
        break :blk try canonicalWrite(tty, buffer);
    } else blk: {
        tty.out_lock.lock();
        defer tty.out_lock.unlock();

        break :blk try tty.writeOutput(buffer);
    };

    if (tty.out_buffer.pos > 0) try tty.flush();
    return writen;
}

fn canonicalWrite(tty: *Teletype, buffer: []const u8) Teletype.Error!usize {
    tty.out_lock.lock();
    defer tty.out_lock.unlock();

    for (buffer) |c| {
        if (c == control_code.cr and tty.config.oflag.ONOCR) {
            continue;
        } else if (c == control_code.cr and tty.config.oflag.OCRNL) {
            try tty.writeOutputByteAtomic('\n');
        } else if (c == control_code.lf and tty.config.oflag.ONLCR) {
            _ = try tty.writeOutputAtomic("\r\n");
        } else {
            try tty.writeOutputByteAtomic(c);
        }
    }

    return buffer.len;
}

fn putByte(tty: *Teletype, byte: u8) void {
    if (!tty.bufferInputByteAtomic(byte)) {
        @branchHint(.unlikely);

        if (tty.config.iflag.IMAXBEL) tty.flushRaw(&.{control_code.bel}) catch {};
        if (tty.config.iflag.IXOFF) {
            const vstop = tty.config.cc[@intFromEnum(Teletype.V.STOP)];
            tty.flushRaw(&.{vstop}) catch {};
        }
        return;
    }

    if (tty.config.lflag.ECHO or
        (byte == control_code.lf and tty.config.lflag.ECHONL)
    ) {
        if (tty.config.oflag.OPOST) {
            if (byte == control_code.lf and tty.config.oflag.ONLCR) {
                tty.flushRaw("\r\n") catch {};
            } else {
                tty.flushRaw(&.{byte}) catch {};
            }
        } else {
            tty.flushRaw(&.{byte}) catch {};
        }
    }

    if (byte == control_code.lf) tty.notifyInputReceived(); 
}

fn sendControlSignal(tty: *Teletype, code: u8, comptime ctrl: Teletype.V) void {
    const sig: sys.Process.Signal = comptime switch (ctrl) {
        .INTR => .Interrupt,
        .SUSP => .TerminalStop,
        .QUIT => .Quit,
        else => @compileError("Invalid control code to signal convertion")
    };

    echoControl(tty, code);
    if (!tty.config.lflag.ISIG) return;

    if (ctrl != .SUSP and !tty.config.lflag.NOFLSH) tty.eraseInputLineAtomic();
    tty.controlSignal(sig);
}

fn echoControl(tty: *Teletype, code: u8) void {
    if (!tty.config.lflag.ECHOCTL) return;
    tty.flushRaw(&.{'^', code + 0x40}) catch {};
}

inline fn echoEraseSequence(tty: *Teletype) void {
    comptime std.debug.assert(control_code.bs == '\x08');
    tty.flushRaw("\x08\x20\x08") catch {};
}

inline fn isLiteralNext(tty: *Teletype) bool {
    defer tty.config.iflag._15 = 0;
    return tty.config.iflag._15 != 0;
}

inline fn setLiteralNext(tty: *Teletype) void {
    tty.config.iflag._15 = 1;
}
