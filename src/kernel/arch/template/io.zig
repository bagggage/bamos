//! # I/O Subsystem
//! 
//! The subsystem should implement functionality
//! for reading/writing operations to input/output ports.
//! 
//! Some architectures **may not support** port operations.
//! In such cases, certain modifications to the
//! architecture-independent code or device driver code
//! might be necessary to accommodate this feature.

/// Write a byte into a I\O port.
pub inline fn outb(port: u16, byte: u8) void {
    _ = byte;
    _ = port;
}

/// Write a word into a I\O port.
pub inline fn outw(port: u16, word: u16) void {
    _ = word;
    _ = port;
}

/// Write a double word into a I\O port.
pub inline fn outl(port: u16, dword: u32) void {
    _ = dword;
    _ = port;
}

/// Read a byte from I\O port.
pub inline fn inb(port: u16) u8 {
    _ = port;
}

/// Read a word from I\O port.
pub inline fn inw(port: u16) u16 {
    _ = port;
}

/// Read a double word from I\O port.
pub inline fn inl(port: u16) u32 {
    _ = port;
}
