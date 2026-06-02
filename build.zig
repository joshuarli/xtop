const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build-time options embedded into every module.
    const opts = b.addOptions();
    opts.addOption([]const u8, "version", "0.1.0");

    // Library module — the public API surface (types, parsers, store).
    // Tests run against this module, validating the API independently.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addOptions("build_options", opts);

    // Library tests
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_tests.step);

    // Render/TUI integration tests — needs direct file access since
    // render.zig and tui.zig live in the executable module, not the library.
    const test_runner_mod = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_runner_mod.addImport("xtop", lib_mod);
    const render_tests = b.addTest(.{
        .root_module = test_runner_mod,
    });
    const run_render_tests = b.addRunArtifact(render_tests);
    test_step.dependOn(&run_render_tests.step);

    // Executable — imports the library via `@import("xtop")`
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("xtop", lib_mod);
    exe_mod.addOptions("build_options", opts);

    const exe = b.addExecutable(.{
        .name = "xtop",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run xtop");
    run_step.dependOn(&run_cmd.step);
}
