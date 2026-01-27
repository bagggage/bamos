// Copyright (C) 2024-2026 Konstantin Pigulevskiy (bagggage@github)

const std = @import("std");
const builtin = @import("builtin");

const src_dir = "src";

const qemu_cores_default = 4;
const qemu_ram_default = "128M";

// Build tools
var dbg_make_exe: *std.Build.Step.Compile = undefined;
var tar_exe: *std.Build.Step.Compile = undefined;
var zip_exe: *std.Build.Step.Compile = undefined;

pub fn build(b: *std.Build) void {
    const kernel_step = b.step("kernel", "Build the kernel");
    const image_step = b.step("iso", "Build the kernel and create bootable image");
    const qemu_step = b.step("qemu", "Run qemu and boot generated image");
    const docs_step = b.step("docs", "Generate documentation");

    const arch = b.option(std.Target.Cpu.Arch, "arch", "The target CPU architecture") orelse .x86_64;

    makeTools(b);

    const kernel = makeKernel(b, arch);
    kernel_step.dependOn(&kernel.step);

    const image = makeImage(b, image_step, kernel) catch return;
    image_step.dependOn(&image.step);

    const qemu = runQemu(b, arch, image);
    qemu_step.dependOn(&qemu.step);

    const docs_install = makeDocs(b, kernel);
    docs_step.dependOn(docs_install);

    // Make `zig build [install]` same as `zig build iso`
    b.getInstallStep().dependOn(&image.step);
}

fn makeKernel(b: *std.Build, arch: std.Target.Cpu.Arch) *std.Build.Step.InstallArtifact {
    const name = b.option([]const u8, "exe-name", "Name of the kernel executable");
    const optimize = b.standardOptimizeOption(.{});

    var cpu_feat: std.Target.Cpu.Feature.Set = .empty;
    if (arch == .x86_64) {
        cpu_feat.addFeature(@intFromEnum(std.Target.x86.Feature.avx));
    }

    const target = b.resolveTargetQuery(.{
        .os_tag = .freestanding,
        .cpu_arch = arch,
        .cpu_features_add = cpu_feat,
        .ofmt = .elf
    });

    const dbg_module = b.createModule(.{
        .root_source_file = b.path("build-tools/dbg-make/dbg.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
        .red_zone = false,
    });

    const kernel_obj = b.addObject(.{
        .name = "bamos",
        .root_module = b.createModule(.{
            .root_source_file = b.path(src_dir++"/kernel/main.zig"),
            .omit_frame_pointer = if (optimize == .Debug or optimize == .ReleaseSafe) false else null,
            .optimize = optimize,
            .target = target,
            .code_model = .kernel,
            .error_tracing = false,
            .pic = true
        }),
        .use_llvm = true
    });

    kernel_obj.root_module.addImport("dbg-info", dbg_module);
    kernel_obj.addIncludePath(b.path("third-party/boot"));

    const zon = @import("build.zig.zon");
    const kernel_opts = b.addOptions();

    const timestamp = makeTimestamp(b, optimize);
    defer b.allocator.free(timestamp);

    const build_string = b.fmt("{s}-{t}: Zig {f} # {s}", .{
        zon.version, optimize, builtin.zig_version, timestamp
    });
    const kernel_ver = std.SemanticVersion.parse(zon.version) catch blk: {
        const parse_fail = b.addFail("Failed to parse version from build.zig.zon");
        kernel_obj.step.dependOn(&parse_fail.step);
        break :blk std.SemanticVersion{.major = 0, .minor = 0, .patch = 0};
    };

    kernel_opts.addOption([]const u8, "os_name", "BamOS");
    kernel_opts.addOption(std.SemanticVersion, "version", kernel_ver);
    kernel_opts.addOption([]const u8, "version_string", b.fmt("{f}", .{kernel_ver}));
    kernel_opts.addOption([]const u8, "build", build_string);

    kernel_obj.root_module.addOptions("opts", kernel_opts);

    const maker_run = b.addRunArtifact(dbg_make_exe);
    maker_run.addArtifactArg(kernel_obj);
    maker_run.addArg("-o");
    const maker_sym = maker_run.addOutputFileArg("debug.sym");
    const maker_script = maker_sym.dirname().path(b, "debug.sym.zig");

    const dbg_obj = b.addObject(.{
        .name = "dbg-script",
        .root_module = b.createModule(.{
            .root_source_file = maker_script,
            .code_model = .kernel,
            .optimize = optimize,
            .target = target,
            .pic = true
        }),
        .use_llvm = true
    });
    dbg_obj.root_module.addImport("dbg-info", dbg_module);

    const kernel_exe = b.addExecutable(.{
        .name = name orelse "bamos.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path(src_dir++"/kernel/start.zig"),
            .omit_frame_pointer = if (optimize == .Debug) false else null,
            .optimize = optimize,
            .target = target,
            .code_model = .kernel,
            .strip = false,
            .pic = true
        }),
        .use_llvm = true
    });
    kernel_exe.addObject(kernel_obj);
    kernel_exe.addObject(dbg_obj);
    kernel_exe.setLinkerScript(b.path("config/kernel.ld"));

    const kernel_install = b.addInstallArtifact(kernel_exe, .{});

    return kernel_install;
}

fn makeDocs(b: *std.Build, kernel: *std.Build.Step.InstallArtifact) *std.Build.Step {
    const docs_dir: std.Build.InstallDir = .{ .custom = "../docs" };
    const html_file = b.addInstallFileWithDir(
        b.path(src_dir++"/docs/index.html"),
        docs_dir,
        "index.html"
    );
    const logo_file = b.addInstallFileWithDir(
        b.path(src_dir++"/docs/logo.svg"),
        docs_dir,
        "logo.svg"
    );
    const js_file = b.addInstallFileWithDir(
        b.path(src_dir++"/docs/main.js"),
        docs_dir,
        "main.js"
    );

    const kernel_docs = kernel.artifact.getEmittedDocs();
    const wasm_install = b.addInstallFile(
        kernel_docs.path(b, "main.wasm"),
        "../docs/main.wasm"
    );

    var tar_run = b.addRunArtifact(tar_exe);
    tar_run.setCwd(b.path(""));
    tar_run.addArgs(&.{"-o", "docs/sources.tar", "-s", "src/kernel", "-n", "bamos"});

    wasm_install.step.dependOn(&tar_run.step);
    wasm_install.step.dependOn(&logo_file.step);
    wasm_install.step.dependOn(&js_file.step);
    wasm_install.step.dependOn(&html_file.step);

    return &wasm_install.step;
}

fn makeImage(b: *std.Build, step: *std.Build.Step, kernel: *std.Build.Step.InstallArtifact) !*std.Build.Step.InstallFile {
    const mkbootimg = try getMkbootimg(b, step);
    const mk_cfg_path = b.path("config/bootboot.json");
    const bt_cfg_path = b.path("config/boot.env");

    const mk_cfg_install = b.addInstallFile(mk_cfg_path, "bootboot.json");
    const bt_cfg_install = b.addInstallFile(bt_cfg_path, "boot.env");

    const mk_run = std.Build.Step.Run.create(b, "run mkbootimg");
    mk_run.setCwd(.{ .cwd_relative = b.install_path });
    mk_run.addFileArg(mkbootimg);
    mk_run.addFileArg(mk_cfg_path);
    mk_run.addFileInput(bt_cfg_path);
    mk_run.addFileInput(kernel.artifact.getEmittedBin());
    mk_run.step.dependOn(&bt_cfg_install.step);
    mk_run.step.dependOn(&kernel.step);

    const image_path = mk_run.addOutputFileArg("bamos.iso");
    const image_install = b.addInstallFile(image_path, "bamos.iso");

    image_install.step.dependOn(&mk_cfg_install.step);

    return image_install;
}

fn runQemu(b: *std.Build, arch: std.Target.Cpu.Arch, image: *std.Build.Step.InstallFile) *std.Build.Step.Run {
    const enable_gdb = b.option(bool, "qemu-gdb", "Enable GDB server (default: false)") orelse false;
    const enable_serial = b.option(bool, "qemu-serial", "Serial output to stdout (default: true)") orelse true;
    const enable_trace = b.option(bool, "qemu-trace", "Enable interrupts tracing (default: false)") orelse false;
    const enable_kvm = b.option(bool, "qemu-kvm", "Enable KVM acceleration") orelse true;
    const cpu_num = b.option(u5, "qemu-cpus", "QEMU machine cpus number (default: 4)") orelse qemu_cores_default;
    const ram_size = b.option([]const u8, "qemu-ram", "QEMU machine RAM size (default: "++qemu_ram_default++")") orelse qemu_ram_default;
    const drives = b.option([]const []const u8, "qemu-drives", "QEMU additional NVMe drives (paths to images)") orelse &.{};
    const no_gui = b.option(bool, "qemu-nogui", "Disable graphical output") orelse false;
    const no_uefi = b.option(bool, "qemu-noefi", "Legacy BIOS firmware") orelse false;

    const qemu_name = switch (arch) {
        .x86,
        .x86_64 => "qemu-system-x86_64",
        else => @panic("unsupported architecture")
    };

    const qemu_run = b.addSystemCommand(&.{
        qemu_name,
        "-nic", "none",
        "-no-reboot",
        "-machine", "q35",
        "-m", ram_size
    });

    if (no_uefi == false) {
        qemu_run.addArg("-bios");
        qemu_run.addFileArg(b.path("third-party/uefi/OVMF-efi.fd"));
    }

    if (enable_gdb) qemu_run.addArg("-s");
    if (enable_trace) qemu_run.addArgs(&.{"-d", "int"});

    if (enable_serial and !no_gui) {
        qemu_run.addArgs(&.{
            "-chardev", "stdio,id=char0",
            "-serial",  "chardev:char0",
        });
    }

    if (no_gui) qemu_run.addArg("-nographic");

    if (cpu_num > 1) {
        qemu_run.addArgs(&.{"-smp", b.fmt("cores={}", .{cpu_num})});
    }

    // Add boot drive
    qemu_run.addArg("-drive");
    qemu_run.addPrefixedFileArg("id=boot,format=raw,if=none,file=", image.source);
    qemu_run.addArgs(&.{"-device", "ide-hd,drive=boot,bootindex=0"});
    qemu_run.step.dependOn(&image.step);

    // Add additional drives as NVMe devices
    for (drives, 0..) |drive, i| {
        qemu_run.addArgs(&.{
            "-drive", b.fmt("file={s},if=none,id=drv{}", .{drive, i}),
            "-device", b.fmt("nvme,serial=QEMU-DRIVE-{},drive=drv{}", .{i, i})
        });
    }

    // Enable KVM on linux
    if (enable_kvm and builtin.os.tag == .linux and !enable_trace) {
        qemu_run.addArgs(&.{"-enable-kvm", "-cpu", "host"});
    } else {
        qemu_run.addArgs(&.{"-cpu", "max"});
    }

    return qemu_run;
}

fn makeTools(b: *std.Build) void {
    dbg_make_exe = b.addExecutable(.{
        .name = "dbg-make",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build-tools/dbg-make/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .strip = true
        })
    });
    tar_exe = b.addExecutable(.{
        .name = "tar",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build-tools/tar/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .strip = true
        })
    });
    zip_exe = b.addExecutable(.{
        .name = "zip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build-tools/zip/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .strip = true
        })
    });
}

fn makeTimestamp(b: *std.Build, optimize: std.builtin.OptimizeMode) []const u8 {
    const timestamp: std.time.epoch.EpochSeconds = .{ .secs = @intCast(std.time.timestamp()) };
    const day_secs = timestamp.getDaySeconds();
    const day_year = timestamp.getEpochDay().calculateYearDay();
    const day_month = day_year.calculateMonthDay();

    const time_string = b.fmt(
        "{:0>2}:{:0>2}:{:0>2}",
        .{day_secs.getHoursIntoDay(), day_secs.getMinutesIntoHour(), day_secs.getSecondsIntoMinute()}
    );
    defer b.allocator.free(time_string);

    const timestamp_postfix = switch (optimize) {
        .Debug, .ReleaseSafe => "--:--:--",
        else => time_string
    };

    return b.fmt(
        "{} {t} {:0>4} {s}",
        .{day_month.day_index, day_month.month, day_year.year, timestamp_postfix}
    );
}

fn getMkbootimg(b: *std.Build, step: *std.Build.Step) !std.Build.LazyPath {
    const bootboot_git =
        b.lazyDependency("bootboot_bin", .{}) orelse return error.MkbootimgNotFetched;

    const mkbootimg_zip_name = comptime switch (builtin.os.tag) {
        .linux => "mkbootimg-Linux.zip",
        .macos => "mkbootimg-MacOSX.zip",
        .windows => "mkbootimg-Win.zip",
        else => @compileError("'mkbootimg' is not precompiled for your OS, please make issue on GitHub to fix it")
    };
    const mkbootimg_name = comptime if (builtin.os.tag == .windows) "mkbootimg.exe" else "mkbootimg";
    const mkbootimg_zip_path = bootboot_git.path(mkbootimg_zip_name);

    const mkbootimg_dst = unzip(b, step, mkbootimg_zip_path, "mkbootimg");
    return mkbootimg_dst.path(b, mkbootimg_name);
}

fn unzip(b: *std.Build, step: *std.Build.Step, src: std.Build.LazyPath, dst: []const u8) std.Build.LazyPath {
    const zip_run = b.addRunArtifact(zip_exe);
    zip_run.addFileArg(src);
    zip_run.addArg("-o");
    const output = zip_run.addOutputDirectoryArg(dst);

    step.dependOn(&zip_run.step);
    return output;
}