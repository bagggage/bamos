const kernel_main = @import("src/kernel/main.zig");

pub const panic = kernel_main.panic;
pub const std_options = kernel_main.std_options;

pub export fn main() noreturn {
    kernel_main.main();
}
