// Copyright (C) 2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");

pub fn addIncludePaths(mod: *std.Build.Module, sources: *std.Build.Dependency) void {
    mod.addIncludePath(sources.path("src/common/sdk/nvidia/inc"));
    mod.addIncludePath(sources.path("src/common/shared/inc"));
    mod.addIncludePath(sources.path("src/common/inc"));
    mod.addIncludePath(sources.path("src/nvidia/arch/nvalloc/common/inc"));
    mod.addIncludePath(sources.path("src/nvidia/arch/nvalloc/unix/include"));
    mod.addIncludePath(sources.path("src/nvidia/interface"));
    mod.addIncludePath(sources.path("src/nvidia/inc"));
    mod.addIncludePath(sources.path("src/nvidia/generated"));
    mod.addIncludePath(sources.path("src/nvidia/kernel/inc"));
}

pub fn make(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode)
    struct { *std.Build.Dependency, std.Build.LazyPath }
{
    const nvidia_sources = b.dependency("nvidia_sources", .{});
    const zig_nvidia = b.dependency("zig_nvidia_open", .{
        .target = target,
        .optimize = optimize,
        .sources = nvidia_sources.path(&.{}),
    });

    return .{ nvidia_sources, zig_nvidia.namedLazyPath("nv-kernel.o") };
}
