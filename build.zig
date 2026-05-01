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
        });
        // Workaround for Zig 0.16 wasi libc bug: rt.c fails to build with
        // exception_handling enabled because zig doesn't pass `-mllvm
        // -wasm-enable-sjlj` to its own libc compile. We instead leave
        // exception_handling out of the cpu features and shadow
        // <setjmp.h> via include/wasm/ so lua's compile picks up our
        // own runtime in src/wasm_stubs.c. Routed through zlua's
        // `lua_user_h` option which adds the file's directory to the
        // lua compile's include path.
        const zlua_wasm = b.dependency("zlua", .{
            .target = wasm_target,
            .optimize = .ReleaseFast,
            .lang = .lua52,
            .lua_user_h = b.path("include/wasm/user.h"),
        });
        const web_mod = b.createModule(.{
            .root_source_file = b.path("src/main_web.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        web_mod.addImport("zlua", zlua_wasm.module("zlua"));
        web_mod.linkSystemLibrary("wasi-emulated-process-clocks", .{});
        web_mod.linkSystemLibrary("wasi-emulated-signal", .{});
        // Override the broken bundled wasi setjmp.h — see include/wasm/setjmp.h
        web_mod.addIncludePath(b.path("include/wasm"));
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

    // Headless cart runner — no SDL window/audio, scriptable input, PPM screenshots
    const run_cart_mod = b.createModule(.{
        .root_source_file = b.path("src/run_cart.zig"),
        .target = target,
        .optimize = optimize,
    });
    run_cart_mod.addImport("zlua", zlua_dep.module("zlua"));
    run_cart_mod.linkLibrary(sdl_dep.artifact("SDL3"));
    const run_cart_exe = b.addExecutable(.{
        .name = "run_cart",
        .root_module = run_cart_mod,
    });
    b.installArtifact(run_cart_exe);
    const run_cart_run = b.addRunArtifact(run_cart_exe);
    if (b.args) |args| run_cart_run.addArgs(args);
    const run_cart_step = b.step("run-cart", "Run the headless cart runner: zig build run-cart -- <cart> [script]");
    run_cart_step.dependOn(&run_cart_run.step);

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
