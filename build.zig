const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ziglua (Lua 5.2) - must use ReleaseFast because Lua's C code
    // relies on integer wrapping (e.g. in hash functions) which Zig's
    // Debug safety checks would trap as signed overflow.
    const zlua_dep = b.dependency("zlua", .{
        .target = target,
        .optimize = .ReleaseFast,
        .lang = .lua52,
    });

    // SDL3
    const sdl_dep = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("zlua", zlua_dep.module("zlua"));
    mod.linkLibrary(sdl_dep.artifact("SDL3"));
    mod.addWin32ResourceFile(.{ .file = b.path("res/icon.rc") });

    const exe = b.addExecutable(.{
        .name = "pico-z",
        .root_module = mod,
    });
    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run pico-z");
    run_step.dependOn(&run_cmd.step);

    // Web (WASM) build — gated behind -Dweb to avoid resolving WASM deps for native builds
    const build_web = b.option(bool, "web", "Build WebAssembly module") orelse false;
    if (build_web) {
        const web_step = b.step("web", "Build WebAssembly module");
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.exception_handling}),
        });
        const zlua_wasm = b.dependency("zlua", .{
            .target = wasm_target,
            .optimize = .ReleaseFast,
            .lang = .lua52,
        });
        const web_mod = b.createModule(.{
            .root_source_file = b.path("src/main_web.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        web_mod.addImport("zlua", zlua_wasm.module("zlua"));
        web_mod.linkSystemLibrary("wasi-emulated-process-clocks", .{});
        web_mod.linkSystemLibrary("wasi-emulated-signal", .{});
        web_mod.addIncludePath(zlua_wasm.artifact("lua").getEmittedIncludeTree());
        web_mod.addCSourceFile(.{ .file = b.path("src/wasm_stubs.c") });
        const web_lib = b.addExecutable(.{
            .name = "pico-z",
            .root_module = web_mod,
        });
        web_lib.entry = .disabled;
        web_lib.rdynamic = true;
        web_lib.root_module.linkSystemLibrary("wasi-emulated-process-clocks", .{});
        web_lib.root_module.linkSystemLibrary("wasi-emulated-signal", .{});
        const web_install = b.addInstallArtifact(web_lib, .{
            .dest_dir = .{ .override = .{ .custom = "../web" } },
            .dest_sub_path = "pico-z.wasm",
        });
        web_step.dependOn(&web_install.step);
        b.getInstallStep().dependOn(&web_install.step);
    }

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zlua", zlua_dep.module("zlua"));
    test_mod.linkLibrary(sdl_dep.artifact("SDL3"));

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
