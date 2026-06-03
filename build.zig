const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const maru_mod = b.addModule("maru", .{
        .root_source_file = b.path("src/maru.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "maru-dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "maru", .module = maru_mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the development CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{
        .root_module = maru_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all Zig tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
