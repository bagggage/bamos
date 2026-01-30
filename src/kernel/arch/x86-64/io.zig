//! # Input-output subsystem implementation

/// Write a byte into a I\O port.
pub inline fn outb(port: u16, byte: u8) void {
    asm volatile ("outb %[d],%[p]"
        :
        : [d] "{al}" (byte),
          [p] "{dx}" (port),
    );
}

/// Write a word into a I\O port.
pub inline fn outw(port: u16, word: u16) void {
    asm volatile ("outw %[d],%[p]"
        :
        : [d] "{ax}" (word),
          [p] "{dx}" (port),
    );
}

/// Write a double word into a I\O port.
pub inline fn outl(port: u16, dword: u32) void {
    asm volatile ("outl %[d],%[p]"
        :
        : [d] "{eax}" (dword),
          [p] "{dx}" (port),
    );
}

/// Read a byte from I\O port.
pub inline fn inb(port: u16) u8 {
    var res: u8 = undefined;

    asm volatile ("inb %[p],%[r]"
        : [r] "={al}" (res),
        : [p] "{dx}" (port),
    );
    return res;
}

/// Read a word from I\O port.
pub inline fn inw(port: u16) u16 {
    var res: u16 = undefined;

    asm volatile ("inw %[p],%[r]"
        : [r] "={ax}" (res),
        : [p] "{dx}" (port),
    );
    return res;
}

/// Read a double word from I\O port.
pub inline fn inl(port: u16) u32 {
    var res: u32 = undefined;

    asm volatile ("inl %[p],%[r]"
        : [r] "={eax}" (res),
        : [p] "{dx}" (port),
    );
    return res;
}

pub inline fn delay() void {
    asm volatile(
        \\ mul %rax
        \\ sub $1, %rax
        ::: .{ .rax = true, .rdx = true });
}
