//! # Input-output subsystem implementation

/// Write a byte into a I\O port.
pub inline fn outb(byte: u8, port: u16) void {
    asm volatile("outb %[d],%[p]"::[d]"{al}"(byte),[p]"{dx}"(port));
}

/// Write a word into a I\O port.
pub inline fn outw(word: u16, port: u16) void {
    asm volatile("outw %[d],%[p]"::[d]"{ax}"(word),[p]"{dx}"(port));
}

/// Write a double word into a I\O port.
pub inline fn outl(dword: u32, port: u16) void {
    asm volatile("outl %[d],%[p]"::[d]"{eax}"(dword),[p]"{dx}"(port));
}

/// Read a byte from I\O port.
pub inline fn inb(port: u16) u8 {
    var res: u8 = undefined;

    asm("inb %[p],%[r]":[r]"={al}"(res):[p]"{dx}"(port));
    return res;
}

/// Read a word from I\O port.
pub inline fn inw(port: u32) u16 {
    var res: u16 = undefined;

    asm("inw %[p],%[r]":[r]"={ax}"(res):[p]"{dx}"(port));
    return res;
}

/// Read a double word from I\O port.
pub inline fn inl(port: u32) u32 {
    var res: u32 = undefined;

    asm("inl %[p],%[r]":[r]"={eax}"(res):[p]"{dx}"(port));
    return res;
}
