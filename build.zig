const std = @import("std");

const src_path = "src";
const dest_path = "bin";

pub fn build(b: *std.Build) void {
    const kernel_step = b.step("kernel", "Build the kernel");
    const docs_step = b.step("docs", "Generate documentation");

    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .cpu_arch = .x86_64,
        .ofmt = .elf
    });
    const optimize = b.standardOptimizeOption(.{});

    const dbg_module = b.addModule("dbg-info", .{
        .root_source_file = b.path(src_path++"/debug-maker/dbg.zig"),
        .optimize = optimize,
        .strip = true,
        .red_zone = false,
        .target = target,
    });
    const kernel_obj = b.addObject(.{
        .name = "bamos",
        .root_source_file = b.path(src_path++"/kernel/main.zig"),
        .omit_frame_pointer = false,
        .optimize = optimize,
        .target = target,
        .code_model = .kernel,
        .pic = true,
    });

    kernel_obj.root_module.addImport("dbg-info", dbg_module);
    kernel_obj.addIncludePath(b.path("third-party/boot"));

    const dbg_maker = b.addExecutable(.{
        .name = "dbg-maker",
        .root_source_file = b.path(src_path++"/debug-maker/main.zig"),
        .optimize = .ReleaseFast,
        .target = b.host,
    });

    const maker_run = b.addRunArtifact(dbg_maker);
    maker_run.addArtifactArg(kernel_obj);
    maker_run.addArg("-o");
    const maker_sym = maker_run.addOutputFileArg("debug.sym");
    const maker_script = maker_sym.dirname().path(b, "debug.sym.zig");

    const dbg_obj = b.addObject(.{
        .name = "dbg-script",
        .root_source_file = maker_script,
        .code_model = .kernel,
        .optimize = optimize,
        .target = target,
        .pic = true,
    });
    dbg_obj.root_module.addImport("dbg-info", dbg_module);

    const kernel_exe = b.addExecutable(.{
        .name = "bamos.kernel",
        .root_source_file = b.path(src_path++"/kernel/start.zig"),
        .omit_frame_pointer = false,
        .optimize = optimize,
        .target = target,
        .code_model = .kernel,
        .pic = true,
    });
    kernel_exe.addObject(kernel_obj);
    kernel_exe.addObject(dbg_obj);
    kernel_exe.setLinkerScript(b.path("config/kernel.ld"));

    const kernel_install = b.addInstallArtifact(kernel_exe, .{
        .dest_dir = .{ .override = .{ .custom = dest_path } }
    });

    kernel_step.dependOn(&kernel_install.step);

    const docs_install = b.addInstallDirectory(.{
        .source_dir = kernel_obj.getEmittedDocs(),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "docs"
    });
    docs_step.dependOn(&docs_install.step);
}
