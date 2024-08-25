const std = @import("std");

const src_path = "src";
const dest_path = "bin";

pub fn build(b: *std.Build) void {
    const kernel_step = b.step("kernel", "Build the kernel");
    const docs_step = b.step("docs", "Generate documentation");

    const kernel_install = makeKernel(b);
    kernel_step.dependOn(kernel_install);

    const docs_install = makeDocs(b);
    docs_step.dependOn(docs_install);
}

fn makeKernel(b: *std.Build) *std.Build.Step {
    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target CPU architecture");
    const optimize = b.standardOptimizeOption(.{});
    const emitAsm = b.option(bool, "emit-asm", "Generate assembler code file");

    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .cpu_arch = arch orelse .x86_64,
        .ofmt = .elf
    });

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
        .error_tracing = false,
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
        .strip = false,
        .pic = true,
    });
    kernel_exe.addObject(kernel_obj);
    kernel_exe.addObject(dbg_obj);
    kernel_exe.setLinkerScript(b.path("config/kernel.ld"));

    const kernel_install = b.addInstallArtifact(kernel_exe, .{
        .dest_dir = .{ .override = .{ .custom = dest_path } }
    });

    if (emitAsm) |value| {
        if (value) {
            const asm_install = b.addInstallFile(kernel_obj.getEmittedAsm(), "kernel.asm");
            kernel_install.step.dependOn(&asm_install.step);
        }
    }

    return &kernel_install.step;
}

fn makeDocs(b: *std.Build) *std.Build.Step {
    const html_file = b.addInstallFileWithDir(
        b.path(src_path++"/docs/index.html"),
        .{ .custom = "../docs" },
        "index.html"
    );
    const js_file = b.addInstallFileWithDir(
        b.path(src_path++"/docs/main.js"),
        .{ .custom = "../docs" },
        "main.js"
    );

    const wasm = b.addExecutable(.{
        .name = "main",
        .root_source_file = b.path(src_path++"/docs/wasm/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
            .cpu_features_add = std.Target.wasm.featureSet(&.{
                .atomics,
                .bulk_memory,
                // .extended_const, not supported by Safari
                .multivalue,
                .mutable_globals,
                .nontrapping_fptoint,
                .reference_types,
                //.relaxed_simd, not supported by Firefox or Safari
                .sign_ext,
                // observed to cause Error occured during wast conversion :
                // Unknown operator: 0xfd058 in Firefox 117
                //.simd128,
                // .tail_call, not supported by Safari
            })
        }),
        .optimize = .ReleaseSmall,
        .strip = false
    });
    wasm.rdynamic = true;
    wasm.entry = std.Build.Step.Compile.Entry.disabled;

    const wasm_install = b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../docs" } },
        .dest_sub_path = "main.wasm",
    });

    const tar_maker = b.addExecutable(.{
        .name = "tar-maker",
        .root_source_file = b.path(src_path++"/docs/tar/main.zig"),
        .target = b.host,
        .optimize = .ReleaseFast,
        .strip = true
    });
    var tar_run = b.addRunArtifact(tar_maker);
    tar_run.addArg("-o");
    const tar_file = tar_run.addOutputFileArg("sources.tar");
    tar_run.addArg("-src");
    tar_run.addDirectoryArg(b.path(src_path++"/kernel"));
    tar_run.addArgs(&.{"-n", "bamos"});

    const tar_install = b.addInstallFileWithDir(
        tar_file,
        .{ .custom = "../docs" },
        "sources.tar"
    );

    tar_install.step.dependOn(&wasm_install.step);
    tar_install.step.dependOn(&js_file.step);
    tar_install.step.dependOn(&html_file.step);

    return &tar_install.step;
}
