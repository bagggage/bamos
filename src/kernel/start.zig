extern fn main() noreturn;

export fn _start() callconv(.Naked) noreturn {
    @import("utils.zig").arch.startImpl();
}
