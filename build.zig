const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // lib mode
    const lib_mod = b.addModule("concurrent_skip_list", .{
        .root_source_file = b.path("src/concurrent_skip_list.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "concurrent_skip_list",
        .linkage = .static,
        .root_module = lib_mod,
    });

    // benchmark module
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });

    // benchmark executable
    const exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = exe_mod,
    });
    exe.root_module.addImport("concurrent_skip_list", lib_mod);

    b.installArtifact(lib);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // args
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // run
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // test
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
